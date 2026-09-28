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
CREATE INDEX IF NOT EXISTS idx_decisions_ts ON decisions(ts);
CREATE TABLE IF NOT EXISTS learned_overrides (
    subject  TEXT PRIMARY KEY,
    verdict  TEXT NOT NULL,
    ts       REAL NOT NULL
);
"""

# Columns added after v0.1. `open_db` adds any that an older database lacks,
# so an existing audit trail upgrades in place instead of being discarded.
_MIGRATIONS = (
    ("response_reason", "TEXT"),
    ("sender", "TEXT"),
    ("explanation", "TEXT"),
)

RESPONSES = ("approve", "dismiss")
RESPONSE_REASONS = ("user", "timeout")


def sender_key(payload: dict | None) -> str | None:
    """The lowercased address inside `Name <address>`, or the bare value.

    Learning keys on the address, never the display name: two people can
    share a name, and one person's name renders differently across clients.
    """
    if not isinstance(payload, dict):
        return None
    raw = payload.get("sender")
    if not isinstance(raw, str) or not raw.strip():
        return None
    start, end = raw.rfind("<"), raw.rfind(">")
    address = raw[start + 1 : end] if 0 <= start < end else raw
    address = address.strip().lower()
    return address or None


def open_db(path: Path | str = DEFAULT_PATH) -> sqlite3.Connection:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(_SCHEMA)
    existing = {row[1] for row in conn.execute("PRAGMA table_info(decisions)")}
    for column, kind in _MIGRATIONS:
        if column not in existing:
            conn.execute(f"ALTER TABLE decisions ADD COLUMN {column} {kind}")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_decisions_sender ON decisions(sender)")
    conn.commit()
    if str(path) != ":memory:":
        try:
            path.chmod(0o600)
        except OSError:
            pass
    return conn


def record_decision(conn: sqlite3.Connection, decision: dict, event: dict, *, floor: float, model: str) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO decisions (
            decision_id, event_id, ts, kind, app, event_payload, model, floor,
            action, confidence, schema_mass, latency_ms, abstained,
            hypotheses, readouts, suggestion, why, sender, explanation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            sender_key(event.get("payload")),
            decision.get("explanation"),
        ),
    )
    conn.commit()


def record_response(
    conn: sqlite3.Connection,
    decision_id: str,
    response: str,
    ts: float | None = None,
    reason: str | None = None,
) -> bool:
    """Record the user's verdict. `reason` separates a click on Ignore
    (`user`) from an overlay that simply timed out (`timeout`): the first is
    a label, the second is at most a weak hint, and conflating them was the
    largest source of noise in the v0.1 training set."""
    if response not in RESPONSES:
        raise ValueError(f"response must be 'approve' or 'dismiss', got {response!r}")
    if reason is not None and reason not in RESPONSE_REASONS:
        raise ValueError(f"reason must be one of {RESPONSE_REASONS}, got {reason!r}")
    if response == "approve":
        reason = "user"
    cursor = conn.execute(
        "UPDATE decisions SET response = ?, response_ts = ?, response_reason = ? WHERE decision_id = ?",
        (response, ts if ts is not None else time.time(), reason or "user", decision_id),
    )
    conn.commit()
    return cursor.rowcount > 0


def sweep(conn: sqlite3.Connection, retention_days: int, *, now: float | None = None) -> int:
    """Forget decisions older than `retention_days`. They carry message
    bodies, so they are subject to retention exactly like screen memory."""
    now = now if now is not None else time.time()
    cursor = conn.execute("DELETE FROM decisions WHERE ts < ?", (now - retention_days * 86400,))
    conn.commit()
    return cursor.rowcount


def delete_all(conn: sqlite3.Connection) -> int:
    count = conn.execute("SELECT COUNT(*) FROM decisions").fetchone()[0]
    conn.execute("DELETE FROM decisions")
    conn.execute("DELETE FROM learned_overrides")
    conn.commit()
    conn.execute("VACUUM")
    return count


def summary(conn: sqlite3.Connection, *, since: float | None = None) -> dict:
    """Counts for the Mind header and the stats frame: how much Leonard saw,
    how often it spoke, and how its suggestions were received."""
    since = since if since is not None else 0.0
    row = conn.execute(
        """
        SELECT COUNT(*),
               SUM(action = 'suggest'),
               SUM(action = 'prepare'),
               SUM(abstained),
               SUM(response = 'approve'),
               SUM(response = 'dismiss' AND COALESCE(response_reason, 'user') = 'user'),
               SUM(response = 'dismiss' AND response_reason = 'timeout'),
               AVG(CASE WHEN readouts != '[]' THEN latency_ms END)
        FROM decisions WHERE ts >= ?
        """,
        (since,),
    ).fetchone()
    total, suggested, prepared, abstained, approved, dismissed, expired, mean_latency = row
    total = int(total or 0)
    spoke = int(suggested or 0)
    return {
        "since": since,
        "decisions": total,
        "suggested": spoke,
        "prepared": int(prepared or 0),
        "abstained": int(abstained or 0),
        "approved": int(approved or 0),
        "dismissed": int(dismissed or 0),
        "expired": int(expired or 0),
        "silent": total - spoke,
        "mean_decision_ms": round(float(mean_latency), 1) if mean_latency is not None else None,
    }


def recent(conn: sqlite3.Connection, *, limit: int = 50) -> list[dict]:
    rows = conn.execute("SELECT * FROM decisions ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
    columns = [d[0] for d in conn.execute("SELECT * FROM decisions LIMIT 0").description]
    return [dict(zip(columns, row)) for row in rows]


def fetch_decision(conn: sqlite3.Connection, decision_id: str) -> dict | None:
    row = conn.execute("SELECT * FROM decisions WHERE decision_id = ?", (decision_id,)).fetchone()
    if row is None:
        return None
    columns = [d[0] for d in conn.execute("SELECT * FROM decisions LIMIT 0").description]
    return dict(zip(columns, row))


__all__ = [
    "DEFAULT_PATH",
    "RESPONSES",
    "RESPONSE_REASONS",
    "open_db",
    "record_decision",
    "record_response",
    "fetch_decision",
    "sender_key",
    "sweep",
    "delete_all",
    "summary",
    "recent",
]
