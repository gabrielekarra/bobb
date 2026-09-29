"""Promises the user made, found in what they sent."""

import asyncio
from datetime import datetime

import pytest
from server_helpers import recv_frame, running_server, send_frame
from test_agent import scripted

import leonardd.commitments as cm
from leonardd.audit import open_db
from leonardd.generation import Generated

# Monday 28 September 2026, 10:00.
SENT = datetime(2026, 9, 28, 10, 0)


@pytest.mark.parametrize(
    "text, expected",
    [
        ("Ti mando il contratto firmato entro venerdì.", datetime(2026, 10, 2, 18)),
        ("I'll send it by Friday", datetime(2026, 10, 2, 18)),
        ("Ti richiamo domani mattina", datetime(2026, 9, 29, 18)),
        ("I'll get back to you tomorrow", datetime(2026, 9, 29, 18)),
        ("Te lo giro oggi pomeriggio", datetime(2026, 9, 28, 18)),
        ("dopodomani ti faccio sapere", datetime(2026, 9, 30, 18)),
        ("I'll check within 3 days", datetime(2026, 10, 1, 18)),
        ("te lo mando tra due giorni", datetime(2026, 9, 30, 18)),
        ("ne parliamo la prossima settimana", datetime(2026, 10, 9, 18)),
        ("entro fine settimana ti mando tutto", datetime(2026, 10, 2, 18)),
        ("pagherò la fattura entro fine mese", datetime(2026, 9, 30, 18)),
        ("I'll have it ready on 15 October", datetime(2026, 10, 15, 18)),
        ("consegna il 15/10", datetime(2026, 10, 15, 18)),
        ("by October 20th", datetime(2026, 10, 20, 18)),
        ("see you on Monday", datetime(2026, 10, 5, 18)),
        ("entro il 3 ti mando il preventivo", datetime(2026, 10, 3, 18)),
        ("il 2 gennaio", datetime(2027, 1, 2, 18)),
        ("Grazie mille per il supporto", None),
    ],
)
def test_due_dates_are_read_by_code(text, expected):
    assert cm.due_from_text(text, SENT) == expected


def test_only_the_new_part_of_a_reply_counts():
    body = "Perfetto, te lo mando domani.\n\nIl giorno 27 set 2026, Marco ha scritto:\n> Mi mandi il contratto?"
    assert cm.newest_part(body) == "Perfetto, te lo mando domani."


def sent_event(body, to="Marco Rossi <marco@studiorossi.it>", subject="Re: Contratto", message_id="<s1@x>"):
    return {"kind": "mail.sent", "ts": SENT.timestamp(), "app": "Mail",
            "payload": {"to": to, "subject": subject, "body": body, "message_id": message_id}}


def test_a_promise_is_found_phrased_and_dated(monkeypatch):
    monkeypatch.setattr(cm, "decide_many", scripted({"promises": True}))
    monkeypatch.setattr(cm, "supports_generation", lambda engine: True)
    monkeypatch.setattr(cm, "stream_text", lambda e, m, **kw: Generated("Mandare il contratto firmato.\nAltro", 6, 1, 1, False, "stop"))
    found = cm.find_promise(object(), sent_event("Ciao Marco, ti mando il contratto firmato entro venerdì. Buona giornata!"))
    assert found.what == "Mandare il contratto firmato"
    assert found.person == "Marco Rossi"
    assert found.address == "marco@studiorossi.it"
    assert datetime.fromtimestamp(found.due_ts) == datetime(2026, 10, 2, 18)
    assert found.source_id == "<s1@x>"


def test_no_promise_no_generation(monkeypatch):
    monkeypatch.setattr(cm, "decide_many", scripted({"promises": False}))
    monkeypatch.setattr(cm, "stream_text", lambda *a, **k: pytest.fail("must not generate"))
    assert cm.find_promise(object(), sent_event("Grazie Marco, ricevuto tutto. A presto!")) is None
    assert cm.find_promise(object(), sent_event("Ok!")) is None


def test_storage_update_listing_and_sweep(tmp_path):
    conn = open_db(tmp_path / "a.db")
    cm.ensure_schema(conn)
    now = SENT.timestamp()
    c = cm.Commitment(id="com_1", ts=now, person="Marco", address="m@x", what="Send the contract", due_ts=now + 86400,
                      source="mail.sent", source_id="<s1@x>", subject="Contratto")
    assert cm.save(conn, c)
    assert not cm.save(conn, c)  # the same sent message is never read twice
    assert cm.seen(conn, "<s1@x>")
    assert [i["what"] for i in cm.listing(conn)] == ["Send the contract"]
    assert cm.update(conn, "com_1", status="done", now=now)
    assert cm.listing(conn) == []
    assert cm.listing(conn, status=None)[0]["status"] == "done"
    with pytest.raises(ValueError):
        cm.update(conn, "com_1", status="forgotten")
    assert cm.sweep(conn, 30, now=now + 31 * 86400) == 1


@pytest.mark.asyncio
async def test_the_daemon_finds_lists_and_closes_promises(tmp_path, monkeypatch):
    monkeypatch.setattr(cm, "decide_many", scripted({"promises": True}))
    monkeypatch.setattr(cm, "supports_generation", lambda engine: True)
    monkeypatch.setattr(cm, "stream_text", lambda e, m, **kw: Generated("Send the signed contract", 5, 1, 1, False, "stop"))
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {**sent_event("Hi Marco, I'll send you the signed contract by Friday."), "t": "event", "id": "evt_s"})
        frames = [await recv_frame(reader) for _ in range(3)]
        found = next(f for f in frames if f["t"] == "commitment")
        assert found["item"]["what"] == "Send the signed contract"

        await send_frame(writer, {"t": "commitments.list", "id": "l1"})
        listing = await recv_frame(reader)
        assert listing["t"] == "commitments" and listing["request_id"] == "l1"
        [item] = listing["items"]

        await send_frame(writer, {"t": "commitment.update", "id": "u1", "commitment_id": item["id"], "status": "done"})
        after = await recv_frame(reader)
        assert after["items"] == []
        writer.close()


# ---------------------------------------------------------------- meetings

import leonardd.attention as attention_mod  # noqa: E402
from fake_engine import TrivialEngine  # noqa: E402
from leonardd import compose  # noqa: E402
from leonardd.attention import AttentionEngine  # noqa: E402
from leonardd.settings import Settings  # noqa: E402

MEETING = {
    "id": "evt_meeting",
    "kind": "calendar.upcoming",
    "app": "Calendar",
    "ts": SENT.timestamp(),
    "payload": {
        "title": "Revisione contratto Rossi",
        "start_ts": SENT.timestamp() + 600,
        "minutes_until": 10,
        "attendees": ["Marco Rossi <marco@studiorossi.it>", "Giulia Bianchi <giulia@studiorossi.it>"],
        "location": "Zoom",
        "notes": "Chiudere i punti aperti sul preventivo",
    },
}


def test_a_meeting_with_people_is_worth_a_brief(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", scripted({"worth_preparing": True}))
    decision = AttentionEngine(TrivialEngine(), settings=Settings()).decide_event(MEETING)
    assert decision["action"] == "suggest"
    assert decision["suggestion"]["action_id"] == "prepare_meeting"
    assert decision["suggestion"]["title"] == "Alle 10:10 con Marco Rossi e altri 1" or "Marco Rossi" in decision["suggestion"]["title"]


def test_a_focus_block_is_not(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", scripted({"worth_preparing": False}))
    decision = AttentionEngine(TrivialEngine(), settings=Settings()).decide_event(MEETING)
    assert decision["action"] == "ignore"


def test_the_brief_includes_what_was_promised_to_these_people():
    task = compose.for_action("prepare_meeting", MEETING, None, "it", promises=["Mandare il contratto firmato (Marco Rossi, 02/10)"])
    user = task.messages[1]["content"]
    assert "Revisione contratto Rossi" in user
    assert "Mandare il contratto firmato" in user
    assert "Italian" in task.messages[0]["content"]
    assert task.result_kind == "brief"


@pytest.mark.asyncio
async def test_open_promises_are_matched_to_attendees(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        cm.save(server.conn, cm.Commitment(id="c1", ts=SENT.timestamp(), person="Marco Rossi", address="marco@studiorossi.it",
                                           what="Send the signed contract", due_ts=None, source="mail.sent", source_id="s1",
                                           subject="x"))
        cm.save(server.conn, cm.Commitment(id="c2", ts=SENT.timestamp(), person="Anna", address="anna@else.com",
                                           what="Call back", due_ts=None, source="mail.sent", source_id="s2", subject="y"))
        assert server._promises_for(MEETING) == ["Send the signed contract (Marco Rossi)"]
