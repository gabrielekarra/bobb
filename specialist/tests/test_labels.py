from labels import (
    ARCHIVED_UNREAD_MAX_SECONDS,
    NEVER_OPENED_WINDOW_SECONDS,
    READ_ABANDONED_DWELL_MS,
    LabelResult,
    RULES,
    TimedEvent,
    label_event,
    rule_archived_unread,
    rule_calendar_after_reading,
    rule_delayed_reply,
    rule_never_opened,
    rule_read_and_abandoned,
    rule_replied_within_hour,
)

_OPENED = TimedEvent(
    ts=1_000.0,
    kind="mail.opened",
    app="Mail",
    payload={"sender": "Marco Bianchi <marco@work.it>", "subject": "Revisione urgente"},
    action="wait",
)

_ARRIVED = TimedEvent(
    ts=1_000.0,
    kind="mail.arrived",
    app="Mail",
    payload={"sender": "Newsletter <news@saas-tool.com>", "subject": "Le novita' del mese"},
    action="ignore",
)


def _composing(ts, to="marco@work.it", subject="Re: Revisione urgente"):
    return TimedEvent(ts=ts, kind="mail.composing", app="Mail", payload={"to": to, "subject": subject}, action="ignore")


def _closed(ts, *, dwell_ms=None, still_unread=None, sender="Marco Bianchi <marco@work.it>", subject="Revisione urgente"):
    payload = {"sender": sender, "subject": subject}
    if dwell_ms is not None:
        payload["dwell_ms"] = dwell_ms
    if still_unread is not None:
        payload["still_unread"] = still_unread
    return TimedEvent(ts=ts, kind="mail.closed", app="Mail", payload=payload, action="ignore")


def _mail_event(kind, ts, *, sender="Newsletter <news@saas-tool.com>", subject="Le novita' del mese"):
    return TimedEvent(ts=ts, kind=kind, app="Mail", payload={"sender": sender, "subject": subject}, action="ignore")


def test_replied_within_hour_fires_on_prompt_reply():
    result = rule_replied_within_hour(_OPENED, [_composing(_OPENED.ts + 300)])
    assert result == LabelResult(label="suggest", confidence=0.9, rule="replied_within_hour")


def test_replied_within_hour_does_not_fire_past_the_window():
    assert rule_replied_within_hour(_OPENED, [_composing(_OPENED.ts + 3601)]) is None


def test_replied_within_hour_does_not_fire_on_unrelated_thread():
    unrelated = _composing(_OPENED.ts + 60, to="someone.else@work.it", subject="Tutt'altro argomento")
    assert rule_replied_within_hour(_OPENED, [unrelated]) is None


def test_replied_within_hour_ignores_non_mail_opened_kind():
    other = TimedEvent(ts=1.0, kind="app.activated", app="Mail", payload={}, action="ignore")
    assert rule_replied_within_hour(other, [_composing(2.0)]) is None


def test_replied_within_hour_matches_on_thread_id_even_with_different_subject():
    original = TimedEvent(
        ts=1_000.0, kind="mail.opened", app="Mail",
        payload={"sender": "a@b.com", "subject": "hi", "thread_id": "t1"}, action="wait",
    )
    reply = TimedEvent(
        ts=1_100.0, kind="mail.composing", app="Mail",
        payload={"to": "someone.else@b.com", "subject": "totally different", "thread_id": "t1"}, action="ignore",
    )
    assert rule_replied_within_hour(original, [reply]) is not None


def test_delayed_reply_fires_between_one_hour_and_one_day():
    result = rule_delayed_reply(_OPENED, [_composing(_OPENED.ts + 7200)])
    assert result == LabelResult(label="wait", confidence=0.65, rule="delayed_reply")


def test_delayed_reply_does_not_fire_within_the_first_hour():
    assert rule_delayed_reply(_OPENED, [_composing(_OPENED.ts + 300)]) is None


def test_delayed_reply_does_not_fire_after_a_day():
    assert rule_delayed_reply(_OPENED, [_composing(_OPENED.ts + 90_000)]) is None


def test_calendar_after_reading_fires_within_window():
    calendar_event = TimedEvent(ts=_OPENED.ts + 60, kind="app.activated", app="Calendar", payload={}, action="ignore")
    result = rule_calendar_after_reading(_OPENED, [calendar_event])
    assert result == LabelResult(label="prepare", confidence=0.75, rule="calendar_after_reading")


def test_calendar_after_reading_ignores_unrelated_apps():
    other_event = TimedEvent(ts=_OPENED.ts + 60, kind="app.activated", app="Slack", payload={}, action="ignore")
    assert rule_calendar_after_reading(_OPENED, [other_event]) is None


def test_calendar_after_reading_respects_the_time_window():
    late = TimedEvent(ts=_OPENED.ts + 600, kind="app.activated", app="Calendar", payload={}, action="ignore")
    assert rule_calendar_after_reading(_OPENED, [late]) is None


def test_read_and_abandoned_fires_on_long_dwell_still_unread():
    result = rule_read_and_abandoned(_OPENED, [_closed(_OPENED.ts + 60, dwell_ms=45_000, still_unread=True)])
    assert result == LabelResult(label="wait", confidence=0.75, rule="read_and_abandoned")


def test_read_and_abandoned_abstains_when_dwell_ms_is_missing():
    assert rule_read_and_abandoned(_OPENED, [_closed(_OPENED.ts + 60, still_unread=True)]) is None


def test_read_and_abandoned_abstains_when_still_unread_is_missing():
    assert rule_read_and_abandoned(_OPENED, [_closed(_OPENED.ts + 60, dwell_ms=45_000)]) is None


def test_read_and_abandoned_does_not_fire_below_the_dwell_threshold():
    closed = _closed(_OPENED.ts + 60, dwell_ms=READ_ABANDONED_DWELL_MS - 1, still_unread=True)
    assert rule_read_and_abandoned(_OPENED, [closed]) is None


def test_read_and_abandoned_does_not_fire_when_it_was_read():
    closed = _closed(_OPENED.ts + 60, dwell_ms=45_000, still_unread=False)
    assert rule_read_and_abandoned(_OPENED, [closed]) is None


def test_read_and_abandoned_does_not_fire_if_a_reply_follows():
    closed = _closed(_OPENED.ts + 60, dwell_ms=45_000, still_unread=True)
    reply = _composing(_OPENED.ts + 1800)
    assert rule_read_and_abandoned(_OPENED, [closed, reply]) is None


def test_read_and_abandoned_ignores_non_mail_opened_kind():
    other = TimedEvent(ts=1.0, kind="app.activated", app="Mail", payload={}, action="ignore")
    closed = _closed(2.0, dwell_ms=45_000, still_unread=True)
    assert rule_read_and_abandoned(other, [closed]) is None


def test_archived_unread_fires_with_no_preceding_open():
    archived = _mail_event("mail.archived", _ARRIVED.ts + 500)
    result = rule_archived_unread(_ARRIVED, [archived])
    assert result == LabelResult(label="ignore", confidence=0.92, rule="archived_unread")


def test_archived_unread_fires_for_deleted_too():
    deleted = _mail_event("mail.deleted", _ARRIVED.ts + 500)
    assert rule_archived_unread(_ARRIVED, [deleted]) is not None


def test_archived_unread_does_not_fire_if_it_was_opened_first():
    opened = _mail_event("mail.opened", _ARRIVED.ts + 100)
    archived = _mail_event("mail.archived", _ARRIVED.ts + 500)
    assert rule_archived_unread(_ARRIVED, [opened, archived]) is None


def test_archived_unread_does_not_fire_on_an_unrelated_thread():
    archived = _mail_event("mail.archived", _ARRIVED.ts + 500, sender="someone@else.com", subject="other")
    assert rule_archived_unread(_ARRIVED, [archived]) is None


def test_archived_unread_respects_its_outer_bound():
    archived = _mail_event("mail.archived", _ARRIVED.ts + ARCHIVED_UNREAD_MAX_SECONDS + 1)
    assert rule_archived_unread(_ARRIVED, [archived]) is None


def test_archived_unread_ignores_non_mail_arrived_kind():
    assert rule_archived_unread(_OPENED, [_mail_event("mail.archived", _OPENED.ts + 10)]) is None


def test_never_opened_fires_once_the_window_fully_elapses():
    filler = TimedEvent(ts=_ARRIVED.ts + NEVER_OPENED_WINDOW_SECONDS + 10, kind="idle.entered", app="Mail", payload={})
    result = rule_never_opened(_ARRIVED, [filler])
    assert result == LabelResult(label="ignore", confidence=0.5, rule="never_opened")


def test_never_opened_abstains_if_the_window_has_not_elapsed_yet():
    filler = TimedEvent(ts=_ARRIVED.ts + NEVER_OPENED_WINDOW_SECONDS - 10, kind="idle.entered", app="Mail", payload={})
    assert rule_never_opened(_ARRIVED, [filler]) is None


def test_never_opened_abstains_with_no_subsequent_events():
    assert rule_never_opened(_ARRIVED, []) is None


def test_never_opened_does_not_fire_if_opened_within_the_window():
    opened = _mail_event("mail.opened", _ARRIVED.ts + 1000)
    filler = TimedEvent(ts=_ARRIVED.ts + NEVER_OPENED_WINDOW_SECONDS + 10, kind="idle.entered", app="Mail", payload={})
    assert rule_never_opened(_ARRIVED, [opened, filler]) is None


def test_never_opened_ignores_non_mail_arrived_kind():
    filler = TimedEvent(ts=_OPENED.ts + NEVER_OPENED_WINDOW_SECONDS + 10, kind="idle.entered", app="Mail", payload={})
    assert rule_never_opened(_OPENED, [filler]) is None


def test_label_event_abstains_when_no_rule_fires():
    unrelated = TimedEvent(ts=_OPENED.ts + 500, kind="window.changed", app="Safari", payload={}, action="ignore")
    assert label_event(_OPENED, [unrelated]) is None


def test_label_event_passes_through_a_single_firing_rule():
    result = label_event(_OPENED, [_composing(_OPENED.ts + 300)])
    assert result.label == "suggest"
    assert result.rule == "replied_within_hour"


def test_label_event_abstains_on_conflicting_rules():
    calendar_event = TimedEvent(ts=_OPENED.ts + 60, kind="app.activated", app="Calendar", payload={}, action="ignore")
    reply = _composing(_OPENED.ts + 300)
    assert rule_calendar_after_reading(_OPENED, [calendar_event, reply]) is not None
    assert rule_replied_within_hour(_OPENED, [calendar_event, reply]) is not None
    assert label_event(_OPENED, [calendar_event, reply]) is None


def test_label_event_honours_enabled_rules_subset():
    subsequent = [_composing(_OPENED.ts + 300)]
    assert label_event(_OPENED, subsequent, enabled_rules=("delayed_reply",)) is None
    assert label_event(_OPENED, subsequent, enabled_rules=("replied_within_hour",)) is not None


def test_label_event_rejects_unknown_rule_name():
    try:
        label_event(_OPENED, [], enabled_rules=("not_a_real_rule",))
    except ValueError:
        return
    raise AssertionError("expected ValueError for an unknown rule name")


def test_label_event_combines_agreeing_rules_on_the_same_thread():
    archived = _mail_event("mail.archived", _ARRIVED.ts + 500)
    filler = TimedEvent(ts=_ARRIVED.ts + NEVER_OPENED_WINDOW_SECONDS + 10, kind="idle.entered", app="Mail", payload={})
    result = label_event(_ARRIVED, [archived, filler])
    assert result.label == "ignore"
    assert result.confidence == 0.92
    assert result.rule == "archived_unread+never_opened"


def test_all_rules_are_registered():
    assert set(RULES) == {
        "replied_within_hour",
        "delayed_reply",
        "calendar_after_reading",
        "read_and_abandoned",
        "archived_unread",
        "never_opened",
    }
