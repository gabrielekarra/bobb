import asyncio
import sqlite3
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from bobbd.email import EmailStore, deadline, normalize, triage, writing_task, finalize_reply
from bobbd import server as server_mod, attention as attention_mod
from bobbd.generation import Generated
from server_helpers import running_server, send_frame, recv_frame
from fake_engine import TrivialEngine
from bobbd.attention import AttentionEngine
from bobbd.settings import Settings


def message(identifier="request@example.test", **values):
    return {"message_id": identifier, "sender": "Marco <marco@example.test>", "to": "user@example.test",
            "subject": "Preventivo", "body": "Ciao, puoi confermare il preventivo entro domani alle 15:30?",
            "sent_at": time.time(), **values}


@pytest.fixture
def store():
    conn = sqlite3.connect(":memory:")
    yield EmailStore(conn)
    conn.close()


def test_queue_deadline_and_idempotence(store):
    now = datetime(2026, 10, 3, 10, tzinfo=ZoneInfo("Europe/Rome")).timestamp()
    p = message(sent_at=now)
    assert store.observe(p, now=now, timezone="Europe/Rome")
    assert not store.observe(p, now=now + 20, timezone="Europe/Rome")
    item = store.listing(view="reply")[0]
    assert item["category"] == "personal_request" and item["priority"] == 3
    assert datetime.fromtimestamp(item["due"], ZoneInfo("Europe/Rome")).isoformat() == "2026-10-04T15:30:00+02:00"
    assert len(store.reminders()) == 1
    store.set_status(p["message_id"], "done")
    store.observe(p, now=now + 30)
    assert store.listing(view="reply") == [] and store.reminders() == []


def test_quotes_newsletters_and_automatic_mail_are_not_requests(store):
    quoted = message(body="Grazie per l’aggiornamento.\nOn yesterday wrote:\nCan you reply by tomorrow?")
    assert not triage(normalize(quoted))["needs_reply"]
    for p in [message(body="Can you read our newsletter? Unsubscribe here"), message(automatic=True), message(list_id="list@example.test")]:
        hints = triage(normalize(p))
        assert not hints["needs_reply"] and hints["due"] is None


def test_dates_are_local_and_expired_dates_do_not_roll_to_next_year():
    stamp = datetime(2026, 10, 2, 10, tzinfo=ZoneInfo("Europe/Rome"))
    assert deadline("entro venerdì alle 14", stamp).isoformat() == "2026-10-02T14:00:00+02:00"
    assert deadline("deadline 2026-09-30 at 3pm", stamp).isoformat() == "2026-09-30T15:00:00+02:00"
    assert deadline("entro 30/09/2026", stamp).year == 2026
    assert deadline("entro 31/02/2026", stamp) is None


def test_same_subject_is_never_a_conversation_link(store):
    store.observe(message("one"))
    store.observe(message("two"))
    assert [p["id"] for p in store.thread("one")] == ["one"]
    store.observe(message("reply", direction="sent", to="marco@example.test", sender="user@example.test", in_reply_to="one"))
    assert store.get("one")["status"] == "replied"
    assert store.get("two")["status"] == "open"
    assert set(p["id"] for p in store.thread("one")) == {"one", "reply"}


def test_waiting_resolves_from_headers_and_correct_person_in_any_batch_order(store):
    now = time.time()
    parent = message("out", direction="sent", sender="user@example.test", to="marco@example.test", sent_at=now - 100, body="Can you send the estimate?")
    store.observe(message("unrelated", in_reply_to="out", sender="other@example.test", sent_at=now, body="Unrelated update."))
    store.observe(parent)
    store.remind("out", "waiting", now + 86400, now=now)
    assert len(store.reminders()) == 1
    store.observe(message("answer", references=["out"], sent_at=now + 1, body="Here is the estimate."))
    assert store.reminders() == []
    store.remind("out", "waiting", now + 86400, now=now)
    assert store.reminders() == []  # existing proof prevents a stale reminder


def test_replies_use_reply_to_and_do_not_resolve_older_messages(store):
    now = time.time()
    store.observe(message("in", reply_to="help@example.test", sent_at=now))
    store.observe(message("bad", direction="sent", to="help@example.test", in_reply_to="in", sent_at=now - 5))
    assert store.get("in")["status"] == "open"
    store.observe(message("good", direction="sent", to="help@example.test", in_reply_to="in", sent_at=now + 5))
    assert store.get("in")["status"] == "replied"


def test_snooze_present_done_and_retention(store):
    now = time.time()
    store.observe(message(sent_at=now - 100))
    store.remind("request@example.test", "reply", now + 10, now=now)
    identifier = next(r["id"] for r in store.reminders() if r["kind"] == "reply")
    store.update_reminder(identifier, "present", now=now)
    assert next(r for r in store.reminders() if r["id"] == identifier)["announced"] == 0
    store.update_reminder(identifier, "present", now=now + 20)
    store.update_reminder(identifier, "snooze", due=now + 86400, now=now)
    item = next(r for r in store.reminders() if r["id"] == identifier)
    assert item["announced"] == 0 and not item["ready"]
    store.update_reminder(identifier, "done")
    store.observe(message("old", sent_at=now - 40 * 86400))
    assert store.sweep(30, now=now) == 1
    assert store.get("old") is None


def test_search_vip_and_preferences_survive_reopening(store):
    store.observe(message(body="Status 100% ready", subject="Release_status"))
    assert len(store.listing(query="100%")) == 1
    assert store.listing(query="_incorrect") == []
    assert len(store.listing(query="Marco Release_status")) == 1
    store.set_preferences({"vip": ["Marco <MARCO@example.test>"], "signature": "Gabriele", "style": "formal"})
    assert len(store.listing(view="vip")) == 1
    assert EmailStore(store.conn).preferences()["signature"] == "Gabriele"
    store.delete()
    assert store.counts()["all"] == 0 and store.preferences()["vip"] == []


@pytest.mark.parametrize("due", [0, True, float("nan"), float("inf"), time.time() - 1, time.time() + 400 * 86400])
def test_invalid_reminders_are_rejected(store, due):
    store.observe(message())
    with pytest.raises(ValueError): store.remind("request@example.test", "reply", due)


@pytest.mark.parametrize("op", ["summary", "actions", "questions", "reply", "followup", "forward", "new", "rewrite", "translate", "digest", "meeting"])
def test_every_writing_tool_is_grounded_and_bounded(op):
    p = normalize(message(direction="sent" if op == "followup" else "received"))
    task = writing_task(op, p, [p], "Keep it short; ask about delivery.", "it", {"style": "formal", "signature": "Gabriele"},
                        draft="Ciao, vorrei sapere la data di consegna.", target="French")
    assert task.max_tokens <= 600
    assert "data" in task.messages[0]["content"] and "<<<" in task.messages[1]["content"]
    assert "450" not in task.grounding
    if op == "rewrite": assert "CURRENT DRAFT" in task.messages[1]["content"]
    if op == "translate": assert "French" in task.messages[0]["content"]


def test_reply_keeps_neutral_intent_history_and_signature():
    p = normalize(message())
    previous = normalize(message("previous", body="Il prezzo concordato è 450 euro."))
    task = writing_task("reply", p, [previous, p], "", "it", {"style": "warm", "signature": "Gabriele"})
    assert "No confirmation, agreement, promise" in task.messages[1]["content"]
    assert "450" in task.grounding and "Gabriele" in task.grounding
    assert "warm" in task.messages[0]["content"]


def test_measured_reply_failures_cannot_become_final_quick_variants():
    p = normalize(message())
    text, checks = finalize_reply("Confermo il preventivo. La consegna avverrà il giorno successivo alla ricezione del pagamento.", p, "accept")
    assert "delivery_terms" in checks and "pagamento" not in text
    text, checks = finalize_reply("Grazie. Resto in attesa delle tue indicazioni.", p, "")
    assert "reply_direction" in checks and "attesa" not in text
    text, checks = finalize_reply("Ho già inviato il contratto.", p, "")
    assert "completed_work" in checks and "già inviato" not in text


def test_summary_sources_include_dates_direction_and_observation_scope():
    p = normalize(message(direction="sent"))
    task = writing_task("digest", p, [p], "", "it", {}, timezone="Europe/Rome")
    assert "USER SENT THIS" in task.messages[1]["content"]
    assert "Date:" in task.messages[1]["content"]
    assert "SENT email NEVER" in task.messages[0]["content"]
    task = writing_task("meeting", p, [p], "", "it", {})
    assert "RESPONSE DEADLINES ARE NOT MEETING DATES" in task.messages[0]["content"]


async def command(reader, writer, op, payload=None, identifier="email_test"):
    await send_frame(writer, {"t": "email.command", "id": identifier, "op": op, "payload": payload or {}})
    deltas = ""
    while True:
        frame = await recv_frame(reader)
        if frame["t"] == "email.delta": deltas += frame["text"]
        else: return frame, deltas


@pytest.mark.asyncio
async def test_socket_ingest_generate_edit_and_memory_off(tmp_path, monkeypatch):
    prompts = []
    def generate(engine, messages, *, on_delta=None, **kwargs):
        prompts.append(messages)
        on_delta("Ciao Marco.")
        return Generated("Ciao Marco.", 4, 1, 2, False, "stop")
    monkeypatch.setattr(server_mod, "supports_generation", lambda e: True)
    monkeypatch.setattr(server_mod, "stream_text", generate)
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        frame, _ = await command(reader, writer, "ingest", {"items": [message()]})
        assert frame["counts"]["reply"] == 1
        frame, deltas = await command(reader, writer, "reply", {"message_id": "request@example.test"})
        assert frame["result"]["result_kind"] == "reply" and deltas == frame["result"]["text"]
        assert frame["result"]["message_id"] == "request@example.test" and not server._task_sessions
        frame, _ = await command(reader, writer, "rewrite", {"message_id": "request@example.test", "draft": "La mia data scelta è il 15 ottobre.", "instruction": "Make it warmer."})
        assert "La mia data scelta" in prompts[-1][1]["content"]
        server.apply_settings({"memory_enabled": False})
        frame, _ = await command(reader, writer, "ingest", {"items": [message("another")]})
        assert frame["t"] == "error" and server.email.get("another") is None
        frame, _ = await command(reader, writer, "summary", {"snapshot": message("ephemeral")})
        assert frame["result"]["text"] and server.email.get("ephemeral") is None
        writer.close()


@pytest.mark.asyncio
async def test_excluded_app_and_batch_validation(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        frame, _ = await command(reader, writer, "ingest", {"items": [message(), {}]})
        assert frame["t"] == "error" and server.email.counts()["all"] == 0
        server.apply_settings({"extra_protected_apps": ["com.apple.mail"]})
        frame, _ = await command(reader, writer, "list")
        assert frame["t"] == "error"
        writer.close()


@pytest.mark.asyncio
async def test_excluding_mail_during_generation_discards_output(tmp_path, monkeypatch):
    started, proceed = threading.Event(), threading.Event()
    def generate(engine, messages, *, on_delta=None, **kwargs):
        started.set(); proceed.wait(3)
        on_delta("private email text")
        return Generated("private email text", 3, 1, 1, False, "stop")
    monkeypatch.setattr(server_mod, "supports_generation", lambda e: True)
    monkeypatch.setattr(server_mod, "stream_text", generate)
    async with running_server(tmp_path, monkeypatch) as server:
        server.email.observe(message())
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "email.command", "id": "email_private", "op": "reply", "payload": {"message_id": "request@example.test"}})
        assert await asyncio.to_thread(started.wait, 3)
        server.apply_settings({"extra_protected_apps": ["com.apple.mail"]})
        proceed.set()
        frame = await recv_frame(reader)
        assert frame["t"] == "email.state" and frame["result"]["text"] == "" and frame["result"]["error"]
        writer.close()


@pytest.mark.asyncio
async def test_delete_memory_clears_email_copy(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        server.email.observe(message())
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "memory.delete", "id": "delete", "scope": "all"})
        assert (await recv_frame(reader))["t"] == "memory.deleted"
        assert server.email.counts()["all"] == 0
        writer.close()


def test_draft_checks_are_immediate_deduplicated_and_quiet(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", lambda *a, **kw: pytest.fail("draft check ran inference"))
    attention = AttentionEngine(TrivialEngine(), settings=Settings(locale="it"))
    event = {"kind": "mail.draft_check", "payload": {"compose_id": "one", "draft": "Ti allego il contratto.", "issues": ["attachment"], "typing": False}}
    result = attention.decide_event(event)
    assert result["action"] == "suggest" and result["suggestion"]["action_id"] == "check_mail"
    assert attention.decide_event(event)["action"] == "ignore"
    attention.settings = Settings(proactive_kinds=frozenset())
    assert attention.decide_event({**event, "payload": {**event["payload"], "compose_id": "two"}})["action"] == "ignore"
