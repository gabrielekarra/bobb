"""User-facing copy, in English and Italian.

Only text a person reads lives here: suggestion titles, button labels and the
one-sentence explanation Mind shows for every decision. Model-facing question
text stays in `intents.py`, in English, matching the checkpoint's tuning
language. Technical `why` strings stay untranslated, because they are for
debugging and quoting them in a bug report must not depend on the locale.
"""

from __future__ import annotations

DEFAULT_LOCALE = "en"

_STRINGS: dict[str, dict[str, str]] = {
    # ---- suggestions
    "reply.title": {"en": "{name} is waiting for your reply", "it": "{name} aspetta una tua risposta"},
    "reply.cta": {"en": "Draft reply", "it": "Prepara risposta"},
    "meeting.title": {"en": "Your {time} with {who}", "it": "Alle {time} con {who}"},
    "meeting.others": {"en": "{name} and {count} more", "it": "{name} e altri {count}"},
    "meeting.cta": {"en": "Brief me", "it": "Preparami"},
    "explain.meeting": {
        "en": "A meeting with other people starts in {minutes} minutes.",
        "it": "Tra {minutes} minuti inizia un incontro con altre persone.",
    },
    "notice.title": {"en": "This notice looks urgent", "it": "Questo avviso sembra urgente"},
    "notice.cta": {"en": "Summarize", "it": "Riassumi"},
    "tone.title": {"en": "This draft may come across as harsh", "it": "Questa bozza potrebbe suonare brusca"},
    "tone.detail": {"en": "Leonard can suggest a calmer version", "it": "Leonard può proporne una versione più pacata"},
    "tone.cta": {"en": "Soften it", "it": "Ammorbidisci"},
    "continue.title": {"en": "Stuck on this draft?", "it": "Bloccato su questa bozza?"},
    "continue.detail": {"en": "Paused for {seconds}s", "it": "In pausa da {seconds}s"},
    "continue.cta": {"en": "Continue it", "it": "Continua"},
    "select.define.title": {"en": 'Explain "{snippet}"?', "it": 'Vuoi una spiegazione di "{snippet}"?'},
    "select.translate.title": {"en": 'Translate "{snippet}"?', "it": 'Vuoi tradurre "{snippet}"?'},
    "select.compute.title": {"en": 'Work out "{snippet}"?', "it": 'Vuoi calcolare "{snippet}"?'},
    "select.lookup.title": {"en": 'Find what you know about "{snippet}"?', "it": 'Cerco cosa sai su "{snippet}"?'},
    "select.cta": {"en": "Show me", "it": "Mostra"},
    "select.detail": {"en": "Selected in {app}", "it": "Selezionato in {app}"},
    # ---- urgency phrases
    "urgency.0": {"en": "no reply expected", "it": "nessuna risposta attesa"},
    "urgency.1": {"en": "whenever you like", "it": "quando vuoi"},
    "urgency.2": {"en": "this week", "it": "entro la settimana"},
    "urgency.3": {"en": "today or tomorrow", "it": "oggi o domani"},
    "urgency.4": {"en": "right now", "it": "subito"},
    # ---- explanations: what the message is
    "explain.broadcast": {"en": "A newsletter or mass mailing.", "it": "Una newsletter o un invio di massa."},
    "explain.transactional": {"en": "An automated notice ({urgency}).", "it": "Un avviso automatico ({urgency})."},
    "explain.personal_no_ask": {
        "en": "{name} writes to keep you informed, with no request.",
        "it": "{name} scrive per informarti, senza chiederti nulla.",
    },
    "explain.personal_request": {
        "en": "{name} is asking you for something ({urgency}).",
        "it": "{name} ti chiede qualcosa ({urgency}).",
    },
    "explain.composing.curt_or_hostile": {
        "en": "The draft reads as curt or hostile.",
        "it": "La bozza suona brusca o ostile.",
    },
    "explain.composing.firm": {"en": "The draft is firm but fine.", "it": "La bozza è decisa ma corretta."},
    "explain.composing.warm_or_neutral": {"en": "The draft reads well.", "it": "La bozza suona bene."},
    "explain.selection": {"en": "You selected some text.", "it": "Hai selezionato del testo."},
    "explain.generic": {"en": "Something changed on screen.", "it": "Qualcosa è cambiato sullo schermo."},
    # ---- explanations: what Leonard did about it
    "outcome.suggest": {"en": "Worth your attention now.", "it": "Merita la tua attenzione adesso."},
    "outcome.prepare": {
        "en": "Worth preparing, but not worth interrupting you.",
        "it": "Vale la pena prepararlo, non interromperti.",
    },
    "outcome.prepare.typing": {
        "en": "You were typing, so Leonard waits instead of interrupting.",
        "it": "Stavi scrivendo: Leonard aspetta invece di interromperti.",
    },
    "outcome.prepare.meeting": {
        "en": "You were in a call, so Leonard waits instead of interrupting.",
        "it": "Eri in una chiamata: Leonard aspetta invece di interromperti.",
    },
    "outcome.prepare.quiet_hours": {
        "en": "Quiet hours: Leonard keeps it for later.",
        "it": "Ore di silenzio: Leonard lo tiene per dopo.",
    },
    "outcome.wait": {"en": "Not urgent enough to interrupt.", "it": "Non abbastanza urgente per interromperti."},
    "outcome.ignore": {"en": "Nothing to do.", "it": "Niente da fare."},
    "outcome.abstained": {
        "en": "Leonard was {confidence} sure, below your {floor} threshold, so it stayed quiet.",
        "it": "Leonard era sicuro al {confidence}, sotto la tua soglia del {floor}: è rimasto in silenzio.",
    },
    "outcome.failed_readout": {
        "en": "The model's answer was unreliable, so Leonard stayed quiet.",
        "it": "La risposta del modello non era affidabile: Leonard è rimasto in silenzio.",
    },
    "outcome.muted": {
        "en": "You dismissed {count} suggestions about {sender}, so Leonard stays quiet about them.",
        "it": "Hai ignorato {count} suggerimenti su {sender}: Leonard non ti disturba più per questo mittente.",
    },
    "outcome.proactive_off": {
        "en": "Proactive help is off for this kind of event.",
        "it": "L'aiuto proattivo è disattivato per questo tipo di evento.",
    },
    "outcome.specialist": {
        "en": "Leonard has learned from you that messages like this can wait, so it stayed quiet without asking the model.",
        "it": "Leonard ha imparato da te che messaggi così possono aspettare, quindi è rimasto in silenzio senza interpellare il modello.",
    },
    "outcome.recorded": {
        "en": "Recorded so Leonard can learn from what you do next.",
        "it": "Registrato perché Leonard impari da cosa fai dopo.",
    },
    "outcome.loading": {"en": "Leonard was still starting up.", "it": "Leonard si stava ancora avviando."},
    "outcome.personal_floor": {
        "en": "Your threshold for this is {floor}, learned from your answers.",
        "it": "La tua soglia per questo è {floor}, imparata dalle tue risposte.",
    },
    # ---- misc
    "someone": {"en": "Someone", "it": "Qualcuno"},
}


def locale_or_default(locale: str | None) -> str:
    return locale if locale in ("en", "it") else DEFAULT_LOCALE


def t(key: str, locale: str | None = None, **values: object) -> str:
    entry = _STRINGS[key]
    template = entry.get(locale_or_default(locale)) or entry[DEFAULT_LOCALE]
    return template.format(**values) if values else template


def percent(p: float) -> str:
    return f"{round(p * 100)}%"


def display_name(sender: str | None, locale: str | None = None) -> str:
    """`Marco Rossi <marco@x.it>` -> `Marco Rossi`; a bare address stays."""
    if not sender:
        return t("someone", locale)
    name = sender.split("<")[0].strip().strip('"').strip()
    return name or sender.strip("<> ")


__all__ = ["t", "percent", "display_name", "locale_or_default", "DEFAULT_LOCALE"]
