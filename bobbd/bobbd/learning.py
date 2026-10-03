"""Adaptive quiet: what Bobb learns from how the user answers it.

Two things, both small, both explainable in one sentence, both reversible by
the user. That is deliberately less than the personal specialist in
`specialist/` promises, because it is what the data supports on day three
rather than day thirty, and because a learning rule the user cannot read is
one they cannot trust.

1. **A personal floor per event kind.** If the user keeps dismissing
   suggestions of one kind, Bobb asks for more confidence before it
   speaks about that kind again; if they keep accepting, a little less. The
   approval rate is shrunk toward one half by a Beta(2, 2) prior, nothing
   moves before `MIN_EVIDENCE` explicit answers, and the result is clamped,
   so a bad week cannot silence Bobb entirely or make it chatty.

2. **Muted senders.** Three explicit dismissals of suggestions about one
   sender, with no approval in between, mute that sender. The user sees the
   rule in Mind and can undo it; undoing it restarts the count from zero
   rather than re-muting on the next message from the old evidence.

A suggestion that timed out on screen is weak evidence — the user may simply
not have looked — so it counts a quarter of an explicit dismissal and never
contributes to a mute.
"""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass

from .audit import sender_key

LOOKBACK_DAYS = 60
MIN_EVIDENCE = 6
TIMEOUT_WEIGHT = 0.25
MUTE_AFTER_DISMISSALS = 3
FLOOR_MIN = 0.40
FLOOR_MAX = 0.90
MAX_RAISE = 0.15
MAX_LOWER = 0.08


@dataclass(frozen=True)
class KindStats:
    kind: str
    approved: int
    dismissed: int
    expired: int

    @property
    def evidence(self) -> float:
        return self.approved + self.dismissed + TIMEOUT_WEIGHT * self.expired

    @property
    def approval_rate(self) -> float:
        """Posterior mean under a Beta(2, 2) prior."""
        return (self.approved + 2.0) / (self.evidence + 4.0)


@dataclass(frozen=True)
class MutedSender:
    sender: str
    dismissed: int
    since: float
    manual: bool = False

    @property
    def rule_id(self) -> str:
        return f"sender:{self.sender}"


def floor_offset(stats: KindStats) -> float:
    if stats.evidence < MIN_EVIDENCE:
        return 0.0
    rate = stats.approval_rate
    if rate < 0.5:
        return min(MAX_RAISE, 0.3 * (0.5 - rate))
    if rate > 0.6:
        return -min(MAX_LOWER, 0.2 * (rate - 0.6))
    return 0.0


class Personalizer:
    def __init__(self, conn: sqlite3.Connection, *, now: float | None = None):
        self.conn = conn
        self._kind_stats: dict[str, KindStats] = {}
        self._muted: dict[str, MutedSender] = {}
        self.refresh(now=now)

    # ---- state

    def refresh(self, *, now: float | None = None) -> None:
        now = now if now is not None else time.time()
        since = now - LOOKBACK_DAYS * 86400
        rows = self.conn.execute(
            """
            SELECT kind,
                   SUM(response = 'approve'),
                   SUM(response = 'dismiss' AND COALESCE(response_reason, 'user') = 'user'),
                   SUM(response = 'dismiss' AND response_reason = 'timeout')
            FROM decisions
            WHERE action = 'suggest' AND response IS NOT NULL AND ts >= ?
            GROUP BY kind
            """,
            (since,),
        ).fetchall()
        self._kind_stats = {
            kind: KindStats(kind, int(a or 0), int(d or 0), int(e or 0)) for kind, a, d, e in rows
        }

        overrides = {
            subject: (verdict, ts)
            for subject, verdict, ts in self.conn.execute("SELECT subject, verdict, ts FROM learned_overrides")
        }
        muted: dict[str, MutedSender] = {}
        sender_rows = self.conn.execute(
            """
            SELECT sender, response, response_reason, ts
            FROM decisions
            WHERE kind IN ('mail.opened', 'mail.reply_started') AND action = 'suggest' AND response IS NOT NULL
              AND sender IS NOT NULL AND ts >= ?
            ORDER BY ts
            """,
            (since,),
        ).fetchall()
        streaks: dict[str, tuple[int, float]] = {}
        for sender, response, reason, ts in sender_rows:
            override = overrides.get(f"sender:{sender}")
            if override and override[0] == "reset" and ts <= override[1]:
                continue
            count, first = streaks.get(sender, (0, ts))
            if response == "approve":
                streaks[sender] = (0, ts)
            elif (reason or "user") == "user":
                streaks[sender] = (count + 1, first if count else ts)
        for sender, (count, first) in streaks.items():
            if count >= MUTE_AFTER_DISMISSALS:
                muted[sender] = MutedSender(sender, count, first)
        for subject, (verdict, ts) in overrides.items():
            if verdict == "mute" and subject.startswith("sender:"):
                sender = subject.removeprefix("sender:")
                muted[sender] = MutedSender(sender, muted.get(sender, MutedSender(sender, 0, ts)).dismissed, ts, True)
        self._muted = muted

    # ---- queries

    def stats_for(self, kind: str) -> KindStats:
        return self._kind_stats.get(kind, KindStats(kind, 0, 0, 0))

    def personal_floor(self, kind: str, base_floor: float) -> float:
        return max(FLOOR_MIN, min(FLOOR_MAX, base_floor + floor_offset(self.stats_for(kind))))

    def muted_sender(self, event: dict) -> MutedSender | None:
        if event.get("kind") not in {"mail.opened", "mail.reply_started"}:
            return None
        sender = sender_key(event.get("payload"))
        return self._muted.get(sender) if sender else None

    @property
    def muted(self) -> list[MutedSender]:
        return sorted(self._muted.values(), key=lambda m: m.since, reverse=True)

    # ---- user control

    def mute(self, sender: str, *, now: float | None = None) -> None:
        self._set_override(f"sender:{sender.strip().lower()}", "mute", now)

    def forget(self, rule_id: str, *, now: float | None = None) -> bool:
        """Undo a learned or manual rule; evidence before now stops counting."""
        if not rule_id.startswith("sender:"):
            return False
        self._set_override(rule_id, "reset", now)
        return True

    def _set_override(self, subject: str, verdict: str, now: float | None) -> None:
        self.conn.execute(
            "INSERT OR REPLACE INTO learned_overrides (subject, verdict, ts) VALUES (?, ?, ?)",
            (subject, verdict, now if now is not None else time.time()),
        )
        self.conn.commit()
        self.refresh(now=now)

    def snapshot(self, base_floor: float) -> dict:
        kinds = []
        for kind, stats in sorted(self._kind_stats.items()):
            kinds.append(
                {
                    "kind": kind,
                    "approved": stats.approved,
                    "dismissed": stats.dismissed,
                    "expired": stats.expired,
                    "approval_rate": round(stats.approval_rate, 4),
                    "floor": round(self.personal_floor(kind, base_floor), 4),
                    "learning": stats.evidence >= MIN_EVIDENCE,
                }
            )
        return {
            "base_floor": base_floor,
            "kinds": kinds,
            "muted_senders": [
                {"rule_id": m.rule_id, "sender": m.sender, "dismissed": m.dismissed, "since": m.since, "manual": m.manual}
                for m in self.muted
            ],
        }


__all__ = ["Personalizer", "KindStats", "MutedSender", "floor_offset", "MIN_EVIDENCE"]
