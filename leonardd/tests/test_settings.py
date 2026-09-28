from leonardd import settings as settings_mod
from leonardd.settings import DEFAULT_PROACTIVE_KINDS, Settings, apply, is_protected, load, save


def test_defaults_are_conservative():
    s = Settings()
    assert s.floor == 0.60
    assert s.proactive_kinds == DEFAULT_PROACTIVE_KINDS
    assert "app.activated" not in s.proactive_kinds
    assert s.memory_retention_days == 30


def test_apply_keeps_valid_fields_and_drops_invalid_ones():
    s = apply(
        Settings(),
        {"floor": 0.7, "locale": "it", "memory_retention_days": -3, "quiet_hours": [22, 7], "unknown": 1},
    )
    assert s.floor == 0.7 and s.locale == "it" and s.quiet_hours == (22, 7)
    assert s.memory_retention_days == 30


def test_invalid_floor_and_locale_are_ignored():
    s = apply(Settings(), {"floor": 1.5, "locale": "xx"})
    assert s.floor == 0.60 and s.locale == "en"


def test_bools_are_not_numbers():
    assert apply(Settings(), {"floor": True}).floor == 0.60
    assert apply(Settings(), {"memory_retention_days": True}).memory_retention_days == 30


def test_quiet_hours_can_be_disabled_explicitly():
    s = apply(Settings(quiet_hours=(22, 7)), {"quiet_hours": None})
    assert s.quiet_hours is None


def test_quiet_hours_wrap_midnight():
    s = Settings(quiet_hours=(22, 7))
    assert s.in_quiet_hours(23) and s.in_quiet_hours(3)
    assert not s.in_quiet_hours(12)
    assert Settings(quiet_hours=(13, 14)).in_quiet_hours(13)
    assert not Settings().in_quiet_hours(3)


def test_protection_matches_bundle_id_or_name_and_user_additions():
    s = apply(Settings(), {"extra_protected_apps": ["com.intesasanpaolo.app"]})
    assert is_protected(s, app="1Password", bundle_id=None)
    assert is_protected(s, app="Whatever", bundle_id="com.bitwarden.desktop")
    assert is_protected(s, app="Intesa", bundle_id="com.intesasanpaolo.app")
    assert not is_protected(s, app="Mail", bundle_id="com.apple.mail")


def test_round_trips_through_disk_with_owner_only_permissions(tmp_path):
    path = tmp_path / "settings.json"
    s = apply(Settings(), {"floor": 0.72, "locale": "it", "memory_retention_days": 365})
    save(s, path)
    assert path.stat().st_mode & 0o777 == 0o600
    loaded = load(path)
    assert loaded.floor == 0.72 and loaded.locale == "it" and loaded.memory_retention_days == 365


def test_unreadable_file_falls_back_to_defaults(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text("{not json")
    assert load(path) == Settings()
    assert settings_mod.load(tmp_path / "missing.json") == Settings()
