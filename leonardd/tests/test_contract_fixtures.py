"""Replay every frame the Swift app encodes into the real daemon.

`LeonardApp/Tests/LeonardCoreTests/Fixtures/app_frames.jsonl` is written by
`ContractFixtureTests.appFramesAreWrittenForTheDaemonToReplay`. If the app
encodes a frame the daemon cannot read, this fails with the frame named.
"""

import asyncio
import json
from pathlib import Path

import pytest
from server_helpers import fake_decide_many, recv_frame, running_server

import leonardd.agent as agent_mod

from leonardd.memory import MemoryStore



FIXTURE = Path(__file__).resolve().parents[2] / "LeonardApp" / "Tests" / "LeonardCoreTests" / "Fixtures" / "app_frames.jsonl"


def _frames():
    return [json.loads(line) for line in FIXTURE.read_text().splitlines() if line.strip()]


def test_fixture_exists_and_covers_the_v1_frames():
    kinds = {f["t"] for f in _frames()}
    assert {"hello", "settings", "memory.observe", "event", "ask", "cancel", "memory.search", "stats",
            "task.start", "observe", "task.step", "task.end", "tasks.recent"} <= kinds


@pytest.mark.asyncio
async def test_the_daemon_accepts_every_app_frame(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_mod, "decide_many", fake_decide_many)
    async with running_server(tmp_path, monkeypatch) as server:
        server.memory = MemoryStore(tmp_path / "memory.db")
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        for frame in _frames():
            writer.write((json.dumps(frame) + "\n").encode())
            await writer.drain()
        writer.write(b'{"t": "hello"}\n')
        await writer.drain()
        received = []
        while True:
            reply = await recv_frame(reader)
            received.append(reply)
            if reply["t"] == "ready" and len([r for r in received if r["t"] == "ready"]) == 2:
                break
        errors = [r for r in received if r["t"] == "error"]
        # The only acceptable error is the dismiss of a decision this test never made.
        assert [e["detail"] for e in errors] == ["unknown decision_id 'dec_unknown'"], errors
        settings = next(r for r in received if r["t"] == "settings")
        assert settings["locale"] in ("en", "it") and settings["quiet_hours"] is None
        assert any(r["t"] == "memory.results" for r in received)
        writer.close()
