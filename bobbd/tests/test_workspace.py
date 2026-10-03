import json
import sqlite3
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from bobbd.workspace import Workspace, next_due, schedule


@pytest.fixture
def workspace(tmp_path):
    conn = sqlite3.connect(tmp_path / "work.db")
    yield Workspace(conn)
    conn.close()


def job(w, **changes):
    return w.put("job", {"name": "Check", "agent_id": "bobb", "goal": "Check the page and report",
                         "surface": "browser", "url": "https://example.test", "enabled": True,
                         "schedule": {"kind": "once", "at": 100}, **changes}, now=90)


def test_schedule_coalesces_and_does_not_queue_twice(workspace):
    j = job(workspace)
    workspace.tick(now=1000)
    workspace.tick(now=1001)
    assert len(workspace.snapshot()["runs"]) == 1
    assert workspace.get("job", j["id"])["next_due"] is None


def test_same_mcp_computer_is_serialized_across_agents(workspace):
    workspace.put("agent", {"id": "other", "name": "Other"})
    job(workspace, id="first", surface="mcp", url="virtual-mac")
    job(workspace, id="second", surface="mcp", url="virtual-mac", agent_id="other")
    workspace.tick(now=101)
    first = workspace.claim("one", now=102)
    assert first is not None
    assert workspace.claim("two", now=103) is None
    workspace.update_run(first["id"], "one", "done", now=104)
    assert workspace.claim("two", now=105) is not None


def test_recurring_schedule_uses_local_calendar_across_spring_dst():
    s = schedule({"kind": "daily", "hour": 9, "minute": 0, "timezone": "Europe/Rome"})
    before = datetime(2026, 3, 28, 9, 0, tzinfo=ZoneInfo("Europe/Rome")).timestamp()
    assert next_due(s, before) - before == 23 * 3600


def test_nonexistent_time_shifts_forward_and_autumn_time_runs_once():
    zone = ZoneInfo("Europe/Rome")
    s = schedule({"kind": "daily", "hour": 2, "minute": 30, "timezone": "Europe/Rome"})
    before = datetime(2026, 3, 29, 0, 0, tzinfo=zone).timestamp()
    assert datetime.fromtimestamp(next_due(s, before), zone).hour == 3
    first = datetime(2026, 10, 25, 2, 30, tzinfo=zone).timestamp()
    assert datetime.fromtimestamp(next_due(s, first), zone).date().isoformat() == "2026-10-26"


@pytest.mark.parametrize("raw", [None, {}, {"kind": "once", "at": float("nan")}, {"kind": "once", "at": True},
    {"kind": "daily", "hour": 9, "minute": 0, "timezone": "Unknown"},
    {"kind": "weekly", "hour": 9, "minute": 0, "weekday": 7, "timezone": "UTC"}])
def test_malformed_schedules_are_rejected(raw):
    with pytest.raises(ValueError):
        schedule(raw)


def test_weekly_next_due_stays_on_the_same_weekday():
    s = schedule({"kind": "weekly", "hour": 9, "minute": 0, "weekday": 0, "timezone": "UTC"})
    monday = datetime(2026, 9, 28, 9, 0, tzinfo=ZoneInfo("UTC")).timestamp()
    assert next_due(s, monday) == monday + 7 * 86400


def test_only_one_run_per_agent_and_one_physical_desktop(workspace):
    workspace.put("agent", {"id": "other", "name": "Other"})
    job(workspace, surface="desktop", url="", id="a")
    job(workspace, surface="desktop", url="", agent_id="other", id="b")
    job(workspace, agent_id="other", id="c")
    workspace.tick(now=101)
    first = workspace.claim("one", now=102)
    assert first is not None
    second = workspace.claim("two", now=103)
    assert second is None
    assert workspace.claim("three", now=104) is None


def test_user_browsers_share_the_desktop_and_cannot_run_while_it_is_unavailable(workspace):
    workspace.put("agent", {"id": "other", "name": "Other"})
    job(workspace, id="a")
    job(workspace, id="b", agent_id="other")
    workspace.tick(now=101)
    assert workspace.claim("executor", desktop_available=False, now=102) is None
    first = workspace.claim("executor", desktop_available=True, now=103)
    assert first["surface"] == "browser"
    assert workspace.claim("executor", desktop_available=True, now=104) is None
    workspace.update_run(first["id"], "executor", "done", "Observed result", now=105)
    assert workspace.claim("executor", desktop_available=True, now=106)["surface"] == "browser"


def test_disabled_jobs_are_not_claimed_even_if_previously_queued(workspace):
    j = job(workspace)
    workspace.tick(now=101)
    workspace.put("job", {**j, "enabled": False}, now=102)
    assert workspace.claim("executor", now=103) is None


def test_explicit_run_does_not_claim_an_unrelated_job(workspace):
    j = job(workspace)
    workspace.tick(now=101)
    result = workspace.command({"op": "run", "payload": {"goal": "Read another page", "agent_id": "bobb", "surface": "browser", "url": "https://other.test"}})
    run = workspace.claim("executor", run_id=result["result"])
    assert run["goal"] == "Read another page"
    assert run["source_id"] is None
    assert workspace.get("job", j["id"])


def test_executor_ownership_is_enforced(workspace):
    job(workspace); workspace.tick(now=101)
    run = workspace.claim("owner", now=102)
    with pytest.raises(ValueError):
        workspace.update_run(run["id"], "intruder", "done")
    workspace.update_run(run["id"], "owner", "done", "Read and verified", now=103)
    assert workspace.snapshot()["runs"][0]["report"] == "Read and verified"


def test_expired_lease_does_not_replay_a_side_effect(workspace):
    job(workspace); workspace.tick(now=101)
    run = workspace.claim("owner", now=102)
    workspace.tick(now=403)
    assert workspace.snapshot()["runs"][0]["status"] == "interrupted"
    assert workspace.claim("owner", now=404) is None
    workspace.retry(run["id"])
    retried = workspace.claim("owner", now=405)
    assert retried["task_id"] != run["task_id"]  # audit of the old attempt survives


def test_restart_marks_running_and_permission_waiting_as_interrupted(workspace):
    job(workspace); workspace.tick(now=101)
    run = workspace.claim("owner", now=102)
    workspace.update_run(run["id"], "owner", "waiting", "Review Send", now=103)
    recovered = Workspace(workspace.conn, recover=True)
    assert recovered.snapshot()["runs"][0]["status"] == "interrupted"
    assert recovered.claim("owner", now=104) is None


def test_project_advances_only_after_a_subtask_is_verified_done(workspace):
    project = workspace.put("project", {"name": "A project", "goal": "Finish", "agent_id": "bobb", "surface": "desktop", "url": "",
                                        "enabled": True, "steps": ["Inspect", "Implement", "Test"]})
    workspace.tick(now=100)
    first = workspace.claim("owner", now=101)
    assert first["goal"] == "Inspect"
    workspace.update_run(first["id"], "owner", "waiting", "Need a decision", now=102)
    workspace.tick(now=103)
    assert len(workspace.snapshot()["runs"]) == 1
    workspace.retry(first["id"])
    retried = workspace.claim("owner", now=104)
    workspace.update_run(retried["id"], "owner", "done", "Inspected", now=105)
    workspace.tick(now=106)
    assert workspace.claim("owner", now=107)["goal"] == "Implement"
    with pytest.raises(ValueError):
        workspace.put("project", {**project, "steps": ["A changed plan"]})


def test_events_are_deduplicated_and_coalesced(workspace):
    job(workspace, schedule={"kind": "event", "event": "mail.opened"})
    workspace.event("mail.opened", "mail1", now=100)
    workspace.event("mail.opened", "mail1", now=101)
    workspace.event("mail.opened", "mail2", now=102)
    workspace.event("message.opened", "chat1", now=103)
    assert len(workspace.snapshot()["runs"]) == 1


def test_routines_require_three_different_weeks_and_remain_proposals(workspace):
    monday = datetime(2026, 9, 7, 9, 0, tzinfo=ZoneInfo("Europe/Rome")).timestamp()
    for index in range(3):
        workspace.remember_routine(str(index), "Review my inbox", now=monday + index * 7 * 86400, timezone="Europe/Rome")
    routines = workspace.snapshot()["routines"]
    assert len(routines) == 1 and routines[0]["samples"] == 3
    assert workspace.entities("job") == []
    workspace.command({"op": "dismiss_routine", "payload": {"id": routines[0]["id"]}})
    workspace.remember_routine("fourth", "Review my inbox", now=monday + 21 * 86400, timezone="Europe/Rome")
    assert workspace.snapshot()["routines"] == []


def test_repeating_a_task_on_one_day_is_not_a_weekly_routine(workspace):
    for index in range(10):
        workspace.remember_routine(str(index), "Review inbox", now=1_800_000_000 + index)
    assert workspace.snapshot()["routines"] == []


def test_entities_validate_agents_and_urls(workspace):
    with pytest.raises(ValueError): job(workspace, agent_id="missing")
    with pytest.raises(ValueError): job(workspace, url="file:///private")
    with pytest.raises(ValueError): job(workspace, url="javascript:alert(1)")
    with pytest.raises(ValueError): workspace.delete("agent", "missing")
    job(workspace)
    with pytest.raises(ValueError): workspace.delete("agent", "bobb")


@pytest.mark.asyncio
async def test_workspace_protocol_without_a_loaded_model(tmp_path):
    from bobbd.audit import open_db
    from bobbd.server import BobbServer
    conn = open_db(tmp_path / "audit.db")
    server = BobbServer(None, conn)
    class Client:
        frames = []
        async def send(self, frame): self.frames.append(frame)
    client = Client()
    await server._dispatch(json.dumps({"t": "bobb.command", "id": "w1", "op": "list"}).encode(), client)
    assert client.frames[-1]["t"] == "bobb.state"
    assert client.frames[-1]["request_id"] == "w1"
    assert client.frames[-1]["agents"][0]["name"] == "Bobb"
    await server._dispatch(json.dumps({"t": "bobb.command", "id": "bad", "op": "put", "payload": {}}).encode(), client)
    assert client.frames[-1]["t"] == "error" and client.frames[-1]["request_id"] == "bad"
    server.close()


def test_late_heartbeat_does_not_resurrect_or_erase_a_finished_run(workspace):
    job(workspace)
    workspace.tick(now=100)
    run = workspace.claim("mac")
    workspace.update_run(run["id"], "mac", "done", "verified")
    workspace.command({"op": "heartbeat", "payload": {"id": run["id"], "owner": "mac"}})
    persisted = workspace.snapshot()["runs"][0]
    assert persisted["status"] == "done"
    assert persisted["report"] == "verified"
    assert persisted["owner"] is None


def test_next_project_step_receives_completed_evidence(workspace):
    workspace.put("project", {"id": "p", "name": "Release", "agent_id": "bobb", "goal": "Release the app",
                            "steps": ["Build", "Review"], "surface": "desktop", "url": "", "enabled": True})
    workspace.tick()
    first = workspace.claim("mac")
    workspace.update_run(first["id"], "mac", "done", "Build succeeded at commit abc")
    workspace.tick()
    second = workspace.claim("mac")
    assert second["goal"] == "Review"
    assert "Release the app" in second["context"]
    assert "Build succeeded at commit abc" in second["context"]


def test_retry_carries_previous_report_and_cannot_delete_last_agent(workspace):
    with pytest.raises(ValueError, match="at least one"):
        workspace.delete("agent", "bobb")
    job(workspace)
    workspace.tick(now=100)
    first = workspace.claim("mac")
    workspace.update_run(first["id"], "mac", "interrupted", "Confirmation may already have been sent")
    workspace.retry(first["id"])
    second = workspace.claim("mac")
    assert second["task_id"] != first["task_id"]
    assert "Confirmation may already have been sent" in second["context"]
    assert "Never repeat" in second["context"]
