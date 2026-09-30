"""The implicit labeller: turns an event plus a window of what happened next
into a label over `model.ACTIONS`, or refuses to label at all.

This is the highest-risk module in the pipeline (`SPECIALIST.md`, "the
labels are censored"). It is deliberately conservative: every rule is a pure
function, individually testable and individually disableable through
`label_event`'s `enabled_rules`, and every emitted `LabelResult` carries the
name of the rule (or rules) that produced it so agreement can be audited per
rule later against a held-out sample the user confirms directly. When rules
disagree on the label for the same event, `label_event` abstains rather than
guessing — disagreement between independent behavioural signals is itself
evidence the event is ambiguous, and `SPECIALIST.md` is explicit that a wrong
label is worse than no label.

Two anchor kinds are labelled: `mail.opened` (`replied_within_hour`,
`delayed_reply`, `calendar_after_reading`, `read_and_abandoned`) and
`mail.arrived` (`archived_unread`, `never_opened`) — the latter added once
`docs/CONTRACT.md` grew `mail.arrived`/`mail.closed`/`mail.archived`/
`mail.deleted` specifically so the negative observations `SPECIALIST.md`
names ("archived or deleted unread", "never opened it at all", "opened, read
for 40 seconds, left it unread") would have real signal to key off instead
of being guessed at. Before that contract change none of the three could be
built honestly; see the README for the one casualty of building them
properly instead — a rule this module used to carry that a real `dwell_ms`
observation now makes redundant.

**Payload-shape assumption, flagged for verification against the real
sensor once it exists:** `mail.arrived`, `mail.archived`, and `mail.deleted`
are assumed to carry the same `sender`/`subject`/`thread_id` fields as
`mail.opened` (`docs/CONTRACT.md` documents `dwell_ms`/`still_unread` as
`mail.closed`'s *additions* to the standard mail payload, not its entirety,
which is the basis for this assumption) — thread/message matching below
falls back to sender+subject only when `thread_id` is absent from either
side, so a payload with neither still safely abstains rather than
mismatching.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

REPLY_WINDOW_SECONDS = 3600
"""SPECIALIST.md's own phrasing: 'replied to that thread within the hour'."""

DELAYED_REPLY_MIN_SECONDS = REPLY_WINDOW_SECONDS
DELAYED_REPLY_MAX_SECONDS = 86400
"""A reply that lands after the first hour but within a day: it mattered,
just not urgently."""

CALENDAR_WINDOW_SECONDS = 300

ARCHIVED_UNREAD_MAX_SECONDS = 2_592_000
"""30 days. Archiving-while-unread is strong evidence however late it
happens — an inbox cleanup weeks later is still evidence the message never
mattered — so this bound exists to cap scan cost and to limit how far a
sender+subject fallback match (no `thread_id`) can drift into matching an
unrelated later message with the same generic subject line, not because the
signal itself goes stale."""

NEVER_OPENED_WINDOW_SECONDS = 259_200
"""3 days. Chosen with 'someone who reads mail twice a day' as the explicit
failure case to avoid: twice-daily checking implies gaps up to roughly 12
hours, and a single busy or offline day can double that. Three days gives
headroom for a missed day plus a weekend, or a short trip, without waiting
so long that the label becomes rare and stale — the cost of a longer window
is only that this specific label arrives later, which is fine since
`ignore` is already the most abundant class once `archived_unread` exists
too; the cost of a shorter window is a wrong label, which is what this
whole module exists to avoid. This is a parameter precisely so it can be
re-tuned once `data.implicit_explicit_agreement` has real numbers to tune
it against."""

READ_ABANDONED_DWELL_MS = 40_000
"""SPECIALIST.md's own number: 'read for 40 seconds, left it unread.'"""

_CALENDAR_APPS = frozenset({"Calendar", "Fantastical", "Google Calendar", "Outlook", "Teams"})


@dataclass(frozen=True)
class TimedEvent:
    ts: float
    kind: str
    app: str | None
    payload: Mapping[str, Any]
    action: str | None = None


@dataclass(frozen=True)
class LabelResult:
    label: str
    confidence: float
    rule: str

    def __post_init__(self) -> None:
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError(f"confidence must be in [0, 1], got {self.confidence}")


_SUBJECT_PREFIX = re.compile(r"^(re|fwd?|r|rif)\s*:\s*", re.IGNORECASE)


def _normalize_subject(subject: str) -> str:
    text = subject.strip()
    while True:
        stripped = _SUBJECT_PREFIX.sub("", text)
        if stripped == text:
            return stripped.lower()
        text = stripped


def _address(text: str) -> str:
    match = re.search(r"<([^>]+)>", text)
    return (match.group(1) if match else text).strip().lower()


def _thread_ids_match(a: Mapping[str, Any], b: Mapping[str, Any]) -> bool:
    a_id, b_id = a.get("thread_id"), b.get("thread_id")
    return bool(a_id) and bool(b_id) and a_id == b_id


def _same_thread(original: Mapping[str, Any], reply: Mapping[str, Any]) -> bool:
    """`original` is a `mail.opened`-shaped payload, `reply` a
    `mail.composing`-shaped one (matched on `to`, not `sender`)."""
    if _thread_ids_match(original, reply):
        return True
    original_subject = _normalize_subject(str(original.get("subject", "")))
    reply_subject = _normalize_subject(str(reply.get("subject", "")))
    if original_subject and original_subject == reply_subject:
        return True
    sender = _address(str(original.get("sender", "")))
    to = _address(str(reply.get("to", "")))
    return bool(sender) and sender == to


def _same_message(a: Mapping[str, Any], b: Mapping[str, Any]) -> bool:
    """Both sides are views of the same message (`mail.arrived`/`opened`/
    `closed`/`archived`/`deleted`), so matching is symmetric on
    `sender`+`subject` rather than the asymmetric `sender`-vs-`to` reply
    match `_same_thread` does."""
    if _thread_ids_match(a, b):
        return True
    a_subject = _normalize_subject(str(a.get("subject", "")))
    b_subject = _normalize_subject(str(b.get("subject", "")))
    if not a_subject or a_subject != b_subject:
        return False
    a_sender = _address(str(a.get("sender", "")))
    b_sender = _address(str(b.get("sender", "")))
    return bool(a_sender) and a_sender == b_sender


def _composing_replies(
    event: TimedEvent, subsequent: Sequence[TimedEvent], *, min_gap: float, max_gap: float
) -> TimedEvent | None:
    for candidate in subsequent:
        if candidate.kind != "mail.composing":
            continue
        gap = candidate.ts - event.ts
        if gap < min_gap or gap > max_gap:
            continue
        if _same_thread(event.payload, candidate.payload):
            return candidate
    return None


def rule_replied_within_hour(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """A reply drafted to the same thread within the hour: the interruption
    would have been welcome."""
    if event.kind != "mail.opened":
        return None
    if _composing_replies(event, subsequent, min_gap=0.0, max_gap=REPLY_WINDOW_SECONDS) is None:
        return None
    return LabelResult(label="suggest", confidence=0.9, rule="replied_within_hour")


def rule_delayed_reply(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """A reply drafted to the same thread between one hour and one day
    later: it mattered, but not urgently."""
    if event.kind != "mail.opened":
        return None
    if (
        _composing_replies(
            event,
            subsequent,
            min_gap=DELAYED_REPLY_MIN_SECONDS,
            max_gap=DELAYED_REPLY_MAX_SECONDS,
        )
        is None
    ):
        return None
    return LabelResult(label="wait", confidence=0.65, rule="delayed_reply")


def rule_calendar_after_reading(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """The user opened the calendar shortly after reading the email: the
    relevant context was the calendar, so Bobb should have prepared it."""
    if event.kind != "mail.opened":
        return None
    for candidate in subsequent:
        if candidate.kind not in ("app.activated", "window.changed"):
            continue
        gap = candidate.ts - event.ts
        if gap < 0 or gap > CALENDAR_WINDOW_SECONDS:
            continue
        if candidate.app in _CALENDAR_APPS:
            return LabelResult(label="prepare", confidence=0.75, rule="calendar_after_reading")
    return None


def rule_read_and_abandoned(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """A real `mail.closed` observation: dwelled at least
    `READ_ABANDONED_DWELL_MS` on the message, it was still unread when they
    left, and no reply ever followed. Built honestly off real telemetry
    (`dwell_ms`, `still_unread`) rather than approximated from event
    spacing — abstains outright if either field is missing rather than
    guessing, per this module's whole premise. Higher confidence than
    `delayed_reply` precisely because this is the real signal that rule
    used to stand in for."""
    if event.kind != "mail.opened":
        return None
    closed = next(
        (c for c in subsequent if c.kind == "mail.closed" and _same_message(event.payload, c.payload)),
        None,
    )
    if closed is None:
        return None
    dwell_ms = closed.payload.get("dwell_ms")
    still_unread = closed.payload.get("still_unread")
    if dwell_ms is None or still_unread is None:
        return None
    if not isinstance(dwell_ms, (int, float)) or isinstance(dwell_ms, bool):
        return None
    if dwell_ms < READ_ABANDONED_DWELL_MS or not still_unread:
        return None
    if _composing_replies(event, subsequent, min_gap=0.0, max_gap=DELAYED_REPLY_MAX_SECONDS) is not None:
        return None
    return LabelResult(label="wait", confidence=0.75, rule="read_and_abandoned")


def rule_archived_unread(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """`mail.archived` or `mail.deleted` for this message with no
    `mail.opened` anywhere before it: about as clear as this signal gets,
    so it is the highest-confidence rule in the set. Scans chronologically
    and stops at the first matching event either way, so a later open does
    not retroactively un-fire an earlier unread archive, and an earlier open
    correctly prevents firing at all."""
    if event.kind != "mail.arrived":
        return None
    for candidate in subsequent:
        gap = candidate.ts - event.ts
        if gap < 0:
            continue
        if gap > ARCHIVED_UNREAD_MAX_SECONDS:
            break
        if not _same_message(event.payload, candidate.payload):
            continue
        if candidate.kind == "mail.opened":
            return None
        if candidate.kind in ("mail.archived", "mail.deleted"):
            return LabelResult(label="ignore", confidence=0.92, rule="archived_unread")
    return None


def rule_never_opened(event: TimedEvent, subsequent: Sequence[TimedEvent]) -> LabelResult | None:
    """No `mail.opened` for this message anywhere within
    `NEVER_OPENED_WINDOW_SECONDS`. Absence is only meaningful once the full
    window has actually been observed, so this abstains — rather than
    concluding "never opened" — whenever `subsequent` runs out before the
    window closes; that runs out either because the row is near the most
    recent end of the table or because the caller's own lookahead was too
    short, and in both cases we simply do not know yet, so we say nothing
    rather than guess. Lower confidence than every other rule: this is pure
    absence-of-evidence, the weakest form of evidence in this module, softer
    still than `archived_unread`'s explicit action."""
    if event.kind != "mail.arrived" or not subsequent:
        return None
    horizon = event.ts + NEVER_OPENED_WINDOW_SECONDS
    if subsequent[-1].ts < horizon:
        return None
    for candidate in subsequent:
        if candidate.ts > horizon:
            break
        if candidate.kind == "mail.opened" and _same_message(event.payload, candidate.payload):
            return None
    return LabelResult(label="ignore", confidence=0.5, rule="never_opened")


RuleFn = Callable[[TimedEvent, Sequence[TimedEvent]], "LabelResult | None"]

RULES: dict[str, RuleFn] = {
    "replied_within_hour": rule_replied_within_hour,
    "delayed_reply": rule_delayed_reply,
    "calendar_after_reading": rule_calendar_after_reading,
    "read_and_abandoned": rule_read_and_abandoned,
    "archived_unread": rule_archived_unread,
    "never_opened": rule_never_opened,
}


def label_event(
    event: TimedEvent,
    subsequent: Sequence[TimedEvent],
    *,
    enabled_rules: Sequence[str] = tuple(RULES),
) -> LabelResult | None:
    fired = []
    for name in enabled_rules:
        rule = RULES.get(name)
        if rule is None:
            raise ValueError(f"unknown rule {name!r}")
        result = rule(event, subsequent)
        if result is not None:
            fired.append(result)
    if not fired:
        return None
    labels = {r.label for r in fired}
    if len(labels) > 1:
        return None
    best = max(fired, key=lambda r: r.confidence)
    combined_rule = "+".join(sorted({r.rule for r in fired}))
    return LabelResult(label=best.label, confidence=best.confidence, rule=combined_rule)


__all__ = [
    "REPLY_WINDOW_SECONDS",
    "DELAYED_REPLY_MIN_SECONDS",
    "DELAYED_REPLY_MAX_SECONDS",
    "CALENDAR_WINDOW_SECONDS",
    "ARCHIVED_UNREAD_MAX_SECONDS",
    "NEVER_OPENED_WINDOW_SECONDS",
    "READ_ABANDONED_DWELL_MS",
    "TimedEvent",
    "LabelResult",
    "rule_replied_within_hour",
    "rule_delayed_reply",
    "rule_calendar_after_reading",
    "rule_read_and_abandoned",
    "rule_archived_unread",
    "rule_never_opened",
    "RULES",
    "label_event",
]
