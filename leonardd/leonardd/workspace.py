"""Bobb's durable work ledger. No scheduler thread, tools, or network here.

The Mac app ticks and claims work, then executes it through the same checked
task loop as a foreground request. A crash never silently replays a partially
completed action: its run becomes interrupted and needs an explicit retry.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

KINDS = {"agent", "job", "project"}
SURFACES = {"desktop", "browser", "mcp"}
PROFILES = {"development", "secretary", "general"}
TERMINAL = {"done", "failed", "stopped", "interrupted"}


def text(value, name, limit=4000):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f"invalid {name}")
    return value.strip()


def timestamp(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid {name}")
    return float(value)


def schedule(raw):
    if not isinstance(raw, dict) or raw.get("kind") not in {"once", "daily", "weekly", "event"}:
        raise ValueError("invalid schedule")
    kind = raw["kind"]
    if kind == "event":
        return {"kind": kind, "event": text(raw.get("event"), "event", 100)}
    if kind == "once":
        return {"kind": kind, "at": timestamp(raw.get("at"), "at")}
    zone = text(raw.get("timezone"), "timezone", 100)
    try:
        ZoneInfo(zone)
    except ZoneInfoNotFoundError as exc:
        raise ValueError("unknown timezone") from exc
    out = {"kind": kind, "timezone": zone}
    for key, hi in [("hour", 23), ("minute", 59)]:
        v = raw.get(key)
        if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= hi:
            raise ValueError(f"invalid {key}")
        out[key] = v
    if kind == "weekly":
        v = raw.get("weekday")
        if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 6:
            raise ValueError("invalid weekday (Monday = 0)")
        out["weekday"] = v
    return out


def next_due(s, after):
    """First occurrence strictly after `after`; local calendar days across DST.

    Ambiguous times use the first occurrence. Nonexistent spring times shift
    forward by the gap. A missed occurrence is coalesced, never replayed N times.
    """
    if s["kind"] == "event":
        return None
    if s["kind"] == "once":
        return s["at"] if s["at"] > after else None
    zone = ZoneInfo(s["timezone"])
    day = datetime.fromtimestamp(after, zone).date()
    for offset in range(9):
        candidate = datetime.combine(day + timedelta(days=offset), datetime.min.time(), zone)
        if s["kind"] == "weekly" and candidate.weekday() != s["weekday"]:
            continue
        candidate = candidate.replace(hour=s["hour"], minute=s["minute"])
        if candidate.timestamp() > after:
            return candidate.timestamp()
    raise ValueError("schedule has no next occurrence")


class Workspace:
    def __init__(self, conn: sqlite3.Connection, *, recover=False):
        self.conn = conn
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS bobb_entities (
                kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL,
                updated REAL NOT NULL, PRIMARY KEY(kind, id));
            CREATE TABLE IF NOT EXISTS bobb_runs (
                id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, source_id TEXT,
                project_id TEXT, step INTEGER, goal TEXT NOT NULL,
                surface TEXT NOT NULL, url TEXT NOT NULL, status TEXT NOT NULL,
                created REAL NOT NULL, updated REAL NOT NULL,
                owner TEXT, lease REAL, report TEXT NOT NULL DEFAULT '',
                occurrence TEXT UNIQUE, task_id TEXT);
            CREATE INDEX IF NOT EXISTS bobb_runs_status ON bobb_runs(status, created);
            CREATE TABLE IF NOT EXISTS bobb_events (
                id TEXT PRIMARY KEY, ts REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS bobb_routine_samples (
                task_id TEXT PRIMARY KEY, goal TEXT NOT NULL, ts REAL NOT NULL,
                timezone TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS bobb_routines (
                id TEXT PRIMARY KEY, goal TEXT NOT NULL, weekday INTEGER NOT NULL,
                hour INTEGER NOT NULL, minute INTEGER NOT NULL, timezone TEXT NOT NULL,
                samples INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'suggested');
        """)
        if recover:
            conn.execute("UPDATE bobb_runs SET status='interrupted',owner=NULL,lease=NULL,report=? WHERE status IN ('running','waiting')",
                         ("Bobb restarted. Review the last steps before retrying.",))
            conn.commit()
        if not self.entities("agent"):
            self.put("agent", {"id": "bobb", "name": "Bobb", "character": "Practical, thoughtful, concise.", "profile": "general"})

    def entities(self, kind):
        return [json.loads(r[0]) for r in self.conn.execute(
            "SELECT data FROM bobb_entities WHERE kind=? ORDER BY updated,id", (kind,))]

    def get(self, kind, identifier):
        row = self.conn.execute("SELECT data FROM bobb_entities WHERE kind=? AND id=?", (kind, identifier)).fetchone()
        if row is None:
            raise ValueError(f"unknown {kind}")
        return json.loads(row[0])

    def put(self, kind, raw, *, now=None):
        if kind not in KINDS or not isinstance(raw, dict):
            raise ValueError("invalid entity")
        now = time.time() if now is None else now
        identifier = text(raw.get("id") or uuid.uuid4().hex, "id", 100)
        data = {"id": identifier, "name": text(raw.get("name"), "name", 100)}
        if kind == "agent":
            profile = raw.get("profile", "general")
            if profile not in PROFILES:
                raise ValueError("invalid profile")
            data.update(character=text(raw.get("character") or "Practical and concise.", "character", 1000), profile=profile)
        else:
            agent_id = text(raw.get("agent_id"), "agent_id", 100)
            self.get("agent", agent_id)
            surface = raw.get("surface", "browser")
            if surface not in SURFACES:
                raise ValueError("invalid surface")
            url = raw.get("url", "")
            if not isinstance(url, str) or len(url) > 2000:
                raise ValueError("invalid url")
            if surface == "browser" and not re.match(r"^https?://[^/\s]+", url):
                raise ValueError("browser work needs an http(s) URL")
            data.update(agent_id=agent_id, surface=surface, url=url)
            if kind == "job":
                s = schedule(raw.get("schedule"))
                data.update(goal=text(raw.get("goal"), "goal"), schedule=s,
                            enabled=raw.get("enabled") is True, next_due=next_due(s, now))
                # Due single-shot jobs are still queued once when created.
                if s["kind"] == "once":
                    data["next_due"] = s["at"]
                # Preserve the cursor when editing unrelated fields.
                try:
                    old = self.get(kind, identifier)
                    if old["schedule"] == s:
                        data["next_due"] = old["next_due"]
                except ValueError:
                    pass
            else:
                steps = raw.get("steps")
                if not isinstance(steps, list) or not 1 <= len(steps) <= 100:
                    raise ValueError("project needs 1–100 reviewed subtasks")
                data.update(goal=text(raw.get("goal"), "goal"), steps=[text(s, "step") for s in steps],
                            enabled=raw.get("enabled") is True)
                # A running project's plan is immutable; pause and create a new plan.
                active = self.conn.execute("SELECT 1 FROM bobb_runs WHERE project_id=? LIMIT 1", (identifier,)).fetchone()
                if active and self.get(kind, identifier)["steps"] != data["steps"]:
                    raise ValueError("cannot replace a project plan with recorded work")
        self.conn.execute("INSERT INTO bobb_entities VALUES (?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data,updated=excluded.updated",
                          (kind, identifier, json.dumps(data), now))
        self.conn.commit()
        return data

    def delete(self, kind, identifier):
        self.get(kind, identifier)
        if kind == "agent" and len(self.entities("agent")) <= 1:
            raise ValueError("at least one Bobb must remain")
        if kind == "agent" and any(e.get("agent_id") == identifier for k in ("job", "project") for e in self.entities(k)):
            raise ValueError("remove the agent's jobs and projects first")
        if self.conn.execute("SELECT 1 FROM bobb_runs WHERE status='running' AND (agent_id=? OR source_id=? OR project_id=?)",
                             (identifier, identifier, identifier)).fetchone():
            raise ValueError("stop running work before deleting")
        self.conn.execute("DELETE FROM bobb_entities WHERE kind=? AND id=?", (kind, identifier))
        self.conn.execute("UPDATE bobb_runs SET status='stopped' WHERE status='queued' AND (source_id=? OR project_id=?)", (identifier, identifier))
        self.conn.commit()

    def queue(self, data, *, occurrence=None, project_id=None, step=None, now=None):
        now = time.time() if now is None else now
        identifier = uuid.uuid4().hex
        self.conn.execute("""INSERT OR IGNORE INTO bobb_runs
            (id,agent_id,source_id,project_id,step,goal,surface,url,status,created,updated,occurrence)
            VALUES (?,?,?,?,?,?,?,?, 'queued',?,?,?)""",
            (identifier, data["agent_id"], data.get("id"), project_id, step, data["goal"], data["surface"], data["url"], now, now, occurrence))
        return identifier

    def tick(self, *, now=None):
        now = time.time() if now is None else timestamp(now, "now")
        with self.conn:
            self.conn.execute("UPDATE bobb_runs SET status='interrupted',owner=NULL,lease=NULL,report=? WHERE status='running' AND lease<?",
                              ("The executor stopped responding. Review before retrying.", now))
            for job in self.entities("job"):
                due = job["next_due"]
                if not job["enabled"] or due is None or due > now:
                    continue
                self.queue(job, occurrence=f"job:{job['id']}:{due}", now=now)
                job["next_due"] = next_due(job["schedule"], now)
                self.conn.execute("UPDATE bobb_entities SET data=?,updated=? WHERE kind='job' AND id=?", (json.dumps(job), now, job["id"]))
            for project in self.entities("project"):
                if not project["enabled"]:
                    continue
                rows = list(self.conn.execute("SELECT step,status FROM bobb_runs WHERE project_id=? ORDER BY step", (project["id"],)))
                if any(r[1] != "done" for r in rows):
                    continue
                step = len(rows)
                if step >= len(project["steps"]):
                    continue
                data = {**project, "goal": project["steps"][step]}
                self.queue(data, occurrence=f"project:{project['id']}:{step}", project_id=project["id"], step=step, now=now)
            self.conn.execute("DELETE FROM bobb_events WHERE ts<?", (now - 90 * 86400,))

    def event(self, kind, event_id, *, now=None):
        event_id = text(event_id, "event_id", 200)
        now = time.time() if now is None else now
        with self.conn:
            if self.conn.execute("INSERT OR IGNORE INTO bobb_events VALUES (?,?)", (event_id, now)).rowcount == 0:
                return
            for job in self.entities("job"):
                if job["enabled"] and job["schedule"] == {"kind": "event", "event": kind}:
                    # At most one outstanding run per event job: chatty sensors
                    # cannot enqueue thousands of follow-ups while the Mac sleeps.
                    if not self.conn.execute("SELECT 1 FROM bobb_runs WHERE source_id=? AND status IN ('queued','running','waiting')", (job["id"],)).fetchone():
                        self.queue(job, occurrence=f"event:{job['id']}:{event_id}", now=now)

    def claim(self, owner, *, desktop_available=True, now=None, run_id=None):
        now = time.time() if now is None else now
        owner = text(owner, "owner", 100)
        # SQLite transactions serialize claims even when another app connects.
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            rows = list(self.conn.execute("SELECT * FROM bobb_runs WHERE status='queued' ORDER BY created,id"))
            claimed = None
            columns = [d[0] for d in self.conn.execute("SELECT * FROM bobb_runs LIMIT 0").description]
            for row in rows:
                run = dict(zip(columns, row))
                if run_id is not None and run["id"] != run_id:
                    continue
                if self.conn.execute("SELECT 1 FROM bobb_runs WHERE status IN ('running','waiting') AND agent_id=?", (run["agent_id"],)).fetchone():
                    continue
                if run["surface"] == "desktop" and (not desktop_available or self.conn.execute("SELECT 1 FROM bobb_runs WHERE surface='desktop' AND status IN ('running','waiting')").fetchone()):
                    continue
                if run["project_id"] and not self.get("project", run["project_id"])["enabled"]:
                    continue
                if run["source_id"] and not run["project_id"]:
                    try:
                        if not self.get("job", run["source_id"])["enabled"]:
                            continue
                    except ValueError:  # ad hoc run
                        pass
                task_id = f"work_{uuid.uuid4().hex}"
                self.conn.execute("UPDATE bobb_runs SET status='running',owner=?,lease=?,updated=?,task_id=? WHERE id=? AND status='queued'",
                                  (owner, now + 300, now, task_id, run["id"]))
                context = []
                if run["project_id"]:
                    project = self.get("project", run["project_id"])
                    context.append("Project objective: " + project["goal"][:1000])
                    completed = list(self.conn.execute("SELECT step,goal,report FROM bobb_runs WHERE project_id=? AND status='done' ORDER BY step DESC LIMIT 4", (run["project_id"],)))
                    for previous in reversed(completed):
                        context.append(f"Completed subtask {previous[0] + 1}: {previous[1][:300]}\nVerified report: {previous[2][:600]}")
                if run["report"]:
                    context.append("Previous attempt: " + run["report"][:1000] + "\nInspect the actual state before resuming. Never repeat an irreversible action merely because the previous attempt was interrupted.")
                claimed = {**run, "status": "running", "owner": owner, "task_id": task_id, "context": "\n".join(context)}
                break
            self.conn.commit()
            return claimed
        except BaseException:
            self.conn.rollback()
            raise

    def update_run(self, identifier, owner, status, report="", *, now=None):
        if status not in TERMINAL | {"waiting", "running"}:
            raise ValueError("invalid run status")
        row = self.conn.execute("SELECT status,owner FROM bobb_runs WHERE id=?", (identifier,)).fetchone()
        if row is None or row[1] != owner or row[0] not in {"running", "waiting"}:
            raise ValueError("run is not owned by this executor")
        now = time.time() if now is None else now
        with self.conn:
            self.conn.execute("UPDATE bobb_runs SET status=?,report=?,updated=?,lease=?,owner=? WHERE id=?",
                              (status, str(report)[:8000], now, now + 300 if status == "running" else None,
                               owner if status in {"running", "waiting"} else None, identifier))

    def retry(self, identifier):
        row = self.conn.execute("SELECT status FROM bobb_runs WHERE id=?", (identifier,)).fetchone()
        if row is None or row[0] not in {"failed", "stopped", "interrupted", "waiting"}:
            raise ValueError("only blocked or interrupted work can be retried")
        with self.conn:
            self.conn.execute("UPDATE bobb_runs SET status='queued',owner=NULL,lease=NULL,updated=? WHERE id=?", (time.time(), identifier))

    def remember_routine(self, task_id, goal, *, now=None, timezone="UTC"):
        now = time.time() if now is None else now
        try:
            zone = ZoneInfo(timezone)
        except ZoneInfoNotFoundError:
            return
        goal = " ".join(goal.lower().split())[:4000]
        with self.conn:
            self.conn.execute("INSERT OR IGNORE INTO bobb_routine_samples VALUES (?,?,?,?)", (task_id, goal, now, timezone))
            samples = [datetime.fromtimestamp(r[0], zone) for r in self.conn.execute(
                "SELECT ts FROM bobb_routine_samples WHERE goal=? AND timezone=? AND ts>?", (goal, timezone, now - 90 * 86400))]
            current = datetime.fromtimestamp(now, zone)
            matching = {s.date(): s for s in samples if s.weekday() == current.weekday() and abs(s.hour * 60 + s.minute - current.hour * 60 - current.minute) <= 30}
            if len(matching) >= 3:
                identifier = hashlib.sha256(f"{goal}:{current.weekday()}:{timezone}".encode()).hexdigest()[:24]
                self.conn.execute("INSERT INTO bobb_routines(id,goal,weekday,hour,minute,timezone,samples) VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET samples=excluded.samples",
                                  (identifier, goal, current.weekday(), current.hour, current.minute, timezone, len(matching)))
            self.conn.execute("DELETE FROM bobb_routine_samples WHERE ts<?", (now - 90 * 86400,))

    def snapshot(self):
        columns = [d[0] for d in self.conn.execute("SELECT * FROM bobb_runs LIMIT 0").description]
        routine_columns = [d[0] for d in self.conn.execute("SELECT * FROM bobb_routines LIMIT 0").description]
        return {"agents": self.entities("agent"), "jobs": self.entities("job"), "projects": self.entities("project"),
                "runs": [dict(zip(columns, r)) for r in self.conn.execute("SELECT * FROM bobb_runs ORDER BY created DESC LIMIT 200")],
                "routines": [dict(zip(routine_columns, r)) for r in self.conn.execute("SELECT * FROM bobb_routines WHERE status='suggested'")]}

    def command(self, frame):
        op = frame.get("op", "list")
        payload = frame.get("payload") or {}
        if not isinstance(payload, dict):
            raise ValueError("invalid workspace payload")
        result = None
        if op == "put":
            result = self.put(payload.get("kind"), payload.get("data"))
        elif op == "delete":
            self.delete(payload.get("kind"), payload.get("id"))
        elif op == "tick":
            self.tick()
        elif op == "claim":
            result = self.claim(payload.get("owner"), desktop_available=payload.get("desktop_available") is True, run_id=payload.get("run_id"))
        elif op == "run":
            # Validate ad hoc work through the same schema, without creating a job.
            job = self.put("job", {**payload, "name": payload.get("name") or "Request", "enabled": False,
                                   "schedule": {"kind": "once", "at": time.time()}})
            with self.conn:
                result = self.queue(job)
                self.conn.execute("UPDATE bobb_runs SET source_id=NULL WHERE id=?", (result,))
                self.conn.execute("DELETE FROM bobb_entities WHERE kind='job' AND id=?", (job["id"],))
        elif op == "heartbeat":
            # A late heartbeat cannot resurrect a completed run.
            with self.conn:
                self.conn.execute("UPDATE bobb_runs SET lease=?,updated=? WHERE id=? AND owner=? AND status IN ('running','waiting')",
                                  (time.time() + 300, time.time(), payload.get("id"), payload.get("owner")))
        elif op == "update_run":
            self.update_run(payload.get("id"), payload.get("owner"), payload.get("status"), payload.get("report", ""))
        elif op == "retry":
            self.retry(payload.get("id"))
        elif op == "cancel_run":
            with self.conn:
                self.conn.execute("UPDATE bobb_runs SET status='stopped',owner=NULL,lease=NULL WHERE id=? AND status IN ('queued','waiting')", (payload.get("id"),))
        elif op == "dismiss_routine":
            with self.conn:
                self.conn.execute("UPDATE bobb_routines SET status='dismissed' WHERE id=?", (payload.get("id"),))
        elif op != "list":
            raise ValueError("unknown workspace operation")
        return {"result": result, **self.snapshot()}
