"""Socket-level tests for tasks: start, observe/act, steps, end, history, routing."""

import asyncio

import pytest
from server_helpers import recv_frame, running_server, send_frame
from test_agent import OBSERVATION, first_matching, scripted

import leonardd.agent as agent_mod
from leonardd import audit as audit_mod
from leonardd.generation import Generated

pytestmark = pytest.mark.asyncio


async def _connect(server):
    return await asyncio.open_unix_connection(str(server.socket_path))


def _plan_stream(text):
    def fake(engine, messages, **kwargs):
        return Generated(text, 5, 1.0, 1.0, False, "stop")

    return fake


async def test_a_task_end_to_end(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_mod, "supports_generation", lambda engine: True)
    monkeypatch.setattr(agent_mod, "stream_text", _plan_stream(" Open Spotify\n2. Search for Focus\n3. Play it"))
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await _connect(server)

        await send_frame(writer, {"t": "task.start", "id": "t1", "goal": "Play my Focus playlist", "app": "Finder",
                                  "apps": ["Spotify", "Music"]})
        plan = await recv_frame(reader)
        assert plan["t"] == "task.plan"
        assert plan["request_id"] == "t1"
        assert plan["steps"] == ["Open Spotify", "Search for Focus", "Play it"]
        task_id = plan["task_id"]

        monkeypatch.setattr(agent_mod, "decide_many",
                            scripted({"operation": "OPEN_APP", "target_app": first_matching("Spotify")}))
        await send_frame(writer, {**OBSERVATION, "t": "observe", "task_id": task_id})
        act = await recv_frame(reader)
        assert act["t"] == "act"
        assert (act["operation"], act["candidate_id"], act["task_id"]) == ("OPEN_APP", "a2", task_id)
        assert act["observation_id"] == "obs_1"

        await send_frame(writer, {"t": "task.step", "task_id": task_id, "step": 1, "operation": "OPEN_APP",
                                  "target": "Spotify", "outcome": "ok", "permission": "allowed", "confidence": 0.9,
                                  "digest": "d1"})
        await send_frame(writer, {"t": "task.end", "task_id": task_id, "status": "done"})
        await send_frame(writer, {"t": "tasks.recent", "id": "r1"})
        results = await recv_frame(reader)
        assert results["t"] == "tasks.results"
        [task] = results["tasks"]
        assert task["status"] == "done"
        assert task["goal"] == "Play my Focus playlist"
        assert [s["target"] for s in task["steps"]] == ["Spotify"]
        assert task_id not in server._task_sessions

        await send_frame(writer, {"t": "stats", "id": "s1"})
        stats = await recv_frame(reader)
        assert stats["tasks"]["tasks"] == 1 and stats["tasks"]["done"] == 1
        writer.close()


async def test_observe_for_an_unknown_task_is_an_error(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await _connect(server)
        await send_frame(writer, {**OBSERVATION, "t": "observe", "task_id": "task_nope"})
        error = await recv_frame(reader)
        assert error["t"] == "error"
        assert error["request_id"] == "obs_1"
        writer.close()


async def test_ask_routes_to_a_task_only_when_asked_to_route(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_mod, "decide_many", scripted({"route": "do"}, confidence=0.95))
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await _connect(server)
        await send_frame(writer, {"t": "ask", "id": "a1", "prompt": "metti Focus su Spotify", "mode": "ask", "route": True})
        answer = await recv_frame(reader)
        assert answer["t"] == "answer"
        assert answer["result_kind"] == "task"
        assert answer["mode"] == "do"
        assert answer["text"] == "metti Focus su Spotify"
        writer.close()


async def test_retention_and_delete_cover_tasks(tmp_path):
    conn = audit_mod.open_db(tmp_path / "a.db")
    audit_mod.record_task(conn, "old", "g", ["g"], ts=1000.0)
    audit_mod.record_task_step(conn, "old", {"step": 1, "ts": 1000.0, "operation": "CLICK", "outcome": "ok"})
    audit_mod.record_task(conn, "new", "g", ["g"])
    audit_mod.sweep(conn, 30)
    assert [t["id"] for t in audit_mod.recent_tasks(conn)] == ["new"]
    assert conn.execute("SELECT COUNT(*) FROM task_steps").fetchone()[0] == 0
    audit_mod.delete_all(conn)
    assert audit_mod.recent_tasks(conn) == []


async def test_step_outcomes_and_statuses_are_validated(tmp_path):
    conn = audit_mod.open_db(tmp_path / "a.db")
    audit_mod.record_task(conn, "t", "g", ["g"])
    with pytest.raises(ValueError):
        audit_mod.record_task_step(conn, "t", {"step": 1, "operation": "CLICK", "outcome": "exploded"})
    with pytest.raises(ValueError):
        audit_mod.end_task(conn, "t", "running")
