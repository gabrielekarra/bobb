"""Archive and native-inline commands, without requiring a GPU or IPC sockets."""
import asyncio
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

import pytest
from bobbd.email import EmailStore
from bobbd.audit import open_db
from bobbd.attention import AttentionEngine
from bobbd.generation import Generated
from bobbd.server import BobbServer
from bobbd import server as server_mod
from fake_engine import TrivialEngine


def message(n, **values):
    return {"message_id": str(n), "sender": "Marco <marco@example.test>", "to": "user@example.test",
            "subject": "Update", "body": "Here is the update.", "sent_at": time.time() + n, **values}


@pytest.fixture
def store():
    conn = sqlite3.connect(":memory:")
    yield EmailStore(conn)
    conn.close()


def test_every_archive_page_is_reachable_without_duplicates(store):
    for n in range(137): store.observe(message(n))
    pages = [store.listing(offset=n) for n in (0, 60, 120)]
    ids = [item["id"] for page in pages for item in page]
    assert len(ids) == len(set(ids)) == store.matching_count() == 137
    assert [len(page) for page in pages] == [60, 60, 17]


def test_filters_apply_before_pagination_even_beyond_old_scan_limit(store):
    for n in range(350):
        store.observe(message(n, sender="other@example.test", mailbox="Inbox", account="Personal"))
    store.observe(message(-1000, sender="VIP <vip@example.test>", unread=True, flagged=True, attachments=["quote.pdf"], mailbox="Archive", account="Work"))
    store.set_preferences({"vip": ["vip@example.test"]})
    for view in ("vip", "unread", "attachments", "flagged"):
        assert [p["id"] for p in store.listing(view=view)] == ["-1000"]
    assert store.matching_count(mailbox="Archive", account="Work") == 1
    assert store.listing(mailbox="Archive", account="Personal") == []
    assert store.folders() == {"mailboxes": ["Archive", "Inbox"], "accounts": ["Personal", "Work"]}


def test_vip_matches_address_not_another_person(store):
    store.set_preferences({"vip": ["vip@example.test"]})
    store.observe(message(0, sender="notvip@example.test"))
    store.observe(message(1, sender="Name <vip@example.test>"))
    assert [p["id"] for p in store.listing(view="vip")] == ["1"]


def test_same_message_in_multiple_folders_remains_searchable_in_each(store):
    store.observe(message(1, mailbox="Inbox", account="Work"))
    store.observe(message(1, mailbox="All Mail", account="Work"))
    store.observe(message(1, mailbox="Saved", account="Personal"))
    assert store.matching_count() == 1
    assert len(store.listing(mailbox="Inbox", account="Work")) == 1
    assert len(store.listing(mailbox="All Mail", account="Work")) == 1
    assert store.listing(mailbox="Saved", account="Work") == []
    store.delete("1")
    assert store.folders() == {"mailboxes": [], "accounts": []}


def test_old_archive_survives_only_explicit_full_archive_retention(store):
    now = time.time()
    store.observe(message(0, sent_at=now - 365 * 86400))
    store.set_preferences({"archive_all": True})
    assert store.sweep(30, now=now) == 0 and store.get("0")
    assert EmailStore(store.conn).preferences()["archive_all"] is True
    store.set_preferences({"archive_all": False})
    assert store.sweep(30, now=now) == 1
    store.delete()
    assert store.preferences()["archive_all"] is False


def test_long_conversation_includes_latest_updates(store):
    for n in range(42): store.observe(message(n, in_reply_to=str(n-1) if n else ""))
    thread = store.thread("0")
    assert len(thread) == 30 and thread[0]["id"] == "12" and thread[-1]["id"] == "41"


@pytest.mark.parametrize("offset", [-1, True, "60", 0.5])
def test_invalid_pages_cannot_reinterpret_query(store, offset):
    with pytest.raises(ValueError): store.listing(offset=offset)


def test_date_and_direction_filters_keep_search_literal(store):
    now = time.time()
    store.observe(message(0, subject="100% quote", sent_at=now-20))
    store.observe(message(1, subject="100X quote", sent_at=now, direction="sent"))
    assert [p["id"] for p in store.listing(query="100%")] == ["0"]
    assert [p["id"] for p in store.listing(view="sent", since=now-10)] == ["1"]
    store.observe({"message_id": "1", "body": "Full text"})
    assert [p["id"] for p in store.listing(view="sent")] == ["1"]


class Client:
    def __init__(self): self.frames = []
    async def send(self, frame): self.frames.append(frame)


@contextmanager
def daemon(tmp_path):
    server = BobbServer(AttentionEngine(TrivialEngine()), open_db(tmp_path / "audit.db"),
                       socket_path=Path("/tmp/unused-email-test.sock"), model_name="fake", prime_ms=0, decide_ms=0)
    try: yield server
    finally: server.close()


@pytest.mark.asyncio
async def test_command_reports_filtered_total_and_page_state(tmp_path):
    with daemon(tmp_path) as server:
        for n in range(75): server.email.observe(message(n, account="Work"))
        client = Client()
        await server._on_email_command({"id": "email_page", "op": "list", "payload": {"offset": 60, "account": "Work"}}, client)
        frame = client.frames[-1]
        assert frame["request_id"] == "email_page" and frame["total"] == 75
        assert len(frame["items"]) == 15 and frame["has_more"] is False
        assert frame["accounts"] == ["Work"] and "mailboxes" in frame


@pytest.mark.asyncio
async def test_inline_gesture_records_source_and_never_displays_duplicate_offer(tmp_path, monkeypatch):
    with daemon(tmp_path) as server:
        monkeypatch.setattr(server.attention, "reply_started", lambda *a: pytest.fail("Duplicated inline offer"))
        client = Client()
        await server._on_event({"id": "reply_native", "kind": "mail.reply_started", "app": "Mail", "payload": {
            **message(1), "compose_id": "draft", "inline_handled": True}}, client)
        assert client.frames[-1]["action"] == "ignore" and "suggestion" not in client.frames[-1]
        assert client.frames[-1]["event_id"] == "reply_native" and server.email.get("1")


@pytest.mark.asyncio
async def test_inline_command_generates_without_offer_or_approval_and_binds_composer(tmp_path, monkeypatch):
    monkeypatch.setattr(server_mod, "supports_generation", lambda e: True)
    monkeypatch.setattr(server_mod, "stream_text", lambda *a, **kw: Generated("Thank you for the update.", 6, 1, 1, False, "stop"))
    with daemon(tmp_path) as server:
        client = Client()
        snapshot = message(1, compose_id="draft-42", draft="", typing=False)
        await server._on_email_command({"id": "email_inline_1", "op": "reply", "payload": {
            "message_id": "1", "snapshot": snapshot, "automatic": True}}, client)
        await asyncio.gather(*list(server._tasks))
        result = client.frames[-1]["result"]
        assert result["compose_id"] == "draft-42" and result["message_id"] == "1"
        assert result["text"] and not result["cancelled"]
        assert all(f["t"] in {"email.delta", "email.state"} for f in client.frames)


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["muted", "wrong_original", "written", "typing", "disabled"])
async def test_inline_command_stays_quiet_when_source_or_user_state_is_wrong(tmp_path, monkeypatch, case):
    monkeypatch.setattr(server_mod, "stream_text", lambda *a, **kw: pytest.fail("Unexpected automatic generation"))
    with daemon(tmp_path) as server:
        snapshot = message(1, compose_id="draft-42", draft="", typing=False)
        identifier = "1"
        if case == "muted": server.personalizer.mute("marco@example.test")
        if case == "wrong_original": identifier = "another"
        if case == "written": snapshot["draft"] = "My own reply"
        if case == "typing": snapshot["typing"] = True
        if case == "disabled": server.apply_settings({"proactive_kinds": []})
        client = Client()
        await server._on_email_command({"id": "email_inline_1", "op": "reply", "payload": {
            "message_id": identifier, "snapshot": snapshot, "automatic": True}}, client)
        assert client.frames[-1]["result"]["cancelled"] is True and not server._email_requests
