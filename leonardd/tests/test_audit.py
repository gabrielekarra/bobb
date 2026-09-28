import json
import time

from leonardd.audit import fetch_decision, open_db, record_decision, record_response


def _decision(decision_id="dec_1", event_id="evt_1", action="wait", confidence=0.5, schema_mass=0.9):
    return {
        "t": "decision",
        "ts": time.time(),
        "id": decision_id,
        "event_id": event_id,
        "action": action,
        "confidence": confidence,
        "schema_mass": schema_mass,
        "latency_ms": 12.3,
        "hypotheses": [],
        "readouts": [],
        "why": "test",
    }


def _event(event_id="evt_1", kind="mail.opened"):
    return {
        "t": "event",
        "ts": time.time(),
        "id": event_id,
        "kind": kind,
        "app": "Mail",
        "payload": {"sender": "a@b.com", "subject": "s", "body": "corpo del messaggio", "thread_len": 1, "unread": True},
    }


def test_decision_is_durably_written_before_it_would_be_sent(tmp_path):
    db_path = tmp_path / "audit.db"
    conn = open_db(db_path)
    decision = _decision()
    event = _event()

    record_decision(conn, decision, event, floor=0.6, model="test-model")

    def send(d: dict) -> None:
        # A fresh connection onto the same file stands in for "the socket
        # write already happened": if the row is not visible here, the
        # invariant (write before send) was violated.
        reader = open_db(db_path)
        row = fetch_decision(reader, d["id"])
        assert row is not None, "decision must be durably committed before it is sent"
        assert row["action"] == d["action"]
        reader.close()

    send(decision)


def test_audit_preserves_readouts_hypotheses_and_suggestion(tmp_path):
    conn = open_db(tmp_path / "audit.db")
    decision = _decision(action="suggest", confidence=0.9)
    decision["hypotheses"] = [{"intent": "reply_to_email", "p": 0.9}]
    decision["readouts"] = [{"q": "reply_needed", "value": True, "p": 0.9, "schema_mass": 0.99}]
    decision["suggestion"] = {"title": "t", "action_id": "draft_reply", "detail": "d"}

    record_decision(conn, decision, _event(), floor=0.6, model="test-model")
    row = fetch_decision(conn, decision["id"])

    assert json.loads(row["hypotheses"]) == decision["hypotheses"]
    assert json.loads(row["readouts"]) == decision["readouts"]
    assert json.loads(row["suggestion"]) == decision["suggestion"]
    assert json.loads(row["event_payload"])["subject"] == "s"
    assert row["abstained"] == 0


def test_abstained_decision_is_flagged(tmp_path):
    conn = open_db(tmp_path / "audit.db")
    decision = _decision(action="wait")
    decision["abstained"] = True
    record_decision(conn, decision, _event(), floor=0.6, model="test-model")
    row = fetch_decision(conn, decision["id"])
    assert row["abstained"] == 1


def test_response_updates_the_existing_row(tmp_path):
    conn = open_db(tmp_path / "audit.db")
    decision = _decision()
    record_decision(conn, decision, _event(), floor=0.6, model="test-model")

    found = record_response(conn, decision["id"], "approve")

    assert found is True
    row = fetch_decision(conn, decision["id"])
    assert row["response"] == "approve"
    assert row["response_ts"] is not None


def test_response_to_unknown_decision_id_reports_not_found(tmp_path):
    conn = open_db(tmp_path / "audit.db")
    assert record_response(conn, "dec_missing", "approve") is False


def test_wal_mode_is_enabled(tmp_path):
    conn = open_db(tmp_path / "audit.db")
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode.lower() == "wal"
