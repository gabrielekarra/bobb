"""The judgement evaluation, A/B, on the CPU reference engine.

Three configurations of the `mail.opened` question set, each evaluated on
`judgement_eval.FIXTURE` (25 hand-labelled emails) with the same weights:

  v0.1      message_type asked once, the original urgency rubric
  debias    message_type asked in both option orders, original rubric
  v1        debias plus the urgency rubric that names automated notices
            with a real consequence (the shipped configuration)

Writes `results/reference/judgement_ab_<ts>.json`. These are reference
numbers: the probabilities are the shipped model's to within bfloat16
rounding; nothing here is a latency.

    PYTHONPATH=. uv run --no-sync python -u tools/reference_eval.py
"""

from __future__ import annotations

import dataclasses
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from torch_reference import TorchEngine  # noqa: E402

from leonardd import intents, judgement_eval  # noqa: E402
from leonardd.schema import Score  # noqa: E402

V01_URGENCY = Score(
    name="urgency",
    rubric=(
        "How soon does this email need a response? Use these levels:\n"
        "0 = never; no response is expected at all (newsletter, receipt, automated notice).\n"
        "1 = whenever; a response would be polite but nothing depends on when.\n"
        "2 = this week; a real request with no stated deadline.\n"
        "3 = today or tomorrow; a deadline is stated or implied, or someone is waiting.\n"
        "4 = right now; something breaks, is lost, or escalates if this waits."
    ),
    lo=0,
    hi=4,
)


def configure(name: str) -> None:
    intent = intents.INTENTS["mail.opened"]
    message_type, urgency = intent.questions
    if name == "v0.1":
        questions = (dataclasses.replace(message_type, debias=False), V01_URGENCY)
    elif name == "debias":
        questions = (dataclasses.replace(message_type, debias=True), V01_URGENCY)
    else:
        questions = (dataclasses.replace(message_type, debias=True), intents._URGENCY)
    intents.INTENTS["mail.opened"] = dataclasses.replace(intent, questions=questions)


def summary(report: dict) -> dict:
    by_floor = {row["floor"]: row for row in report["floor_sweep"]}
    return {
        "reply_needed_accuracy": report["reply_needed_accuracy_via_message_type"],
        "letter_order_moved": report["letter_order_bias"]["moved_fraction"],
        **{f"floor_{f:.2f}": {k: by_floor[f][k] for k in ("coverage", "precision", "recall", "tp", "fp", "fn")}
           for f in (0.5, 0.6, 0.7) if f in by_floor},
    }


def main() -> None:
    engine = TorchEngine(threads=4)
    original = intents.INTENTS["mail.opened"]
    results = {}
    for name in ("v0.1", "debias", "v1"):
        configure(name)
        started = time.time()
        report = judgement_eval.run(engine=engine)
        results[name] = {"summary": summary(report), "report": report, "seconds": round(time.time() - started)}
        print(name, json.dumps(results[name]["summary"]), flush=True)
    intents.INTENTS["mail.opened"] = original
    out = Path(__file__).resolve().parents[1] / "results" / "reference"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"judgement_ab_{int(time.time())}.json"
    path.write_text(json.dumps({"engine": engine.name, "configurations": results}, indent=2))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
