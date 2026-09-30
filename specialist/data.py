"""Builds a training set from `audit.db`'s `decisions` table.

Three kinds of examples come out of the same rows, per `SPECIALIST.md`:

- **explicit** — a decision the user answered with `approve`/`dismiss`.
  `approve` confirms the surfaced action was correct; `dismiss` only tells us
  the surfaced action was wrong, not what the right one was, so it is mapped
  to `ignore` (staying quiet is the closest available proxy for "you should
  not have interrupted me"). This is a modeling assumption, not an
  observation, and is flagged again in the README.
- **implicit** — `labels.label_event` run against the event and everything
  that happened afterward in the same table (every event `bobbd` ever
  scores gets a row here, per `bobbd/bobbd/server.py`'s `_on_event`, so
  "subsequent events" is just later rows ordered by `ts`).
- **distillation** — the teacher's stored per-option distribution for the
  `interrupt` question, read off the row's `readouts` JSON.

A row that has both an explicit response and a fired implicit rule is
counted once, as explicit — a direct human action outranks an inferred one.

`user_state` is not stored in `decisions` (`bobbd/bobbd/intents.py`
folds it into context text and never asks the model to predict it), so
`estimate_user_states` recomputes it by replaying the same rule
`bobbd/bobbd/attention.py`'s `UserActivityTracker` uses, hand-kept in
sync rather than imported, per the constraint that this package carries no
runtime dependency on `bobbd`.

**Distillation data gap.** `bobbd/bobbd/attention.py`'s
`_readout_frame` only persists the chosen answer's confidence (`p`), not
`schema.Decision.probabilities`, the full calibrated distribution `readouts`
would need to carry for proper KL distillation. `_teacher_distribution`
prefers a `probabilities` field if a future `bobbd` schema adds one, and
otherwise falls back to a peaked pseudo-distribution — `p` on the chosen
action, the remainder split uniformly over the other three. That fallback is
a materially worse distillation target than the true teacher distribution
and is not a fix; the real fix is a `bobbd` schema change this package is
not permitted to make (`bobbd/` is off limits here).
"""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, TypeVar

from labels import ARCHIVED_UNREAD_MAX_SECONDS, NEVER_OPENED_WINDOW_SECONDS, RULES, TimedEvent, label_event
from model import ACTIONS, MAX_HISTORY_EVENTS, serialize_context

_MEETING_APPS = frozenset(
    {"zoom.us", "Zoom", "Microsoft Teams", "Teams", "FaceTime", "Google Meet", "Meet", "Webex"}
)


def load_rows(path: str | Path) -> list[dict[str, Any]]:
    """All `decisions` rows, oldest first, from a read-only connection."""
    conn = sqlite3.connect(f"file:{Path(path)}?mode=ro", uri=True)
    try:
        cursor = conn.execute("SELECT * FROM decisions ORDER BY ts ASC")
        columns = [d[0] for d in cursor.description]
        return [dict(zip(columns, row, strict=True)) for row in cursor.fetchall()]
    finally:
        conn.close()


def _to_timed_event(row: Mapping[str, Any]) -> TimedEvent:
    payload = json.loads(row["event_payload"]) if row.get("event_payload") else {}
    return TimedEvent(
        ts=float(row["ts"]), kind=row["kind"], app=row.get("app"), payload=payload, action=row.get("action")
    )


def estimate_user_states(events: Sequence[TimedEvent]) -> list[str]:
    """One `typing`/`reading`/`idle`/`meeting` estimate per event, computed
    from the prior events exactly as `AttentionEngine.decide_event` computes
    it live (state read before that event is folded into tracker state)."""
    idle = False
    app: str | None = None
    states = []
    for event in events:
        payload = event.payload
        if payload.get("typing") is True:
            state = "typing"
        elif idle or payload.get("idle") is True:
            state = "idle"
        elif (event.app or app) in _MEETING_APPS:
            state = "meeting"
        elif event.kind == "mail.composing":
            state = "typing"
        else:
            state = "reading"
        states.append(state)
        if event.kind == "idle.entered":
            idle = True
        elif event.kind == "idle.left":
            idle = False
        elif event.kind in ("app.activated", "window.changed"):
            idle = False
            app = event.app or app
        elif event.kind == "mail.composing":
            idle = False
    return states


def _history(events: Sequence[TimedEvent], index: int) -> list[dict[str, Any]]:
    start = max(0, index - MAX_HISTORY_EVENTS)
    return [{"kind": e.kind, "action": e.action} for e in events[start:index]]


def _context_for(event: TimedEvent, user_state: str, history: Sequence[dict[str, Any]]) -> str:
    return serialize_context(
        {"kind": event.kind, "app": event.app, "ts": event.ts, "user_state": user_state, "payload": event.payload},
        history,
    )


def _subsequent_within(events: Sequence[TimedEvent], index: int, horizon_seconds: float) -> list[TimedEvent]:
    origin = events[index].ts
    result = []
    for event in events[index + 1 :]:
        if event.ts - origin > horizon_seconds:
            break
        result.append(event)
    return result


@dataclass(frozen=True)
class Example:
    context: str
    label: int
    weight: float
    source: str
    ts: float

    def __post_init__(self) -> None:
        if not 0 <= self.label < len(ACTIONS):
            raise ValueError(f"label must index ACTIONS, got {self.label}")
        if not 0.0 <= self.weight <= 1.0:
            raise ValueError(f"weight must be in [0, 1], got {self.weight}")


@dataclass(frozen=True)
class DistillExample:
    context: str
    teacher_probs: tuple[float, ...]
    ts: float

    def __post_init__(self) -> None:
        if len(self.teacher_probs) != len(ACTIONS):
            raise ValueError("teacher_probs must have one entry per action")


LOOKAHEAD_SECONDS = float(max(ARCHIVED_UNREAD_MAX_SECONDS, NEVER_OPENED_WINDOW_SECONDS))
"""Derived from `labels.py`'s own rule windows rather than hardcoded, so it
cannot silently fall out of sync with them — `rule_never_opened` in
particular needs to see a `subsequent` tail that actually spans its full
window before it can conclude anything (see that rule's docstring), and a
shorter lookahead here would make it abstain even when the real answer is
knowable. This makes each `build_examples`/`build_distill_examples` row scan
up to 30 real days of subsequent rows; the caller can still pass a shorter
`lookahead_seconds` for cheaper scans that trade away `never_opened` and the
tail of `archived_unread`."""


def build_examples(
    rows: Sequence[Mapping[str, Any]],
    *,
    lookahead_seconds: float = LOOKAHEAD_SECONDS,
    enabled_rules: Sequence[str] = tuple(RULES),
) -> list[Example]:
    events = [_to_timed_event(row) for row in rows]
    states = estimate_user_states(events)
    examples: list[Example] = []
    for index, (row, event) in enumerate(zip(rows, events, strict=True)):
        context = _context_for(event, states[index], _history(events, index))
        response = row.get("response")
        if response in ("approve", "dismiss"):
            action = event.action if response == "approve" else "ignore"
            if action not in ACTIONS:
                continue
            examples.append(
                Example(context=context, label=ACTIONS.index(action), weight=1.0, source="explicit", ts=event.ts)
            )
            continue
        subsequent = _subsequent_within(events, index, lookahead_seconds)
        result = label_event(event, subsequent, enabled_rules=enabled_rules)
        if result is None:
            continue
        examples.append(
            Example(
                context=context,
                label=ACTIONS.index(result.label),
                weight=result.confidence,
                source=f"implicit:{result.rule}",
                ts=event.ts,
            )
        )
    return examples


def _teacher_distribution(readouts: list[dict[str, Any]]) -> tuple[float, ...] | None:
    entry = next((r for r in readouts if r.get("q") == "interrupt"), None)
    if entry is None:
        return None
    probabilities = entry.get("probabilities")
    if isinstance(probabilities, dict) and probabilities:
        vector = [float(probabilities.get(action, 0.0)) for action in ACTIONS]
        total = sum(vector)
        if total > 0:
            return tuple(v / total for v in vector)
    value, p = entry.get("value"), entry.get("p")
    if value not in ACTIONS or not isinstance(p, (int, float)):
        return None
    remainder = (1.0 - float(p)) / (len(ACTIONS) - 1)
    return tuple(float(p) if action == value else remainder for action in ACTIONS)


def build_distill_examples(rows: Sequence[Mapping[str, Any]]) -> list[DistillExample]:
    events = [_to_timed_event(row) for row in rows]
    states = estimate_user_states(events)
    examples: list[DistillExample] = []
    for index, (row, event) in enumerate(zip(rows, events, strict=True)):
        readouts = json.loads(row["readouts"]) if row.get("readouts") else []
        distribution = _teacher_distribution(readouts)
        if distribution is None:
            continue
        context = _context_for(event, states[index], _history(events, index))
        examples.append(DistillExample(context=context, teacher_probs=distribution, ts=event.ts))
    return examples


def implicit_explicit_agreement(
    rows: Sequence[Mapping[str, Any]],
    *,
    lookahead_seconds: float = LOOKAHEAD_SECONDS,
    enabled_rules: Sequence[str] = tuple(RULES),
) -> dict[str, dict[str, int]]:
    """Per-rule agreement between a fired implicit label and the user's own
    explicit response on the same row — `SPECIALIST.md` measurement 1."""
    events = [_to_timed_event(row) for row in rows]
    tally: dict[str, dict[str, int]] = {}
    for index, (row, event) in enumerate(zip(rows, events, strict=True)):
        response = row.get("response")
        if response not in ("approve", "dismiss"):
            continue
        subsequent = _subsequent_within(events, index, lookahead_seconds)
        result = label_event(event, subsequent, enabled_rules=enabled_rules)
        if result is None:
            continue
        explicit_label = event.action if response == "approve" else "ignore"
        bucket = tally.setdefault(result.rule, {"agree": 0, "disagree": 0})
        bucket["agree" if result.label == explicit_label else "disagree"] += 1
    return tally


class _HasTs(Protocol):
    ts: float


T = TypeVar("T", bound=_HasTs)


def time_split(items: Sequence[T], *, train_frac: float = 0.7, val_frac: float = 0.15) -> tuple[list[T], list[T], list[T]]:
    """Chronological split: sort by `ts`, cut by position. No item in the
    validation split can precede an item in train, and none in test can
    precede one in validation — a random split would leak the future into
    training, which is exactly the failure mode this guards against."""
    if not 0.0 < train_frac < 1.0 or not 0.0 <= val_frac < 1.0 or train_frac + val_frac > 1.0:
        raise ValueError("train_frac and val_frac must describe a valid, non-overlapping split")
    ordered = sorted(items, key=lambda item: item.ts)
    n = len(ordered)
    train_end = min(round(n * train_frac), n)
    val_end = min(train_end + round(n * val_frac), n)
    return ordered[:train_end], ordered[train_end:val_end], ordered[val_end:]


__all__ = [
    "load_rows",
    "estimate_user_states",
    "Example",
    "DistillExample",
    "LOOKAHEAD_SECONDS",
    "build_examples",
    "build_distill_examples",
    "implicit_explicit_agreement",
    "time_split",
]
