"""The Attention Engine: one event in, exactly one contract-shaped `decision` out.

One `decide_many` call per event answers every LLM question `intents.py`
declares for that event's `kind`, off a single prefill forked from the
model's primed system prefix. `user_state` is derived cheaply from event
history by `UserActivityTracker` and folded into the shared context text;
it is never itself sent through the model, so it costs no forward pass and
never appears in `readouts`.

`decide.py` reports what the model believes about the event; `policy.py`
turns those facts plus `user_state` into an action, deterministically, with
no model involved. This module is the seam between the two: it gathers the
readouts, asks `policy.decide_action` what to do about them, then applies
the runtime floor on top of the policy's own confidence — a low-confidence
action is downgraded to `wait`, and a failed readout (`schema_mass` below
`SCHEMA_MASS_FLOOR`) forces `wait` regardless of confidence, per the
contract's invariant.
"""

from __future__ import annotations

import time
import uuid
from typing import Any

from .decide import decide_many, prime
from .engine import Cache, Engine
from .intents import SYSTEM_PREFIX, intent_for
from .policy import PolicyResult, decide_action
from .schema import Decision

DEFAULT_FLOOR = 0.60
SCHEMA_MASS_FLOOR = 0.5

_MEETING_APPS = frozenset(
    {"zoom.us", "Zoom", "Microsoft Teams", "Teams", "FaceTime", "Google Meet", "Meet", "Webex"}
)


class UserActivityTracker:
    """Cheap, payload-only estimate of what the user is doing right now.

    Updated from every event's kind and payload, never from the model: idle
    state comes from `idle.entered`/`idle.left`, typing from an in-progress
    compose, meeting from an app name that looks like a call app.
    """

    def __init__(self) -> None:
        self._idle = False
        self._app: str | None = None

    def observe(self, event: dict) -> None:
        kind = event.get("kind")
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        if kind == "idle.entered":
            self._idle = True
        elif kind == "idle.left":
            self._idle = False
        elif kind in ("app.activated", "window.changed"):
            self._idle = False
            self._app = event.get("app") or payload.get("app") or self._app
        elif kind == "mail.composing":
            self._idle = False

    def state(self, event: dict) -> str:
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        if payload.get("typing") is True:
            return "typing"
        if self._idle or payload.get("idle") is True:
            return "idle"
        app = event.get("app") or self._app
        if app in _MEETING_APPS:
            return "meeting"
        if event.get("kind") == "mail.composing":
            return "typing"
        return "reading"


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:20]}"


def _readout_frame(d: Decision) -> dict[str, Any]:
    return {
        "q": d.name,
        "value": d.value,
        "p": round(d.confidence, 6),
        "schema_mass": round(d.schema_mass, 6),
        "probabilities": {k: round(v, 6) for k, v in d.probabilities.items()},
        "raw_probabilities": {k: round(v, 6) for k, v in d.raw_probabilities.items()},
    }


def _value_str(d: Decision) -> str:
    return ("true" if d.value else "false") if d.kind == "bool" else str(d.value)


def _why(readouts: dict[str, Decision], user_state: str, policy_result: PolicyResult) -> str:
    parts = [f"{name} {_value_str(d)} a {d.confidence:.2f}" for name, d in readouts.items()]
    parts.append(f"stato utente: {user_state}")
    parts.append(
        f"azione calcolata da policy.py: {policy_result.action} "
        f"(base: {', '.join(policy_result.basis)})"
    )
    return ", ".join(parts)


def _ignored_decision(event: dict, reason: str, latency_ms: float) -> dict:
    return {
        "t": "decision",
        "ts": time.time(),
        "id": _new_id("dec"),
        "event_id": event.get("id", ""),
        "action": "ignore",
        "confidence": 1.0,
        "schema_mass": 1.0,
        "latency_ms": latency_ms,
        "hypotheses": [],
        "readouts": [],
        "why": reason,
    }


class AttentionEngine:
    """Holds the warm model, the primed cache, the runtime floor and the
    session's user-activity estimate. One instance serves every event for
    the lifetime of the daemon."""

    def __init__(self, engine: Engine, *, floor: float = DEFAULT_FLOOR, system_prefix: str = SYSTEM_PREFIX):
        self.engine = engine
        self.floor = floor
        self.tracker = UserActivityTracker()
        self.primed: Cache = prime(engine, system_prefix)

    def set_floor(self, floor: float) -> None:
        if not (0.0 <= floor <= 1.0):
            raise ValueError(f"floor must be in [0, 1], got {floor}")
        self.floor = floor

    def decide_event(self, event: dict) -> dict:
        started = time.perf_counter()
        kind = event.get("kind", "")
        intent = intent_for(kind)
        user_state = self.tracker.state(event)

        readouts: dict[str, Decision] = {}
        if intent.questions:
            context = intent.context(event, user_state)
            answers = decide_many(self.engine, context, intent.questions, primed=self.primed)
            readouts = {d.name: d for d in answers}

        self.tracker.observe(event)
        latency_ms = (time.perf_counter() - started) * 1000

        if not readouts:
            return _ignored_decision(event, f"nessun contenuto decidibile ({kind or 'kind sconosciuto'})", latency_ms)

        policy_result = decide_action(kind, readouts, user_state)
        action = policy_result.action
        confidence = policy_result.confidence
        schema_mass = min(d.schema_mass for d in readouts.values())

        abstained = False
        if schema_mass < SCHEMA_MASS_FLOOR or confidence < self.floor:
            action = "wait"
            abstained = True

        hypotheses = sorted(intent.hypotheses(event, readouts), key=lambda h: h.p, reverse=True)

        suggestion = None
        if action == "suggest":
            suggestion = intent.suggestion(event, readouts, hypotheses)

        ordered = [readouts[q.name] for q in intent.questions if q.name in readouts]
        decision: dict[str, Any] = {
            "t": "decision",
            "ts": time.time(),
            "id": _new_id("dec"),
            "event_id": event.get("id", ""),
            "action": action,
            "confidence": round(confidence, 6),
            "schema_mass": round(schema_mass, 6),
            "latency_ms": latency_ms,
            "hypotheses": [{"intent": h.intent, "p": round(h.p, 6)} for h in hypotheses],
            "readouts": [_readout_frame(d) for d in ordered],
            "why": _why(readouts, user_state, policy_result),
        }
        if suggestion is not None:
            decision["suggestion"] = suggestion
        if abstained:
            decision["abstained"] = True
        return decision


__all__ = ["AttentionEngine", "UserActivityTracker", "DEFAULT_FLOOR", "SCHEMA_MASS_FLOOR"]
