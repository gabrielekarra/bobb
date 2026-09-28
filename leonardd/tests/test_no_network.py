import asyncio
import socket

import pytest
from server_helpers import mail_event, recv_frame, running_server, send_frame

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _forbid_non_unix_sockets(monkeypatch):
    """The daemon must bind no TCP port and open no outbound connection.

    `asyncio.start_unix_server` / `open_unix_connection` (used by the test
    client itself) both go through `socket.socket(AF_UNIX, ...)`, so allowing
    that family and raising on every other one lets a real decision cycle run
    while catching any accidental AF_INET/AF_INET6 socket anywhere in the path.
    """
    real_socket = socket.socket

    def guarded(family=socket.AF_INET, type=socket.SOCK_STREAM, proto=0, fileno=None):
        if family != socket.AF_UNIX:
            raise AssertionError(f"attempted to open a non-AF_UNIX socket: family={family!r}")
        return real_socket(family, type, proto, fileno)

    monkeypatch.setattr(socket, "socket", guarded)


async def test_full_decision_cycle_opens_no_non_unix_socket(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, mail_event("evt_net"))
        trace = await recv_frame(reader)
        assert trace["t"] == "trace"
        decision = await recv_frame(reader)
        assert decision["t"] == "decision"
        assert decision["event_id"] == "evt_net"
        writer.close()


async def test_frame_gate_cycle_opens_no_non_unix_socket(tmp_path, monkeypatch):
    import base64
    import io

    from PIL import Image

    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        image = Image.new("L", (32, 32), color=64)
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        data = base64.b64encode(buf.getvalue()).decode("ascii")
        await send_frame(writer, {"t": "frame", "ts": 0.0, "id": "evt_frame", "data": data})
        trace = await recv_frame(reader)
        assert trace["stage"] == "gate"
        writer.close()


async def test_memory_and_ask_open_no_non_unix_socket(tmp_path, monkeypatch):
    import leonardd.server as server_mod
    from leonardd.generation import Generated
    from leonardd.memory import MemoryStore

    def fake_stream(engine, messages, *, max_tokens, on_delta=None, cancel=None, temperature=0.3, prefix=""):
        on_delta("ok [1]")
        return Generated("ok [1]", 1, 1.0, 1.0, False, "stop")

    monkeypatch.setattr(server_mod, "supports_generation", lambda engine: True)
    monkeypatch.setattr(server_mod, "stream_text", fake_stream)
    async with running_server(tmp_path, monkeypatch) as server:
        server.memory = MemoryStore(tmp_path / "memory.db")
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "memory.observe", "app": "Mail", "window": "w",
                                  "text": "a message long enough to be remembered by leonard"})
        await send_frame(writer, {"t": "ask", "id": "q", "prompt": "what message was remembered?"})
        frames = [await recv_frame(reader) for _ in range(2)]
        assert frames[-1]["t"] == "answer" and frames[-1]["ok"] is True
        await send_frame(writer, {"t": "memory.search", "id": "s", "query": "message"})
        assert (await recv_frame(reader))["t"] == "memory.results"
        writer.close()
