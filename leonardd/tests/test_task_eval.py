"""The any-app fixture is well formed: every observation is one the daemon
accepts, and every accepted answer names something that was offered."""

import pytest

from leonardd import agent, task_eval


@pytest.mark.parametrize("case", task_eval.FIXTURE, ids=lambda c: c.id)
def test_fixture_case_is_answerable(case):
    groups = agent.candidates_by_kind(case.observation())
    offered = {kind: {c.id for c in items} for kind, items in groups.items()}
    assert case.accept
    for operation, targets in case.accept:
        assert operation in agent.available_operations(groups), (case.id, operation)
        kind = agent.TARGET_KIND.get(operation)
        if kind is None:
            assert targets == ()
        else:
            assert targets and set(targets) <= offered[kind], (case.id, operation, targets)


def test_fixture_covers_every_kind_of_work():
    families = {c.family for c in task_eval.FIXTURE}
    for family in ("files", "spreadsheet", "documents", "browser", "web form", "code", "terminal", "notes",
                   "calendar", "system settings", "viewer", "media", "presentation", "photos", "pixels",
                   "between apps", "dialogs", "menus"):
        assert family in families
    operations = {op for c in task_eval.FIXTURE for op, _ in c.accept}
    assert {"CLICK", "OPEN", "TYPE", "KEY", "SCROLL_DOWN", "OPEN_APP", "DONE"} <= operations
    assert len({c.id for c in task_eval.FIXTURE}) == len(task_eval.FIXTURE)


def test_judge():
    case = task_eval.FIXTURE[0]
    right = agent.StepVerdict("OPEN", "f2", "Contratto Rossi.pdf", 0.9, 1, False, None, False, "", {}, {}, 1)
    wrong = agent.StepVerdict("OPEN", "f1", "Bilancio", 0.9, 1, False, None, False, "", {}, {}, 1)
    stopped = agent.StepVerdict("BLOCKED", "", "", 0.2, 1, True, None, False, "", {}, {}, 1)
    assert [task_eval.judge(case, v) for v in (right, wrong, stopped)] == ["right", "wrong", "stopped"]
