import pytest
from fake_engine import TrivialEngine

import leonardd.attention as attention_mod
from leonardd import intents
from leonardd.attention import AttentionEngine
from leonardd.schema import Decision, decision_key


def make_decision(question, value, confidence, schema_mass=0.99, latency_ms=1.0) -> Decision:
    labels = question.labels
    key = decision_key(question.kind, value)
    remaining = [label for label in labels if label != key]
    other_mass = (1.0 - confidence) / len(remaining) if remaining else 0.0
    probabilities = {label: (confidence if label == key else other_mass) for label in labels}
    return Decision(
        name=question.name,
        kind=question.kind,
        value=value,
        probabilities=probabilities,
        raw_probabilities=probabilities,
        confidence=confidence,
        schema_mass=schema_mass,
        latency_ms=latency_ms,
    )


def _mail_event(event_id="evt_1"):
    return {
        "t": "event",
        "ts": 0.0,
        "id": event_id,
        "kind": "mail.opened",
        "app": "Mail",
        "payload": {
            "sender": "Marco Rossi <marco@example.com>",
            "subject": "Preventivo revisione",
            "body": "Ciao, mi confermi il preventivo?",
            "thread_len": 3,
            "unread": True,
        },
    }


def _mail_questions():
    return intents.INTENTS["mail.opened"].questions


def _urgency_decision(confidence: float, schema_mass: float = 0.99) -> Decision:
    """value=4 (top tier), with every point of non-argmax mass placed on
    labels "0"/"1" -- below `policy._URGENCY_SURFACE_TIER` -- so the
    policy's cumulative side-confidence (see `_urgency_side_confidence`)
    equals this point `confidence` exactly. Keeps these floor tests'
    expected numbers the plain values passed in, without hand-deriving
    what the cumulative sum would otherwise be.
    """
    remaining = 1.0 - confidence
    probabilities = {"0": remaining / 2, "1": remaining / 2, "2": 0.0, "3": 0.0, "4": confidence}
    return Decision(
        name="urgency",
        kind="score",
        value=4,
        probabilities=probabilities,
        raw_probabilities=probabilities,
        confidence=confidence,
        schema_mass=schema_mass,
        latency_ms=1.0,
    )


def _scripted(
    monkeypatch,
    *,
    message_type="personal_request",
    message_type_p=0.9,
    urgency_p=0.9,
    urgency_schema_mass=0.99,
):
    questions = {q.name: q for q in _mail_questions()}

    def fake_decide_many(engine, context, questions_arg, *, calibrators=None, primed=None):
        answers = {
            "message_type": make_decision(questions["message_type"], message_type, message_type_p),
            "urgency": _urgency_decision(urgency_p, schema_mass=urgency_schema_mass),
        }
        return [answers[q.name] for q in questions_arg]

    monkeypatch.setattr(attention_mod, "decide_many", fake_decide_many)


def test_high_confidence_suggest_passes_through(monkeypatch):
    _scripted(monkeypatch, urgency_p=0.9)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event(_mail_event())

    assert decision["t"] == "decision"
    assert decision["action"] == "suggest"
    assert "abstained" not in decision
    assert decision["confidence"] == pytest.approx(0.9)
    assert decision["suggestion"]["action_id"] == "draft_reply"
    assert {r["q"] for r in decision["readouts"]} == {"message_type", "urgency"}


def test_floor_downgrades_low_confidence_action_to_wait(monkeypatch):
    _scripted(monkeypatch, urgency_p=0.55)  # below default floor 0.60
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event(_mail_event())

    assert decision["action"] == "wait"
    assert decision["abstained"] is True
    assert decision["confidence"] == pytest.approx(0.55)  # the fact is reported, not hidden
    assert "suggestion" not in decision


def test_floor_is_runtime_configurable(monkeypatch):
    _scripted(monkeypatch, urgency_p=0.65)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    assert engine.decide_event(_mail_event())["action"] == "suggest"

    engine.set_floor(0.70)
    assert engine.decide_event(_mail_event())["action"] == "wait"


def test_low_schema_mass_forces_wait_regardless_of_confidence(monkeypatch):
    _scripted(monkeypatch, urgency_p=0.99, urgency_schema_mass=0.2)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event(_mail_event())

    assert decision["action"] == "wait"
    assert decision["abstained"] is True
    assert decision["confidence"] == pytest.approx(0.99)  # confidence is real, mass is not trustworthy
    assert decision["schema_mass"] < 0.5


def test_broadcast_message_type_ignores_regardless_of_urgency(monkeypatch):
    _scripted(monkeypatch, message_type="broadcast", urgency_p=0.95)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event(_mail_event())

    assert decision["action"] == "ignore"


def test_expensive_user_state_caps_suggest_to_prepare(monkeypatch):
    _scripted(monkeypatch, urgency_p=0.9)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    event = _mail_event()
    event["payload"]["typing"] = True
    decision = engine.decide_event(event)

    assert decision["action"] == "prepare"
    assert "suggestion" not in decision


def test_exactly_one_decision_per_event_for_idle_kind():
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event({"t": "event", "ts": 0.0, "id": "evt_idle", "kind": "idle.entered", "payload": {}})
    assert decision["t"] == "decision"
    assert decision["event_id"] == "evt_idle"
    assert decision["action"] == "ignore"
    assert decision["readouts"] == []


def test_exactly_one_decision_per_event_for_unknown_kind():
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event({"t": "event", "ts": 0.0, "id": "evt_ukn", "kind": "some.new.kind", "payload": {}})
    assert decision["t"] == "decision"
    assert decision["action"] == "ignore"
    assert decision["event_id"] == "evt_ukn"


@pytest.mark.parametrize("kind", ["mail.arrived", "mail.closed", "mail.archived", "mail.deleted"])
def test_mail_lifecycle_events_cost_no_forward_pass(monkeypatch, kind):
    def fail_if_called(*args, **kwargs):
        raise AssertionError("mail lifecycle events must not call decide_many")

    monkeypatch.setattr(attention_mod, "decide_many", fail_if_called)
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    decision = engine.decide_event({"t": "event", "ts": 0.0, "id": f"evt_{kind}", "kind": kind, "payload": {}})
    assert decision["action"] == "ignore"
    assert decision["readouts"] == []


def test_invalid_floor_is_rejected():
    engine = AttentionEngine(TrivialEngine(), floor=0.60)
    with pytest.raises(ValueError):
        engine.set_floor(1.5)
