"""The first experiment `SPECIALIST.md` calls out to run: fit on 100, 300,
1000, and 3000 labels and plot accuracy, calibration, and separation on a
fixed held-out set. "This is the number that decides whether the moat is
real" (`SPECIALIST.md`, "What we must measure before believing any of it").

**Not run in this session.** Two other agents are benchmarking latency on
this same machine right now (a session constraint on this work), and a real
sweep across four training runs of a 706K-parameter transformer would be
exactly the kind of CPU load that could corrupt their numbers. Every module
underneath this one (`model.py`, `data.py`, `train.py`, `metrics.py`) is
unit-tested on tiny fixtures instead, and `run_scaling_experiment` refuses to
run at all unless `confirm_heavy=True` is passed explicitly — nothing in
this package's test suite passes it.

To actually run it once real `audit.db` data exists:

    from data import load_rows, build_examples
    from scaling import run_scaling_experiment
    rows = load_rows(audit_db_path)
    examples = build_examples(rows)
    report = run_scaling_experiment(examples, confirm_heavy=True)
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from data import Example, time_split
from metrics import MetricsReport, compute_metrics
from model import DEFAULT_CONFIG, make_model
from train import TrainConfig, predict_probs, run_supervised

DEFAULT_SIZES: tuple[int, ...] = (100, 300, 1000, 3000)


@dataclass(frozen=True)
class ScalingPoint:
    n_labels: int
    metrics: MetricsReport


def run_scaling_experiment(
    examples: Sequence[Example],
    *,
    sizes: Sequence[int] = DEFAULT_SIZES,
    train_config: TrainConfig = TrainConfig(epochs=10),
    model_config: dict = DEFAULT_CONFIG,
    confirm_heavy: bool = False,
) -> list[ScalingPoint]:
    """One freshly initialized model per size, trained on that many of the
    earliest labels and evaluated on the same held-out chronological tail,
    so points are comparable to each other and to the teacher's own
    distribution on that tail."""
    if not confirm_heavy:
        raise RuntimeError(
            "run_scaling_experiment is the heavy job named in SPECIALIST.md's "
            "measurement 2 ('how many labels does a useful specialist need'). "
            "It is deliberately not run in this session — see this module's "
            "docstring. Pass confirm_heavy=True once you intend to actually "
            "spend the compute."
        )
    train_all, _val, test = time_split(examples)
    if not train_all:
        raise ValueError("need at least one training example")
    if not test:
        raise ValueError("need a non-empty held-out test split to score against")

    points: list[ScalingPoint] = []
    for size in sizes:
        subset = train_all[:size]
        if not subset:
            continue
        model, collator = make_model(model_config)
        run_supervised(model, collator, subset, train_config)
        probs = predict_probs(model, collator, [example.context for example in test])
        labels = [example.label for example in test]
        points.append(ScalingPoint(n_labels=len(subset), metrics=compute_metrics(probs, labels)))
    return points


__all__ = ["DEFAULT_SIZES", "ScalingPoint", "run_scaling_experiment"]
