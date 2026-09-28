import math

from model import (
    ACTIONS,
    DEFAULT_CONFIG,
    SpecialistCollator,
    SpecialistExample,
    make_model,
    parameter_count,
    serialize_context,
)


def test_parameter_count_matches_cua_s1_forms_target():
    model, _ = make_model(DEFAULT_CONFIG)
    assert parameter_count(model) == 706_048


def test_serialize_context_field_order_and_truncation():
    event = {
        "kind": "mail.opened",
        "app": "Mail",
        "ts": 1_767_600_000.0,
        "user_state": "reading",
        "payload": {
            "sender": "Elena Conti <elena.conti@work.it>",
            "subject": "Revisione documento",
            "body": "Puoi dare un'occhiata entro oggi?",
            "thread_len": 3,
            "unread": True,
        },
    }
    text = serialize_context(event, history=[{"kind": "idle.left", "action": "ignore"}])
    lines = text.splitlines()
    assert lines[0] == "K mail.opened"
    assert lines[1] == "A Mail"
    assert lines[2].startswith("T h")
    assert lines[3] == "U reading"
    assert "F Elena Conti <elena.conti@work.it>" in lines
    assert "J Revisione documento" in lines
    assert "N thread_len=3 unread=1" in lines
    assert "H idle.left:ignore" in lines
    assert "B Puoi dare un'occhiata entro oggi?" in lines


def test_serialize_context_populates_sender_subject_for_mail_arrived():
    event = {
        "kind": "mail.arrived",
        "app": "Mail",
        "ts": 0.0,
        "payload": {"sender": "Marco Bianchi <marco@work.it>", "subject": "Urgente", "body": "..."},
    }
    text = serialize_context(event)
    assert "F Marco Bianchi <marco@work.it>" in text.splitlines()
    assert "J Urgente" in text.splitlines()


def test_serialize_context_clips_long_free_text():
    event = {
        "kind": "mail.opened",
        "app": "Mail",
        "ts": 0.0,
        "payload": {"sender": "a@b.com", "subject": "x", "body": "y" * 500},
    }
    text = serialize_context(event)
    body_line = next(line for line in text.splitlines() if line.startswith("B "))
    assert len(body_line) <= 82


def test_serialize_context_is_deterministic():
    event = {"kind": "app.activated", "app": "Safari", "ts": 100.0, "payload": {"previous_app": "Mail"}}
    assert serialize_context(event) == serialize_context(event)


def test_collator_shapes_and_fixed_option_count():
    _, collator = make_model(DEFAULT_CONFIG)
    examples = [
        SpecialistExample(context="K mail.opened\nA Mail", label=0),
        SpecialistExample(context="K app.activated\nA Safari", label=3),
    ]
    batch = collator(examples)
    assert batch["option_ids"].shape[0] == 2
    assert batch["option_ids"].shape[1] == len(ACTIONS)
    assert batch["option_mask"].all()
    assert batch["labels"].tolist() == [0, 3]


def test_forward_pass_produces_one_logit_per_action():
    model, collator = make_model(DEFAULT_CONFIG)
    examples = [SpecialistExample(context=serialize_context({"kind": "mail.opened", "ts": 0.0}), label=1)]
    logits = model(collator(examples))
    assert logits.shape == (1, len(ACTIONS))
    assert not math.isnan(float(logits.detach().sum()))


def test_specialist_example_rejects_out_of_range_label():
    try:
        SpecialistExample(context="x", label=len(ACTIONS))
    except ValueError:
        return
    raise AssertionError("expected ValueError for out-of-range label")
