"""The Leonard-specific question set: one `EventIntent` per contract `kind`.

Each `EventIntent` declares the ordered LLM questions to ask, how to render
an event's payload into the shared context text those questions are read
against, and how to turn the answered readouts into intent hypotheses and a
user-facing suggestion. `user_state` is deliberately not one of the LLM
questions: it is folded into the context text as a stated fact, computed by
`attention.UserActivityTracker` from event history rather than guessed by
the model, because the model was never given the keystroke/calendar signals
that would make it a decidable question for the model to guess at.

`idle.entered` and `idle.left` carry no LLM questions at all: an idle
transition by itself states nothing content-bearing to decide, so asking the
model about it would be asking it to guess. Their sole effect is on the
activity tracker; the emitted decision is a deterministic `ignore`.

`mail.arrived`, `mail.closed`, `mail.archived` and `mail.deleted` likewise
carry no LLM questions. Per `docs/CONTRACT.md` they exist so the implicit
labeller has the negatives (archived unread, opened and abandoned) and not
only the positives; the payload already says everything there is to decide,
so asking the model would cost a forward pass to re-derive what the event
already states. They are recorded to the audit store as a deterministic
`ignore` and read back later as training data, never acted on here.

Every LLM question below asks something answerable from the stated text
alone: what kind of message this is, how urgent a reply is. None of them ask
what Leonard should *do*; that is `policy.py`'s job, from these facts plus
`user_state`, in code instead of a model's opinion.

`mail.opened` originally also asked two `Bool` facts, `deadline_stated` and
`sender_waiting_on_user`, worded as narrowly as `_URGENCY`'s levels are.
Measured against `judgement_eval`'s fixture both came back `true` on every
one of the 25 events -- newsletters and receipts included -- the same
constant-answer failure the diagnosis found in the old `reply_needed`, just
moved to two new names. Anchoring the *true* case precisely was not enough;
a bare `Bool` still had only one way to be interesting and it took it every
time. `message_type` and `urgency` did not fail this way because both force
a choice among several genuinely different, mutually exclusive labels
(`Choice` and an anchored `Score`) rather than a single statement that can
be reflexively agreed with. Both `Bool` questions were removed rather than
kept as decoration; see `leonardd/README.md` for the measurement.

Model-facing question text is English, matching the checkpoint's tuning
language. User-facing suggestion copy is Italian, matching the product.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from .schema import Bool, Choice, Decision, Question, Score

SYSTEM_PREFIX = """You are the fact-extraction core of Leonard, a local, privacy-preserving desktop assistant.

You are shown one fact pattern at a time - an email that just opened, a draft in progress, a text selection, a window that changed - and asked a small number of narrow questions about it. You never see anything about the user beyond what is stated in the fact pattern.

Answer strictly from the stated facts. Never assume information that was not given: no deadline exists unless the text states or clearly implies one, no urgency exists unless the content or thread history implies it. Report what you actually believe, including when you are unsure; a caller downstream decides what to do with an uncertain answer.

For every question you are given a lettered list of the only valid answers, each one defined in the question itself. Respond with a single letter and nothing else: no explanation, no punctuation, no repetition of the option text.

You are never asked what Leonard should do about a fact pattern. You are asked what is true about it; deciding what to do with that is somebody else's job, downstream of you."""

USER_STATE = Choice(
    name="user_state",
    question="What is the user doing right now?",
    options=("typing", "reading", "idle", "meeting"),
)


@dataclass(frozen=True)
class Hypothesis:
    intent: str
    p: float


ContextFn = Callable[[dict, str], str]
HypothesesFn = Callable[[dict, dict[str, Decision]], list[Hypothesis]]
SuggestionFn = Callable[[dict, dict[str, Decision], list[Hypothesis]], dict | None]


@dataclass(frozen=True)
class EventIntent:
    kind: str
    questions: tuple[Question, ...]
    context: ContextFn
    hypotheses: HypothesesFn
    suggestion: SuggestionFn


def _payload(event: dict) -> dict:
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else {}


def _no_hypotheses(event: dict, readouts: dict[str, Decision]) -> list[Hypothesis]:
    return []


def _no_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict | None:
    return None


# ---------- mail.opened ----------

_MESSAGE_TYPE = Choice(
    name="message_type",
    question=(
        "What kind of message is this? Use these definitions:\n"
        "broadcast = sent to a list or many recipients at once; nobody specific is expected to reply "
        "(newsletter, marketing, mass announcement).\n"
        "transactional = an automated notice generated by software about an account, order, system or "
        "service, not typed by a person (receipt, shipping update, calendar reminder, security alert).\n"
        "personal_no_ask = written by a specific person to the user and contains no request: information, "
        "thanks, an FYI, a forwarded item.\n"
        "personal_request = written by a specific person to the user and asks for something: an answer, "
        "a decision, a document, a meeting, a confirmation."
    ),
    options=("broadcast", "transactional", "personal_no_ask", "personal_request"),
)
_URGENCY = Score(
    name="urgency",
    rubric=(
        "How soon does this email need a response? Use these levels:\n"
        "0 = never; no response is expected at all (newsletter, receipt, automated notice).\n"
        "1 = whenever; a response would be polite but nothing depends on when.\n"
        "2 = this week; a real request with no stated deadline.\n"
        "3 = today or tomorrow; a deadline is stated or implied, or someone is waiting.\n"
        "4 = right now; something breaks, is lost, or escalates if this waits."
    ),
    lo=0,
    hi=4,
)


def _mail_opened_context(event: dict, user_state: str) -> str:
    p = _payload(event)
    return (
        "An email just opened.\n"
        f"From: {p.get('sender', 'unknown sender')}\n"
        f"Subject: {p.get('subject', '(no subject)')}\n"
        f"Thread length: {p.get('thread_len', 1)} message(s). Unread: {p.get('unread', True)}.\n\n"
        f"Body:\n{p.get('body', '')}"
    )


def _mail_opened_hypotheses(event: dict, readouts: dict[str, Decision]) -> list[Hypothesis]:
    p = _payload(event)
    message_type = readouts["message_type"]
    urgency = readouts["urgency"]
    hyps = [Hypothesis("reply_to_email", message_type.probabilities["personal_request"])]
    haystack = f"{p.get('subject', '')} {p.get('body', '')}".lower()
    if any(word in haystack for word in ("attach", "allegat")):
        hyps.append(Hypothesis("look_for_attachment", round(0.3 + 0.4 * (int(urgency.value) / 4), 3)))
    return hyps


def _mail_opened_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict:
    p = _payload(event)
    sender = p.get("sender", "quel mittente")
    sender_name = sender.split("<")[0].strip() or sender
    thread_len = p.get("thread_len", 1)
    top = max(hypotheses, key=lambda h: h.p, default=None)
    if top is not None and top.intent == "look_for_attachment":
        return {
            "title": f"Vuoi che cerchi l'allegato menzionato da {sender_name}?",
            "action_id": "find_attachment",
            "detail": f"{thread_len} messaggi nel thread",
        }
    return {
        "title": f"Vuoi che prepari una risposta a {sender_name}?",
        "action_id": "draft_reply",
        "detail": f"{thread_len} messaggi nel thread, urgenza {readouts['urgency'].value}/4",
    }


# ---------- mail.composing ----------

_STUCK = Bool(
    name="stuck",
    statement="The user appears to have paused mid-draft, and offering to continue would likely help rather than interrupt.",
)
_TONE_RISK = Bool(
    name="tone_risk",
    statement="The tone of this draft could plausibly cause a problem with the recipient (e.g. terse, angry, or easily misread).",
)


def _mail_composing_context(event: dict, user_state: str) -> str:
    p = _payload(event)
    return (
        f"The user is composing an email to {p.get('to', 'unknown recipient')}.\n"
        f"Subject: {p.get('subject', '(no subject)')}\n"
        f"Idle for {p.get('idle_seconds', 0)}s since the last keystroke.\n\n"
        f"Draft so far:\n{p.get('draft', '')}"
    )


def _mail_composing_hypotheses(event: dict, readouts: dict[str, Decision]) -> list[Hypothesis]:
    hyps = []
    if readouts["stuck"].value:
        hyps.append(Hypothesis("continue_draft", readouts["stuck"].probabilities["true"]))
    if readouts["tone_risk"].value:
        hyps.append(Hypothesis("review_tone", readouts["tone_risk"].probabilities["true"]))
    return hyps


def _mail_composing_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict:
    p = _payload(event)
    if readouts["tone_risk"].value:
        return {
            "title": "Il tono di questa bozza potrebbe creare un problema: vuoi rivederlo?",
            "action_id": "review_tone",
            "detail": "rischio di tono rilevato nel testo",
        }
    return {
        "title": "Vuoi che ti aiuti a continuare questa bozza?",
        "action_id": "continue_draft",
        "detail": f"in pausa da {p.get('idle_seconds', 0)}s",
    }


# ---------- text.selected ----------

_ACTIONABLE = Bool(
    name="actionable",
    statement="This selected text is something the user would plausibly want help with (e.g. a definition, translation, calculation, or lookup), not just incidental text.",
)
_ACTION_KIND = Choice(
    name="action_kind",
    question="If Leonard should act on this selection, which action fits best?",
    options=("define", "translate", "compute", "lookup", "none"),
)


def _text_selected_context(event: dict, user_state: str) -> str:
    p = _payload(event)
    app = event.get("app") or p.get("app", "unknown app")
    return (
        f"The user selected text in {app}.\n"
        f"Selection: \"{p.get('text', '')}\"\n"
        f"Surrounding context: {p.get('surrounding', '')}"
    )


def _text_selected_hypotheses(event: dict, readouts: dict[str, Decision]) -> list[Hypothesis]:
    action = readouts["action_kind"]
    if action.value == "none":
        return []
    return [Hypothesis(f"{action.value}_selection", action.confidence)]


def _text_selected_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict:
    p = _payload(event)
    text = p.get("text", "")
    snippet = text if len(text) <= 40 else text[:37] + "..."
    kind = readouts["action_kind"].value
    titles = {
        "define": f'Vuoi una definizione di "{snippet}"?',
        "translate": f'Vuoi che traduca "{snippet}"?',
        "compute": f'Vuoi che calcoli "{snippet}"?',
        "lookup": f'Vuoi che cerchi informazioni su "{snippet}"?',
    }
    app = event.get("app") or p.get("app", "")
    return {
        "title": titles.get(kind, f'Vuoi aiuto con "{snippet}"?'),
        "action_id": f"{kind}_selection",
        "detail": f"selezione in {app}",
    }


# ---------- app.activated ----------

_APP_RELEVANT = Bool(
    name="relevant",
    statement="This app switch is something Leonard could actively help with right now, not just routine navigation.",
)


def _app_activated_context(event: dict, user_state: str) -> str:
    p = _payload(event)
    app = event.get("app") or p.get("app", "unknown app")
    return (
        f"The user switched from {p.get('previous_app', 'unknown')} to {app}.\n"
        f"Window title: {p.get('title', '')}"
    )


def _relevance_hypotheses(intent_name: str) -> HypothesesFn:
    def build(event: dict, readouts: dict[str, Decision]) -> list[Hypothesis]:
        relevant = readouts["relevant"]
        if not relevant.value:
            return []
        return [Hypothesis(intent_name, relevant.probabilities["true"])]

    return build


def _app_activated_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict:
    p = _payload(event)
    app = event.get("app") or p.get("app", "questa app")
    return {
        "title": f"Vuoi che ti aiuti con {app}?",
        "action_id": "assist_with_app",
        "detail": p.get("title", ""),
    }


# ---------- window.changed ----------

_WINDOW_RELEVANT = Bool(
    name="relevant",
    statement="This window or tab contains something Leonard could plausibly help with right now (e.g. a form, an invoice, a document needing action), not just routine browsing.",
)


def _window_changed_context(event: dict, user_state: str) -> str:
    p = _payload(event)
    app = event.get("app") or p.get("app", "unknown app")
    return (
        f"The active window changed in {app}.\n"
        f"Title: {p.get('title', '')}\n"
        f"URL: {p.get('url', '')}"
    )


def _window_changed_suggestion(event: dict, readouts: dict[str, Decision], hypotheses: list[Hypothesis]) -> dict:
    p = _payload(event)
    title = p.get("title", "questa finestra")
    app = event.get("app") or p.get("app", "")
    return {
        "title": f'Vuoi che ti aiuti con "{title}"?',
        "action_id": "assist_with_window",
        "detail": app,
    }


# ---------- idle.entered / idle.left: no decidable content, tracker-only ----------


def _idle_context(event: dict, user_state: str) -> str:
    return f"idle transition, user state now {user_state}"


_IDLE_INTENT = EventIntent(
    kind="idle",
    questions=(),
    context=_idle_context,
    hypotheses=_no_hypotheses,
    suggestion=_no_suggestion,
)


# ---------- mail.arrived / mail.closed / mail.archived / mail.deleted: recorded, not decided ----------


def _mail_recorded_context(event: dict, user_state: str) -> str:
    return f"{event.get('kind', 'mail')} recorded, no decidable content"


def _mail_lifecycle_intent(kind: str) -> EventIntent:
    return EventIntent(
        kind=kind,
        questions=(),
        context=_mail_recorded_context,
        hypotheses=_no_hypotheses,
        suggestion=_no_suggestion,
    )


INTENTS: dict[str, EventIntent] = {
    "mail.opened": EventIntent(
        kind="mail.opened",
        questions=(_MESSAGE_TYPE, _URGENCY),
        context=_mail_opened_context,
        hypotheses=_mail_opened_hypotheses,
        suggestion=_mail_opened_suggestion,
    ),
    "mail.composing": EventIntent(
        kind="mail.composing",
        questions=(_STUCK, _TONE_RISK),
        context=_mail_composing_context,
        hypotheses=_mail_composing_hypotheses,
        suggestion=_mail_composing_suggestion,
    ),
    "text.selected": EventIntent(
        kind="text.selected",
        questions=(_ACTIONABLE, _ACTION_KIND),
        context=_text_selected_context,
        hypotheses=_text_selected_hypotheses,
        suggestion=_text_selected_suggestion,
    ),
    "app.activated": EventIntent(
        kind="app.activated",
        questions=(_APP_RELEVANT,),
        context=_app_activated_context,
        hypotheses=_relevance_hypotheses("assist_with_app"),
        suggestion=_app_activated_suggestion,
    ),
    "window.changed": EventIntent(
        kind="window.changed",
        questions=(_WINDOW_RELEVANT,),
        context=_window_changed_context,
        hypotheses=_relevance_hypotheses("assist_with_window"),
        suggestion=_window_changed_suggestion,
    ),
    "idle.entered": _IDLE_INTENT,
    "idle.left": _IDLE_INTENT,
    "mail.arrived": _mail_lifecycle_intent("mail.arrived"),
    "mail.closed": _mail_lifecycle_intent("mail.closed"),
    "mail.archived": _mail_lifecycle_intent("mail.archived"),
    "mail.deleted": _mail_lifecycle_intent("mail.deleted"),
}

DEFAULT_INTENT = EventIntent(
    kind="unknown",
    questions=(),
    context=_idle_context,
    hypotheses=_no_hypotheses,
    suggestion=_no_suggestion,
)


def intent_for(kind: str) -> EventIntent:
    return INTENTS.get(kind, DEFAULT_INTENT)


__all__ = [
    "SYSTEM_PREFIX",
    "USER_STATE",
    "Hypothesis",
    "EventIntent",
    "INTENTS",
    "DEFAULT_INTENT",
    "intent_for",
]
