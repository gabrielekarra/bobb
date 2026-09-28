"""Learning how things are done on this Mac, by watching."""

import asyncio

import pytest
from server_helpers import recv_frame, running_server, send_frame
from test_agent import OBSERVATION, first_matching, scripted

import leonardd.agent as agent_mod
import leonardd.procedures as pm
from leonardd import audit as audit_mod
from leonardd.agent import TaskSession, candidates_by_kind, context_text
from leonardd.audit import open_db
from leonardd.generation import Generated


def test_similar_requests_match_and_different_ones_do_not():
    assert pm.similarity("metti la playlist Focus su Spotify", "metti Focus su Spotify") >= pm.PLAN_MATCH
    assert pm.similarity("Put on my Focus playlist", "put on the focus playlist please") >= pm.PLAN_MATCH
    assert pm.similarity("metti Focus su Spotify", "scrivi a Giulia su Slack") < pm.GUIDE_MATCH


def test_steps_are_cleaned_and_a_newer_way_replaces_the_old(tmp_path):
    conn = open_db(tmp_path / "a.db")
    pm.ensure_schema(conn)
    first = pm.record(conn, "metti Focus su Spotify", [
        {"operation": "OPEN_APP", "target": "Spotify"},
        {"operation": "OPEN_APP", "target": "Spotify"},
        {"operation": "WAIT"},
        {"operation": "TYPE", "target": "Search", "text": "Focus", "app": "Spotify"},
        {"operation": "rm -rf /", "target": "x"},
    ], source="task")
    assert [s["operation"] for s in first.steps] == ["OPEN_APP", "TYPE"]
    assert first.lines("it") == ["Apri “Spotify”", "Scrivi in “Search” (Spotify): “Focus”"]
    pm.record(conn, "metti Focus su Spotify", [{"operation": "OPEN_APP", "target": "Spotify"}], source="demonstration")
    [only] = pm.all_procedures(conn)
    assert only.source == "demonstration"
    assert pm.record(conn, "   ", [{"operation": "CLICK", "target": "x"}], source="task") is None


def test_a_guide_appears_in_every_step_context():
    session = TaskSession(id="t", goal="metti Focus su Spotify", plan=["Apri Spotify"], guide=["Apri “Spotify”", "Premi “Focus Flow”"])
    text = context_text(session, OBSERVATION, candidates_by_kind(OBSERVATION))
    assert "How this was done before on this Mac" in text
    assert "2. Premi “Focus Flow”" in text


@pytest.mark.asyncio
async def test_a_done_task_is_learned_and_its_procedure_becomes_the_next_plan(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_mod, "supports_generation", lambda engine: True)
    generated = []

    def fake_stream(engine, messages, **kw):
        generated.append(messages)
        return Generated(" Open Spotify\n2. Play Focus", 5, 1, 1, False, "stop")

    monkeypatch.setattr(agent_mod, "stream_text", fake_stream)
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "task.start", "id": "s1", "task_id": "task_a", "goal": "Put on my Focus playlist on Spotify"})
        first = await recv_frame(reader)
        assert first["learned"] is False and len(generated) == 1
        for step, (op, target) in enumerate([("OPEN_APP", "Spotify"), ("CLICK", "Focus Flow")], 1):
            await send_frame(writer, {"t": "task.step", "task_id": "task_a", "step": step, "operation": op, "target": target,
                                      "app": "Spotify", "outcome": "ok"})
        await send_frame(writer, {"t": "task.end", "task_id": "task_a", "status": "done"})

        await send_frame(writer, {"t": "task.start", "id": "s2", "task_id": "task_b", "goal": "put on the Focus playlist on Spotify"})
        second = await recv_frame(reader)
        assert second["learned"] is True
        assert second["steps"] == ["Open “Spotify”", "Press “Focus Flow” (Spotify)"]
        assert len(generated) == 1  # no second plan was generated
        assert server._task_sessions["task_b"].guide == second["steps"]

        await send_frame(writer, {"t": "procedures.list", "id": "l1"})
        listing = await recv_frame(reader)
        assert listing["items"][0]["uses"] == 1
        await send_frame(writer, {"t": "procedure.delete", "id": "d1", "procedure_id": listing["items"][0]["id"]})
        assert (await recv_frame(reader))["items"] == []
        writer.close()


@pytest.mark.asyncio
async def test_a_demonstration_is_recorded(tmp_path, monkeypatch):
    async with running_server(tmp_path, monkeypatch) as server:
        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "procedure.record", "id": "r1", "goal": "archivia le fatture",
                                  "steps": [{"operation": "OPEN_APP", "target": "Finder"},
                                            {"operation": "CLICK", "target": "Downloads", "app": "Finder"}]})
        reply = await recv_frame(reader)
        assert reply["t"] == "procedure.recorded"
        assert reply["procedure"]["source"] == "demonstration"
        assert len(reply["procedure"]["steps"]) == 2
        writer.close()
