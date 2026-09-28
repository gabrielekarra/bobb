"""End-to-end sanity against the real resident model.

Everything else in the suite runs against fakes so it stays fast; this file
is the check that the real tokenizer, chat template and letter table
actually agree with what `decide.py` assumes about them.
"""

import asyncio
import json
import time
import uuid
from pathlib import Path

import pytest

from leonardd.attention import AttentionEngine
from leonardd.audit import open_db, record_decision
from leonardd.engine import ResidentMLX
from leonardd.server import LeonardServer

MODEL_ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

pytestmark = pytest.mark.slow


@pytest.fixture(scope="module")
def engine():
    return ResidentMLX(MODEL_ID)


@pytest.fixture(scope="module")
def attention(engine):
    return AttentionEngine(engine, floor=0.60)


def test_mail_opened_produces_a_valid_decision(attention):
    event = {
        "t": "event",
        "ts": 0.0,
        "id": "evt_slow_1",
        "kind": "mail.opened",
        "app": "Mail",
        "payload": {
            "sender": "Marco Rossi <marco@example.com>",
            "subject": "Conferma urgente entro oggi",
            "body": "Ciao, mi confermi il preventivo entro oggi? Ho bisogno di una risposta al piu presto.",
            "thread_len": 3,
            "unread": True,
        },
    }
    decision = attention.decide_event(event)
    assert decision["action"] in ("ignore", "wait", "prepare", "suggest")
    assert 0.0 <= decision["confidence"] <= 1.0
    assert 0.0 <= decision["schema_mass"] <= 1.0
    assert decision["schema_mass"] > 0.5
    assert {r["q"] for r in decision["readouts"]} == {"message_type", "urgency"}


def test_idle_event_short_circuits_without_a_model_call(attention):
    decision = attention.decide_event(
        {"t": "event", "ts": 0.0, "id": "evt_slow_2", "kind": "idle.entered", "payload": {}}
    )
    assert decision["action"] == "ignore"
    assert decision["readouts"] == []


def test_text_selected_produces_a_valid_decision_within_a_generous_ceiling(attention):
    event = {
        "t": "event",
        "ts": 0.0,
        "id": "evt_slow_3",
        "kind": "text.selected",
        "app": "Safari",
        "payload": {"text": "quanto fa 12 per 8?", "surrounding": "una pagina di calcolo"},
    }
    started = time.perf_counter()
    decision = attention.decide_event(event)
    elapsed_ms = (time.perf_counter() - started) * 1000
    assert elapsed_ms < 1000
    assert decision["action"] in ("ignore", "wait", "prepare", "suggest")
    assert {r["q"] for r in decision["readouts"]} == {"actionable", "action_kind"}


@pytest.mark.asyncio
async def test_approve_produces_a_real_generated_draft_over_the_real_socket(tmp_path, attention):
    event = {
        "kind": "mail.opened",
        "app": "Mail",
        "payload": {
            "sender": "Marco Rossi <marco@example.com>",
            "subject": "Conferma preventivo",
            "body": "Ciao, mi confermi il preventivo entro venerdi? Grazie mille.",
            "thread_len": 2,
            "unread": True,
        },
    }
    decision = {
        "id": "dec_slow_draft",
        "event_id": "evt_slow_draft",
        "ts": 0.0,
        "action": "suggest",
        "confidence": 0.9,
        "schema_mass": 1.0,
        "latency_ms": 1.0,
        "hypotheses": [],
        "readouts": [],
        "why": "test fixture",
        "suggestion": {
            "title": "Vuoi che prepari una risposta a Marco?",
            "action_id": "draft_reply",
            "detail": "2 messaggi nel thread",
        },
    }
    conn = open_db(tmp_path / "audit.db")
    record_decision(conn, decision, event, floor=0.6, model=MODEL_ID)

    socket_path = Path(f"/tmp/leonardd-test-{uuid.uuid4().hex[:10]}.sock")
    server = LeonardServer(attention, conn, socket_path=socket_path, model_name=MODEL_ID)
    asyncio_server = await server.start()
    task = asyncio.create_task(asyncio_server.serve_forever())
    try:
        reader, writer = await asyncio.open_unix_connection(str(socket_path))
        writer.write((json.dumps({"t": "approve", "ts": 0.0, "decision_id": "dec_slow_draft"}) + "\n").encode())
        await writer.drain()
        line = await asyncio.wait_for(reader.readline(), timeout=60.0)
        prepared = json.loads(line)
        writer.close()
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        asyncio_server.close()
        server.close()
        socket_path.unlink(missing_ok=True)

    assert prepared["t"] == "prepared"
    assert prepared["decision_id"] == "dec_slow_draft"
    assert prepared["action_id"] == "draft_reply"
    body = prepared["result"]["body"]
    assert prepared["result"]["kind"] == "text"
    assert isinstance(body, str) and len(body.strip()) > 0
    assert "generazione del contenuto non ancora implementata" not in body
