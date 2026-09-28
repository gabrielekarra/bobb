import json
import sqlite3

import pytest

from data import (
    build_distill_examples,
    build_examples,
    estimate_user_states,
    implicit_explicit_agreement,
    load_rows,
    time_split,
)
from labels import TimedEvent
from model import ACTIONS

_SCHEMA = """
CREATE TABLE decisions (
    decision_id   TEXT PRIMARY KEY,
    event_id      TEXT NOT NULL,
    ts            REAL NOT NULL,
    kind          TEXT NOT NULL,
    app           TEXT,
    event_payload TEXT NOT NULL,
    model         TEXT NOT NULL,
    floor         REAL NOT NULL,
    action        TEXT NOT NULL,
    confidence    REAL NOT NULL,
    schema_mass   REAL NOT NULL,
    latency_ms    REAL NOT NULL,
    abstained     INTEGER NOT NULL DEFAULT 0,
    hypotheses    TEXT NOT NULL,
    readouts      TEXT NOT NULL,
    suggestion    TEXT,
    why           TEXT,
    response      TEXT,
    response_ts   REAL
);
"""


def _row(
    decision_id,
    ts,
    kind,
    action,
    *,
    app="Mail",
    payload=None,
    response=None,
    readouts=None,
):
    return {
        "decision_id": decision_id,
        "event_id": f"evt_{decision_id}",
        "ts": ts,
        "kind": kind,
        "app": app,
        "event_payload": json.dumps(payload or {}),
        "model": "test-model",
        "floor": 0.6,
        "action": action,
        "confidence": 0.8,
        "schema_mass": 0.9,
        "latency_ms": 5.0,
        "abstained": 0,
        "hypotheses": "[]",
        "readouts": json.dumps(readouts if readouts is not None else []),
        "suggestion": None,
        "why": None,
        "response": response,
        "response_ts": None,
    }


def _make_db(tmp_path, rows):
    path = tmp_path / "audit.db"
    conn = sqlite3.connect(str(path))
    conn.executescript(_SCHEMA)
    columns = list(rows[0])
    placeholders = ", ".join("?" for _ in columns)
    conn.executemany(
        f"INSERT INTO decisions ({', '.join(columns)}) VALUES ({placeholders})",
        [[row[c] for c in columns] for row in rows],
    )
    conn.commit()
    conn.close()
    return path


def test_load_rows_reads_in_chronological_order(tmp_path):
    rows = [
        _row("d2", 200.0, "mail.opened", "wait"),
        _row("d1", 100.0, "mail.opened", "ignore"),
    ]
    path = _make_db(tmp_path, rows)
    loaded = load_rows(path)
    assert [r["decision_id"] for r in loaded] == ["d1", "d2"]


def test_estimate_user_states_tracks_idle_typing_and_meeting():
    events = [
        TimedEvent(ts=0, kind="mail.opened", app="Mail", payload={}),
        TimedEvent(ts=1, kind="idle.entered", app="Mail", payload={}),
        TimedEvent(ts=2, kind="idle.left", app="Mail", payload={}),
        TimedEvent(ts=3, kind="mail.composing", app="Mail", payload={}),
        TimedEvent(ts=4, kind="app.activated", app="Zoom", payload={}),
        TimedEvent(ts=5, kind="mail.opened", app="Zoom", payload={}),
        TimedEvent(ts=6, kind="text.selected", app="Safari", payload={"typing": True}),
    ]
    states = estimate_user_states(events)
    assert states == ["reading", "reading", "idle", "typing", "meeting", "meeting", "typing"]


def test_build_examples_explicit_approve_uses_the_surfaced_action():
    rows = [_row("d1", 100.0, "mail.opened", "suggest", response="approve")]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].label == ACTIONS.index("suggest")
    assert examples[0].source == "explicit"
    assert examples[0].weight == 1.0


def test_build_examples_explicit_dismiss_maps_to_ignore():
    rows = [_row("d1", 100.0, "mail.opened", "suggest", response="dismiss")]
    examples = build_examples(rows)
    assert examples[0].label == ACTIONS.index("ignore")


def test_build_examples_prefers_explicit_over_implicit_on_the_same_row():
    rows = [
        _row(
            "d1",
            100.0,
            "mail.opened",
            "wait",
            payload={"sender": "a@b.com", "subject": "hi"},
            response="approve",
        ),
        _row(
            "d2",
            200.0,
            "mail.composing",
            "ignore",
            payload={"to": "a@b.com", "subject": "Re: hi"},
        ),
    ]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].source == "explicit"
    assert examples[0].label == ACTIONS.index("wait")


def test_build_examples_uses_implicit_label_when_no_response():
    rows = [
        _row("d1", 100.0, "mail.opened", "wait", payload={"sender": "a@b.com", "subject": "hi"}),
        _row("d2", 400.0, "mail.composing", "ignore", payload={"to": "a@b.com", "subject": "Re: hi"}),
    ]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].label == ACTIONS.index("suggest")
    assert examples[0].source == "implicit:replied_within_hour"


def test_build_examples_skips_rows_with_no_response_and_no_firing_rule():
    rows = [_row("d1", 100.0, "app.activated", "ignore")]
    assert build_examples(rows) == []


def test_build_examples_labels_archived_unread_from_mail_arrived():
    rows = [
        _row("d1", 100.0, "mail.arrived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
        _row("d2", 500.0, "mail.archived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
    ]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].label == ACTIONS.index("ignore")
    assert examples[0].source == "implicit:archived_unread"
    assert examples[0].weight == pytest.approx(0.92)


def test_build_examples_does_not_label_archived_after_it_was_opened():
    rows = [
        _row("d1", 100.0, "mail.arrived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
        _row("d2", 200.0, "mail.opened", "wait", payload={"sender": "a@b.com", "subject": "promo"}),
        _row("d3", 500.0, "mail.archived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
    ]
    examples = build_examples(rows)
    arrived_examples = [e for e in examples if e.ts == 100.0]
    assert arrived_examples == []


def test_build_examples_labels_never_opened_once_the_window_elapses():
    from labels import NEVER_OPENED_WINDOW_SECONDS

    rows = [
        _row("d1", 0.0, "mail.arrived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
        _row("d2", NEVER_OPENED_WINDOW_SECONDS + 10, "idle.entered", "ignore"),
    ]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].label == ACTIONS.index("ignore")
    assert examples[0].source == "implicit:never_opened"


def test_build_examples_never_opened_abstains_before_the_window_elapses():
    from labels import NEVER_OPENED_WINDOW_SECONDS

    rows = [
        _row("d1", 0.0, "mail.arrived", "ignore", payload={"sender": "a@b.com", "subject": "promo"}),
        _row("d2", NEVER_OPENED_WINDOW_SECONDS - 10, "idle.entered", "ignore"),
    ]
    assert build_examples(rows) == []


def test_build_examples_labels_read_and_abandoned_from_real_dwell_data():
    rows = [
        _row("d1", 100.0, "mail.opened", "wait", payload={"sender": "a@b.com", "subject": "hi"}),
        _row(
            "d2", 160.0, "mail.closed", "ignore",
            payload={"sender": "a@b.com", "subject": "hi", "dwell_ms": 45_000, "still_unread": True},
        ),
    ]
    examples = build_examples(rows)
    assert len(examples) == 1
    assert examples[0].label == ACTIONS.index("wait")
    assert examples[0].source == "implicit:read_and_abandoned"
    assert examples[0].weight == pytest.approx(0.75)


def test_build_examples_read_and_abandoned_abstains_without_dwell_ms():
    rows = [
        _row("d1", 100.0, "mail.opened", "wait", payload={"sender": "a@b.com", "subject": "hi"}),
        _row("d2", 160.0, "mail.closed", "ignore", payload={"sender": "a@b.com", "subject": "hi", "still_unread": True}),
    ]
    assert build_examples(rows) == []


def test_build_distill_examples_uses_probabilities_when_present():
    readouts = [
        {"q": "interrupt", "value": "wait", "p": 0.5, "probabilities": {"ignore": 0.1, "wait": 0.5, "prepare": 0.2, "suggest": 0.2}}
    ]
    rows = [_row("d1", 100.0, "mail.opened", "wait", readouts=readouts)]
    examples = build_distill_examples(rows)
    assert len(examples) == 1
    assert examples[0].teacher_probs == (0.1, 0.5, 0.2, 0.2)


def test_build_distill_examples_falls_back_to_peaked_distribution():
    readouts = [{"q": "interrupt", "value": "suggest", "p": 0.7}]
    rows = [_row("d1", 100.0, "mail.opened", "suggest", readouts=readouts)]
    examples = build_distill_examples(rows)
    assert len(examples) == 1
    probs = examples[0].teacher_probs
    assert probs[ACTIONS.index("suggest")] == pytest.approx(0.7)
    remainder = pytest.approx(0.1)
    for action in ("ignore", "wait", "prepare"):
        assert probs[ACTIONS.index(action)] == remainder


def test_build_distill_examples_skips_rows_without_an_interrupt_readout():
    rows = [_row("d1", 100.0, "idle.entered", "ignore", readouts=[])]
    assert build_distill_examples(rows) == []


def test_implicit_explicit_agreement_counts_agreement_and_disagreement():
    rows = [
        _row(
            "d1", 100.0, "mail.opened", "suggest",
            payload={"sender": "a@b.com", "subject": "hi"}, response="approve",
        ),
        _row("d2", 200.0, "mail.composing", "ignore", payload={"to": "a@b.com", "subject": "Re: hi"}),
        _row(
            "d3", 1000.0, "mail.opened", "suggest",
            payload={"sender": "c@d.com", "subject": "bye"}, response="dismiss",
        ),
        _row("d4", 1100.0, "mail.composing", "ignore", payload={"to": "c@d.com", "subject": "Re: bye"}),
    ]
    tally = implicit_explicit_agreement(rows)
    assert tally["replied_within_hour"] == {"agree": 1, "disagree": 1}


def test_time_split_preserves_chronology_regardless_of_input_order():
    class _Item:
        def __init__(self, ts):
            self.ts = ts

    items = [_Item(ts) for ts in [50, 10, 40, 20, 30, 5, 15, 25, 35, 45]]
    train, val, test = time_split(items, train_frac=0.6, val_frac=0.2)
    assert len(train) + len(val) + len(test) == len(items)
    assert max(i.ts for i in train) <= min(i.ts for i in val)
    assert max(i.ts for i in val) <= min(i.ts for i in test)


def test_time_split_rejects_invalid_fractions():
    with pytest.raises(ValueError):
        time_split([], train_frac=0.9, val_frac=0.2)
