"""Conversations in any chat app: the same judgement as email, a chat-sized reply."""

from fake_engine import TrivialEngine
from test_agent import scripted

import leonardd.attention as attention_mod
from leonardd import compose
from leonardd.attention import AttentionEngine
from leonardd.settings import Settings

CHAT = {
    "id": "evt_chat",
    "kind": "message.opened",
    "app": "Slack",
    "ts": 1_790_000_000.0,
    "payload": {
        "sender": "Giulia Bianchi",
        "subject": "Slack: Giulia Bianchi",
        "body": "Giulia Bianchi 10:41\nHai visto il preventivo di Marco?\nGiulia Bianchi 10:42\nMi confermi entro stasera se possiamo procedere?",
        "new": True,
        "bundle_id": "com.tinyspeck.slackmacgap",
    },
}


def test_a_request_in_a_chat_is_worth_a_reply(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", scripted({"message_type": "personal_request", "urgency": 3}))
    engine = AttentionEngine(TrivialEngine(), settings=Settings())
    decision = engine.decide_event(CHAT)
    assert decision["action"] == "suggest"
    assert decision["suggestion"]["action_id"] == "draft_reply"
    assert "Giulia" in decision["suggestion"]["title"]
    assert decision["suggestion"]["detail"].startswith("Slack · ")


def test_a_channel_announcement_gets_nothing(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", scripted({"message_type": "broadcast", "urgency": 0}))
    engine = AttentionEngine(TrivialEngine(), settings=Settings())
    decision = engine.decide_event(CHAT)
    assert decision["action"] in ("ignore", "wait")
    assert "suggestion" not in decision


def test_chat_is_proactive_by_default_and_can_be_turned_off(monkeypatch):
    monkeypatch.setattr(attention_mod, "decide_many", scripted({"message_type": "personal_request", "urgency": 3}))
    assert "message.opened" in Settings().proactive_kinds
    engine = AttentionEngine(TrivialEngine(), settings=Settings(proactive_kinds=frozenset({"mail.opened"})))
    assert engine.decide_event(CHAT)["action"] == "ignore"


def test_the_reply_is_chat_sized_and_written_as_the_user():
    task = compose.draft_reply(CHAT, None, "it")
    system, user = task.messages[0]["content"], task.messages[1]["content"]
    assert "Slack conversation with Giulia Bianchi" in system
    assert "never as Giulia Bianchi" in system
    assert "One to three short sentences" in system
    assert "Mi confermi entro stasera" in user
    assert task.result_kind == "reply"
    assert task.prefix == ""
    assert task.max_tokens <= 200
