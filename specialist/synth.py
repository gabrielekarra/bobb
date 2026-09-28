"""Synthetic labelled events for exercising the pipeline before real
`audit.db` data exists.

**This tests plumbing, not the thesis.** `SPECIALIST.md`'s central claim is
that a few thousand *real* accept/dismiss and implicit-behaviour labels
teach a useful specialist; nothing generated here can validate that, because
the whole point of the thesis is that one person's interruption preference
is not synthesizable the way a form field's value is (`SPECIALIST.md`, "Why
the CUA-S1 recipe does not transfer"; `CUA-INVESTIGATION.md` section 2.6
point 4, "training data cannot be template-generated the way form data is").
This module exists only so `model.py`/`data.py`/`train.py`/`metrics.py` can
be exercised end to end on deterministic, plausible-looking rows without a
live daemon.

Borrows CUA-S1's `synth.py` technique (`libs/cua-s1/python/src/cua_s1/
synth.py`): a small typed catalog (their `concepts.py`, here `CATEGORIES`),
seeded per-episode generation via `random.Random(seed + index * 7919)` so
the first N rows of an M-row run (M > N) are byte-identical to a direct
N-row run, deliberate co-location of confusable cases, and a stable-hash
split so the same scenario combination cannot straddle train/validation/
test. CUA-S1 co-locates confusable *field* pairs inside one form's option
table; there is no per-example option table here (`model.ACTIONS` is always
the same four strings for every example), so `HARD_NEGATIVE_PAIRS` instead
co-locates confusable *categories* inside one event's preceding history
window, so the model cannot shortcut on "was there an urgent-looking event
recently" and has to read the current event's own content.
"""

from __future__ import annotations

import hashlib
import random
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from data import Example
from model import ACTIONS, MAX_HISTORY_EVENTS, serialize_context

SPLIT_NAMES = ("train", "validation", "test")
_BASE_MONDAY = datetime(2026, 1, 5, tzinfo=timezone.utc)


@dataclass(frozen=True)
class Category:
    key: str
    group: str
    action: str
    senders: tuple[str, ...]
    subjects: tuple[str, ...]
    bodies: tuple[str, ...]
    thread_len: tuple[int, int]


CATEGORIES: tuple[Category, ...] = (
    Category(
        "boss_deadline", "internal", "suggest",
        ("Marco Bianchi <marco.bianchi@work.it>", "Elena Conti <elena.conti@work.it>"),
        ("Serve la tua revisione entro oggi", "Urgente: bozza per il cliente"),
        (
            "Puoi rivedere il documento entro questo pomeriggio? Il cliente lo aspetta.",
            "Mi serve il tuo ok prima delle 17 per mandare tutto al cliente.",
        ),
        (1, 3),
    ),
    Category(
        "client_escalation", "external", "suggest",
        ("Giulia Rossi <g.rossi@clientco.com>",),
        ("Non funziona ancora, serve una risposta", "Siamo fermi da ieri"),
        (
            "Il problema segnalato la settimana scorsa non e' stato risolto.",
            "Abbiamo bisogno di sapere subito come procedere.",
        ),
        (2, 5),
    ),
    Category(
        "colleague_question", "internal", "wait",
        ("Luca Ferrari <luca.ferrari@work.it>",),
        ("Una domanda veloce", "Curiosita' sul progetto"),
        (
            "Quando hai un minuto, mi spieghi come hai gestito la parte X?",
            "Nessuna fretta, ma mi piacerebbe capire meglio questo punto.",
        ),
        (1, 2),
    ),
    Category(
        "calendar_invite", "internal", "prepare",
        ("Calendar <calendar@work.it>", "Elena Conti <elena.conti@work.it>"),
        ("Invito: revisione trimestrale", "Possiamo spostare la call di domani?"),
        (
            "Ho proposto un nuovo orario per la riunione di domani, controlla la disponibilita'.",
            "Serve confermare la presenza all'incontro di giovedi'.",
        ),
        (1, 2),
    ),
    Category(
        "fyi_thread", "internal", "ignore",
        ("Team Ops <ops@work.it>",),
        ("FYI: aggiornamento processo", "Per conoscenza"),
        (
            "Vi giriamo questa mail solo per conoscenza, nessuna azione richiesta.",
            "Aggiungiamo in copia per trasparenza, non serve rispondere.",
        ),
        (1, 4),
    ),
    Category(
        "newsletter", "external", "ignore",
        ("Newsletter <news@saas-tool.com>",),
        ("Le novita' del mese", "5 modi per essere piu' produttivo"),
        (
            "Scopri le nuove funzionalita' rilasciate questo mese.",
            "I nostri consigli settimanali per il tuo team.",
        ),
        (1, 1),
    ),
    Category(
        "automated_notification", "external", "ignore",
        ("noreply@service.com",),
        ("Il tuo report settimanale", "Backup completato"),
        (
            "Il backup automatico e' stato completato con successo.",
            "Ecco il riepilogo automatico delle attivita' della settimana.",
        ),
        (1, 1),
    ),
    Category(
        "delayed_followup", "internal", "wait",
        ("Marco Bianchi <marco.bianchi@work.it>",),
        ("Ci sentiamo la prossima settimana?", "Da riprendere quando puoi"),
        (
            "Non e' urgente, ma sarebbe bello riprendere questo discorso nei prossimi giorni.",
            "Quando hai tempo, senza fretta, vediamo questo punto insieme.",
        ),
        (1, 3),
    ),
    Category(
        "reschedule_request", "internal", "prepare",
        ("Elena Conti <elena.conti@work.it>",),
        ("Dobbiamo spostare la riunione", "Conflitto in agenda"),
        (
            "Ho un conflitto in agenda per domani, possiamo trovare un altro slot?",
            "Serve controllare la disponibilita' per spostare l'incontro.",
        ),
        (1, 2),
    ),
)

_CATEGORY_BY_KEY: dict[str, Category] = {c.key: c for c in CATEGORIES}

HARD_NEGATIVE_PAIRS: tuple[tuple[str, str], ...] = (
    ("boss_deadline", "fyi_thread"),
    ("client_escalation", "colleague_question"),
    ("calendar_invite", "newsletter"),
    ("delayed_followup", "automated_notification"),
)


def _stable_fraction(text: str) -> float:
    digest = hashlib.sha256(text.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / 2**64


def _paired_category(key: str) -> Category | None:
    for first, second in HARD_NEGATIVE_PAIRS:
        if key == first:
            return _CATEGORY_BY_KEY[second]
        if key == second:
            return _CATEGORY_BY_KEY[first]
    return None


def _timestamp(rng: random.Random, hour: int, weekday: int, index: int) -> float:
    when = _BASE_MONDAY + timedelta(weeks=index, days=weekday, hours=hour, minutes=rng.randint(0, 59))
    return when.timestamp()


def sample_episode(index: int, seed: int = 2026, *, hard_negative_probability: float = 0.35) -> dict:
    """One deterministic, replayable labelled row: `random.Random(seed +
    index * 7919)` makes generation order-independent, so the first N rows
    of a run of M >= N are identical to a direct run of N."""
    rng = random.Random(seed + index * 7919)
    category = rng.choice(CATEGORIES)
    sender = rng.choice(category.senders)
    subject = rng.choice(category.subjects)
    body = rng.choice(category.bodies)
    thread_len = rng.randint(*category.thread_len)
    hour = rng.randint(0, 23)
    weekday = rng.randint(0, 6)
    user_state = rng.choice(("typing", "reading", "idle", "meeting"))

    history: list[dict] = []
    signature_keys = {category.key}
    paired = _paired_category(category.key)
    if paired is not None and rng.random() < hard_negative_probability:
        history.append({"kind": "mail.opened", "action": paired.action})
        signature_keys.add(paired.key)
    for _ in range(rng.randint(0, 2)):
        history.append(
            {"kind": rng.choice(("app.activated", "window.changed", "idle.entered")), "action": "ignore"}
        )
    rng.shuffle(history)
    history = history[-MAX_HISTORY_EVENTS:]

    ts = _timestamp(rng, hour, weekday, index)
    event = {
        "kind": "mail.opened",
        "app": "Mail",
        "ts": ts,
        "user_state": user_state,
        "payload": {"sender": sender, "subject": subject, "body": body, "thread_len": thread_len, "unread": True},
    }
    return {
        "context": serialize_context(event, history),
        "label": ACTIONS.index(category.action),
        "ts": ts,
        "meta": {"category": category.key, "signature": "|".join(sorted(signature_keys))},
    }


def generate_examples(n: int, *, seed: int = 2026, hard_negative_probability: float = 0.35) -> list[dict]:
    if n < 0:
        raise ValueError("n must be non-negative")
    return [sample_episode(i, seed, hard_negative_probability=hard_negative_probability) for i in range(n)]


def split_examples(
    examples: Sequence[dict], ratios: tuple[float, float, float] = (0.8, 0.1, 0.1)
) -> dict[str, list[dict]]:
    """Bucket by a stable hash of each row's category signature, so the
    same category (or hard-negative-paired category combination) never
    straddles train/validation/test."""
    total = sum(ratios)
    if total <= 0:
        raise ValueError("ratios must sum to a positive number")
    train_ratio, val_ratio, _ = (r / total for r in ratios)
    buckets: dict[str, list[dict]] = {name: [] for name in SPLIT_NAMES}
    for example in examples:
        fraction = _stable_fraction(example["meta"]["signature"])
        if fraction < train_ratio:
            name = "train"
        elif fraction < train_ratio + val_ratio:
            name = "validation"
        else:
            name = "test"
        buckets[name].append(example)
    return buckets


def to_examples(rows: Sequence[dict]) -> list[Example]:
    return [Example(context=row["context"], label=row["label"], weight=1.0, source="synthetic", ts=row["ts"]) for row in rows]


__all__ = [
    "SPLIT_NAMES",
    "Category",
    "CATEGORIES",
    "HARD_NEGATIVE_PAIRS",
    "sample_episode",
    "generate_examples",
    "split_examples",
    "to_examples",
]
