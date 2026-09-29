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
CREATE TABLE IF NOT EXISTS labels (
    decision_id TEXT PRIMARY KEY,
    label       REAL NOT NULL,
    weight      REAL NOT NULL,
    source      TEXT NOT NULL,
    ts          REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
    task_id   TEXT PRIMARY KEY,
    ts        REAL NOT NULL,
    goal      TEXT NOT NULL,
    app       TEXT,
    plan      TEXT NOT NULL,
    status    TEXT NOT NULL DEFAULT 'running',
    ended_ts  REAL,
    detail    TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_ts ON tasks(ts);
CREATE TABLE IF NOT EXISTS task_steps (
    task_id     TEXT NOT NULL,
    step        INTEGER NOT NULL,
    ts          REAL NOT NULL,
    app         TEXT,
    window      TEXT,
    operation   TEXT NOT NULL,
    target      TEXT,
    target_role TEXT,
    confidence  REAL,
    permission  TEXT,
    outcome     TEXT NOT NULL,
    latency_ms  REAL,
    PRIMARY KEY (task_id, step)
);
"""

# Columns added after v0.1. `open_db` adds any that an older database lacks,
# so an existing audit trail upgrades in place instead of being discarded.
_MIGRATIONS = (
    ("response_reason", "TEXT"),
    ("sender", "TEXT"),
    ("explanation", "TEXT"),
    ("tier", "TEXT"),
    ("specialist_p", "REAL"),
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
            hypotheses, readouts, suggestion, why, sender, explanation, tier, specialist_p
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            decision.get("tier"),
            decision.get("specialist_p"),
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
    """Forget decisions and tasks older than `retention_days`. Decisions
    carry message bodies and tasks carry what the user asked for, so both are
    subject to retention exactly like screen memory."""
    now = now if now is not None else time.time()
    cutoff = now - retention_days * 86400
    cursor = conn.execute("DELETE FROM decisions WHERE ts < ?", (cutoff,))
    conn.execute("DELETE FROM labels WHERE decision_id NOT IN (SELECT decision_id FROM decisions)")
    conn.execute("DELETE FROM task_steps WHERE task_id IN (SELECT task_id FROM tasks WHERE ts < ?)", (cutoff,))
    conn.execute("DELETE FROM tasks WHERE ts < ?", (cutoff,))
    conn.commit()
    return cursor.rowcount


# ---------------------------------------------------------------- tasks

TASK_STATUSES = ("running", "done", "stopped", "blocked", "failed")
STEP_OUTCOMES = ("ok", "failed", "denied", "undone", "user")


def record_task(conn: sqlite3.Connection, task_id: str, goal: str, plan: list[str], *, app: str = "",
                ts: float | None = None) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO tasks (task_id, ts, goal, app, plan, status) VALUES (?, ?, ?, ?, ?, 'running')",
        (task_id, ts if ts is not None else time.time(), goal, app, json.dumps(plan)),
    )
    conn.commit()


def record_task_step(conn: sqlite3.Connection, task_id: str, step: dict) -> None:
    outcome = step.get("outcome")
    if outcome not in STEP_OUTCOMES:
        raise ValueError(f"outcome must be one of {STEP_OUTCOMES}, got {outcome!r}")
    conn.execute(
        """
        INSERT OR REPLACE INTO task_steps (
            task_id, step, ts, app, window, operation, target, target_role, confidence, permission, outcome, latency_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            task_id,
            int(step.get("step", 0)),
            float(step.get("ts") or time.time()),
            step.get("app"),
            step.get("window"),
            str(step.get("operation") or ""),
            step.get("target"),
            step.get("target_role"),
            step.get("confidence"),
            step.get("permission"),
            outcome,
            step.get("latency_ms"),
        ),
    )
    conn.commit()


def end_task(conn: sqlite3.Connection, task_id: str, status: str, *, detail: str = "", ts: float | None = None) -> bool:
    if status not in TASK_STATUSES or status == "running":
        raise ValueError(f"status must be one of {TASK_STATUSES[1:]}, got {status!r}")
    cursor = conn.execute(
        "UPDATE tasks SET status = ?, ended_ts = ?, detail = ? WHERE task_id = ?",
        (status, ts if ts is not None else time.time(), detail, task_id),
    )
    conn.commit()
    return cursor.rowcount > 0


def recent_tasks(conn: sqlite3.Connection, *, limit: int = 30) -> list[dict]:
    tasks = conn.execute(
        "SELECT task_id, ts, goal, app, plan, status, ended_ts, detail FROM tasks ORDER BY ts DESC LIMIT ?",
        (limit,),
    ).fetchall()
    out = []
    for task_id, ts, goal, app, plan, status, ended_ts, detail in tasks:
        steps = conn.execute(
            "SELECT step, ts, app, window, operation, target, confidence, permission, outcome, latency_ms "
            "FROM task_steps WHERE task_id = ? ORDER BY step",
            (task_id,),
        ).fetchall()
        out.append(
            {
                "id": task_id,
                "ts": ts,
                "goal": goal,
                "app": app,
                "plan": json.loads(plan or "[]"),
                "status": status,
                "ended_ts": ended_ts,
                "detail": detail or "",
                "steps": [
                    {
                        "step": s[0], "ts": s[1], "app": s[2], "window": s[3], "operation": s[4], "target": s[5],
                        "confidence": s[6], "permission": s[7], "outcome": s[8], "latency_ms": s[9],
                    }
                    for s in steps
                ],
            }
        )
    return out


def task_summary(conn: sqlite3.Connection, *, since: float = 0.0) -> dict:
    row = conn.execute(
        """
        SELECT COUNT(*), SUM(status = 'done'), SUM(status = 'stopped'), SUM(status IN ('blocked', 'failed'))
        FROM tasks WHERE ts >= ?
        """,
        (since,),
    ).fetchone()
    steps = conn.execute(
        """
        SELECT COUNT(*), SUM(outcome = 'ok'), SUM(permission = 'asked'), SUM(outcome = 'undone'),
               AVG(latency_ms)
        FROM task_steps WHERE ts >= ?
        """,
        (since,),
    ).fetchone()
    return {
        "tasks": int(row[0] or 0),
        "done": int(row[1] or 0),
        "stopped": int(row[2] or 0),
        "blocked": int(row[3] or 0),
        "steps": int(steps[0] or 0),
        "steps_ok": int(steps[1] or 0),
        "asked": int(steps[2] or 0),
        "undone": int(steps[3] or 0),
        "mean_step_ms": round(float(steps[4]), 1) if steps[4] is not None else None,
    }


def delete_all(conn: sqlite3.Connection) -> int:
    count = conn.execute("SELECT COUNT(*) FROM decisions").fetchone()[0]
    conn.execute("DELETE FROM decisions")
    conn.execute("DELETE FROM labels")
    conn.execute("DELETE FROM task_steps")
    conn.execute("DELETE FROM tasks")
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
    "STEP_OUTCOMES",
    "TASK_STATUSES",
    "end_task",
    "record_task",
    "record_task_step",
    "recent_tasks",
    "task_summary",
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
