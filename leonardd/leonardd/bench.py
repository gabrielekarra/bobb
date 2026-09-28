"""Latency benchmarks against the resident model, written as JSON to `results/`.

All three measurement categories -- per-decision latency, decide_many vs
sequential decide at K=2/4/8, and end-to-end socket latency -- run inside one
loop over repetitions rather than as three back-to-back phases, and every
comparison interleaves its variants within that same repetition. A single
long phase of sustained GPU work absorbs whatever drift the machine produces
next (thermal, memory pressure, a background process) and reports it as if it
belonged to whichever measurement happened to run last; interleaving spreads
that drift evenly across every number instead of hiding it inside one of
them. Every reported figure is a median next to its min/max spread; no bare
mean appears anywhere in the output.

`_check_idle` refuses -- raises `NotIdleError`, writes nothing -- rather than
measuring under load and labelling the result contaminated. A contaminated
benchmark that still looks authoritative in `results/` is worse than no
benchmark at all; a run that never produced a file is unambiguous.
"""

from __future__ import annotations

import asyncio
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from .attention import AttentionEngine
from .audit import open_db
from .decide import decide, decide_many
from .engine import ResidentMLX
from .intents import intent_for
from .schema import Bool, Choice, Score
from .server import LeonardServer

MODEL_ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
RESULTS_DIR = Path(__file__).resolve().parents[1] / "results"
REPS = 6
BATCH_KS = (2, 4, 8)

_EVENT_PAYLOADS: dict[str, dict] = {
    "mail.opened": {
        "sender": "Marco Rossi <marco@example.com>",
        "subject": "Conferma preventivo",
        "body": "Ciao, mi confermi il preventivo entro venerdi? Ho bisogno di una risposta al piu presto, grazie.",
        "thread_len": 3,
        "unread": True,
    },
    "mail.composing": {
        "to": "cliente@example.com",
        "subject": "Re: Preventivo",
        "idle_seconds": 12,
        "draft": "Ciao, riguardo al preventivo che mi hai mandato",
    },
    "text.selected": {
        "text": "quanto fa 12 per 8?",
        "surrounding": "una pagina di calcolo",
    },
}


def _stats(samples_ms: list[float]) -> dict:
    ordered = sorted(samples_ms)
    return {
        "median_ms": round(statistics.median(ordered), 2),
        "min_ms": round(ordered[0], 2),
        "max_ms": round(ordered[-1], 2),
        "n": len(ordered),
        "samples_ms": [round(s, 2) for s in ordered],
    }


def _top_processes(n: int = 5) -> list[dict]:
    try:
        out = subprocess.run(
            ["ps", "-Ao", "pid,pcpu,comm", "-r"], capture_output=True, text=True, timeout=2
        ).stdout.splitlines()
    except Exception:
        return []
    rows = []
    for line in out[1 : n + 1]:
        parts = line.split(None, 2)
        if len(parts) == 3:
            rows.append({"pid": parts[0], "pcpu": parts[1], "comm": parts[2].strip()})
    return rows


class NotIdleError(RuntimeError):
    """The machine did not settle under the idle ceiling within `max_wait_s`.

    A contaminated benchmark that looks authoritative is worse than no
    benchmark: this stops `main()` from ever writing `results/latest_bench.json`
    off a loaded machine. Call `_check_idle(..., refuse=False)` deliberately
    when a labelled dirty reading is wanted anyway (see `README.md`).
    """


def _check_idle(load_ceiling_per_core: float = 0.3, max_wait_s: float = 30.0, *, refuse: bool = True) -> dict:
    try:
        load1, load5, load15 = os.getloadavg()
    except (AttributeError, OSError):
        return {"checked": False}
    cores = os.cpu_count() or 1
    ceiling = cores * load_ceiling_per_core
    waited = 0.0
    while load1 > ceiling and waited < max_wait_s:
        print(
            f"[bench] load average {load1:.2f} > {ceiling:.1f} ({cores} cores) -- "
            f"waiting for it to settle ({waited:.0f}s/{max_wait_s:.0f}s)",
            file=sys.stderr,
        )
        time.sleep(3)
        waited += 3
        load1, load5, load15 = os.getloadavg()
    settled = load1 <= ceiling
    result = {
        "checked": True,
        "load1": load1,
        "load5": load5,
        "load15": load15,
        "cores": cores,
        "ceiling": ceiling,
        "settled": settled,
        "waited_s": waited,
    }
    if not settled:
        result["top_processes"] = _top_processes()
        if refuse:
            raise NotIdleError(
                f"load average {load1:.2f} > ceiling {ceiling:.1f} ({cores} cores) after waiting "
                f"{waited:.0f}s; refusing to measure on a non-idle machine. Top processes: "
                f"{result['top_processes']}"
            )
        print(
            f"[bench] proceeding on a non-idle machine (load1={load1:.2f} > {ceiling:.1f}) -- "
            "numbers below are an upper bound, not a clean-machine baseline; this run was "
            "explicitly requested with refuse=False",
            file=sys.stderr,
        )
    return result


def _hardware_info() -> dict:
    info = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "python": platform.python_version(),
    }
    try:
        chip = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
        mem = subprocess.run(
            ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
        if chip:
            info["cpu_brand"] = chip
        if mem.isdigit():
            info["memory_gb"] = round(int(mem) / (1024**3), 1)
    except Exception:
        pass
    return info


def _event(kind: str, event_id: str) -> dict:
    return {"t": "event", "ts": time.time(), "id": event_id, "kind": kind, "app": "Mail", "payload": _EVENT_PAYLOADS[kind]}


def _question_pool() -> list:
    return [
        Bool(name="deadline_stated", statement="This email states or clearly implies a deadline."),
        Score(name="urgency", rubric="How urgent is a response to this email?", lo=0, hi=4),
        Choice(
            name="message_type",
            question="What kind of message is this?",
            options=("broadcast", "transactional", "personal_no_ask", "personal_request"),
        ),
        Bool(name="tone_risk", statement="The tone of this draft could plausibly cause a problem with the recipient."),
        Choice(
            name="action_kind",
            question="Which action fits best?",
            options=("define", "translate", "compute", "lookup", "none"),
        ),
        Bool(name="actionable", statement="This selected text is something the user would plausibly want help with."),
        Bool(name="relevant", statement="This app switch is something Leonard could actively help with right now."),
        Choice(name="user_state", question="What is the user doing right now?", options=("typing", "reading", "idle", "meeting")),
    ]


async def _run(reps: int) -> dict:
    idle = _check_idle()

    t0 = time.perf_counter()
    engine = ResidentMLX(MODEL_ID)
    load_ms = (time.perf_counter() - t0) * 1000

    t1 = time.perf_counter()
    attention = AttentionEngine(engine, floor=0.60)
    prime_ms = (time.perf_counter() - t1) * 1000

    warm = attention.decide_event(_event("mail.opened", "evt_warmup"))
    warm_decide_ms = warm["latency_ms"]

    tmp_dir = Path(tempfile.mkdtemp(prefix="leonardd-bench-"))
    conn = open_db(tmp_dir / "audit.db")
    socket_path = Path(f"/tmp/leonardd-bench-{uuid.uuid4().hex[:10]}.sock")
    server = LeonardServer(attention, conn, socket_path=socket_path, model_name=attention.engine.name)
    asyncio_server = await server.start()
    serve_task = asyncio.create_task(asyncio_server.serve_forever())
    reader, writer = await asyncio.open_unix_connection(str(socket_path))

    kinds = list(_EVENT_PAYLOADS)
    pool = _question_pool()
    questions_by_k = {k: [pool[i % len(pool)] for i in range(k)] for k in BATCH_KS}
    context = intent_for("mail.opened").context(_event("mail.opened", "evt_ctx"), "reading")

    per_decision_times: dict[str, list[float]] = {k: [] for k in kinds}
    socket_times: list[float] = []
    batched_times: dict[int, list[float]] = {k: [] for k in BATCH_KS}
    sequential_times: dict[int, list[float]] = {k: [] for k in BATCH_KS}

    try:
        for rep in range(reps):
            for kind in kinds:
                d = attention.decide_event(_event(kind, f"evt_pd_{kind}_{rep}"))
                per_decision_times[kind].append(d["latency_ms"])

            event = _event("mail.opened", f"evt_socket_{rep}")
            t0 = time.perf_counter()
            writer.write((json.dumps(event) + "\n").encode("utf-8"))
            await writer.drain()
            await reader.readline()  # trace
            await reader.readline()  # decision
            socket_times.append((time.perf_counter() - t0) * 1000)

            for k in BATCH_KS:
                questions = questions_by_k[k]

                t0 = time.perf_counter()
                decide_many(engine, context, questions, primed=attention.primed)
                batched_times[k].append((time.perf_counter() - t0) * 1000)

                t0 = time.perf_counter()
                for q in questions:
                    decide(engine, context, q, primed=attention.primed)
                sequential_times[k].append((time.perf_counter() - t0) * 1000)
        writer.close()
        await writer.wait_closed()
    finally:
        serve_task.cancel()
        try:
            await serve_task
        except asyncio.CancelledError:
            pass
        asyncio_server.close()
        server.close()
        socket_path.unlink(missing_ok=True)
        conn.close()

    batching = {}
    for k in BATCH_KS:
        b = _stats(batched_times[k])
        s = _stats(sequential_times[k])
        batching[f"k={k}"] = {
            "batched": b,
            "sequential": s,
            "speedup_median": round(s["median_ms"] / b["median_ms"], 3),
        }

    return {
        "ts": time.time(),
        "model": MODEL_ID,
        "hardware": _hardware_info(),
        "idle_check": idle,
        "reps": reps,
        "load_ms": round(load_ms, 2),
        "prime_ms": round(prime_ms, 2),
        "warm_decide_ms": round(warm_decide_ms, 2),
        "per_decision": {kind: _stats(v) for kind, v in per_decision_times.items()},
        "socket_end_to_end": _stats(socket_times),
        "batching_speedup": batching,
    }


def main() -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    report = asyncio.run(_run(REPS))
    out_path = RESULTS_DIR / f"bench_{int(time.time())}.json"
    out_path.write_text(json.dumps(report, indent=2))
    (RESULTS_DIR / "latest_bench.json").write_text(json.dumps(report, indent=2))
    print(f"[bench] wrote {out_path}", file=sys.stderr)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
