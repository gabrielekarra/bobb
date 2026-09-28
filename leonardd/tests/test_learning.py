import itertools

import pytest

from leonardd.audit import open_db, record_decision, record_response, sender_key
from leonardd.learning import MIN_EVIDENCE, KindStats, Personalizer, floor_offset

_ids = itertools.count()
NOW = 1_800_000_000.0


def _surface(conn, *, kind="mail.opened", sender="Marco Rossi <marco@example.com>", ts=NOW - 3600, response=None, reason=None):
    n = next(_ids)
    decision = {
        "id": f"dec_{n}",
        "event_id": f"evt_{n}",
        "ts": ts,
        "action": "suggest",
        "confidence": 0.8,
        "schema_mass": 0.99,
        "latency_ms": 1.0,
        "hypotheses": [],
        "readouts": [],
        "suggestion": {"title": "t", "action_id": "draft_reply", "detail": ""},
    }
    event = {"kind": kind, "app": "Mail", "payload": {"sender": sender, "subject": "s", "body": "b"}}
    record_decision(conn, decision, event, floor=0.6, model="m")
    if response:
        record_response(conn, decision["id"], response, ts + 5, reason=reason)
    return decision["id"]


@pytest.fixture
def conn(tmp_path):
    c = open_db(tmp_path / "audit.db")
    yield c
    c.close()


def test_sender_key_uses_the_address_not_the_display_name():
    assert sender_key({"sender": "Marco Rossi <Marco@Example.com>"}) == "marco@example.com"
    assert sender_key({"sender": "ops@atlas.io"}) == "ops@atlas.io"
    assert sender_key({}) is None


def test_no_evidence_means_no_change():
    assert floor_offset(KindStats("mail.opened", 1, 1, 0)) == 0.0


def test_mostly_dismissed_raises_the_floor_mostly_approved_lowers_it():
    assert floor_offset(KindStats("k", 0, 12, 0)) > 0.1
    assert floor_offset(KindStats("k", 12, 0, 0)) < -0.05
    assert floor_offset(KindStats("k", 5, 5, 0)) == 0.0


def test_timeouts_are_weak_evidence():
    only_timeouts = KindStats("k", 0, 0, MIN_EVIDENCE)
    assert only_timeouts.evidence < MIN_EVIDENCE
    assert floor_offset(only_timeouts) == 0.0


def test_personal_floor_is_clamped(conn):
    for _ in range(40):
        _surface(conn, response="dismiss", sender=f"x{next(_ids)}@a.com")
    p = Personalizer(conn, now=NOW)
    assert p.personal_floor("mail.opened", 0.85) == 0.90
    assert p.personal_floor("mail.opened", 0.60) == pytest.approx(0.60 + 0.15, abs=0.02)
    assert p.personal_floor("text.selected", 0.60) == 0.60


def test_three_explicit_dismissals_mute_a_sender(conn):
    for _ in range(3):
        _surface(conn, response="dismiss", reason="user")
    p = Personalizer(conn, now=NOW)
    muted = p.muted_sender({"kind": "mail.opened", "payload": {"sender": "M. Rossi <marco@example.com>"}})
    assert muted is not None and muted.dismissed == 3


def test_an_approval_resets_the_streak(conn):
    _surface(conn, response="dismiss", ts=NOW - 5000)
    _surface(conn, response="dismiss", ts=NOW - 4000)
    _surface(conn, response="approve", ts=NOW - 3000)
    _surface(conn, response="dismiss", ts=NOW - 2000)
    p = Personalizer(conn, now=NOW)
    assert p.muted == []


def test_timeouts_never_mute(conn):
    for _ in range(5):
        _surface(conn, response="dismiss", reason="timeout")
    assert Personalizer(conn, now=NOW).muted == []


def test_forgetting_a_mute_restarts_the_count(conn):
    for i in range(3):
        _surface(conn, response="dismiss", ts=NOW - 5000 + i)
    p = Personalizer(conn, now=NOW)
    rule = p.muted[0].rule_id
    assert p.forget(rule, now=NOW)
    assert p.muted == []
    _surface(conn, response="dismiss", ts=NOW + 10)
    p.refresh(now=NOW + 20)
    assert p.muted == []


def test_manual_mute_and_snapshot(conn):
    p = Personalizer(conn, now=NOW)
    p.mute("News <news@techmeme.com>".split("<")[1].rstrip(">"), now=NOW)
    snap = p.snapshot(0.6)
    assert snap["muted_senders"][0]["sender"] == "news@techmeme.com"
    assert snap["muted_senders"][0]["manual"] is True


def test_evidence_outside_the_lookback_is_ignored(conn):
    for _ in range(3):
        _surface(conn, response="dismiss", ts=NOW - 90 * 86400)
    assert Personalizer(conn, now=NOW).muted == []


def test_old_database_is_migrated_in_place(tmp_path):
    import sqlite3

    path = tmp_path / "old.db"
    old = sqlite3.connect(path)
    old.execute(
        "CREATE TABLE decisions (decision_id TEXT PRIMARY KEY, event_id TEXT NOT NULL, ts REAL NOT NULL,"
        " kind TEXT NOT NULL, app TEXT, event_payload TEXT NOT NULL, model TEXT NOT NULL, floor REAL NOT NULL,"
        " action TEXT NOT NULL, confidence REAL NOT NULL, schema_mass REAL NOT NULL, latency_ms REAL NOT NULL,"
        " abstained INTEGER NOT NULL DEFAULT 0, hypotheses TEXT NOT NULL, readouts TEXT NOT NULL,"
        " suggestion TEXT, why TEXT, response TEXT, response_ts REAL)"
    )
    old.commit()
    old.close()
    conn = open_db(path)
    columns = {row[1] for row in conn.execute("PRAGMA table_info(decisions)")}
    assert {"response_reason", "sender", "explanation"} <= columns
    assert Personalizer(conn).muted == []
