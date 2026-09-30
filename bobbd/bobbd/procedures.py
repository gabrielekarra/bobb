"""How things are done on this Mac, learned by watching (VISION rule 3).

A procedure is a request and the steps that carried it out: which app,
what was pressed, what was typed into which field. Bobb keeps one every
time a task it ran ends done, and every time the user shows it how
("Show me") after it got stuck. The next request like it gets that
procedure as a guide in every step's context, and when the match is close
the procedure becomes the plan itself — no generation needed.

Nothing here is a macro that replays blindly: each step is still decided on
the live screen, under the same permission engine. A procedure is a strong
hint, not a script.
"""

from __future__ import annotations

import json
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass

GUIDE_MATCH = 0.5
PLAN_MATCH = 0.75
MAX_STEPS = 25

_SCHEMA = """
CREATE TABLE IF NOT EXISTS procedures (
    procedure_id TEXT PRIMARY KEY,
    ts           REAL NOT NULL,
    goal         TEXT NOT NULL,
    steps        TEXT NOT NULL,
    source       TEXT NOT NULL,
    uses         INTEGER NOT NULL DEFAULT 0,
    last_used    REAL
);
"""

_WORD = re.compile(r"[a-zà-ÿ0-9]{2,}", re.IGNORECASE)
_STOP = frozenset(
    "the a an and or of to in on for with my me please it is this that from il lo la i gli le un una e o di da del "
    "della dei delle al alla ai alle nel nella per con su sul sulla mi mia mio che si ti puoi".split()
)
_VERBS = {
    "CLICK": ("Press", "Premi"), "OPEN": ("Open", "Apri"), "TYPE": ("Type into", "Scrivi in"),
    "KEY": ("Press the key", "Premi il tasto"), "SCROLL_DOWN": ("Scroll down", "Scorri giù"),
    "SCROLL_UP": ("Scroll up", "Scorri su"), "OPEN_APP": ("Open", "Apri"),
}


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(_SCHEMA)
    conn.commit()


def words(text: str) -> set[str]:
    return {w.lower() for w in _WORD.findall(text or "") if w.lower() not in _STOP}


def similarity(a: str, b: str) -> float:
    """Word overlap between two requests, 0..1, generous to the shorter one:
    "metti Focus su Spotify" and "metti la playlist Focus su Spotify" match."""
    wa, wb = words(a), words(b)
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / min(len(wa), len(wb)) * (0.5 + 0.5 * len(wa & wb) / len(wa | wb))


@dataclass(frozen=True)
class Procedure:
    id: str
    ts: float
    goal: str
    steps: list[dict]
    source: str
    uses: int = 0

    def lines(self, locale: str = "en") -> list[str]:
        out = []
        for step in self.steps:
            verb = _VERBS.get(step.get("operation", ""), (step.get("operation", ""),) * 2)[1 if locale == "it" else 0]
            target = step.get("target") or ""
            line = f"{verb} “{target}”" if target else verb
            if step.get("app") and step.get("operation") != "OPEN_APP":
                line += f" ({step['app']})"
            if step.get("text"):
                line += f": “{str(step['text'])[:60]}”"
            out.append(line)
        return out

    def to_frame(self) -> dict:
        return {"id": self.id, "ts": self.ts, "goal": self.goal, "steps": self.steps, "source": self.source, "uses": self.uses}


def _clean_steps(steps: list[dict]) -> list[dict]:
    out = []
    for step in steps[:MAX_STEPS]:
        operation = str(step.get("operation") or "")
        if operation not in _VERBS:
            continue
        clean = {"operation": operation, "target": str(step.get("target") or "")[:120], "app": str(step.get("app") or "")[:60]}
        if operation == "TYPE" and step.get("text"):
            clean["text"] = str(step["text"])[:200]
        if out and out[-1] == clean:
            continue
        out.append(clean)
    return out


def record(conn: sqlite3.Connection, goal: str, steps: list[dict], *, source: str, now: float | None = None) -> Procedure | None:
    """Keeps a procedure; replaces an older one for the same request so the
    latest way of doing it wins."""
    steps = _clean_steps(steps)
    if not goal.strip() or not steps:
        return None
    now = now if now is not None else time.time()
    for existing in all_procedures(conn):
        if similarity(existing.goal, goal) >= 0.9:
            conn.execute("DELETE FROM procedures WHERE procedure_id = ?", (existing.id,))
    procedure = Procedure(id=f"proc_{uuid.uuid4().hex[:16]}", ts=now, goal=goal.strip(), steps=steps, source=source)
    conn.execute(
        "INSERT INTO procedures (procedure_id, ts, goal, steps, source) VALUES (?, ?, ?, ?, ?)",
        (procedure.id, procedure.ts, procedure.goal, json.dumps(procedure.steps), procedure.source),
    )
    conn.commit()
    return procedure


def from_task(conn: sqlite3.Connection, task_id: str) -> list[dict]:
    """The steps of a finished task that actually happened, in order."""
    rows = conn.execute(
        "SELECT operation, target, app FROM task_steps WHERE task_id = ? AND outcome IN ('ok', 'user') ORDER BY step",
        (task_id,),
    ).fetchall()
    return [{"operation": op, "target": target or "", "app": app or ""} for op, target, app in rows]


def all_procedures(conn: sqlite3.Connection) -> list[Procedure]:
    rows = conn.execute("SELECT procedure_id, ts, goal, steps, source, uses FROM procedures ORDER BY ts DESC").fetchall()
    return [Procedure(pid, ts, goal, json.loads(steps), source, uses) for pid, ts, goal, steps, source, uses in rows]


def best_match(conn: sqlite3.Connection, goal: str) -> tuple[Procedure, float] | None:
    best: tuple[Procedure, float] | None = None
    for procedure in all_procedures(conn):
        score = similarity(procedure.goal, goal)
        if score >= GUIDE_MATCH and (best is None or score > best[1]):
            best = (procedure, score)
    return best


def used(conn: sqlite3.Connection, procedure_id: str, *, now: float | None = None) -> None:
    conn.execute(
        "UPDATE procedures SET uses = uses + 1, last_used = ? WHERE procedure_id = ?",
        (now if now is not None else time.time(), procedure_id),
    )
    conn.commit()


def delete(conn: sqlite3.Connection, procedure_id: str | None = None) -> int:
    if procedure_id is None:
        cursor = conn.execute("DELETE FROM procedures")
    else:
        cursor = conn.execute("DELETE FROM procedures WHERE procedure_id = ?", (procedure_id,))
    conn.commit()
    return cursor.rowcount


__all__ = ["Procedure", "all_procedures", "best_match", "delete", "ensure_schema", "from_task", "record", "similarity", "used"]
