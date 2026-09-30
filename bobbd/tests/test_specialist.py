import json
import random
import time

import pytest
from fake_engine import TrivialEngine

import bobbd.attention as attention_mod
from bobbd import specialist as sp
from bobbd.attention import AttentionEngine
from bobbd.audit import open_db, record_decision, record_response
from bobbd.settings import Settings

NOW = 1_790_000_000.0


def mail(sender, subject, body, *, ts=NOW, message_id=None, thread_len=1):
    return {
        "id": f"evt_{random.random()}",
        "kind": "mail.opened",
        "app": "Mail",
        "ts": ts,
        "payload": {"sender": sender, "subject": subject, "body": body, "thread_len": thread_len, "unread": True,
                    "message_id": message_id or f"<{random.random()}@x>"},
    }


def decide(conn, event, *, action="ignore", confidence=0.9, abstained=False, decision_id=None, tier="general"):
    decision = {
        "id": decision_id or f"dec_{random.random()}",
        "event_id": event["id"],
        "ts": event["ts"],
        "action": action,
        "confidence": confidence,
        "schema_mass": 0.99,
        "latency_ms": 600.0,
        "hypotheses": [],
        "readouts": [{"q": "message_type"}],
        "abstained": abstained,
        "tier": tier,
    }
    record_decision(conn, decision, event, floor=0.6, model="m")
    return decision["id"]


def synthetic_user(conn, n=80, *, start=NOW - 40 * 86400):
    """A person who always ignores the newsletter and the shop, and always
    wants to hear from their client when she asks something."""
    rng = random.Random(3)
    for i in range(n):
        ts = start + i * 3600 * 8
        roll = rng.random()
        if roll < 0.45:
            event = mail("Techmeme <news@techmeme.com>", f"Techmeme daily {i}", "Top stories today in tech and AI.", ts=ts)
            d = decide(conn, event, action="suggest" if i % 7 == 0 else "ignore")
            if i % 7 == 0:
                record_response(conn, d, "dismiss", ts=ts + 60)
        elif roll < 0.6:
            event = mail("Shop <no-reply@shop.example>", f"Your order {i} has shipped", "Tracking number inside.", ts=ts)
            d = decide(conn, event, action="ignore")
            if i % 3 == 0:
                record_response(conn, d, "dismiss", ts=ts + 60)
        else:
            event = mail("Giulia Bianchi <giulia@studiorossi.it>", f"Contratto {i}",
                         "Ciao, mi confermi entro domani la versione finale?", ts=ts)
            d = decide(conn, event, action="suggest", confidence=0.8)
            record_response(conn, d, "approve", ts=ts + 60)


def test_features_are_stable_across_processes():
    # blake2b, not hash(): the same feature must land on the same weight tomorrow.
    assert sp._index("from:news@techmeme.com") == sp._index("from:news@techmeme.com")
    assert sp._index("bias") == 65716
    names = sp.feature_names(mail("Techmeme <news@techmeme.com>", "Re: Daily", "Is it?"))
    assert {"from:news@techmeme.com", "domain:techmeme.com", "from:automated", "subj:is_reply", "body:question"} <= set(names)


def test_normalized_subject_strips_reply_prefixes():
    assert sp.normalized_subject("Re: R: Fwd: Preventivo") == "preventivo"
    assert sp.normalized_subject("RIF: preventivo") == "preventivo"


def test_a_reply_started_labels_the_opened_message(tmp_path):
    conn = open_db(tmp_path / "a.db")
    event = mail("Marco Rossi <marco@studiorossi.it>", "Preventivo", "Mi confermi?", ts=NOW - 3600)
    d = decide(conn, event, action="wait", abstained=True)
    composing = {"kind": "mail.composing", "payload": {"to": "Marco Rossi <marco@studiorossi.it>", "subject": "Re: Preventivo"}}
    assert sp.record_implicit(conn, composing, now=NOW) == [d]
    [example] = sp.examples(conn, now=NOW)
    assert (example.y, example.source) == (1.0, "replied")
    assert example.is_personal


def test_a_quick_glance_is_a_weak_no_and_never_overrides_a_reply(tmp_path):
    conn = open_db(tmp_path / "a.db")
    event = mail("A <a@x.com>", "Hello", "hi", ts=NOW - 60, message_id="<m1@x>")
    d = decide(conn, event)
    closed = {"kind": "mail.closed", "payload": {"message_id": "<m1@x>", "dwell_ms": 1200, "still_unread": True}}
    assert sp.record_implicit(conn, closed, now=NOW) == [d]
    assert sp.examples(conn, now=NOW)[0].source == "glanced"
    conn.execute("UPDATE labels SET weight = 0.8, source = 'replied', label = 1")
    sp.record_implicit(conn, closed, now=NOW)
    assert sp.examples(conn, now=NOW)[0].source == "replied"


def test_its_own_verdicts_are_not_training_data(tmp_path):
    conn = open_db(tmp_path / "a.db")
    decide(conn, mail("A <a@x.com>", "x", "y"), tier="specialist")
    assert sp.examples(conn, now=NOW) == []


def test_explicit_answers_outrank_everything(tmp_path):
    conn = open_db(tmp_path / "a.db")
    d = decide(conn, mail("A <a@x.com>", "x", "y"), action="suggest")
    record_response(conn, d, "dismiss", reason="timeout")
    assert sp.examples(conn, now=NOW)[0].source == "timeout"
    record_response(conn, d, "approve")
    assert sp.examples(conn, now=NOW)[0].source == "user"


def test_too_few_answers_keeps_it_learning(tmp_path):
    conn = open_db(tmp_path / "a.db")
    synthetic_user(conn, n=20)
    model = sp.train(sp.examples(conn, now=NOW), now=NOW)
    assert not model.enabled
    assert "more answers" in model.metrics.reason


def test_it_learns_this_person_and_turns_itself_on(tmp_path):
    conn = open_db(tmp_path / "a.db")
    synthetic_user(conn, n=120)
    model = sp.train(sp.examples(conn, now=NOW), now=NOW)
    m = model.metrics
    assert m.personal_labels >= sp.MIN_USER_LABELS
    assert m.accuracy >= 0.9
    assert m.enabled, m.reason
    newsletter = mail("Techmeme <news@techmeme.com>", "Techmeme daily 999", "Top stories today in tech and AI.")
    client = mail("Giulia Bianchi <giulia@studiorossi.it>", "Contratto 999", "Ciao, mi confermi entro domani?")
    assert model.predict(newsletter) <= sp.QUIET_P
    assert model.predict(client) > 0.5
    assert model.metrics.train_ms < 5000


def test_save_and_load_round_trip(tmp_path):
    conn = open_db(tmp_path / "a.db")
    synthetic_user(conn, n=60)
    model = sp.train(sp.examples(conn, now=NOW), now=NOW)
    path = tmp_path / "specialists" / "attention.npz"
    model.save(path)
    loaded = sp.Specialist.load(path)
    event = mail("Techmeme <news@techmeme.com>", "Techmeme daily", "Top stories")
    assert loaded is not None
    assert loaded.predict(event) == pytest.approx(model.predict(event))
    assert loaded.metrics == model.metrics
    assert sp.Specialist.load(tmp_path / "missing.npz") is None


def test_routing_only_decides_alone_when_enabled_and_sure():
    model = sp.Specialist()
    model.weights[sp._index("from:news@techmeme.com")] = -40.0
    event = mail("Techmeme <news@techmeme.com>", "x", "y")
    assert sp.route(model, event).quiet is False  # not validated yet
    model.metrics.enabled = True
    route = sp.route(model, event, rng=random.Random(1))
    assert route.p <= sp.QUIET_P and (route.quiet or route.shadow)
    assert sp.route(model, {"kind": "text.selected", "payload": {}}) is None
    shadows = sum(sp.route(model, event, rng=random.Random(i)).shadow for i in range(2000))
    assert 50 < shadows < 150  # about 5%


def test_attention_skips_the_model_when_the_specialist_is_sure(monkeypatch):
    def boom(*args, **kwargs):
        raise AssertionError("tier 1 must not run")

    monkeypatch.setattr(attention_mod, "decide_many", boom)
    engine = AttentionEngine(TrivialEngine(), settings=Settings(proactive_kinds=frozenset({"mail.opened"})))
    model = sp.Specialist()
    model.weights[sp._index("from:news@techmeme.com")] = -40.0
    model.metrics.enabled = True
    engine.specialist = model
    monkeypatch.setattr(sp, "SHADOW_RATE", 0.0)
    decision = engine.decide_event(mail("Techmeme <news@techmeme.com>", "Daily", "Top stories"))
    assert decision["action"] == "ignore"
    assert decision["tier"] == "specialist"
    assert decision["specialist_p"] <= sp.QUIET_P
    assert decision["latency_ms"] < 50
    assert "learned" in decision["explanation"]


def test_turning_learning_off_turns_tier_zero_off(monkeypatch):
    calls = []

    def fake(engine, context, questions, **kw):
        calls.append(1)
        raise RuntimeError("stop here")

    monkeypatch.setattr(attention_mod, "decide_many", fake)
    engine = AttentionEngine(TrivialEngine(), settings=Settings(proactive_kinds=frozenset({"mail.opened"}), adaptive=False))
    model = sp.Specialist()
    model.weights[sp._index("from:news@techmeme.com")] = -40.0
    model.metrics.enabled = True
    engine.specialist = model
    with pytest.raises(RuntimeError):
        engine.decide_event(mail("Techmeme <news@techmeme.com>", "Daily", "Top stories"))
    assert calls == [1]


def test_snapshot_measures_agreement_and_speed(tmp_path):
    conn = open_db(tmp_path / "a.db")
    e1 = mail("A <a@x.com>", "x", "y", ts=time.time())
    decide(conn, e1, action="suggest")
    conn.execute("UPDATE decisions SET specialist_p = 0.9")
    e2 = mail("B <b@x.com>", "x", "y", ts=time.time())
    decide(conn, e2, action="ignore", tier="specialist")
    conn.execute("UPDATE decisions SET latency_ms = 0.4 WHERE tier = 'specialist'")
    conn.commit()
    snap = sp.snapshot(conn, None, since=time.time() - 3600)
    assert snap["decided_alone"] == 1
    assert snap["agreement_with_general"] == 1.0
    assert snap["alone_ms"] == pytest.approx(0.4)
    assert snap["state"] == "learning"
    json.dumps(snap)


@pytest.mark.asyncio
async def test_the_daemon_mints_and_reports_its_specialist(tmp_path, monkeypatch):
    import asyncio

    from server_helpers import recv_frame, running_server, send_frame

    async with running_server(tmp_path, monkeypatch) as server:
        server.specialist_path = tmp_path / "specialists" / "attention.npz"
        synthetic_user(server.conn, n=120, start=time.time() - 40 * 86400)
        server.maybe_train()
        for _ in range(200):
            if server.specialist is not None:
                break
            await asyncio.sleep(0.05)
        assert server.specialist is not None and server.specialist.enabled
        assert server.attention.specialist is server.specialist
        assert server.specialist_path.exists()

        reader, writer = await asyncio.open_unix_connection(str(server.socket_path))
        await send_frame(writer, {"t": "stats", "id": "s1", "days": 60})
        stats = await recv_frame(reader)
        assert stats["specialist"]["state"] == "active"
        assert stats["specialist"]["metrics"]["personal_labels"] >= sp.MIN_USER_LABELS
        writer.close()
