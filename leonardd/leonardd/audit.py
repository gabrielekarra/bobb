"""Durable decision log: the explainability surface and, later, the
personalization training set.

One row per decision, written before it is sent (the contract's invariant
2), carrying the full readouts, hypotheses, confidences, schema masses and
latency it was made with, plus the eventual `approve`/`dismiss` response
when one arrives. Denormalized on purpose: every feature a future
personalization model would want (kind, payload, readouts, hypotheses) and
its label (the response) live in the same row, so training data is a query,
not a join.

An email's body reaches this database because the contract requires it
(invariant 5: it appears in `event.payload` and here, nowhere else); nothing
in this module writes it, or any other event field, anywhere else.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

DEFAULT_PATH = Path.home() / "Library" / "Application Support" / "Leonard" / "audit.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS decisions (
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
CREATE INDEX IF NOT EXISTS idx_decisions_kind ON decisions(kind);
CREATE INDEX IF NOT EXISTS idx_decisions_response ON decisions(response);
CREATE INDEX IF NOT EXISTS idx_decisions_event_id ON decisions(event_id);
"""


def open_db(path: Path | str = DEFAULT_PATH) -> sqlite3.Connection:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn


def record_decision(conn: sqlite3.Connection, decision: dict, event: dict, *, floor: float, model: str) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO decisions (
            decision_id, event_id, ts, kind, app, event_payload, model, floor,
            action, confidence, schema_mass, latency_ms, abstained,
            hypotheses, readouts, suggestion, why
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            decision["id"],
            decision.get("event_id", ""),
            decision.get("ts", time.time()),
            event.get("kind", ""),
            event.get("app"),
            json.dumps(event.get("payload") or {}),
            model,
            floor,
            decision["action"],
            decision["confidence"],
            decision["schema_mass"],
            decision["latency_ms"],
            int(bool(decision.get("abstained", False))),
            json.dumps(decision.get("hypotheses", [])),
            json.dumps(decision.get("readouts", [])),
            json.dumps(decision["suggestion"]) if decision.get("suggestion") is not None else None,
            decision.get("why"),
        ),
    )
    conn.commit()


def record_response(conn: sqlite3.Connection, decision_id: str, response: str, ts: float | None = None) -> bool:
    if response not in ("approve", "dismiss"):
        raise ValueError(f"response must be 'approve' or 'dismiss', got {response!r}")
    cursor = conn.execute(
        "UPDATE decisions SET response = ?, response_ts = ? WHERE decision_id = ?",
        (response, ts if ts is not None else time.time(), decision_id),
    )
    conn.commit()
    return cursor.rowcount > 0


def fetch_decision(conn: sqlite3.Connection, decision_id: str) -> dict | None:
    row = conn.execute("SELECT * FROM decisions WHERE decision_id = ?", (decision_id,)).fetchone()
    if row is None:
        return None
    columns = [d[0] for d in conn.execute("SELECT * FROM decisions LIMIT 0").description]
    return dict(zip(columns, row))


__all__ = ["DEFAULT_PATH", "open_db", "record_decision", "record_response", "fetch_decision"]
