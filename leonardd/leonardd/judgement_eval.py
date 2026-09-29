"""Honest measurement of the resident model's judgement on realistic mail.

Runs a hand-labelled fixture of `mail.opened` events through `AttentionEngine`
at `floor=0.0` (so the raw argmax and confidence are visible, unforced by any
threshold), then reconstructs what a floor sweep would have done post hoc:
`_action_at(floor)` only needs the stored `action`/`confidence` -- now
`policy.py`'s output, not a model readout -- and `schema_mass`, exactly the
quantities `attention.decide_event` itself compares against the floor, so one
pass over the fixture is enough for every floor.

The model is no longer asked what Leonard should do; it is asked
`message_type` and `urgency` (two more facts, `deadline_stated` and
`sender_waiting_on_user`, were tried and dropped -- see `intents.py`'s
module docstring), and `policy.decide_action` turns those facts into the
action. This file measures both ends: whether the factual readouts are
themselves accurate, and whether the actions `policy.py` derives from them
get the fixture's `should_surface` label right at each floor.

It also measures a confound the letter-readout scheme creates on its own:
options are presented as A/B/C/D and a model can favour early letters
independently of content. `_letter_bias_check` answers the same `message_type`
question a second time with its options reversed and reports how often the
answer moves -- content-driven judgement should not care what letter an
option happened to get.

This module measures; it does not tune anything to look better. See
`leonardd/results/judgement_eval.json` for the run this file produced and
`leonardd/README.md` for the summary.
"""

from __future__ import annotations

import json
import sys
import time
from dataclasses import replace
from pathlib import Path

from .attention import AttentionEngine
from .decide import decide
from .engine import ResidentMLX
from .intents import _MESSAGE_TYPE, intent_for

MODEL_ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
RESULTS_DIR = Path(__file__).resolve().parents[1] / "results"
FLOORS = (0.0, 0.50, 0.55, 0.577, 0.60, 0.65, 0.70, 0.75, 0.80, 0.90)


def _event(fx: dict) -> dict:
    return {
        "t": "event",
        "ts": 0.0,
        "id": fx["id"],
        "kind": "mail.opened",
        "app": "Mail",
        "payload": fx["payload"],
    }


FIXTURE: list[dict] = [
    dict(
        id="evt_it_deadline_venerdi",
        lang="it",
        category="urgent_deadline_personal",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Marco Rossi <marco@example.com>",
            subject="Conferma preventivo entro venerdi",
            body="Ciao, ho bisogno di una conferma sul preventivo entro venerdi altrimenti perdiamo lo slot con il fornitore. Puoi rispondermi appena possibile?",
            thread_len=2,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_signoff_today",
        lang="en",
        category="urgent_deadline_work",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Sarah Connor <sarah@acme.com>",
            subject="Need your sign-off by 3pm today",
            body="Can you approve the contract changes I sent? Legal needs this signed before 3pm today or we lose the vendor slot. Let me know ASAP.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_client_question",
        lang="en",
        category="direct_question",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Priya Patel <priya@partner.io>",
            subject="Quick question about the API",
            body="Hi, does your API support webhook retries? We need to know before we finalize the integration this week. Thanks!",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_cliente_arrabbiato",
        lang="it",
        category="angry_customer",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Luca Bianchi <luca.bianchi@clientecorp.it>",
            subject="Servizio non funzionante, serve una risposta",
            body="Il servizio e' fermo da stamattina e stiamo perdendo clienti ogni minuto. Ho bisogno di una risposta da voi entro un'ora o dovremo valutare la disdetta del contratto.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_angry_customer",
        lang="en",
        category="angry_customer",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Angry Customer <upset@client.com>",
            subject="This is unacceptable, respond now",
            body="Your product has been down for 6 hours and we are losing money every minute. I need a response from you personally within the next 15 minutes or we are cancelling the contract.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_moglie_urgente",
        lang="it",
        category="personal_urgent",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Giulia <giulia@gmail.com>",
            subject="chiamami appena puoi",
            body="Ciao amore, e' successo un incidente, sto bene ma ho bisogno che mi chiami appena vedi questo messaggio, e' urgente.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_vendor_signature",
        lang="en",
        category="urgent_deadline_work",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Tom Reyes <tom@vendor.com>",
            subject="Signature needed today",
            body="Please sign and return the attached contract today. Our legal deadline is 5pm and the deal falls through if we do not have it back by then.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_colloquio",
        lang="it",
        category="scheduling_request",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Elena Ferri <hr@newcompany.it>",
            subject="Disponibilita per colloquio la prossima settimana",
            body="Ciao, saremmo felici di fissare un colloquio con te la prossima settimana. Puoi indicarci due o tre orari che ti vanno bene entro giovedi?",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_reschedule",
        lang="en",
        category="scheduling_request",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Ben Walsh <ben@partnerco.com>",
            subject="Need to move tomorrow's call",
            body="Something came up and I can't make our 10am call tomorrow. Can we push it to Thursday afternoon instead? Let me know what works.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_invoice_overdue",
        lang="en",
        category="urgent_deadline_work",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Accounts <billing@supplierco.com>",
            subject="Invoice #4471 overdue, action required",
            body="Invoice #4471 is now 30 days overdue. Please arrange payment or contact us within 5 business days to avoid a service suspension.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_amico_pranzo",
        lang="it",
        category="casual_low_urgency",
        reply_needed_expected=True,
        should_surface=False,
        payload=dict(
            sender="Dario <dario@gmail.com>",
            subject="pranzo questa settimana?",
            body="Ciao, ti va di pranzare insieme questa settimana? Nessuna fretta, fammi sapere quando sei libero.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_friend_lunch",
        lang="en",
        category="casual_low_urgency",
        reply_needed_expected=True,
        should_surface=False,
        payload=dict(
            sender="Dave <dave@gmail.com>",
            subject="lunch?",
            body="hey wanna grab lunch sometime this week? no rush at all",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_techmeme",
        lang="en",
        category="newsletter",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Techmeme <newsletter@techmeme.com>",
            subject="Techmeme Daily",
            body="Top stories today: a new AI chip announcement, a startup funding round, and a regulatory update. Unsubscribe anytime.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_newsletter_marketing",
        lang="it",
        category="newsletter",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Newsletter Moda <news@fashionshop.it>",
            subject="I saldi sono iniziati! Fino al 50% di sconto",
            body="Approfitta subito dei nostri saldi: fino al 50% di sconto su una selezione di prodotti. Offerta valida solo per pochi giorni. Per annullare l'iscrizione clicca qui.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_shipping_notification",
        lang="en",
        category="automated_transactional",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Orders <no-reply@shopco.com>",
            subject="Your order has shipped",
            body="Your order #88213 has shipped and is expected to arrive in 3-5 business days. Track your package using the link below.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_ricevuta",
        lang="it",
        category="automated_transactional",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Fatture <fatture@energiaservizi.it>",
            subject="La tua bolletta di questo mese",
            body="Gentile cliente, la tua bolletta di questo mese e' disponibile nell'area riservata. L'addebito automatico verra' effettuato come da contratto.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_calendar_reminder",
        lang="en",
        category="automated_reminder",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Calendar <calendar-notification@google.com>",
            subject="Reminder: Team standup in 15 minutes",
            body="This is an automatic reminder that Team standup starts in 15 minutes. Location: Zoom.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_linkedin",
        lang="it",
        category="social_notification",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="LinkedIn <notifications@linkedin.com>",
            subject="3 persone hanno visualizzato il tuo profilo",
            body="Scopri chi ha visualizzato il tuo profilo questa settimana e amplia la tua rete di contatti.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_fyi_thread",
        lang="en",
        category="fyi_no_action",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Ops Team <ops@company.com>",
            subject="FYI: deployment completed",
            body="Just a heads up that the deployment finished successfully at 2pm. No action needed on your end, this is for your records.",
            thread_len=4,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_fyi_nessuna_azione",
        lang="it",
        category="fyi_no_action",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Amministrazione <admin@ufficio.it>",
            subject="FYI: nuovo orario ufficio da lunedi",
            body="Vi informiamo che da lunedi l'orario di apertura dell'ufficio cambiera' come da allegato. Non e' richiesta alcuna azione da parte vostra.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_security_alert",
        lang="en",
        category="security_alert",
        reply_needed_expected=False,
        should_surface=True,
        payload=dict(
            sender="Security <security@yourbank.com>",
            subject="New sign-in to your account from an unrecognized device",
            body="We noticed a new sign-in to your account from a device we don't recognize, located in a different country. If this was not you, secure your account immediately.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_ambiguo_breve",
        lang="it",
        category="ambiguous",
        reply_needed_expected=True,
        should_surface=False,
        payload=dict(
            sender="Anna <anna.verdi@example.it>",
            subject="Dai un'occhiata quando puoi",
            body="Ciao, dai un'occhiata al documento quando hai un attimo, non c'e' fretta particolare.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_boss_decision",
        lang="en",
        category="urgent_deadline_work",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Jane Kim <jane@yourcompany.com>",
            subject="URGENT: need your decision in the next hour",
            body="I need your go/no-go decision on the acquisition in the next hour, the board call starts at 4pm and we cannot proceed without your answer. Please reply the moment you see this.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_it_evento_invito",
        lang="it",
        category="scheduling_request",
        reply_needed_expected=True,
        should_surface=True,
        payload=dict(
            sender="Segreteria Eventi <eventi@associazione.it>",
            subject="Conferma la tua partecipazione entro mercoledi",
            body="Gentile socio, ti chiediamo di confermare la tua partecipazione all'assemblea entro mercoledi, altrimenti il tuo posto verra' riassegnato.",
            thread_len=1,
            unread=True,
        ),
    ),
    dict(
        id="evt_en_promo_flash_sale",
        lang="en",
        category="newsletter",
        reply_needed_expected=False,
        should_surface=False,
        payload=dict(
            sender="Deals <deals@retailstore.com>",
            subject="Flash sale: 24 hours only",
            body="Everything is 30% off for the next 24 hours only. Shop now before it's gone. Click here to browse the sale.",
            thread_len=1,
            unread=True,
        ),
    ),
]


def _action_at(floor: float, action: str, confidence: float, schema_mass: float) -> str:
    if schema_mass < 0.5 or confidence < floor:
        return "wait"
    return action


def _bucket(p: float) -> str:
    edges = [0.5, 0.6, 0.7, 0.8, 0.9, 1.01]
    for lo, hi in zip(edges, edges[1:]):
        if lo <= p < hi:
            return f"{lo:.2f}-{hi if hi <= 1.0 else 1.00:.2f}"
    return "<0.50"


def _letter_bias_check(engine, primed) -> dict:
    shuffled = replace(_MESSAGE_TYPE, options=tuple(reversed(_MESSAGE_TYPE.options)))
    moved = []
    for fx in FIXTURE:
        event = _event(fx)
        context = intent_for("mail.opened").context(event, "reading")
        original = decide(engine, context, _MESSAGE_TYPE, primed=primed)
        flipped = decide(engine, context, shuffled, primed=primed)
        if original.value != flipped.value:
            moved.append(
                {
                    "id": fx["id"],
                    "original_order_value": original.value,
                    "original_order_p": round(original.confidence, 3),
                    "reversed_order_value": flipped.value,
                    "reversed_order_p": round(flipped.confidence, 3),
                }
            )
    return {
        "question": "message_type",
        "n_events": len(FIXTURE),
        "n_moved": len(moved),
        "moved_fraction": round(len(moved) / len(FIXTURE), 3),
        "moved": moved,
    }


def run(engine=None) -> dict:
    """Evaluate on `engine`, the resident MLX model by default.
    `tools/reference_eval.py` passes the CPU reference engine instead."""
    engine = engine if engine is not None else ResidentMLX(MODEL_ID)
    attention = AttentionEngine(engine, floor=0.0)

    per_event = []
    for fx in FIXTURE:
        d = attention.decide_event(_event(fx))
        readouts = {r["q"]: r for r in d["readouts"]}
        mt = readouts["message_type"]
        ug = readouts["urgency"]
        per_event.append(
            {
                "id": fx["id"],
                "lang": fx["lang"],
                "category": fx["category"],
                "reply_needed_expected": fx["reply_needed_expected"],
                "should_surface_expected": fx["should_surface"],
                "message_type_value": mt["value"],
                "message_type_p": mt["p"],
                "urgency_value": ug["value"],
                "urgency_p": ug["p"],
                "action": d["action"],
                "action_confidence": d["confidence"],
                "schema_mass": d["schema_mass"],
            }
        )

    predicted_reply_needed = [e["message_type_value"] == "personal_request" for e in per_event]
    reply_needed_correct = sum(
        1 for e, predicted in zip(per_event, predicted_reply_needed) if predicted == e["reply_needed_expected"]
    )
    reply_needed_accuracy = reply_needed_correct / len(per_event)

    calibration_bins: dict[str, list[bool]] = {}
    for e in per_event:
        bin_key = _bucket(e["action_confidence"])
        surfaced_correct = (e["action"] in ("prepare", "suggest")) == e["should_surface_expected"]
        calibration_bins.setdefault(bin_key, []).append(surfaced_correct)
    calibration = {
        b: {"n": len(v), "accuracy": round(sum(v) / len(v), 3)} for b, v in sorted(calibration_bins.items())
    }

    floor_sweep = []
    for floor in FLOORS:
        surfaced = []
        for e in per_event:
            action = _action_at(floor, e["action"], e["action_confidence"], e["schema_mass"])
            surfaced.append(action in ("prepare", "suggest"))
        tp = sum(1 for e, s in zip(per_event, surfaced) if s and e["should_surface_expected"])
        fp = sum(1 for e, s in zip(per_event, surfaced) if s and not e["should_surface_expected"])
        fn = sum(1 for e, s in zip(per_event, surfaced) if not s and e["should_surface_expected"])
        tn = sum(1 for e, s in zip(per_event, surfaced) if not s and not e["should_surface_expected"])
        coverage = sum(surfaced) / len(surfaced)
        accuracy = (tp + tn) / len(surfaced)
        precision = tp / (tp + fp) if (tp + fp) else None
        recall = tp / (tp + fn) if (tp + fn) else None
        floor_sweep.append(
            {
                "floor": floor,
                "coverage": round(coverage, 3),
                "accuracy": round(accuracy, 3),
                "precision": round(precision, 3) if precision is not None else None,
                "recall": round(recall, 3) if recall is not None else None,
                "tp": tp,
                "fp": fp,
                "fn": fn,
                "tn": tn,
            }
        )

    default_floor = 0.60
    confusion_at_default = next(row for row in floor_sweep if row["floor"] == default_floor)
    confusion_at_0_50 = next(row for row in floor_sweep if row["floor"] == 0.50)
    confusion_at_0_70 = next(row for row in floor_sweep if row["floor"] == 0.70)

    highlights = {
        "urgent_deadline_examples": [
            {
                "id": e["id"],
                "category": e["category"],
                "message_type_value": e["message_type_value"],
                "urgency_value": e["urgency_value"],
                "action": e["action"],
                "action_confidence": e["action_confidence"],
            }
            for e in per_event
            if e["category"].startswith("urgent") or e["category"] == "angry_customer"
        ],
        "newsletter_examples": [
            {
                "id": e["id"],
                "message_type_value": e["message_type_value"],
                "action": e["action"],
                "action_confidence": e["action_confidence"],
            }
            for e in per_event
            if e["category"] == "newsletter"
        ],
    }

    letter_bias = _letter_bias_check(engine, attention.primed)

    return {
        "ts": time.time(),
        "model": MODEL_ID,
        "engine": getattr(engine, "name", MODEL_ID),
        "n_events": len(per_event),
        "per_event": per_event,
        "reply_needed_accuracy_via_message_type": round(reply_needed_accuracy, 3),
        "action_calibration_by_confidence_bin": calibration,
        "floor_sweep": floor_sweep,
        "confusion_at_floor_0_50": confusion_at_0_50,
        "confusion_at_floor_0_60": confusion_at_default,
        "confusion_at_floor_0_70": confusion_at_0_70,
        "letter_order_bias": letter_bias,
        "highlights": highlights,
    }


def main() -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    report = run()
    out_path = RESULTS_DIR / f"judgement_eval_{int(time.time())}.json"
    out_path.write_text(json.dumps(report, indent=2))
    (RESULTS_DIR / "latest_judgement_eval.json").write_text(json.dumps(report, indent=2))
    print(f"[judgement_eval] wrote {out_path}", file=sys.stderr)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
