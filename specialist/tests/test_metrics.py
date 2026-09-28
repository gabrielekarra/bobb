import math

import pytest

from metrics import abstain_curve, accuracy, brier_score, compute_metrics, ece, mce, nll, separation

PROBS = [
    [0.7, 0.1, 0.1, 0.1],
    [0.6, 0.1, 0.1, 0.2],
    [0.25, 0.25, 0.25, 0.25],
]
LABELS = [0, 1, 2]


def test_accuracy_hand_computed():
    assert accuracy(PROBS, LABELS) == pytest.approx(1 / 3)


def test_brier_score_hand_computed():
    assert brier_score(PROBS, LABELS) == pytest.approx(2.09 / 3)


def test_nll_hand_computed():
    expected = (-math.log(0.7) - math.log(0.1) - math.log(0.25)) / 3
    assert nll(PROBS, LABELS) == pytest.approx(expected)


def test_ece_and_mce_hand_computed():
    assert ece(PROBS, LABELS, n_bins=10) == pytest.approx((0.25 + 0.6 + 0.3) / 3)
    assert mce(PROBS, LABELS, n_bins=10) == pytest.approx(0.6)


def test_separation_hand_computed():
    assert separation(PROBS, LABELS) == pytest.approx(0.7 - (0.6 + 0.25) / 2)


def test_separation_is_nan_when_every_prediction_is_correct():
    assert math.isnan(separation([[0.9, 0.1, 0.0, 0.0]], [0]))


def test_abstain_curve_hand_computed():
    curve = abstain_curve(PROBS, LABELS, floors=(0.5, 0.6, 0.7))
    assert curve[0.5]["coverage"] == pytest.approx(2 / 3)
    assert curve[0.5]["accuracy"] == pytest.approx(0.5)
    assert curve[0.6]["coverage"] == pytest.approx(2 / 3)
    assert curve[0.6]["accuracy"] == pytest.approx(0.5)
    assert curve[0.7]["coverage"] == pytest.approx(1 / 3)
    assert curve[0.7]["accuracy"] == pytest.approx(1.0)


def test_abstain_curve_reports_nan_accuracy_at_zero_coverage():
    curve = abstain_curve([[0.4, 0.3, 0.2, 0.1]], [1], floors=(0.9,))
    assert curve[0.9]["coverage"] == 0.0
    assert math.isnan(curve[0.9]["accuracy"])


def test_compute_metrics_bundles_every_number():
    report = compute_metrics(PROBS, LABELS)
    assert report.accuracy == pytest.approx(1 / 3)
    assert report.brier == pytest.approx(2.09 / 3)
    assert report.separation == pytest.approx(0.7 - (0.6 + 0.25) / 2)
    assert set(report.abstain_curve) == {0.5, 0.6, 0.7}


def test_metrics_reject_mismatched_lengths():
    with pytest.raises(ValueError):
        accuracy(PROBS, [0, 1])
