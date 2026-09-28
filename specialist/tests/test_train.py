import math

import torch

from data import DistillExample, Example
from model import DEFAULT_CONFIG, make_model
from train import TrainConfig, predict_probs, run_distillation, run_supervised

_TEACHER_DISTRIBUTIONS = [
    (0.7, 0.1, 0.1, 0.1),
    (0.1, 0.7, 0.1, 0.1),
    (0.1, 0.1, 0.7, 0.1),
    (0.1, 0.1, 0.1, 0.7),
]


def _context(tag: str, index: int) -> str:
    return f"K mail.opened\nA Mail\nT h{index % 24} d0\nU reading\nB {tag} body {index}"


def test_distillation_reduces_kl_on_a_tiny_fixture():
    torch.manual_seed(0)
    model, collator = make_model(DEFAULT_CONFIG)
    examples = [
        DistillExample(context=_context("distill", i), teacher_probs=probs, ts=float(i))
        for i, probs in enumerate(_TEACHER_DISTRIBUTIONS)
    ]
    config = TrainConfig(learning_rate=5e-3, batch_size=4, epochs=25, warmup_frac=0.1)
    losses = run_distillation(model, collator, examples, config)
    assert len(losses) == config.epochs
    early = sum(losses[:3]) / 3
    late = sum(losses[-3:]) / 3
    assert late < early


def test_supervised_fit_reduces_cross_entropy_on_a_tiny_fixture():
    torch.manual_seed(0)
    model, collator = make_model(DEFAULT_CONFIG)
    labels = [0, 1, 2, 3, 0, 1, 2, 3]
    examples = [
        Example(context=_context("fit", i), label=label, weight=1.0, source="synthetic", ts=float(i))
        for i, label in enumerate(labels)
    ]
    config = TrainConfig(learning_rate=5e-3, batch_size=4, epochs=25, warmup_frac=0.1)
    losses = run_supervised(model, collator, examples, config)
    early = sum(losses[:3]) / 3
    late = sum(losses[-3:]) / 3
    assert late < early


def test_supervised_fit_respects_per_example_weight():
    torch.manual_seed(0)
    model, collator = make_model(DEFAULT_CONFIG)
    heavy = Example(context=_context("heavy", 0), label=0, weight=1.0, source="explicit", ts=0.0)
    light = Example(context=_context("light", 1), label=1, weight=0.05, source="implicit:quick_dismissal", ts=1.0)
    config = TrainConfig(learning_rate=5e-3, batch_size=2, epochs=15, warmup_frac=0.1)
    losses = run_supervised(model, collator, [heavy, light], config)
    assert len(losses) == config.epochs
    probs = predict_probs(model, collator, [heavy.context])
    assert max(range(4), key=lambda i: probs[0][i]) == 0


def test_run_supervised_on_empty_examples_is_a_noop():
    model, collator = make_model(DEFAULT_CONFIG)
    assert run_supervised(model, collator, [], TrainConfig()) == []


def test_predict_probs_returns_a_valid_distribution():
    model, collator = make_model(DEFAULT_CONFIG)
    probs = predict_probs(model, collator, ["K mail.opened\nA Mail"])
    assert len(probs) == 1
    assert len(probs[0]) == 4
    assert math.isclose(sum(probs[0]), 1.0, abs_tol=1e-5)
    assert all(p >= 0.0 for p in probs[0])
