import pytest

from leonardd.policy import PolicyResult, decide_action
from leonardd.schema import Bool, Choice, Score, Decision, decision_key


def _decision(question, value, confidence, schema_mass=0.99) -> Decision:
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
        latency_ms=1.0,
    )


_MESSAGE_TYPE_Q = Choice(
    name="message_type",
    question="?",
    options=("broadcast", "transactional", "personal_no_ask", "personal_request"),
)
_URGENCY_Q = Score(name="urgency", rubric="?", lo=0, hi=4)
_TONE_Q = Choice(name="tone", question="?", options=("warm_or_neutral", "firm", "curt_or_hostile"))
_ACTIONABLE_Q = Bool(name="actionable", statement="?")
_ACTION_KIND_Q = Choice(name="action_kind", question="?", options=("define", "translate", "compute", "lookup", "none"))
_RELEVANT_Q = Bool(name="relevant", statement="?")


def _mail_readouts(*, message_type="personal_request", message_type_p=0.9, urgency=0, urgency_p=0.9):
    return {
        "message_type": _decision(_MESSAGE_TYPE_Q, message_type, message_type_p),
        "urgency": _decision(_URGENCY_Q, urgency, urgency_p),
    }


def test_broadcast_is_always_ignored_regardless_of_urgency():
    readouts = _mail_readouts(message_type="broadcast", urgency=4, urgency_p=0.99)
    result = decide_action("mail.opened", readouts, "reading")
    assert result.action == "ignore"
    assert result.confidence == pytest.approx(readouts["message_type"].confidence)


@pytest.mark.parametrize("tier,expected", [(0, "ignore"), (1, "wait")])
def test_low_urgency_tiers_never_surface(tier, expected):
    readouts = _mail_readouts(urgency=tier, message_type="personal_request")
    result = decide_action("mail.opened", readouts, "reading")
    assert result.action == expected


def test_tier_two_needs_a_personal_request_to_prepare():
    not_a_request = _mail_readouts(urgency=2, message_type="personal_no_ask")
    assert decide_action("mail.opened", not_a_request, "reading").action == "wait"

    a_request = _mail_readouts(urgency=2, message_type="personal_request")
    assert decide_action("mail.opened", a_request, "reading").action == "prepare"


def test_tier_three_needs_a_personal_request_to_suggest():
    not_a_request = _mail_readouts(urgency=3, message_type="transactional")
    assert decide_action("mail.opened", not_a_request, "reading").action == "prepare"

    a_request = _mail_readouts(urgency=3, message_type="personal_request")
    assert decide_action("mail.opened", a_request, "reading").action == "suggest"


def test_tier_four_always_suggests():
    readouts = _mail_readouts(urgency=4, message_type="transactional")
    assert decide_action("mail.opened", readouts, "reading").action == "suggest"


def test_urgency_confidence_is_cumulative_across_the_surfacing_boundary_not_point_mass():
    urgency = Decision(
        name="urgency",
        kind="score",
        value=3,
        probabilities={"0": 0.05, "1": 0.05, "2": 0.35, "3": 0.45, "4": 0.10},
        raw_probabilities={"0": 0.05, "1": 0.05, "2": 0.35, "3": 0.45, "4": 0.10},
        confidence=0.45,
        schema_mass=0.99,
        latency_ms=1.0,
    )
    readouts = {
        "message_type": _decision(_MESSAGE_TYPE_Q, "personal_request", 0.95),
        "urgency": urgency,
    }
    result = decide_action("mail.opened", readouts, "reading")
    assert result.action == "suggest"
    assert result.confidence == pytest.approx(0.90)
    assert result.confidence > urgency.confidence


def test_confidence_is_the_minimum_of_the_facts_the_branch_used():
    readouts = _mail_readouts(urgency=3, urgency_p=0.95, message_type="personal_request", message_type_p=0.6)
    result = decide_action("mail.opened", readouts, "reading")
    assert result.action == "suggest"
    assert set(result.basis) == {"urgency", "message_type"}
    assert result.confidence == pytest.approx(0.6)


def _composing(idle_seconds=0, draft="Ciao Marco, ti scrivo per"):
    return {"kind": "mail.composing", "payload": {"idle_seconds": idle_seconds, "draft": draft}}


def test_mail_composing_hostile_tone_suggests():
    readouts = {"tone": _decision(_TONE_Q, "curt_or_hostile", 0.8)}
    result = decide_action("mail.composing", readouts, "reading", _composing())
    assert result.action == "suggest"
    assert result.basis == ("tone",)
    assert result.confidence == pytest.approx(0.8)


def test_mail_composing_firm_tone_is_left_alone():
    readouts = {"tone": _decision(_TONE_Q, "firm", 0.9)}
    assert decide_action("mail.composing", readouts, "reading", _composing()).action == "wait"


def test_mail_composing_stuck_is_read_from_the_payload_and_only_prepares():
    readouts = {"tone": _decision(_TONE_Q, "warm_or_neutral", 0.9)}
    assert decide_action("mail.composing", readouts, "reading", _composing(idle_seconds=90)).action == "prepare"
    assert decide_action("mail.composing", readouts, "reading", _composing(idle_seconds=10)).action == "wait"
    assert decide_action("mail.composing", readouts, "reading", _composing(idle_seconds=90, draft="")).action == "wait"


def test_uncapped_policy_reports_what_the_facts_alone_call_for():
    readouts = _mail_readouts(urgency=4)
    assert decide_action("mail.opened", readouts, "typing", cap=False).action == "suggest"
    assert decide_action("mail.opened", readouts, "typing").action == "prepare"


def test_text_selected_not_actionable_is_ignored():
    readouts = {
        "actionable": _decision(_ACTIONABLE_Q, False, 0.85),
        "action_kind": _decision(_ACTION_KIND_Q, "none", 0.99),
    }
    result = decide_action("text.selected", readouts, "reading")
    assert result.action == "ignore"
    assert result.basis == ("actionable",)


def test_text_selected_actionable_but_no_kind_waits():
    readouts = {
        "actionable": _decision(_ACTIONABLE_Q, True, 0.7),
        "action_kind": _decision(_ACTION_KIND_Q, "none", 0.6),
    }
    result = decide_action("text.selected", readouts, "reading")
    assert result.action == "wait"


def test_text_selected_actionable_with_kind_suggests():
    readouts = {
        "actionable": _decision(_ACTIONABLE_Q, True, 0.9),
        "action_kind": _decision(_ACTION_KIND_Q, "define", 0.8),
    }
    result = decide_action("text.selected", readouts, "reading")
    assert result.action == "suggest"
    assert result.confidence == pytest.approx(0.8)


@pytest.mark.parametrize("kind", ["app.activated", "window.changed"])
def test_relevance_kinds_map_directly(kind):
    yes = {"relevant": _decision(_RELEVANT_Q, True, 0.75)}
    assert decide_action(kind, yes, "reading").action == "suggest"
    no = {"relevant": _decision(_RELEVANT_Q, False, 0.9)}
    assert decide_action(kind, no, "reading").action == "ignore"


@pytest.mark.parametrize("state", ["typing", "meeting"])
def test_expensive_states_cap_suggest_to_prepare(state):
    readouts = _mail_readouts(urgency=4)
    result = decide_action("mail.opened", readouts, state)
    assert result.action == "prepare"


@pytest.mark.parametrize("state", ["reading", "idle"])
def test_cheap_states_leave_suggest_alone(state):
    readouts = _mail_readouts(urgency=4)
    result = decide_action("mail.opened", readouts, state)
    assert result.action == "suggest"


def test_unknown_kind_raises():
    with pytest.raises(KeyError):
        decide_action("no.such.kind", {}, "reading")


def test_policy_result_rejects_invalid_action():
    with pytest.raises(ValueError):
        PolicyResult("nope", 0.5, ("x",))


def test_policy_result_rejects_out_of_range_confidence():
    with pytest.raises(ValueError):
        PolicyResult("ignore", 1.5, ("x",))


def test_policy_result_rejects_empty_basis():
    with pytest.raises(ValueError):
        PolicyResult("ignore", 0.5, ())
