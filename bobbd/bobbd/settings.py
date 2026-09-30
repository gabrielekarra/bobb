"""User-facing settings the daemon enforces.

The app is the source of truth: it sends a `settings` frame after every
`hello`, and the daemon applies it. The daemon also keeps the last settings it
applied on disk, because two of them — the retention windows — are enforced
by the daemon itself on startup, before any app has connected. Sweeping with
defaults instead of the user's own choice would delete history the user asked
to keep.

Every field is validated on the way in and an invalid value is dropped with
the rest of the frame still applied, rather than rejecting the frame: a
settings frame from a newer app that carries one field this daemon does not
understand must not undo the fields it does.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

logger = logging.getLogger("bobbd.settings")

SUPPORTED_LOCALES = ("en", "it")

# The two kinds whose readouts measured well enough to interrupt someone on.
# `app.activated`, `window.changed` and `text.selected` still reach the daemon
# and are still recorded, but by default they are never proactive: their only
# readouts are `Bool`s, which `bobbd/README.md` measured as yes-biased, and
# a yes-biased interruption is exactly the noise this product exists to avoid.
# Selection help lives in the command bar instead, where the user asked.
DEFAULT_PROACTIVE_KINDS = frozenset({"mail.opened", "mail.composing", "message.opened", "calendar.upcoming"})

# Never observed, never stored, never driven. Matched against bundle id and,
# as a fallback for apps that report none, the localized name. The app applies
# the same list before it reads anything; the daemon applies it again before
# it stores anything, so a sensor bug is not a leak.
DEFAULT_PROTECTED_APPS = frozenset(
    {
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "1Password",
        "Bitwarden",
        "Keychain Access",
        "Accesso Portachiavi",
        "Passwords",
        "Password",
        "KeePassXC",
    }
)


@dataclass(frozen=True)
class Settings:
    floor: float = 0.60
    locale: str = "en"
    proactive_kinds: frozenset[str] = DEFAULT_PROACTIVE_KINDS
    # Local-time hours [start, end). `None` disables. Wraps midnight when
    # start > end, e.g. (19, 8) is "evenings and nights".
    quiet_hours: tuple[int, int] | None = None
    adaptive: bool = True
    memory_enabled: bool = True
    memory_retention_days: int = 30
    history_retention_days: int = 90
    protected_apps: frozenset[str] = DEFAULT_PROTECTED_APPS
    extra_protected_apps: frozenset[str] = field(default_factory=frozenset)
    timezone: str = "UTC"
    # Legacy clients omit the field; Bobb always sends an explicit list.
    connected_apps: frozenset[str] | None = None

    @property
    def all_protected_apps(self) -> frozenset[str]:
        return self.protected_apps | self.extra_protected_apps

    def in_quiet_hours(self, hour: int) -> bool:
        if self.quiet_hours is None:
            return False
        start, end = self.quiet_hours
        if start == end:
            return False
        if start < end:
            return start <= hour < end
        return hour >= start or hour < end

    def to_frame(self) -> dict[str, Any]:
        return {
            "t": "settings",
            "floor": self.floor,
            "locale": self.locale,
            "proactive_kinds": sorted(self.proactive_kinds),
            "quiet_hours": list(self.quiet_hours) if self.quiet_hours else None,
            "adaptive": self.adaptive,
            "memory_enabled": self.memory_enabled,
            "memory_retention_days": self.memory_retention_days,
            "history_retention_days": self.history_retention_days,
            "extra_protected_apps": sorted(self.extra_protected_apps),
            "timezone": self.timezone,
            "connected_apps": sorted(self.connected_apps) if self.connected_apps is not None else None,
        }


def _valid_floor(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if 0.0 <= value <= 1.0 else None


def _valid_days(value: Any, lo: int = 1, hi: int = 3650) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if lo <= value <= hi else None


def _valid_hours(value: Any) -> tuple[int, int] | None | bool:
    """A pair, `None` (explicitly disabled), or `False` for invalid."""
    if value is None:
        return None
    if (
        isinstance(value, (list, tuple))
        and len(value) == 2
        and all(isinstance(h, int) and not isinstance(h, bool) and 0 <= h <= 23 for h in value)
    ):
        return (value[0], value[1])
    return False


def _valid_strings(value: Any) -> frozenset[str] | None:
    if not isinstance(value, (list, tuple)) or not all(isinstance(v, str) for v in value):
        return None
    return frozenset(v.strip() for v in value if v.strip())


def apply(settings: Settings, frame: dict[str, Any]) -> Settings:
    """`settings` with every valid field of `frame` applied."""
    changes: dict[str, Any] = {}
    if "floor" in frame and (floor := _valid_floor(frame["floor"])) is not None:
        changes["floor"] = floor
    if frame.get("locale") in SUPPORTED_LOCALES:
        changes["locale"] = frame["locale"]
    if isinstance(frame.get("timezone"), str):
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
        try:
            ZoneInfo(frame["timezone"])
            changes["timezone"] = frame["timezone"]
        except (ZoneInfoNotFoundError, ValueError):
            pass
    if "proactive_kinds" in frame and (kinds := _valid_strings(frame["proactive_kinds"])) is not None:
        changes["proactive_kinds"] = kinds
    if "quiet_hours" in frame and (hours := _valid_hours(frame["quiet_hours"])) is not False:
        changes["quiet_hours"] = hours
    for flag in ("adaptive", "memory_enabled"):
        if isinstance(frame.get(flag), bool):
            changes[flag] = frame[flag]
    if (days := _valid_days(frame.get("memory_retention_days"))) is not None:
        changes["memory_retention_days"] = days
    if (days := _valid_days(frame.get("history_retention_days"))) is not None:
        changes["history_retention_days"] = days
    if "extra_protected_apps" in frame and (apps := _valid_strings(frame["extra_protected_apps"])) is not None:
        changes["extra_protected_apps"] = apps
    if "connected_apps" in frame and (apps := _valid_strings(frame["connected_apps"])) is not None:
        changes["connected_apps"] = apps
    return replace(settings, **changes) if changes else settings


def load(path: Path) -> Settings:
    try:
        raw = json.loads(path.read_text("utf-8"))
    except FileNotFoundError:
        return Settings()
    except (OSError, ValueError) as exc:
        logger.warning("ignoring unreadable settings file: %s", exc)
        return Settings()
    return apply(Settings(), raw if isinstance(raw, dict) else {})


def save(settings: Settings, path: Path) -> None:
    frame = settings.to_frame()
    frame.pop("t", None)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(frame, indent=2, sort_keys=True), "utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def is_protected(settings: Settings, *, app: str | None, bundle_id: str | None) -> bool:
    protected = settings.all_protected_apps
    return bool((bundle_id and bundle_id in protected) or (app and app in protected)
                or (settings.connected_apps is not None
                    and bundle_id not in settings.connected_apps and app not in settings.connected_apps))


__all__ = [
    "Settings",
    "DEFAULT_PROACTIVE_KINDS",
    "DEFAULT_PROTECTED_APPS",
    "SUPPORTED_LOCALES",
    "apply",
    "load",
    "save",
    "is_protected",
]
