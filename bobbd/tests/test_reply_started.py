"""The native reply gesture offers help before any model work or app action."""
import asyncio

import pytest
from fake_engine import TrivialEngine
from server_helpers import recv_frame, running_server, send_frame
from bobbd import attention as attention_mod, server as server_mod
from bobbd.attention import AttentionEngine
from bobbd.generation import Generated
from bobbd.settings import Settings


def event(identifier="reply", **changes):
    return {"t": "event", "id": identifier, "kind": "mail.reply_started", "app": "Mail", "payload": {
        "sender": "Marco Rossi <marco@example.com>", "subject": "Preventivo revisione",
        "body": "Ciao Gabriele, mi confermi il preventivo?", "message_id": "<original@example.com>",
        "compose_id": "draft-1", "draft": "", "typing": False, "idle": False, **changes}}


def test_offer_needs_no_inference_and_is_once_per_reply(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", lambda *a, **kw: pytest.fail("Gesture ran model inference"))
    attention = AttentionEngine(TrivialEngine(), settings=Settings(locale="it", floor=1.0))
    decision = attention.decide_event(event())
    assert decision["action"] == "suggest"
    assert decision["tier"] == "gesture" and decision["readouts"] == []
    assert decision["suggestion"]["title"] == "Vuoi che prepari una bozza di risposta?"
    assert decision["suggestion"]["cta"] == "Genera bozza"
    assert attention.decide_event(event("duplicate"))["action"] == "ignore"
    assert attention.decide_event(event("new", compose_id="draft-2"))["action"] == "suggest"


@pytest.mark.parametrize("changes", [{"message_id": ""}, {"compose_id": ""}, {"body": ""}, {"sender": ""},
                                     {"draft": "Sto già scrivendo"}, {"typing": True}, {"idle": True}])
def test_no_offer_without_original_or_when_user_is_writing(changes):
    attention = AttentionEngine(TrivialEngine())
    assert attention.decide_event(event(**changes))["action"] == "ignore"


def test_respects_proactivity_and_quiet_hours():
    attention = AttentionEngine(TrivialEngine(), settings=Settings(proactive_kinds=frozenset()))
    assert attention.decide_event(event())["action"] == "ignore"
    attention.settings = Settings(quiet_hours=(0, 23))
    from unittest.mock import patch
    with patch.object(attention_mod, "_local_hour", return_value=10):
        assert attention.decide_event(event())["action"] == "prepare"


@pytest.mark.asyncio
async def test_socket_offer_is_immediate_and_only_approval_generates(tmp_path, monkeypatch):
    calls = []
    def stream(engine, messages, *, on_delta=None, **kwargs):
        calls.append(messages)
        on_delta("Ciao Marco, grazie per il messaggio.")
        return Generated("Ciao Marco, grazie per il messaggio.", 8, 1, 1, False, "stop")
    monkeypatch.setattr(server_mod, "supports_generation", lambda engine: True)
    monkeypatch.setattr(server_mod, "stream_text", stream)
    async with running_server(tmp_path, monkeypatch) as server:
        async def no_model_queue(*a, **kw):
            pytest.fail("Displaying the reply offer queued behind model inference")
        original_run = server._run_model
        monkeypatch.setattr(server, "_run_model", no_model_queue)
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, event())
        assert (await recv_frame(reader))["t"] == "trace"
        decision = await recv_frame(reader)
        assert decision["action"] == "suggest" and not calls
        assert decision["suggestion"]["action_id"] == "draft_reply"
        monkeypatch.setattr(server, "_run_model", original_run)
        await send_frame(writer, {"t": "approve", "decision_id": decision["id"]})
        assert (await recv_frame(reader))["t"] == "prepared.delta"
        prepared = await recv_frame(reader)
        assert prepared["t"] == "prepared" and "error" not in prepared
        assert prepared["result"]["message_id"] == "<original@example.com>"
        assert prepared["result"]["compose_id"] == "draft-1"
        assert "mi confermi il preventivo" in calls[0][1]["content"]
        assert "No confirmation, agreement, promise" in calls[0][1]["content"]
        assert not server._task_sessions
        writer.close()


@pytest.mark.asyncio
async def test_muted_sender_and_excluded_mail_stay_quiet(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        server.personalizer.mute("marco@example.com")
        assert server.attention.decide_event(event())["action"] == "ignore"
        server.apply_settings({"extra_protected_apps": ["com.apple.mail"]})
        class Client:
            async def send(self, frame):
                pytest.fail("Excluded Mail produced a response")
        await server._on_event(event(), Client())
        assert server.conn.execute("SELECT count(*) FROM decisions").fetchone()[0] == 0


@pytest.mark.asyncio
async def test_three_reply_dismissals_teach_silence_and_reset_restores_offers(tmp_path, monkeypatch):
    from bobbd.audit import record_decision, record_response
    async with running_server(tmp_path, monkeypatch) as server:
        for n in range(3):
            source = event(str(n), compose_id=str(n))
            decision = server.attention.decide_event(source)
            assert decision["action"] == "suggest"
            record_decision(server.conn, decision, source, floor=.6, model="trivial")
            record_response(server.conn, decision["id"], "dismiss", reason="user")
            server.personalizer.refresh()
        assert server.attention.decide_event(event("muted", compose_id="after-mute"))["action"] == "ignore"
        assert server.personalizer.forget("sender:marco@example.com")
        assert server.attention.decide_event(event("restored", compose_id="after-reset"))["action"] == "suggest"


@pytest.mark.asyncio
async def test_excluding_source_after_offer_prevents_draft_generation(tmp_path, monkeypatch):
    monkeypatch.setattr(server_mod, "stream_text", lambda *a, **kw: pytest.fail("Excluded email entered generation"))
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, event())
        await recv_frame(reader)
        decision = await recv_frame(reader)
        server.apply_settings({"extra_protected_apps": ["com.apple.mail"]})
        await send_frame(writer, {"t": "approve", "decision_id": decision["id"]})
        prepared = await recv_frame(reader)
        assert prepared["t"] == "prepared" and prepared["result"]["kind"] == "error"
        assert "excluded" in prepared["result"]["body"]
        writer.close()
