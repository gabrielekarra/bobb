"""Contracts needed by Bobb's probability gates and typed action targets."""
from types import SimpleNamespace

import numpy as np
import pytest

from bobbd.decide import decide_many, prime
from bobbd.kev import decisions_from_logits, record_for
from bobbd.schema import Bool, Choice, Score
from bobbd.server import _Loader


def read(questions, logits, *, owners=None, calibrators=None):
    return decisions_from_logits(
        questions, owners or [(i, False) for i in range(len(questions))],
        [np.asarray(row) for row in logits], temperature=2.406,
        calibrators=calibrators or [None] * len(questions), elapsed_ms=60,
    )


def test_pointer_answers_preserve_bool_score_range_and_opaque_target_ids():
    questions = [Bool("reply", "Needs a reply?"), Score("urgency", "Urgency?", lo=3, hi=5),
                 Choice("target", "Which control?", ("ax:42", "none"))]
    record, owners = record_for("context", questions)
    assert record["questions"][0]["options"] == ["no", "yes"]
    assert record["questions"][1]["options"] == ["3", "4", "5"]
    answers = read(questions, [[0, 2], [0, 2, 0], [3, 0]], owners=owners)
    assert [answer.value for answer in answers] == [True, 4, "ax:42"]
    for answer in answers:
        assert sum(answer.probabilities.values()) == pytest.approx(1)
        assert answer.confidence == max(answer.probabilities.values())
        assert answer.schema_mass == 1


def test_uncertain_answer_does_not_gain_typesafe_relative_confidence():
    answer = read([Bool("reply", "Needs a reply?")], [[0, 0]])[0]
    assert answer.value is False
    assert answer.confidence == pytest.approx(0.5)
    assert answer.raw_probabilities == {"false": 0.5, "true": 0.5}


def test_debias_maps_reversed_rows_back_to_the_original_options():
    question = Choice("target", "Which control?", ("ax:42", "none"), debias=True)
    record, owners = record_for("context", [question])
    assert record["questions"][1]["options"] == ["none", "ax:42"]
    # Both rows support ax:42, even though its option position changes.
    answer = read([question], [[3, 0], [0, 3]], owners=owners)[0]
    assert answer.value == "ax:42"
    assert answer.probabilities["ax:42"] > 0.95


@pytest.mark.parametrize("bad", [[float("nan"), 1], [-1, 2], [0, 0], [1, 2, 3]])
def test_invalid_calibration_cannot_reach_an_action_probability_gate(bad):
    calibrator = SimpleNamespace(transform=lambda _: np.asarray([bad]))
    with pytest.raises(ValueError, match="invalid Kev probability"):
        read([Bool("act", "Should act?")], [[0, 1]], calibrators=[calibrator])


def test_runtime_routes_priming_and_decisions_to_kev_without_generation_logits():
    calls = []
    result = read([Bool("act", "Should act?")], [[1, 0]])
    backend = SimpleNamespace(decide_many=lambda *a, **kw: calls.append((a, kw)) or result)
    # No tokenizer/prefill/logit API: touching the old path would fail.
    engine = SimpleNamespace(decision_backend=backend)
    system = prime(engine, "rules")
    questions = [Bool("act", "Should act?")]
    assert decide_many(engine, "screen", questions, primed=system) == result
    assert calls == [(("screen", questions), {"calibrators": [None], "system": "rules"})]


def test_sharded_generation_model_still_requires_the_local_kev_head(tmp_path, monkeypatch):
    generation, decision = tmp_path / "chat", tmp_path / "kev"
    generation.mkdir()
    decision.mkdir()
    for path in (generation / "config.json", generation / "model-00001-of-00002.safetensors",
                 generation / "model-00002-of-00002.safetensors", decision / "config.json",
                 decision / "model.safetensors"):
        path.write_bytes(b"")
    monkeypatch.setattr("bobbd.engine.resolve_local", lambda name: generation if name == "chat" else decision)
    loader = _Loader(SimpleNamespace(), "chat")
    assert not loader.available()
    (decision / "head.pt").write_bytes(b"")
    assert loader.available()
