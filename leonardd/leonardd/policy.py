"""Deterministic mapping from what the model established (`readouts`) plus
what the user is doing (`user_state`) to what Leonard does about it.

`decide.py` answers narrow factual questions about one event; this module is
the only place that turns those answers into `ignore`/`wait`/`prepare`/
`suggest`. It is pure: no `Engine`, no cache, no forward pass, nothing here
is non-deterministic, and every branch is total over its inputs, so it is
unit-testable against hand-built `Decision` values with no model loaded.

Each event kind gets its own small function because the facts available
differ by kind (an email has a `message_type` and a `urgency`; a draft in
progress has `stuck` and `tone_risk`); there is no single flat formula that
would mean the same thing across all of them.

Confidence composition: an action here is the conclusion of a deterministic
rule applied to a handful of facts, not independent evidence pooled
together, so its confidence is the minimum confidence among the facts the
taken branch actually depended on -- the chain is only as strong as its
weakest link. A fact a branch never inspects does not lower the action's
confidence, because the branch's correctness never depended on it. This is a
choice, not a law: a product that wanted to reward corroborating evidence
would multiply instead of taking the minimum, but that requires the facts to
be independent, which two readouts about the same email are not, so `min`
is the defensible default here.

"Confidence in a fact" is not always that fact's own `Decision.confidence`,
either: a `Score`'s point-mass on one specific integer answers a narrower
question than any branch here asks. See `_urgency_side_confidence` for the
one place that distinction mattered enough, measurably, to earn its own
function instead of being inlined as `urgency.confidence`.

The user's own state carries no model confidence -- it is derived from
event payloads, never asked of the model -- so it never enters that
composition. Instead it caps the result afterward: interrupting someone who
is typing or in a meeting costs more than the content can be worth, so a
`suggest` is capped to `prepare` in those states regardless of how the facts
alone would have scored it. This is the same weighing the old design asked
the model to do in prose ("someone mid-sentence is expensive to interrupt");
here it is a rule instead of a hope.
"""

from __future__ import annotations

from dataclasses import dataclass

from .schema import Decision

ACTIONS = ("ignore", "wait", "prepare", "suggest")

_EXPENSIVE_TO_INTERRUPT = frozenset({"typing", "meeting"})


@dataclass(frozen=True)
class PolicyResult:
    action: str
    confidence: float
    basis: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.action not in ACTIONS:
            raise ValueError(f"action must be one of {ACTIONS}, got {self.action!r}")
        if not (0.0 <= self.confidence <= 1.0):
            raise ValueError(f"confidence must be in [0, 1], got {self.confidence}")
        if not self.basis:
            raise ValueError("basis must name at least one readout the action depended on")


def _min_confidence(readouts: dict[str, Decision], names: tuple[str, ...]) -> float:
    return min(readouts[name].confidence for name in names)


_URGENCY_SURFACE_TIER = 2


def _urgency_side_confidence(urgency: Decision) -> float:
    """Cumulative probability on whichever side of `_URGENCY_SURFACE_TIER`
    the model's own argmax fell on, in place of `urgency.confidence`'s
    point-mass on one specific integer.

    Measured against `judgement_eval`'s fixture, `urgency.confidence` alone
    stayed under 0.5 for most events that should have surfaced (0.257 to
    0.486 for four of the six most urgent ones), not because the model was
    unsure whether to act, but because a well-calibrated 5-way `Score` rarely
    stacks much mass on one integer when the neighbouring one is nearly as
    plausible -- 2 vs. 3 is a real disagreement about *how* urgent, not
    about *whether* this clears the bar for attention at all. Every branch
    below only ever asks the second question, so its confidence should be
    the mass in agreement with that answer, not with the first digit.
    """
    surfacing = sum(
        p for label, p in urgency.probabilities.items() if int(label) >= _URGENCY_SURFACE_TIER
    )
    return surfacing if int(urgency.value) >= _URGENCY_SURFACE_TIER else 1.0 - surfacing


def _mail_opened_action(readouts: dict[str, Decision], user_state: str) -> PolicyResult:
    """mail.opened started with two more facts, `deadline_stated` and
    `sender_waiting_on_user`, each a `Bool` anchored as narrowly as
    `_URGENCY`'s own levels. Measured against `judgement_eval`'s fixture,
    both came back `true` on all 25 events, the same constant-answer failure
    diagnosed in the old `reply_needed` (see `intents.py`'s module
    docstring). They were dropped rather than kept in the confidence
    composition below, where an uninformative fact would only have dragged
    the result down without contributing anything it was actually measuring.
    `message_type` and `urgency` are what is left because both held up under
    the same test.
    """
    message_type = readouts["message_type"]
    urgency = readouts["urgency"]
    urgency_conf = _urgency_side_confidence(urgency)

    if message_type.value == "broadcast":
        return PolicyResult("ignore", message_type.confidence, ("message_type",))

    tier = int(urgency.value)
    is_request = message_type.value == "personal_request"

    if tier == 0:
        return PolicyResult("ignore", urgency_conf, ("urgency",))
    if tier == 1:
        return PolicyResult("wait", urgency_conf, ("urgency",))
    if tier == 2:
        if is_request:
            basis = ("urgency", "message_type")
            return PolicyResult("prepare", min(urgency_conf, message_type.confidence), basis)
        return PolicyResult("wait", urgency_conf, ("urgency",))
    if tier == 3:
        if is_request:
            basis = ("urgency", "message_type")
            return PolicyResult("suggest", min(urgency_conf, message_type.confidence), basis)
        return PolicyResult("prepare", urgency_conf, ("urgency",))
    return PolicyResult("suggest", urgency_conf, ("urgency",))


def _mail_composing_action(readouts: dict[str, Decision], user_state: str) -> PolicyResult:
    stuck = readouts["stuck"]
    tone = readouts["tone_risk"]

    if tone.value:
        return PolicyResult("suggest", tone.confidence, ("tone_risk",))
    if stuck.value:
        return PolicyResult("suggest", stuck.confidence, ("stuck",))
    basis = ("tone_risk", "stuck")
    return PolicyResult("wait", _min_confidence(readouts, basis), basis)


def _text_selected_action(readouts: dict[str, Decision], user_state: str) -> PolicyResult:
    actionable = readouts["actionable"]
    kind = readouts["action_kind"]

    if not actionable.value:
        return PolicyResult("ignore", actionable.confidence, ("actionable",))
    if kind.value == "none":
        basis = ("actionable", "action_kind")
        return PolicyResult("wait", _min_confidence(readouts, basis), basis)
    basis = ("actionable", "action_kind")
    return PolicyResult("suggest", _min_confidence(readouts, basis), basis)


def _relevance_action(readouts: dict[str, Decision], user_state: str) -> PolicyResult:
    relevant = readouts["relevant"]
    if relevant.value:
        return PolicyResult("suggest", relevant.confidence, ("relevant",))
    return PolicyResult("ignore", relevant.confidence, ("relevant",))


_POLICIES = {
    "mail.opened": _mail_opened_action,
    "mail.composing": _mail_composing_action,
    "text.selected": _text_selected_action,
    "app.activated": _relevance_action,
    "window.changed": _relevance_action,
}


def _cap_by_user_state(result: PolicyResult, user_state: str) -> PolicyResult:
    if result.action == "suggest" and user_state in _EXPENSIVE_TO_INTERRUPT:
        return PolicyResult("prepare", result.confidence, result.basis)
    return result


def decide_action(kind: str, readouts: dict[str, Decision], user_state: str) -> PolicyResult:
    policy = _POLICIES.get(kind)
    if policy is None:
        raise KeyError(f"no policy defined for event kind {kind!r}")
    return _cap_by_user_state(policy(readouts, user_state), user_state)


__all__ = ["ACTIONS", "PolicyResult", "decide_action"]
