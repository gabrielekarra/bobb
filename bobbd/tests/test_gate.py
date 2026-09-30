import numpy as np
import pytest

from bobbd.gate import FrameGate, changed_area, signature


def _flat(value, size=(64, 64)):
    return np.full(size, value, dtype=np.uint8)


def test_signature_is_normalised_and_gridded():
    sig = signature(_flat(128), grid=8)
    assert sig.shape == (8, 8)
    assert 0.0 <= sig.min() and sig.max() <= 1.0
    assert sig == pytest.approx(128 / 255, abs=1e-6)


def test_signature_rejects_a_frame_smaller_than_the_grid():
    with pytest.raises(ValueError):
        signature(_flat(10, size=(4, 4)), grid=16)


def test_first_frame_always_infers():
    gate = FrameGate()
    verdict = gate(_flat(100))
    assert verdict.infer and verdict.reason == "first"


def test_identical_frames_are_skipped():
    gate = FrameGate(threshold=0.01, max_age=None)
    gate(_flat(100))
    assert [gate(_flat(100)).infer for _ in range(5)] == [False] * 5


def test_a_large_change_trips_the_gate():
    gate = FrameGate(threshold=0.01, max_age=None)
    gate(_flat(100))
    verdict = gate(_flat(200))
    assert verdict.infer and verdict.reason == "changed"


def test_slow_drift_accumulates_against_the_last_inferred_frame():
    """The property the whole design rests on.

    Each step is far below the threshold relative to its immediate
    predecessor, so a gate comparing consecutive frames would never fire.
    Anchored to the last *inferred* frame instead, the same steps sum, and
    the ramp is eventually caught rather than walking past the threshold
    forever one imperceptible step at a time.
    """
    gate = FrameGate(threshold=0.05, max_age=None)
    gate(_flat(100))
    step = 1  # 1/255 per frame, far under a 0.05 threshold frame-to-frame
    previous_level = 100
    fired = False
    for i in range(1, 60):
        level = 100 + i * step
        verdict = gate(_flat(level))
        step_distance = abs(level - previous_level) / 255
        assert step_distance < 0.05  # invisible frame-to-frame, by construction
        previous_level = level
        if verdict.infer:
            fired = True
            assert verdict.reason == "changed"
            break
    assert fired, "drift never accumulated past the threshold against the fixed reference"


def test_max_age_forces_inference_on_an_unchanging_stream():
    gate = FrameGate(threshold=0.5, max_age=4)
    gate(_flat(100))
    reasons = [gate(_flat(100)).reason for _ in range(8)]
    assert "stale" in reasons
    assert reasons.count("stale") == 2  # frames 4 and 8


def test_skipped_frames_do_not_move_the_reference():
    gate = FrameGate(threshold=0.05, max_age=None)
    gate(_flat(100))
    gate(_flat(105))  # skipped: must not become the new reference
    assert gate.check(_flat(105)).distance == pytest.approx(5 / 255, abs=1e-6)


def test_invalid_configuration_is_rejected():
    with pytest.raises(ValueError):
        FrameGate(threshold=-0.1)
    with pytest.raises(ValueError):
        FrameGate(max_age=0)
    with pytest.raises(ValueError):
        FrameGate(metric="entropy")


def _panel(mark: str = "", caret: bool = False) -> np.ndarray:
    frame = np.full((128, 192), 30, dtype=np.uint8)
    if mark == "word":
        frame[40:52, 20:80] = 220
    if caret:
        frame[60:72, 100:102] = 220
    return frame


def test_changed_area_separates_a_word_from_a_caret_by_area():
    base = _panel(caret=True)
    caret_off = _panel(caret=False)
    word = _panel(mark="word", caret=True)
    assert changed_area(word, base) > 5 * changed_area(caret_off, base)


def test_area_gate_skips_frames_that_did_not_change():
    gate = FrameGate(threshold=0.005, max_age=None, metric="area")
    frame = _panel(caret=True)
    gate(frame)
    assert [gate(frame.copy()).infer for _ in range(4)] == [False] * 4


def test_changed_area_rejects_a_mismatched_shape():
    with pytest.raises(ValueError):
        changed_area(_panel(), np.zeros((64, 64), dtype=np.uint8))
