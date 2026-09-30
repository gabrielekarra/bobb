"""Shared helpers for socket-level server tests. Not a test module itself.

Backs `BobbServer` with a `TrivialEngine` and a monkeypatched `decide_many`
so these tests exercise the real asyncio/NDJSON/audit path end to end
without loading the resident model.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fake_engine import TrivialEngine

import bobbd.attention as attention_mod
from bobbd.attention import AttentionEngine
from bobbd.audit import open_db
from bobbd.schema import Decision, decision_key
from bobbd.server import BobbServer


def fake_decide_many(engine, context, questions, *, calibrators=None, primed=None):
    out = []
    for q in questions:
        if q.kind == "bool":
            value = True
        elif q.kind == "score":
            value = int(q.labels[-1])
        else:
            value = q.labels[-1]
        key = decision_key(q.kind, value)
        other = 0.1 / max(1, len(q.labels) - 1)
        probabilities = {label: (0.9 if label == key else other) for label in q.labels}
        out.append(
            Decision(
                name=q.name,
                kind=q.kind,
                value=value,
                probabilities=probabilities,
                raw_probabilities=probabilities,
                confidence=probabilities[key],
                schema_mass=0.97,
                latency_ms=1.0,
            )
        )
    return out


@asynccontextmanager
async def running_server(tmp_path, monkeypatch, *, floor: float = 0.5):
    # macOS caps AF_UNIX paths at ~104 bytes and pytest's tmp_path nests deep
    # enough to blow past that, so the socket (unlike the audit db) lives
    # under /tmp directly, with a short, collision-proof name.
    monkeypatch.setattr(attention_mod, "decide_many", fake_decide_many)
    attention = AttentionEngine(TrivialEngine(), floor=floor)
    conn = open_db(tmp_path / "audit.db")
    socket_path = Path(f"/tmp/bobbd-test-{uuid.uuid4().hex[:10]}.sock")
    server = BobbServer(
        attention,
        conn,
        socket_path=socket_path,
        model_name="trivial-protocol",
        prime_ms=1.0,
        decide_ms=1.0,
    )
    asyncio_server = await server.start()
    task = asyncio.create_task(asyncio_server.serve_forever())
    try:
        yield server
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        asyncio_server.close()
        server.close()
        socket_path.unlink(missing_ok=True)


async def send_frame(writer: asyncio.StreamWriter, frame: dict) -> None:
    writer.write((json.dumps(frame) + "\n").encode("utf-8"))
    await writer.drain()


async def recv_frame(reader: asyncio.StreamReader, timeout: float = 5.0) -> dict:
    line = await asyncio.wait_for(reader.readline(), timeout)
    return json.loads(line)


def mail_event(event_id: str = "evt_x") -> dict:
    return {
        "t": "event",
        "ts": 0.0,
        "id": event_id,
        "kind": "mail.opened",
        "app": "Mail",
        "payload": {
            "sender": "Marco Rossi <marco@example.com>",
            "subject": "Preventivo",
            "body": "conferma il preventivo",
            "thread_len": 2,
            "unread": True,
        },
    }
