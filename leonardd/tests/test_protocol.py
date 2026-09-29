import asyncio
import base64
import io

import pytest
from PIL import Image
from server_helpers import mail_event, recv_frame, running_server, send_frame

pytestmark = pytest.mark.asyncio


async def test_hello_round_trips_to_ready(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "hello", "ts": 0.0, "client": "LeonardApp", "version": "0.1"})
        reply = await recv_frame(reader)
        assert reply["t"] == "ready"
        assert reply["model"] == "trivial-protocol"
        assert reply["floor"] == pytest.approx(0.5)
        writer.close()


async def test_event_round_trips_to_trace_then_decision(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, mail_event("evt_1"))
        trace = await recv_frame(reader)
        assert trace["t"] == "trace"
        assert trace["stage"] == "attention"
        decision = await recv_frame(reader)
        assert decision["t"] == "decision"
        assert decision["event_id"] == "evt_1"
        assert decision["action"] in ("ignore", "wait", "prepare", "suggest")
        writer.close()


async def test_approve_after_suggest_triggers_prepared(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, mail_event("evt_2"))
        await recv_frame(reader)  # trace
        decision = await recv_frame(reader)
        assert decision["action"] == "suggest"  # fake engine always answers "suggest"

        await send_frame(writer, {"t": "approve", "ts": 0.0, "decision_id": decision["id"]})
        prepared = await recv_frame(reader)
        assert prepared["t"] == "prepared"
        assert prepared["decision_id"] == decision["id"]
        assert prepared["action_id"] == decision["suggestion"]["action_id"]
        writer.close()


async def test_approve_of_draft_reply_streams_a_generated_draft(tmp_path, monkeypatch):
    import leonardd.server as server_mod
    from leonardd.generation import Generated

    def fake_stream(engine, messages, *, max_tokens, on_delta=None, cancel=None, temperature=0.3, prefix=""):
        for piece in ("Ciao, ", "confermo ", "per venerdi."):
            on_delta(piece)
        return Generated("Ciao, confermo per venerdi.", 3, 5.0, 1.0, False, "stop")

    monkeypatch.setattr(server_mod, "supports_generation", lambda engine: True)
    monkeypatch.setattr(server_mod, "stream_text", fake_stream)

    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, mail_event("evt_draft"))
        await recv_frame(reader)  # trace
        decision = await recv_frame(reader)
        assert decision["suggestion"]["action_id"] == "draft_reply"

        await send_frame(writer, {"t": "approve", "ts": 0.0, "decision_id": decision["id"]})
        deltas = [await recv_frame(reader) for _ in range(3)]
        assert [d["t"] for d in deltas] == ["prepared.delta"] * 3
        assert "".join(d["text"] for d in deltas) == "Ciao, confermo per venerdi."
        prepared = await recv_frame(reader)
        assert prepared["t"] == "prepared"
        assert prepared["result"]["kind"] == "reply"
        assert prepared["result"]["body"] == "Ciao, confermo per venerdi."
        assert prepared["result"]["to"] == "Marco Rossi <marco@example.com>"
        writer.close()


async def test_dismiss_is_recorded_without_a_prepared_frame(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, mail_event("evt_3"))
        await recv_frame(reader)
        decision = await recv_frame(reader)

        await send_frame(writer, {"t": "dismiss", "ts": 0.0, "decision_id": decision["id"]})
        await send_frame(writer, {"t": "hello", "ts": 0.0})  # connection must still be alive
        reply = await recv_frame(reader)
        assert reply["t"] == "ready"
        writer.close()


async def test_policy_changes_the_floor(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch, floor=0.5) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "policy", "ts": 0.0, "floor": 0.9})
        await send_frame(writer, {"t": "hello", "ts": 0.0})
        reply = await recv_frame(reader)
        assert reply["floor"] == pytest.approx(0.9)
        assert server.attention.floor == pytest.approx(0.9)
        writer.close()


async def test_frame_round_trips_to_a_gate_trace(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        image = Image.new("L", (32, 32), color=128)
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        data = base64.b64encode(buf.getvalue()).decode("ascii")

        await send_frame(writer, {"t": "frame", "ts": 0.0, "id": "evt_frame", "data": data})
        trace = await recv_frame(reader)
        assert trace["t"] == "trace"
        assert trace["stage"] == "gate"
        assert trace["event_id"] == "evt_frame"
        writer.close()


async def test_unknown_frame_type_is_ignored_not_fatal(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "some_future_frame_type", "ts": 0.0, "payload": {"x": 1}})
        await send_frame(writer, {"t": "hello", "ts": 0.0})
        reply = await recv_frame(reader)
        assert reply["t"] == "ready"  # the unknown frame produced no reply and did not kill the connection
        writer.close()


async def test_malformed_json_produces_an_error_not_a_dropped_connection(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        writer.write(b"{this is not json\n")
        await writer.drain()
        reply = await recv_frame(reader)
        assert reply["t"] == "error"

        await send_frame(writer, {"t": "hello", "ts": 0.0})
        reply2 = await recv_frame(reader)
        assert reply2["t"] == "ready"
        writer.close()


async def test_multiple_sequential_clients_are_each_served(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        for i in range(3):
            reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
            await send_frame(writer, {"t": "hello", "ts": 0.0})
            reply = await recv_frame(reader)
            assert reply["t"] == "ready"
            writer.close()
            await writer.wait_closed()


async def test_socket_is_created_with_owner_only_permissions(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        mode = server.socket_path.stat().st_mode & 0o777
        assert mode == 0o600
