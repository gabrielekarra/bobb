"""The any-app task evaluation, on the CPU reference engine.

Scores every step in `bobbd.task_eval.FIXTURE` — files, spreadsheets,
documents, browsers, web forms, code, the terminal, notes, calendar,
reminders, contacts, system settings, viewers, media, presentations,
photos, maps, mail, dialogs, open menus, copying between apps, and apps
read from their pixels — with the shipped weights, generating the text of
every TYPE step and the report of every DONE step, and routes the
command-bar requests in `ROUTES`.

Writes `results/reference/tasks_<ts>.json`. Reference numbers: the
readouts are the shipped model's to within bfloat16 rounding; nothing here
is a latency.

    PYTHONPATH=. uv run --no-sync python -u tools/task_reference_eval.py [case_id ...]
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from torch_reference import TorchEngine, torch_stream_text  # noqa: E402

from bobbd import agent, task_eval  # noqa: E402
from bobbd.generation import clean  # noqa: E402


def main() -> None:
    engine = TorchEngine(threads=4)

    def write(session, observation, target, memory):
        single = agent.is_single_line(target)
        generated = torch_stream_text(engine, agent.write_messages(session, observation, target, memory),
                                      max_tokens=48 if single else 200, temperature=0.0)
        text = clean(generated.text)
        if single:
            text = text.splitlines()[0].strip().strip("“”\"'") if text.strip() else ""
        return text

    def report(session, observation, memory):
        generated = torch_stream_text(engine, agent.report_messages(session, observation, memory),
                                      max_tokens=100, temperature=0.0)
        return clean(generated.text)

    wanted = set(sys.argv[1:])
    cases = [c for c in task_eval.FIXTURE if not wanted or c.id in wanted]
    started = time.time()
    steps = task_eval.run(engine, write=write, report=report, cases=cases)
    print(json.dumps(steps["summary"], indent=2), flush=True)
    routes = task_eval.run_routes(engine) if not wanted else None
    if routes:
        for r in routes["rows"]:
            print(f"{'ok ' if r['ok'] else 'MISS'} {r['route']:6s} {r['p']:.2f}  {r['prompt']}", flush=True)
        print("routes", routes["accuracy"], flush=True)
    out = Path(__file__).resolve().parents[1] / "results" / "reference"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"tasks_{int(time.time())}.json"
    path.write_text(json.dumps({"engine": engine.name, "seconds": round(time.time() - started), "steps": steps,
                                "routes": routes}, indent=2, ensure_ascii=False))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
