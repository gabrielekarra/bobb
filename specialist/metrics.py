"""Calibration and accuracy metrics for the specialist's four-way readout.

Every function takes `probs` (one probability vector per example, summing to
~1 over `model.ACTIONS`) and `labels` (the gold action index). Plain nested
sequences in, plain floats out — no torch dependency, so a hand-computed
fixture is exact, not floating-point-fuzzy through a tensor pipeline.

`separation` (mean confidence when the top prediction is correct minus mean
confidence when it is wrong) is the headline number, not accuracy:
`SPECIALIST.md`'s confidence floor only works as a safety mechanism if a
correct call is reliably more confident than a wrong one, so this is the
number that decides whether a floor can gate anything at all.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

_EPS = 1e-12


def _confidence_and_prediction(probs: Sequence[float]) -> tuple[float, int]:
    prediction = max(range(len(probs)), key=lambda i: probs[i])
    return probs[prediction], prediction


def _check(probs: Sequence[Sequence[float]], labels: Sequence[int]) -> None:
    if len(probs) != len(labels):
        raise ValueError("probs and labels must have the same length")
    if not probs:
        raise ValueError("probs must be non-empty")


def accuracy(probs: Sequence[Sequence[float]], labels: Sequence[int]) -> float:
    _check(probs, labels)
    correct = sum(1 for row, label in zip(probs, labels) if _confidence_and_prediction(row)[1] == label)
    return correct / len(labels)


def brier_score(probs: Sequence[Sequence[float]], labels: Sequence[int]) -> float:
    """Multi-class Brier score: mean over examples of the sum of squared
    errors between the predicted distribution and the one-hot label,
    summed (not averaged) over classes."""
    _check(probs, labels)
    total = 0.0
    for row, label in zip(probs, labels):
        total += sum((p - (1.0 if k == label else 0.0)) ** 2 for k, p in enumerate(row))
    return total / len(labels)


def nll(probs: Sequence[Sequence[float]], labels: Sequence[int]) -> float:
    _check(probs, labels)
    total = sum(-math.log(max(row[label], _EPS)) for row, label in zip(probs, labels))
    return total / len(labels)


def _bins(probs: Sequence[Sequence[float]], labels: Sequence[int], n_bins: int) -> list[dict[str, float]]:
    buckets: list[list[tuple[float, bool]]] = [[] for _ in range(n_bins)]
    for row, label in zip(probs, labels):
        confidence, prediction = _confidence_and_prediction(row)
        index = min(int(confidence * n_bins), n_bins - 1)
        buckets[index].append((confidence, prediction == label))
    result = []
    for bucket in buckets:
        if not bucket:
            continue
        confidences = [c for c, _ in bucket]
        corrects = [1.0 if ok else 0.0 for _, ok in bucket]
        result.append(
            {
                "count": len(bucket),
                "confidence": sum(confidences) / len(bucket),
                "accuracy": sum(corrects) / len(bucket),
            }
        )
    return result


def ece(probs: Sequence[Sequence[float]], labels: Sequence[int], n_bins: int = 10) -> float:
    _check(probs, labels)
    total = len(labels)
    return sum(bucket["count"] / total * abs(bucket["accuracy"] - bucket["confidence"]) for bucket in _bins(probs, labels, n_bins))


def mce(probs: Sequence[Sequence[float]], labels: Sequence[int], n_bins: int = 10) -> float:
    _check(probs, labels)
    bins = _bins(probs, labels, n_bins)
    if not bins:
        return 0.0
    return max(abs(bucket["accuracy"] - bucket["confidence"]) for bucket in bins)


def separation(probs: Sequence[Sequence[float]], labels: Sequence[int]) -> float:
    """Mean top-1 confidence when correct minus mean top-1 confidence when
    wrong. `nan` if every prediction landed on the same side (no wrong
    predictions to compare against, or no correct ones)."""
    _check(probs, labels)
    correct_conf, wrong_conf = [], []
    for row, label in zip(probs, labels):
        confidence, prediction = _confidence_and_prediction(row)
        (correct_conf if prediction == label else wrong_conf).append(confidence)
    if not correct_conf or not wrong_conf:
        return math.nan
    return sum(correct_conf) / len(correct_conf) - sum(wrong_conf) / len(wrong_conf)


def abstain_curve(
    probs: Sequence[Sequence[float]], labels: Sequence[int], floors: Sequence[float] = (0.5, 0.6, 0.7)
) -> dict[float, dict[str, float]]:
    """Coverage and selective accuracy at each confidence floor: only
    examples whose top-1 confidence clears the floor are kept, mirroring
    `leonardd`'s own abstention gate (`attention.DEFAULT_FLOOR`)."""
    _check(probs, labels)
    curve: dict[float, dict[str, float]] = {}
    for floor in floors:
        kept = [
            (row, label)
            for row, label in zip(probs, labels)
            if _confidence_and_prediction(row)[0] >= floor
        ]
        coverage = len(kept) / len(labels)
        selective_accuracy = accuracy([r for r, _ in kept], [l for _, l in kept]) if kept else math.nan
        curve[floor] = {"coverage": coverage, "accuracy": selective_accuracy}
    return curve


@dataclass(frozen=True)
class MetricsReport:
    accuracy: float
    ece: float
    mce: float
    brier: float
    nll: float
    separation: float
    abstain_curve: dict[float, dict[str, float]]


def compute_metrics(
    probs: Sequence[Sequence[float]], labels: Sequence[int], *, floors: Sequence[float] = (0.5, 0.6, 0.7)
) -> MetricsReport:
    return MetricsReport(
        accuracy=accuracy(probs, labels),
        ece=ece(probs, labels),
        mce=mce(probs, labels),
        brier=brier_score(probs, labels),
        nll=nll(probs, labels),
        separation=separation(probs, labels),
        abstain_curve=abstain_curve(probs, labels, floors),
    )


__all__ = [
    "accuracy",
    "brier_score",
    "nll",
    "ece",
    "mce",
    "separation",
    "abstain_curve",
    "MetricsReport",
    "compute_metrics",
]
