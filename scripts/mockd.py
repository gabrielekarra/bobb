#!/usr/bin/env python3
"""A contract-speaking mock of bobbd, for demoing BobbApp without the
real model.

Standard library only — no `mlx`, no model weights, starts instantly. Speaks
the exact wire shapes in `docs/CONTRACT.md`: `hello`/`ready`, `event` ->
`trace` + `decision`, `approve`/`dismiss` -> `prepared`, `policy`. Writes
every decision into the same `audit.db` schema `bobbd/bobbd/audit.py`
uses, so `BobbApp`'s Audit window works against this too.

Unlike the real model, this one is not conservative: `mail.opened` mostly
resolves to `suggest` so the overlay and the Mind panel have something to
show, with an occasional abstained near-miss for the same reason.

Usage:
    python3 scripts/mockd.py [--socket PATH] [--floor 0.60]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

DEFAULT_SOCKET_PATH = Path.home() / "Library" / "Application Support" / "Bobb" / "bobbd.sock"
DEFAULT_AUDIT_PATH = Path.home() / "Library" / "Application Support" / "Bobb" / "audit.db"
MODEL_NAME = "mock/bobb-demo-0.1"

_AUDIT_SCHEMA = """
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

_LEARNING_ONLY_KINDS = {"mail.arrived", "mail.closed", "mail.archived", "mail.deleted"}
_TRACKER_ONLY_KINDS = {"idle.entered", "idle.left"}


def _now() -> float:
    return time.time()


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:20]}"


def open_audit_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(_AUDIT_SCHEMA)
    conn.commit()
    return conn


def record_decision(conn: sqlite3.Connection, decision: dict, event: dict, *, floor: float) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO decisions (
            decision_id, event_id, ts, kind, app, event_payload, model, floor,
            action, confidence, schema_mass, latency_ms, abstained,
            hypotheses, readouts, suggestion, why
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            decision["id"], decision.get("event_id", ""), decision.get("ts", _now()),
            event.get("kind", ""), event.get("app"), json.dumps(event.get("payload") or {}),
            MODEL_NAME, floor, decision["action"], decision["confidence"], decision["schema_mass"],
            decision["latency_ms"], int(bool(decision.get("abstained", False))),
            json.dumps(decision.get("hypotheses", [])), json.dumps(decision.get("readouts", [])),
            json.dumps(decision["suggestion"]) if decision.get("suggestion") is not None else None,
            decision.get("why"),
        ),
    )
    conn.commit()


def record_response(conn: sqlite3.Connection, decision_id: str, response: str) -> dict | None:
    conn.execute(
        "UPDATE decisions SET response = ?, response_ts = ? WHERE decision_id = ?",
        (response, _now(), decision_id),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM decisions WHERE decision_id = ?", (decision_id,)).fetchone()
    if row is None:
        return None
    columns = [d[0] for d in conn.execute("SELECT * FROM decisions LIMIT 0").description]
    return dict(zip(columns, row))


def _bool_readout(name: str, value: bool, p: float) -> dict:
    probabilities = {"true": p, "false": round(1 - p, 6)} if value else {"true": round(1 - p, 6), "false": p}
    return {"q": name, "value": value, "p": p, "schema_mass": 0.99, "probabilities": probabilities, "raw_probabilities": probabilities}


def _interrupt_readout(action: str, p: float) -> dict:
    others = [o for o in ("ignore", "wait", "prepare", "suggest") if o != action]
    remainder = round((1 - p) / len(others), 6)
    probabilities = {o: remainder for o in others}
    probabilities[action] = p
    return {"q": "interrupt", "value": action, "p": p, "schema_mass": 0.99, "probabilities": probabilities, "raw_probabilities": probabilities}


def _sender_name(payload: dict) -> str:
    sender = payload.get("sender", "qualcuno")
    return sender.split("<")[0].strip() or sender


def decide(event: dict, floor: float) -> dict:
    """The demo's stand-in for `AttentionEngine.decide_event`: deterministic
    enough to be a good demo, varied enough not to look scripted."""
    started = time.perf_counter()
    kind = event.get("kind", "")
    payload = event.get("payload") or {}
    typing = payload.get("typing") is True
    idle = payload.get("idle") is True

    if kind in _LEARNING_ONLY_KINDS or kind in _TRACKER_ONLY_KINDS:
        latency_ms = (time.perf_counter() - started) * 1000 + random.uniform(2, 8)
        return {
            "t": "decision", "ts": _now(), "id": _new_id("dec"), "event_id": event.get("id", ""),
            "action": "ignore", "confidence": round(random.uniform(0.96, 0.99), 6), "schema_mass": 0.999,
            "latency_ms": latency_ms, "hypotheses": [], "readouts": [],
            "why": f"{kind}: evento di apprendimento, nessuna azione",
        }

    action = "wait"
    confidence = round(random.uniform(0.5, 0.7), 6)
    hypotheses: list[dict] = []
    readouts: list[dict] = []
    suggestion: dict | None = None
    why = ""

    if kind == "mail.opened" and not typing and not idle:
        reply_needed_p = round(random.uniform(0.75, 0.95), 6)
        urgency = random.randint(1, 4)
        roll = random.random()
        interrupt_action = "suggest" if roll < 0.65 else ("wait" if roll < 0.9 else "ignore")
        confidence = round(random.uniform(0.62, 0.9), 6) if interrupt_action == "suggest" else round(random.uniform(0.4, 0.65), 6)
        action = interrupt_action
        hypotheses = [{"intent": "reply_to_email", "p": reply_needed_p}]
        readouts = [
            _bool_readout("reply_needed", True, reply_needed_p),
            {"q": "urgency", "value": urgency, "p": round(random.uniform(0.5, 0.85), 6), "schema_mass": 0.99,
             "probabilities": {}, "raw_probabilities": {}},
            _interrupt_readout(action, confidence),
        ]
        sender_name = _sender_name(payload)
        why = f"reply_needed true a {reply_needed_p:.2f}, urgenza {urgency}/4"
        if action == "suggest":
            suggestion = {
                "title": f"Vuoi che prepari una risposta a {sender_name}?",
                "action_id": "draft_reply",
                "detail": f"{payload.get('thread_len', 1)} messaggi nel thread",
            }
    elif kind == "mail.composing":
        stuck_p = round(random.uniform(0.55, 0.85), 6)
        action = "suggest" if random.random() < 0.4 else "prepare"
        confidence = stuck_p
        hypotheses = [{"intent": "continue_draft", "p": stuck_p}]
        readouts = [_bool_readout("stuck", True, stuck_p), _interrupt_readout(action, confidence)]
        why = f"pausa nella bozza, stuck a {stuck_p:.2f}"
        if action == "suggest":
            suggestion = {
                "title": "Vuoi che ti aiuti a continuare questa bozza?",
                "action_id": "continue_draft",
                "detail": f"in pausa da {payload.get('idle_seconds', 0)}s",
            }
    elif kind == "text.selected":
        actionable_p = round(random.uniform(0.5, 0.9), 6)
        action = "suggest" if actionable_p > 0.65 else "wait"
        confidence = actionable_p
        text = str(payload.get("text", ""))[:40]
        readouts = [_bool_readout("actionable", True, actionable_p), _interrupt_readout(action, confidence)]
        why = f"selezione plausibilmente utile a {actionable_p:.2f}"
        if action == "suggest":
            suggestion = {"title": f'Vuoi una definizione di "{text}"?', "action_id": "define_selection", "detail": "selezione"}
    else:
        relevant_p = round(random.uniform(0.3, 0.7), 6)
        action = "suggest" if relevant_p > 0.62 else "wait"
        confidence = relevant_p
        readouts = [_bool_readout("relevant", relevant_p > 0.5, relevant_p), _interrupt_readout(action, confidence)]
        why = f"{kind}: rilevanza a {relevant_p:.2f}"
        if action == "suggest":
            suggestion = {"title": f"Vuoi che ti aiuti con {event.get('app', 'questa app')}?", "action_id": "assist_with_app", "detail": ""}

    if typing or idle:
        action, suggestion = "wait", None
        confidence = min(confidence, 0.4)
        why += ", costo di interruzione alto" if why else "costo di interruzione alto"

    abstained = False
    if confidence < floor:
        action, suggestion, abstained = "wait", None, True

    latency_ms = (time.perf_counter() - started) * 1000 + random.uniform(80, 320)
    decision: dict[str, Any] = {
        "t": "decision", "ts": _now(), "id": _new_id("dec"), "event_id": event.get("id", ""),
        "action": action, "confidence": confidence, "schema_mass": round(random.uniform(0.97, 1.0), 6),
        "latency_ms": latency_ms, "hypotheses": hypotheses, "readouts": readouts, "why": why,
    }
    if suggestion is not None:
        decision["suggestion"] = suggestion
    if abstained:
        decision["abstained"] = True
    return decision


class MockDaemon:
    def __init__(self, socket_path: Path, floor: float, audit_path: Path):
        self.socket_path = socket_path
        self.floor = floor
        self.audit = open_audit_db(audit_path)

    async def start(self) -> asyncio.base_events.Server:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            self.socket_path.unlink()
        server = await asyncio.start_unix_server(self._handle_client, path=str(self.socket_path))
        self.socket_path.chmod(0o600)
        return server

    async def _send(self, writer: asyncio.StreamWriter, frame: dict) -> None:
        writer.write((json.dumps(frame) + "\n").encode("utf-8"))
        await writer.drain()

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if not line.strip():
                    continue
                await self._dispatch(json.loads(line), writer)
        except (ConnectionResetError, BrokenPipeError, json.JSONDecodeError):
            pass
        finally:
            writer.close()

    async def _dispatch(self, frame: dict, writer: asyncio.StreamWriter) -> None:
        kind = frame.get("t")
        if kind == "hello":
            await self._send(writer, {
                "t": "ready", "ts": _now(), "model": MODEL_NAME,
                "prime_ms": 12.0, "decide_ms": 4.0, "floor": self.floor,
            })
        elif kind == "event":
            await self._on_event(frame, writer)
        elif kind == "approve":
            await self._on_response(frame, writer, "approve")
        elif kind == "dismiss":
            await self._on_response(frame, writer, "dismiss")
        elif kind == "policy":
            floor = frame.get("floor")
            if isinstance(floor, (int, float)) and 0.0 <= floor <= 1.0:
                self.floor = float(floor)
        elif kind == "frame":
            await self._send(writer, {
                "t": "trace", "ts": _now(), "event_id": frame.get("id", ""),
                "stage": "gate", "detail": "mock: sempre pass", "ms": 0.1,
            })

    async def _on_event(self, event: dict, writer: asyncio.StreamWriter) -> None:
        await asyncio.sleep(random.uniform(0.05, 0.25))
        decision = decide(event, self.floor)
        record_decision(self.audit, decision, event, floor=self.floor)
        await self._send(writer, {
            "t": "trace", "ts": _now(), "event_id": event.get("id", ""),
            "stage": "attention", "detail": decision["action"], "ms": decision["latency_ms"],
        })
        await self._send(writer, decision)

    async def _on_response(self, frame: dict, writer: asyncio.StreamWriter, response: str) -> None:
        decision_id = frame.get("decision_id", "")
        row = record_response(self.audit, decision_id, response)
        if row is None or response != "approve" or not row.get("suggestion"):
            return
        suggestion = json.loads(row["suggestion"])
        await asyncio.sleep(random.uniform(0.3, 0.9))
        await self._send(writer, {
            "t": "prepared", "ts": _now(), "decision_id": decision_id,
            "action_id": suggestion.get("action_id", ""),
            "result": {"kind": "text", "body": f"[demo: bozza generata per {suggestion.get('action_id', '')}]"},
            "latency_ms": random.uniform(200, 600),
        })


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="mockd")
    parser.add_argument("--socket", default=str(DEFAULT_SOCKET_PATH))
    parser.add_argument("--audit-db", default=str(DEFAULT_AUDIT_PATH))
    parser.add_argument("--floor", type=float, default=0.60)
    return parser.parse_args(argv)


async def _run(args: argparse.Namespace) -> None:
    daemon = MockDaemon(Path(args.socket), args.floor, Path(args.audit_db))
    server = await daemon.start()
    print(f"mockd: listening on {args.socket} (floor {args.floor})")
    async with server:
        await server.serve_forever()


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
