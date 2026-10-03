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

Three things happen before any forward pass and cost nothing: an event kind
the user has not made proactive is recorded and ignored; a sender the user
has muted (see `learning.py`) is recorded and ignored; an event with no
questions is recorded and ignored. Two happen after the policy: quiet hours
cap a `suggest` to `prepare`, and the floor is the user's personal floor for
that kind when adaptive quiet is on.

Every decision carries `explanation`, one localized sentence a person can
read in Mind, alongside the technical `why`.
"""

from __future__ import annotations

import time
import uuid
from typing import Any

from . import i18n
from .decide import decide_many, prime
from .engine import Cache, Engine
from .intents import PREPARABLE_ACTIONS, SYSTEM_PREFIX, intent_for
from .learning import Personalizer
from .policy import PolicyResult, cap_by_user_state, decide_action
from .schema import Decision
from .settings import Settings
from .specialist import QUIET_P, Specialist
from .specialist import route as specialist_route

DEFAULT_FLOOR = 0.60
SCHEMA_MASS_FLOOR = 0.5

_MEETING_APPS = frozenset(
    {"zoom.us", "Zoom", "Microsoft Teams", "Teams", "FaceTime", "Google Meet", "Meet", "Webex", "Slack Huddle"}
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
        if payload.get("in_call") is True:
            return "meeting"
        app = event.get("app") or self._app
        if app in _MEETING_APPS or self._app in _MEETING_APPS:
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


def _why(readouts: dict[str, Decision], user_state: str, policy_result: PolicyResult, floor: float) -> str:
    parts = [f"{name}={_value_str(d)} p={d.confidence:.2f}" for name, d in readouts.items()]
    parts.append(f"user_state={user_state}")
    parts.append(f"policy={policy_result.action} basis={'+'.join(policy_result.basis)}")
    parts.append(f"floor={floor:.2f}")
    return ", ".join(parts)


def _local_hour(event: dict) -> int:
    ts = event.get("ts")
    ts = ts if isinstance(ts, (int, float)) and ts > 1e9 else time.time()
    return time.localtime(ts).tm_hour


class AttentionEngine:
    """Holds the warm model, the primed cache, the user's settings, what it
    has learned about them, and the session's user-activity estimate. One
    instance serves every event for the lifetime of the daemon."""

    def __init__(
        self,
        engine: Engine,
        *,
        floor: float = DEFAULT_FLOOR,
        system_prefix: str = SYSTEM_PREFIX,
        settings: Settings | None = None,
        personalizer: Personalizer | None = None,
        proactive_kinds: frozenset[str] | None = None,
    ):
        self.engine = engine
        base = settings or Settings()
        if settings is None:
            # Direct construction (tests, the bench) keeps the v0.1 meaning:
            # every kind with questions is decided.
            base = Settings(floor=floor, proactive_kinds=proactive_kinds or frozenset(_ALL_DECIDABLE_KINDS))
        self.settings = base
        self.personalizer = personalizer
        # Tier 0: the personal specialist, when one has been minted.
        self.specialist: Specialist | None = None
        self.tracker = UserActivityTracker()
        self._reply_offers: dict[tuple[str, str], None] = {}
        self._draft_checks: dict[tuple, None] = {}
        self.primed: Cache = prime(engine, system_prefix)

    @property
    def floor(self) -> float:
        return self.settings.floor

    def set_floor(self, floor: float) -> None:
        if not (0.0 <= floor <= 1.0):
            raise ValueError(f"floor must be in [0, 1], got {floor}")
        from dataclasses import replace

        self.settings = replace(self.settings, floor=floor)

    def floor_for(self, kind: str) -> float:
        if self.personalizer is not None and self.settings.adaptive:
            return self.personalizer.personal_floor(kind, self.settings.floor)
        return self.settings.floor

    def _silent(self, event: dict, *, why: str, explanation: str, started: float) -> dict:
        self.tracker.observe(event)
        return {
            "t": "decision",
            "ts": time.time(),
            "id": _new_id("dec"),
            "event_id": event.get("id", ""),
            "action": "ignore",
            "confidence": 1.0,
            "schema_mass": 1.0,
            "latency_ms": (time.perf_counter() - started) * 1000,
            "hypotheses": [],
            "readouts": [],
            "why": why,
            "explanation": explanation,
        }

    def decide_event(self, event: dict) -> dict:
        started = time.perf_counter()
        locale = self.settings.locale
        kind = event.get("kind", "")
        if kind == "mail.reply_started":
            return self.reply_started(event)
        if kind == "mail.draft_check":
            return self.draft_check(event)
        intent = intent_for(kind)
        user_state = self.tracker.state(event)

        if not intent.questions:
            return self._silent(
                event,
                why=f"no decidable content ({kind or 'unknown kind'})",
                explanation=i18n.t("outcome.recorded", locale),
                started=started,
            )
        if kind not in self.settings.proactive_kinds:
            return self._silent(
                event,
                why=f"proactive disabled for {kind}",
                explanation=i18n.t("outcome.proactive_off", locale),
                started=started,
            )
        muted = self.personalizer.muted_sender(event) if self.personalizer else None
        if muted is not None:
            return self._silent(
                event,
                why=f"sender muted ({muted.rule_id})",
                explanation=i18n.t("outcome.muted", locale, count=muted.dismissed, sender=muted.sender),
                started=started,
            )

        tier0 = specialist_route(self.specialist, event) if self.settings.adaptive else None
        if tier0 is not None and tier0.quiet:
            decision = self._silent(
                event,
                why=f"personal specialist: p_surface={tier0.p:.3f} <= {QUIET_P}",
                explanation=i18n.t("outcome.specialist", locale),
                started=started,
            )
            decision.update(tier="specialist", specialist_p=round(tier0.p, 4), confidence=round(1 - tier0.p, 6))
            return decision

        context = intent.context(event, user_state)
        answers = decide_many(self.engine, context, intent.questions, primed=self.primed)
        readouts = {d.name: d for d in answers}
        self.tracker.observe(event)
        latency_ms = (time.perf_counter() - started) * 1000

        uncapped = decide_action(kind, readouts, user_state, event, cap=False)
        policy_result = cap_by_user_state(uncapped, user_state)
        action = policy_result.action
        confidence = policy_result.confidence
        schema_mass = min(d.schema_mass for d in readouts.values())
        floor = self.floor_for(kind)

        cap_reason = None
        if uncapped.action == "suggest" and action == "prepare":
            cap_reason = user_state
        if action == "suggest" and self.settings.in_quiet_hours(_local_hour(event)):
            action = "prepare"
            cap_reason = "quiet_hours"

        hypotheses = sorted(intent.hypotheses(event, readouts), key=lambda h: h.p, reverse=True)
        suggestion = None
        if action in ("suggest", "prepare"):
            suggestion = intent.suggestion(event, readouts, hypotheses, locale)
            if suggestion is None or suggestion.get("action_id") not in PREPARABLE_ACTIONS:
                suggestion = None
                action = "wait"

        abstained = False
        failed_readout = schema_mass < SCHEMA_MASS_FLOOR
        if failed_readout or confidence < floor:
            if action != "ignore" or failed_readout:
                action = "wait"
                abstained = True
                suggestion = None

        explanation = self._explain(
            intent, event, readouts, action, confidence, floor, abstained, failed_readout, cap_reason, locale
        )
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
            "floor": round(floor, 6),
            "hypotheses": [{"intent": h.intent, "p": round(h.p, 6)} for h in hypotheses],
            "readouts": [_readout_frame(d) for d in ordered],
            "why": _why(readouts, user_state, policy_result, floor),
            "explanation": explanation,
        }
        if suggestion is not None:
            decision["suggestion"] = suggestion
        if abstained:
            decision["abstained"] = True
        decision["tier"] = "general"
        if tier0 is not None:
            decision["specialist_p"] = round(tier0.p, 4)
            if tier0.shadow:
                decision["shadow"] = True
        return decision

    def reply_started(self, event: dict) -> dict:
        """Offer help for an observed empty reply without model inference.

        Confidence describes the native gesture rule, not an LLM readout.
        Generating text still requires the ordinary approve/prepare flow.
        """
        started = time.perf_counter()
        locale = self.settings.locale
        payload = event.get("payload") or {}
        def silent(why: str, key: str = "outcome.recorded") -> dict:
            return self._silent(event, why=why, explanation=i18n.t(key, locale), started=started)
        if "mail.reply_started" not in self.settings.proactive_kinds:
            return silent("proactive disabled for mail.reply_started", "outcome.proactive_off")
        if not all(isinstance(payload.get(key), str) and payload[key].strip()
                   for key in ("message_id", "compose_id", "sender", "body")):
            return silent("reply has no verified original message")
        if payload.get("draft") != "" or payload.get("typing") is True or payload.get("idle") is True:
            return silent("reply no longer empty or user unavailable")
        muted = self.personalizer.muted_sender(event) if self.personalizer else None
        if muted is not None:
            return self._silent(event, why=f"sender muted ({muted.rule_id})",
                explanation=i18n.t("outcome.muted", locale, count=muted.dismissed, sender=muted.sender), started=started)
        key = (payload["message_id"], payload["compose_id"])
        if key in self._reply_offers:
            return silent("reply offer already made for this compose session")
        self._reply_offers[key] = None
        if len(self._reply_offers) > 256:
            del self._reply_offers[next(iter(self._reply_offers))]
        user_state = self.tracker.state(event)
        self.tracker.observe(event)
        quiet = self.settings.in_quiet_hours(_local_hour(event))
        action = "prepare" if quiet or user_state in {"meeting", "typing", "idle"} else "suggest"
        return {
            "t": "decision", "ts": time.time(), "id": _new_id("dec"), "event_id": event.get("id", ""),
            "action": action, "confidence": 1.0, "schema_mass": 1.0,
            "latency_ms": (time.perf_counter() - started) * 1000,
            "hypotheses": [], "readouts": [], "tier": "gesture",
            "why": f"native empty reply opened; user_state={user_state}; quiet_hours={quiet}",
            "explanation": i18n.t("reply.started.explanation", locale),
            "suggestion": {
                "title": i18n.t("reply.started.title", locale), "action_id": "draft_reply",
                "detail": i18n.display_name(payload["sender"], locale) + " · " + str(payload.get("subject") or "")[:90],
                "cta": i18n.t("reply.started.cta", locale),
            },
        }

    def draft_check(self, event: dict) -> dict:
        started = time.perf_counter()
        p = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        locale = self.settings.locale
        def silent(why):
            return self._silent(event, why=why, explanation=i18n.t("outcome.recorded", locale), started=started)
        if "mail.draft_check" not in self.settings.proactive_kinds:
            return silent("draft checks disabled")
        issues = p.get("issues")
        if not isinstance(issues, list) or not p.get("compose_id") or not p.get("draft") or p.get("typing") is True:
            return silent("no verified draft check")
        issues = tuple(sorted({v for v in issues if isinstance(v, str) and v in {"attachment", "subject", "recipient", "placeholder"}}))
        key = (str(p["compose_id"]), issues)
        if not issues or key in self._draft_checks:
            return silent("draft check already offered")
        self._draft_checks[key] = None
        if len(self._draft_checks) > 256:
            del self._draft_checks[next(iter(self._draft_checks))]
        titles = {
            "attachment": ("Hai citato un allegato: è stato aggiunto?", "You mention an attachment: has it been added?"),
            "subject": ("Questa email non ha un oggetto", "This email has no subject"),
            "recipient": ("Questa email non ha destinatari", "This email has no recipients"),
            "placeholder": ("Ci sono segnaposto nella bozza", "There are placeholders in the draft"),
        }
        issue = "attachment" if "attachment" in issues else issues[0]
        title = titles[issue][0 if locale == "it" else 1]
        unavailable = self.tracker.state(event) in {"meeting", "typing", "idle"}
        self.tracker.observe(event)
        return {"t": "decision", "ts": time.time(), "id": _new_id("dec"), "event_id": event.get("id", ""),
            "action": "prepare" if unavailable or self.settings.in_quiet_hours(_local_hour(event)) else "suggest",
            "confidence": 1.0, "schema_mass": 1.0, "latency_ms": (time.perf_counter() - started) * 1000,
            "hypotheses": [], "readouts": [], "tier": "gesture", "why": "native draft checks: " + ",".join(issues),
            "explanation": title, "suggestion": {"title": title, "action_id": "check_mail",
                "detail": str(p.get("subject") or "")[:90], "cta": "Controlla" if locale == "it" else "Review"}}

    def _explain(
        self,
        intent,
        event: dict,
        readouts: dict[str, Decision],
        action: str,
        confidence: float,
        floor: float,
        abstained: bool,
        failed_readout: bool,
        cap_reason: str | None,
        locale: str,
    ) -> str:
        what = intent.explain(event, readouts, locale)
        if failed_readout:
            outcome = i18n.t("outcome.failed_readout", locale)
        elif abstained:
            outcome = i18n.t(
                "outcome.abstained", locale, confidence=i18n.percent(confidence), floor=i18n.percent(floor)
            )
        elif action == "prepare" and cap_reason:
            outcome = i18n.t(f"outcome.prepare.{cap_reason}", locale)
        else:
            outcome = i18n.t(f"outcome.{action}", locale)
        sentence = f"{what} {outcome}"
        if abs(floor - self.settings.floor) >= 0.005 and action != "ignore":
            sentence += " " + i18n.t("outcome.personal_floor", locale, floor=i18n.percent(floor))
        return sentence


_ALL_DECIDABLE_KINDS = ("mail.opened", "mail.reply_started", "mail.composing", "text.selected", "app.activated", "window.changed")


__all__ = ["AttentionEngine", "UserActivityTracker", "DEFAULT_FLOOR", "SCHEMA_MASS_FLOOR"]
