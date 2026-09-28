import ast
import dataclasses
import inspect

import pytest
from fake_engine import FakeEngine, logits_at, peaked_logits, queued

from leonardd import act
from leonardd.act import MAX_CANDIDATES, OPERATIONS, ActResult, Candidate, act_frame, score_action

_CANDIDATES = [
    {"id": "c1", "label": "Rispondi", "role": "AXButton", "enabled": True},
    {"id": "c2", "label": "Campo testo messaggio", "role": "AXTextArea", "enabled": True},
    {"id": "done", "label": "Obiettivo raggiunto", "enabled": True},
    {"id": "escalate", "label": "Serve ripianificare", "enabled": True},
]


def _observation(candidates=None, **overrides):
    obs = {
        "t": "observe",
        "ts": 0.0,
        "id": "obs_1",
        "goal": "Rispondere a Marco",
        "app": "Mail",
        "window": "Preventivo",
        "step": 1,
        "candidates": candidates if candidates is not None else _CANDIDATES,
    }
    obs.update(overrides)
    return obs


class GenerativeFakeEngine(FakeEngine):
    def __init__(self, logits_fn):
        super().__init__(logits_fn)
        self.model = object()
        self.tokenizer = object()


def test_operation_and_target_come_from_one_prefill():
    engine = FakeEngine(queued(peaked_logits(4096, 0), peaked_logits(4096, 0)))
    result = score_action(engine, _observation())
    assert engine.prefill_calls == 1
    assert result.operation == "CLICK"
    assert result.candidate_id == "c1"
    assert result.text is None


def test_text_is_null_unless_operation_is_type_text():
    engine = FakeEngine(queued(peaked_logits(4096, 0), peaked_logits(4096, 1)))
    result = score_action(engine, _observation())
    assert result.operation == "CLICK"
    assert result.text is None


def test_text_generated_only_for_type_text_and_only_via_the_resident_model(monkeypatch):
    calls = []

    def fake_generate(engine, observation, target):
        calls.append((observation["goal"], target.id))
        return "Ciao, confermo."

    monkeypatch.setattr(act, "_generate_text", fake_generate)
    type_text_index = OPERATIONS.index("TYPE_TEXT")
    engine = GenerativeFakeEngine(queued(peaked_logits(4096, type_text_index), peaked_logits(4096, 1)))
    result = score_action(engine, _observation())

    assert result.operation == "TYPE_TEXT"
    assert result.candidate_id == "c2"
    assert result.text == "Ciao, confermo."
    assert calls == [("Rispondere a Marco", "c2")]


def test_low_confidence_abstains_to_blocked_escalate():
    vocab_size = 4096
    flat_operation_logits = logits_at(vocab_size, {i: -1.0 for i in range(len(OPERATIONS))})
    engine = FakeEngine(queued(flat_operation_logits, peaked_logits(vocab_size, 0)))
    result = score_action(engine, _observation(), floor=0.9)
    assert result.abstained is True
    assert result.operation == "BLOCKED"
    assert result.candidate_id == "escalate"


def test_candidate_cap_is_enforced_and_raises_clearly():
    too_many = [{"id": f"c{i}", "label": f"item {i}"} for i in range(MAX_CANDIDATES)]
    too_many += [{"id": "done", "label": "done"}, {"id": "escalate", "label": "escalate"}]
    assert len(too_many) == MAX_CANDIDATES + 2
    with pytest.raises(ValueError, match="at most"):
        score_action(FakeEngine(queued()), _observation(candidates=too_many))


def test_missing_done_or_escalate_raises():
    with pytest.raises(ValueError, match="escalate"):
        score_action(FakeEngine(queued()), _observation(candidates=[{"id": "c1", "label": "x"}, {"id": "done", "label": "d"}]))


def test_duplicate_candidate_ids_raise():
    dupes = [{"id": "c1", "label": "a"}, {"id": "c1", "label": "b"}, {"id": "done", "label": "d"}, {"id": "escalate", "label": "e"}]
    with pytest.raises(ValueError, match="unique"):
        score_action(FakeEngine(queued()), _observation(candidates=dupes))


def test_act_frame_shape():
    engine = FakeEngine(queued(peaked_logits(4096, 0), peaked_logits(4096, 0)))
    result = score_action(engine, _observation())
    frame = act_frame("obs_1", result, why="test")
    assert frame["t"] == "act"
    assert frame["operation"] == "CLICK"
    assert frame["candidate_id"] == "c1"
    assert frame["text"] is None
    assert set(frame) == {
        "t", "ts", "observation_id", "operation", "candidate_id", "confidence", "schema_mass",
        "operation_probabilities", "probabilities", "text", "latency_ms", "abstained", "why",
    }


# ---------- the security boundary: no tool name, coordinate, argument or file path ----------


def test_act_result_carries_only_opaque_ids_and_scores():
    fields = {f.name for f in dataclasses.fields(ActResult)}
    assert fields == {
        "operation", "candidate_id", "confidence", "schema_mass",
        "operation_probabilities", "probabilities", "text", "latency_ms", "abstained",
    }


def test_candidate_carries_only_an_opaque_id_and_a_label():
    fields = {f.name for f in dataclasses.fields(Candidate)}
    assert fields == {"id", "label", "role", "enabled"}


def test_operation_is_always_one_of_the_declared_eight_and_never_a_tool_name():
    engine = FakeEngine(queued(peaked_logits(4096, 5), peaked_logits(4096, 0)))
    result = score_action(engine, _observation())
    assert result.operation in OPERATIONS


def test_candidate_id_is_always_one_the_app_offered_never_a_synthesized_value():
    engine = FakeEngine(queued(peaked_logits(4096, 0), peaked_logits(4096, 2)))
    result = score_action(engine, _observation())
    offered = {c["id"] for c in _CANDIDATES}
    assert result.candidate_id in offered


def test_module_source_never_mentions_coordinates_tool_names_or_file_paths():
    tree = ast.parse(inspect.getsource(act))
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                if isinstance(body[0].value.value, str):
                    body[0].value.value = ""
    code_only = ast.unparse(tree).lower()
    banned = (
        "subprocess", "appkit", "cgevent", "pyautogui", "os.system",
        "click_at", "file_path", "tool_name", "x_px", "y_px",
        "shell=true", "quartz",
    )
    for term in banned:
        assert term not in code_only, f"act.py must never reference {term!r}"
