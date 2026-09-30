"""Record real daemon frames for the Swift contract tests.

Runs `BobbServer` with the model-free test doubles, drives every v1
request through a real unix socket, and writes each frame the daemon sent
back, verbatim, to `BobbApp/Tests/BobbCoreTests/Fixtures/daemon_frames.jsonl`.
`ContractFixtureTests.swift` decodes every line. If the daemon changes a
frame's shape, rerunning this and the Swift tests shows exactly where the
two sides disagree.

    PYTHONPATH=.:tests uv run --no-sync python tools/export_contract_fixtures.py
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bobbd" / "tests"))

from fake_engine import TrivialEngine  # noqa: E402
from server_helpers import fake_decide_many  # noqa: E402

import bobbd.act as act_mod  # noqa: E402
import bobbd.agent as agent_mod  # noqa: E402
import bobbd.attention as attention_mod  # noqa: E402
import bobbd.server as server_mod  # noqa: E402
from bobbd.attention import AttentionEngine  # noqa: E402
from bobbd.audit import open_db  # noqa: E402
from bobbd.generation import Generated  # noqa: E402
from bobbd.memory import MemoryStore  # noqa: E402
from bobbd.server import BobbServer  # noqa: E402

OUT = ROOT / "BobbApp" / "Tests" / "BobbCoreTests" / "Fixtures" / "daemon_frames.jsonl"


def fake_stream(engine, messages, *, max_tokens, on_delta=None, cancel=None, temperature=0.3, prefix=""):
    text = prefix + " confermo per venerdì [1]."
    for piece in (prefix, " confermo", " per venerdì [1]."):
        if piece and on_delta:
            on_delta(piece)
    return Generated(text, 3, 12.0, 3.0, False, "stop")


def fake_agent_decide(engine, context, questions, *, calibrators=None, primed=None):
    """Picks the first option of every question: CLICK, the first target,
    and "do" for routing, so the recorded frames show a real step."""
    from bobbd.schema import Decision, decision_key

    out = []
    for q in questions:
        value = q.labels[1] if q.name == "route" else (q.labels[0] if q.kind != "bool" else True)
        key = decision_key(q.kind, value)
        probabilities = {label: (0.9 if label == key else 0.1 / (len(q.labels) - 1)) for label in q.labels}
        out.append(Decision(name=q.name, kind=q.kind, value=value, probabilities=probabilities,
                            raw_probabilities=probabilities, confidence=0.9, schema_mass=0.98, latency_ms=4.0))
    return out


def fake_plan(engine, messages, **kwargs):
    return Generated(" Apri Spotify\n2. Cerca Focus\n3. Avvia la playlist", 12, 40.0, 5.0, False, "stop")


async def main() -> None:
    agent_mod.decide_many = fake_agent_decide
    agent_mod.supports_generation = lambda engine: True
    agent_mod.stream_text = fake_plan
    attention_mod.decide_many = fake_decide_many
    act_mod.decide_many = fake_decide_many
    server_mod.supports_generation = lambda engine: True
    server_mod.stream_text = fake_stream

    tmp = Path(tempfile.mkdtemp())
    socket_path = Path(f"/tmp/bobbd-fixtures-{uuid.uuid4().hex[:8]}.sock")
    server = BobbServer(
        AttentionEngine(TrivialEngine()), open_db(tmp / "audit.db"), socket_path=socket_path,
        model_name="mlx-community/Llama-3.2-3B-Instruct-4bit", prime_ms=477.0, decide_ms=149.8,
        memory=MemoryStore(tmp / "memory.db"),
    )
    asyncio_server = await server.start()
    serving = asyncio.create_task(asyncio_server.serve_forever())
    reader, writer = await asyncio.open_unix_connection(str(socket_path))
    frames: list[dict] = []

    async def send(frame: dict, replies: int) -> None:
        writer.write((json.dumps(frame) + "\n").encode())
        await writer.drain()
        for _ in range(replies):
            frames.append(json.loads(await asyncio.wait_for(reader.readline(), 5)))

    await send({"t": "hello", "client": "BobbApp", "version": "1.0", "locale": "it"}, 1)
    await send({"t": "settings", "floor": 0.6, "locale": "it", "quiet_hours": None}, 1)
    await send({"t": "memory.observe", "id": "o1", "app": "Slack", "window": "#studio",
                "text": "Giulia: il preventivo di Marco è approvato, possiamo confermare."}, 1)
    await send({"t": "event", "ts": 1790000000.0, "id": "evt_fixture", "kind": "mail.opened", "app": "Mail",
                "payload": {"sender": "Marco Rossi <marco@studiorossi.it>", "subject": "Preventivo",
                            "body": "Ciao Gabriele, mi confermi il preventivo entro venerdì?", "thread_len": 2,
                            "unread": True, "message_id": "<m1@studiorossi.it>", "typing": False, "idle": False}}, 2)
    decision = frames[-1]
    await send({"t": "approve", "decision_id": decision["id"]}, 4)
    await send({"t": "ask", "id": "ask_fixture", "prompt": "Il preventivo di Marco è approvato?", "mode": "ask"}, 3)
    await send({"t": "memory.search", "id": "req_search", "query": "preventivo"}, 1)
    await send({"t": "memory.stats", "id": "req_mstats"}, 1)
    await send({"t": "stats", "id": "req_stats"}, 1)
    await send({"t": "memory.delete", "id": "req_delete", "scope": "app", "app": "Slack"}, 1)
    await send({"t": "ask", "id": "ask_empty", "prompt": " "}, 1)
    await send({"t": "observe", "id": "obs_fixture", "goal": "Reply", "app": "Mail", "window": "w", "step": 1,
                "candidates": [{"id": "c1", "label": "Reply", "role": "AXButton", "enabled": True},
                               {"id": "done", "label": "Done", "role": "-", "enabled": True},
                               {"id": "escalate", "label": "None", "role": "-", "enabled": True}], "digest": ""}, 1)
    await send({"t": "ask", "id": "ask_route", "prompt": "Metti la playlist Focus su Spotify", "mode": "ask", "route": True}, 1)
    await send({"t": "task.start", "id": "req_task", "task_id": "task_fixture", "goal": "Metti la playlist Focus su Spotify",
                "app": "Finder", "window": "Download", "apps": ["Spotify", "Musica (Music)"]}, 1)
    await send({"t": "observe", "id": "obs_task", "task_id": "task_fixture", "step": 1, "app": "Spotify", "window": "Spotify",
                "digest": "d1",
                "candidates": [{"id": "o1e1", "label": "Focus Flow", "role": "row", "kind": "press", "enabled": True,
                                "focused": False, "value": "", "where": "sidebar"},
                               {"id": "o1e2", "label": "Cosa vuoi ascoltare?", "role": "search field", "kind": "text",
                                "enabled": True, "focused": True, "value": "", "where": ""}],
                "apps": [{"id": "app1", "label": "Musica (Music)"}]}, 1)
    await send({"t": "task.step", "task_id": "task_fixture", "step": 1, "app": "Spotify", "window": "Spotify",
                "operation": "CLICK", "target": "Focus Flow", "target_role": "row", "confidence": 0.9,
                "permission": "allowed", "outcome": "ok", "latency_ms": 180.0, "digest": "d1"}, 0)
    await send({"t": "task.end", "task_id": "task_fixture", "status": "done", "detail": ""}, 0)
    await send({"t": "tasks.recent", "id": "req_tasks", "limit": 5}, 1)
    await send({"t": "history.delete", "id": "req_history"}, 1)
    frames.append(server._status_frame() | {"state": "model_missing", "detail": "mlx-community/Llama-3.2-3B-Instruct-4bit"})

    writer.close()
    serving.cancel()
    asyncio_server.close()
    server.close()
    socket_path.unlink(missing_ok=True)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("".join(json.dumps(f, ensure_ascii=False, sort_keys=True) + "\n" for f in frames))
    print(f"wrote {len(frames)} frames to {OUT}")


if __name__ == "__main__":
    asyncio.run(main())
