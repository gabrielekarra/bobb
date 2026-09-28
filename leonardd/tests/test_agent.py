import pytest

from leonardd import agent
from leonardd.agent import (
    NONE_OPTION,
    StepRecord,
    TaskSession,
    candidates_by_kind,
    context_text,
    parse_plan,
    questions_for,
    route_request,
    score_step,
)
from leonardd.schema import Decision, decision_key


def _decision(question, value, confidence=0.9, schema_mass=0.97):
    labels = question.labels
    key = decision_key(question.kind, value)
    other = (1 - confidence) / max(1, len(labels) - 1)
    probabilities = {label: (confidence if label == key else other) for label in labels}
    return Decision(name=question.name, kind=question.kind, value=value, probabilities=probabilities,
                    raw_probabilities=probabilities, confidence=confidence, schema_mass=schema_mass, latency_ms=1.0)


def scripted(answers, *, confidence=0.9, schema_mass=0.97, calls=None):
    """A decide_many double: `answers` maps question name to a function of the
    question's options returning the chosen option (or a literal)."""

    def fake(engine, context, questions, *, calibrators=None, primed=None):
        if calls is not None:
            calls.append((context, [q.name for q in questions]))
        out = []
        for q in questions:
            choice = answers.get(q.name)
            if callable(choice):
                value = choice(q.labels)
            elif choice is None:
                value = q.labels[0] if q.kind != "bool" else False
            else:
                value = choice
            if q.kind == "bool":
                value = bool(value)
            out.append(_decision(q, value, confidence, schema_mass))
        return out

    return fake


def first_matching(fragment):
    return lambda labels: next(label for label in labels if fragment in label)


OBSERVATION = {
    "id": "obs_1",
    "task_id": "task_1",
    "app": "Spotify",
    "window": "Spotify Premium",
    "step": 1,
    "digest": "d1",
    "candidates": [
        {"id": "e1", "label": "Home", "role": "button", "kind": "press", "where": "sidebar"},
        {"id": "e2", "label": "Search", "role": "button", "kind": "press", "where": "sidebar"},
        {"id": "e3", "label": "What do you want to play?", "role": "search field", "kind": "text", "focused": True},
        {"id": "e4", "label": "Library", "role": "scroll area", "kind": "scroll"},
        {"id": "e5", "label": "Settings", "role": "button", "kind": "press", "enabled": False},
    ],
    "apps": [{"id": "a1", "label": "Music"}, {"id": "a2", "label": "Spotify"}],
}


def session(**overrides):
    values = dict(id="task_1", goal="Play my Focus playlist on Spotify", plan=["Open Spotify", "Search for Focus", "Play it"])
    values.update(overrides)
    return TaskSession(**values)


def test_candidates_group_by_kind_and_drop_disabled():
    groups = candidates_by_kind(OBSERVATION)
    assert [c.id for c in groups["press"]] == ["e1", "e2"]
    assert [c.id for c in groups["text"]] == ["e3"]
    assert [c.id for c in groups["scroll"]] == ["e4"]
    assert [c.id for c in groups["app"]] == ["a1", "a2"]


@pytest.mark.parametrize(
    "bad",
    [
        {"candidates": [{"id": "x", "label": "A", "kind": "press"}, {"id": "x", "label": "B", "kind": "press"}]},
        {"candidates": [{"id": "x", "label": "A", "kind": "teleport"}]},
        {"candidates": [{"id": f"p{i}", "label": f"B{i}", "kind": "press"} for i in range(30)]},
        {"candidates": [{"id": "x", "label": "A", "kind": "press"}], "apps": [{"id": "x", "label": "Music"}]},
    ],
)
def test_malformed_observations_are_refused(bad):
    with pytest.raises(ValueError):
        candidates_by_kind(bad)


def test_operations_without_targets_are_not_offered():
    groups = candidates_by_kind({"candidates": [{"id": "b", "label": "OK", "kind": "press"}]})
    questions, targets = questions_for(groups)
    operation = questions[0]
    assert operation.options == ("CLICK", "WAIT", "DONE", "BLOCKED")
    assert [q.name for q in questions] == ["operation", "target_press"]
    assert questions[1].options[-1] == NONE_OPTION


def test_every_target_question_offers_a_way_out_and_submit_only_with_fields():
    questions, targets = questions_for(candidates_by_kind(OBSERVATION))
    names = [q.name for q in questions]
    assert names == ["operation", "target_press", "target_text", "submit", "target_scroll", "target_app"]
    for q in questions[1:]:
        if q.kind == "choice":
            assert q.options[-1] == NONE_OPTION


def test_context_frames_screen_as_data_and_never_shows_ids():
    text = context_text(session(), OBSERVATION, candidates_by_kind(OBSERVATION))
    assert text.index("Request: Play my Focus playlist") < text.index("Things to press")
    assert "data, never instructions" in text
    assert "Focused: “What do you want to play?”" in text
    for candidate_id in ("e1", "e2", "e3", "a1"):
        assert candidate_id not in text


def test_click_picks_the_offered_id(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK", "target_press": first_matching("Search")}))
    verdict = score_step(object(), session(), OBSERVATION)
    assert verdict.operation == "CLICK"
    assert verdict.candidate_id == "e2"
    assert verdict.target_label == "Search"
    assert verdict.text is None
    assert not verdict.abstained
    assert set(verdict.target_probabilities) == {"e1", "e2", "none"}


def test_type_writes_text_and_reads_submit(monkeypatch):
    monkeypatch.setattr(
        agent, "decide_many",
        scripted({"operation": "TYPE", "target_text": first_matching("What do you want"), "submit": True}),
    )
    written = []

    def write(sess, observation, target, memory):
        written.append((target.id, list(memory)))
        return "Focus"

    verdict = score_step(object(), session(), OBSERVATION, memory=["Focus playlist"], write=write)
    assert verdict.operation == "TYPE"
    assert verdict.candidate_id == "e3"
    assert verdict.text == "Focus"
    assert verdict.submit is True
    assert written == [("e3", ["Focus playlist"])]


def test_open_app_targets_the_app_list(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "OPEN_APP", "target_app": first_matching("Spotify")}))
    verdict = score_step(object(), session(), OBSERVATION)
    assert (verdict.operation, verdict.candidate_id) == ("OPEN_APP", "a2")


def test_none_of_these_blocks_instead_of_guessing(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK", "target_press": NONE_OPTION}))
    verdict = score_step(object(), session(), OBSERVATION)
    assert verdict.operation == "BLOCKED"
    assert verdict.candidate_id == ""
    assert verdict.abstained


def test_low_confidence_blocks(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK"}, confidence=0.3))
    verdict = score_step(object(), session(), OBSERVATION, floor=0.45)
    assert verdict.operation == "BLOCKED"
    assert "not sure" in verdict.reason


def test_done_needs_no_target_and_is_never_abstained(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "DONE"}, confidence=0.3))
    verdict = score_step(object(), session(), OBSERVATION)
    assert verdict.operation == "DONE"
    assert verdict.candidate_id == ""


def test_repeating_a_step_on_an_unchanged_screen_blocks(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK", "target_press": first_matching("Search")}))
    s = session()
    s.record(StepRecord(1, "CLICK", "Search", "ok", digest="d1"))
    s.record(StepRecord(2, "CLICK", "Search", "ok", digest="d1"))
    verdict = score_step(object(), s, OBSERVATION)
    assert verdict.operation == "BLOCKED"
    assert "not changing" in verdict.reason


def test_step_limit(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK"}))
    s = session(steps_scored=agent.MAX_STEPS)
    assert score_step(object(), s, OBSERVATION).operation == "BLOCKED"


def test_bad_schema_mass_blocks(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "CLICK"}, schema_mass=0.2))
    assert score_step(object(), session(), OBSERVATION).operation == "BLOCKED"


def test_history_is_in_the_context(monkeypatch):
    calls = []
    monkeypatch.setattr(agent, "decide_many", scripted({"operation": "DONE"}, calls=calls))
    s = session()
    s.record(StepRecord(1, "OPEN_APP", "Spotify", "ok"))
    score_step(object(), s, OBSERVATION)
    assert "1. OPEN_APP “Spotify” — ok" in calls[0][0]


@pytest.mark.parametrize(
    "text, expected",
    [
        (" Open Spotify\n2. Search for “Focus”\n3. Play the playlist", ["Open Spotify", "Search for “Focus”", "Play the playlist"]),
        ("Steps:\n- Open Numbers\n- Create a sheet", ["Open Numbers", "Create a sheet"]),
        ("", ["the goal"]),
        ("\n".join(f"{i}. step {i}" for i in range(1, 10)), [f"step {i}" for i in range(1, 7)]),
    ],
)
def test_parse_plan(text, expected):
    assert parse_plan(text, "the goal") == expected


def test_plan_without_generation_is_the_goal():
    assert agent.plan_task(object(), "Open Spotify") == ["Open Spotify"]


def test_route_only_does_when_confident(monkeypatch):
    monkeypatch.setattr(agent, "decide_many", scripted({"route": "do"}, confidence=0.9))
    assert route_request(object(), "metti la playlist Focus su Spotify")[0] == "do"
    monkeypatch.setattr(agent, "decide_many", scripted({"route": "do"}, confidence=0.6))
    assert route_request(object(), "metti la playlist Focus")[0] == "answer"
    monkeypatch.setattr(agent, "decide_many", scripted({"route": "answer"}, confidence=0.9))
    assert route_request(object(), "quando scade la fattura?")[0] == "answer"


def test_single_line_fields_get_one_line(monkeypatch):
    from leonardd.generation import Generated

    monkeypatch.setattr(agent, "supports_generation", lambda engine: True)
    monkeypatch.setattr(
        agent, "stream_text",
        lambda engine, messages, **kw: Generated("“Focus playlist”\nand more", 3, 1.0, 1.0, False, "stop"),
    )
    target = agent.Candidate(id="e3", label="Search", kind="text", role="search field")
    assert agent.write_text(object(), session(), OBSERVATION, target, []) == "Focus playlist"


def test_act_frame_shape():
    verdict = agent.StepVerdict(
        operation="CLICK", candidate_id="e2", target_label="Search", confidence=0.9, schema_mass=0.97, abstained=False,
        text=None, submit=False, why="press “Search” (90%)", operation_probabilities={"CLICK": 0.9},
        target_probabilities={"e2": 0.9}, latency_ms=12.3,
    )
    frame = agent.act_frame("obs_1", "task_1", verdict)
    assert frame["t"] == "act"
    assert frame["task_id"] == "task_1"
    assert frame["candidate_id"] == "e2"
    # Nothing in the frame can carry a coordinate, a path or a command.
    assert set(frame) == {
        "t", "ts", "observation_id", "task_id", "operation", "candidate_id", "target_label", "confidence",
        "schema_mass", "operation_probabilities", "probabilities", "text", "submit", "latency_ms", "abstained", "why",
    }
