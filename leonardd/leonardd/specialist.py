"""Tier 0: the personal specialist, minted on the user's own Mac.

VISION rules 3 and 5: Leonard learns by watching, and the decision that
runs on every event should be tiny and fast. This module fits, from one
user's own audit trail, a small model of one question — *would this person
want to be told about this message?* — and lets it answer alone in the
common, confident case: a message it is sure you would leave. Everything
else still goes to the resident model (tier 1), exactly as before.

Why this shape, and not the byte-level transformer in `specialist/`: that
research model needs PyTorch and thousands of labels. A person produces
tens of answers a week. A logistic model over hashed words, senders and
circumstances is what fits well from tens to hundreds of examples, trains in
well under a second in NumPy (already in the bundle), answers in a fraction
of a millisecond, and is calibrated by construction. The transformer stays
the path for when there is enough data to feed it.

Labels, in order of trust (docs/SPECIALIST.md):

* **the user**: approve (1) and dismiss (0) on a card; a card that simply
  timed out is a weak 0;
* **implicit**: you started a reply to that message within three days (1,
  uncensored — it labels messages Leonard stayed quiet on too); you opened
  it and left within a few seconds still unread (weak 0);
* **the teacher**: the resident model's own verdict, weakly, so the
  specialist starts from the general model's judgement and is pulled away
  from it by the person.

The specialist decides alone only when (a) it has been validated on the
newest of the user's own labels it was not trained on — it must agree with
the user at least as well as the resident model did, and be right at least
95% of the time when it says "stay quiet" — and (b) it is very sure. Even
then a small share of those events is still sent to the resident model as a
shadow check, so agreement keeps being measured on live traffic.
"""

from __future__ import annotations

import hashlib
import json
import math
import random
import re
import sqlite3
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

VERSION = 1
DIM = 1 << 18
COVERED_KINDS = ("mail.opened", "message.opened")
QUIET_P = 0.08
SHADOW_RATE = 0.05
MIN_USER_LABELS = 30
MIN_VALIDATION = 10
QUIET_PRECISION_FLOOR = 0.95
RETRAIN_AFTER_LABELS = 12
RETRAIN_AFTER_SECONDS = 24 * 3600
LOOKBACK_DAYS = 180

_WORD = re.compile(r"[a-zà-ÿ0-9]{2,}", re.IGNORECASE)
_AUTOMATED = re.compile(r"(no-?reply|newsletter|notifications?|info|news|marketing|mailer|bounce|updates?|digest)", re.I)
_REPLY_PREFIX = re.compile(r"^\s*((re|r|rif|fwd?|i|aw|sv|tr)\s*:\s*)+", re.IGNORECASE)


# ---------------------------------------------------------------- features


def _index(name: str) -> int:
    # Python's hash() is salted per process; a model saved today must read
    # the same features tomorrow.
    return int.from_bytes(hashlib.blake2b(name.encode("utf-8"), digest_size=8).digest(), "little") % DIM


def _address(raw: str) -> str:
    start, end = raw.rfind("<"), raw.rfind(">")
    return (raw[start + 1 : end] if 0 <= start < end else raw).strip().lower()


def normalized_subject(subject: str) -> str:
    return _REPLY_PREFIX.sub("", subject or "").strip().lower()


def feature_names(event: dict) -> list[str]:
    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    names = ["bias", f"kind:{event.get('kind', '')}", f"app:{str(event.get('app') or '').lower()}"]
    sender = str(payload.get("sender") or "")
    if sender:
        address = _address(sender)
        local, _, domain = address.partition("@")
        names += [f"from:{address}", f"domain:{domain}"]
        if _AUTOMATED.search(local):
            names.append("from:automated")
    subject = str(payload.get("subject") or "")
    words = [w.lower() for w in _WORD.findall(subject)][:20]
    names += [f"subj:{w}" for w in words]
    names += [f"subj2:{a}_{b}" for a, b in zip(words, words[1:])]
    if _REPLY_PREFIX.match(subject):
        names.append("subj:is_reply")
    body = str(payload.get("body") or "")[:600]
    names += [f"body:{w.lower()}" for w in _WORD.findall(body)[:80]]
    if "?" in body:
        names.append("body:question")
    thread = payload.get("thread_len")
    if isinstance(thread, (int, float)):
        names.append("thread:1" if thread <= 1 else "thread:2-3" if thread <= 3 else "thread:4+")
    if isinstance(payload.get("unread"), bool):
        names.append(f"unread:{payload['unread']}")
    ts = event.get("ts") if isinstance(event.get("ts"), (int, float)) and event.get("ts", 0) > 1e9 else time.time()
    local = time.localtime(ts)
    names.append(f"hour:{local.tm_hour // 4}")
    names.append("weekend" if local.tm_wday >= 5 else "weekday")
    return names


def featurize(event: dict) -> tuple[np.ndarray, np.ndarray]:
    names = feature_names(event)
    indices: dict[int, float] = {}
    for name in names:
        index = _index(name)
        indices[index] = indices.get(index, 0.0) + 1.0
    idx = np.fromiter(indices.keys(), dtype=np.int64, count=len(indices))
    val = np.fromiter(indices.values(), dtype=np.float32, count=len(indices))
    # Scale so a long body does not outweigh the sender.
    val /= math.sqrt(float(len(names)))
    return idx, val


# ---------------------------------------------------------------- labels


@dataclass(frozen=True)
class Example:
    decision_id: str
    ts: float
    event: dict
    y: float
    weight: float
    source: str  # user | timeout | replied | glanced | teacher
    teacher_surfaced: bool

    @property
    def is_personal(self) -> bool:
        return self.source in ("user", "replied")


_LABELS_SCHEMA = """
CREATE TABLE IF NOT EXISTS labels (
    decision_id TEXT PRIMARY KEY,
    label       REAL NOT NULL,
    weight      REAL NOT NULL,
    source      TEXT NOT NULL,
    ts          REAL NOT NULL
);
"""


def ensure_schema(conn: sqlite3.Connection) -> None:
    """`audit.open_db` creates all of this; kept for databases opened elsewhere."""
    conn.executescript(_LABELS_SCHEMA)
    columns = {row[1] for row in conn.execute("PRAGMA table_info(decisions)")}
    for column, kind in (("tier", "TEXT"), ("specialist_p", "REAL")):
        if column not in columns:
            conn.execute(f"ALTER TABLE decisions ADD COLUMN {column} {kind}")
    conn.commit()


def record_implicit(conn: sqlite3.Connection, event: dict, *, now: float | None = None) -> list[str]:
    """Labels past decisions from what the user just did. Returns the ids
    labelled. A reply started to a message is a strong 1; leaving a message
    within seconds, still unread, a weak 0."""
    now = now if now is not None else time.time()
    kind = event.get("kind")
    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    labelled: list[str] = []
    if kind == "mail.composing":
        subject = normalized_subject(str(payload.get("subject") or ""))
        to = {_address(part) for part in str(payload.get("to") or "").split(",") if part.strip()}
        if not subject and not to:
            return []
        rows = conn.execute(
            "SELECT decision_id, event_payload, sender FROM decisions WHERE kind = 'mail.opened' AND ts >= ? ORDER BY ts DESC LIMIT 200",
            (now - 3 * 86400,),
        ).fetchall()
        for decision_id, raw_payload, sender in rows:
            try:
                opened = json.loads(raw_payload or "{}")
            except json.JSONDecodeError:
                continue
            same_subject = subject and normalized_subject(str(opened.get("subject") or "")) == subject
            same_person = sender and sender in to
            if same_subject and (same_person or not to):
                _upsert_label(conn, decision_id, 1.0, 0.8, "replied", now)
                labelled.append(decision_id)
                break
    elif kind == "mail.closed":
        dwell = payload.get("dwell_ms")
        if isinstance(dwell, (int, float)) and dwell < 4000 and payload.get("still_unread") is True:
            message_id = str(payload.get("message_id") or "")
            if message_id:
                row = conn.execute(
                    "SELECT decision_id FROM decisions WHERE kind = 'mail.opened' AND ts >= ? AND event_payload LIKE ? "
                    "ORDER BY ts DESC LIMIT 1",
                    (now - 86400, f'%"message_id": {json.dumps(message_id)}%'),
                ).fetchone()
                if row:
                    _upsert_label(conn, row[0], 0.0, 0.3, "glanced", now, keep_stronger=True)
                    labelled.append(row[0])
    if labelled:
        conn.commit()
    return labelled


def _upsert_label(conn, decision_id, label, weight, source, ts, *, keep_stronger=False) -> None:
    if keep_stronger:
        existing = conn.execute("SELECT weight FROM labels WHERE decision_id = ?", (decision_id,)).fetchone()
        if existing and existing[0] >= weight:
            return
    conn.execute(
        "INSERT OR REPLACE INTO labels (decision_id, label, weight, source, ts) VALUES (?, ?, ?, ?, ?)",
        (decision_id, label, weight, source, ts),
    )


def examples(conn: sqlite3.Connection, *, now: float | None = None) -> list[Example]:
    """Every covered decision in the lookback window with its best label."""
    now = now if now is not None else time.time()
    placeholders = ",".join("?" for _ in COVERED_KINDS)
    rows = conn.execute(
        f"""
        SELECT d.decision_id, d.ts, d.kind, d.app, d.event_payload, d.action, d.abstained, d.confidence,
               d.response, d.response_reason, d.tier, l.label, l.weight, l.source
        FROM decisions d LEFT JOIN labels l ON l.decision_id = d.decision_id
        WHERE d.kind IN ({placeholders}) AND d.ts >= ?
        ORDER BY d.ts
        """,
        (*COVERED_KINDS, now - LOOKBACK_DAYS * 86400),
    ).fetchall()
    out: list[Example] = []
    for (decision_id, ts, kind, app, raw_payload, action, abstained, confidence, response, reason, tier,
         label, weight, source) in rows:
        try:
            payload = json.loads(raw_payload or "{}")
        except json.JSONDecodeError:
            continue
        event = {"kind": kind, "app": app, "ts": ts, "payload": payload}
        surfaced = action in ("suggest", "prepare") and not abstained
        if response == "approve":
            y, w, src = 1.0, 1.0, "user"
        elif response == "dismiss" and (reason or "user") == "user":
            y, w, src = 0.0, 1.0, "user"
        elif label is not None:
            y, w, src = float(label), float(weight), str(source)
        elif response == "dismiss":
            y, w, src = 0.0, 0.3, "timeout"
        elif tier == "specialist":
            # Its own verdicts are not evidence; training on them would only
            # teach it to agree with itself.
            continue
        else:
            y = 1.0 if surfaced else (0.4 if abstained else 0.0)
            w, src = 0.3 * float(confidence or 0.5), "teacher"
        out.append(Example(decision_id, float(ts), event, y, w, src, surfaced))
    return out


# ---------------------------------------------------------------- the model


@dataclass
class Metrics:
    trained_at: float = 0.0
    examples: int = 0
    personal_labels: int = 0
    validation: int = 0
    accuracy: float | None = None
    teacher_accuracy: float | None = None
    brier: float | None = None
    quiet_precision: float | None = None
    quiet_coverage: float | None = None
    train_ms: float = 0.0
    enabled: bool = False
    reason: str = ""


@dataclass
class Specialist:
    weights: np.ndarray = field(default_factory=lambda: np.zeros(DIM, dtype=np.float32))
    metrics: Metrics = field(default_factory=Metrics)
    version: int = VERSION

    @property
    def enabled(self) -> bool:
        return self.metrics.enabled

    def predict(self, event: dict) -> float:
        idx, val = featurize(event)
        z = float(np.dot(self.weights[idx], val))
        return 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, z))))

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp.npz")
        np.savez_compressed(tmp, weights=self.weights, version=np.array([self.version]))
        tmp.replace(path)
        path.with_suffix(".json").write_text(json.dumps(asdict(self.metrics), indent=2))

    @classmethod
    def load(cls, path: Path) -> Specialist | None:
        try:
            data = np.load(path)
            if int(data["version"][0]) != VERSION or data["weights"].shape != (DIM,):
                return None
            metrics = Metrics(**json.loads(path.with_suffix(".json").read_text()))
            return cls(weights=data["weights"].astype(np.float32), metrics=metrics)
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return None


def _fit(batch: list[Example], *, epochs: int = 10, lr: float = 0.3, l2: float = 1e-6, seed: int = 7) -> np.ndarray:
    """Weighted logistic regression by AdaGrad over sparse hashed features."""
    weights = np.zeros(DIM, dtype=np.float32)
    grad_sq = np.full(DIM, 1e-6, dtype=np.float32)
    featurized = [featurize(e.event) for e in batch]
    order = list(range(len(batch)))
    rng = random.Random(seed)
    for _ in range(epochs):
        rng.shuffle(order)
        for i in order:
            idx, val = featurized[i]
            example = batch[i]
            z = float(np.dot(weights[idx], val))
            p = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, z))))
            g = (p - example.y) * example.weight * val + l2 * weights[idx]
            grad_sq[idx] += g * g
            weights[idx] -= lr * g / np.sqrt(grad_sq[idx])
    return weights


def train(batch: list[Example], *, now: float | None = None) -> Specialist:
    """Fits on everything but the newest quarter of the user's own labels,
    measures on those, then refits on all of it for use."""
    started = time.perf_counter()
    now = now if now is not None else time.time()
    personal = [e for e in batch if e.is_personal]
    metrics = Metrics(trained_at=now, examples=len(batch), personal_labels=len(personal))

    holdout_size = max(MIN_VALIDATION, len(personal) // 4) if len(personal) >= MIN_USER_LABELS else 0
    if holdout_size:
        holdout = personal[-holdout_size:]
        cutoff = holdout[0].ts
        held = {e.decision_id for e in holdout}
        train_part = [e for e in batch if e.ts < cutoff and e.decision_id not in held]
        model = Specialist(weights=_fit(train_part))
        ps = [model.predict(e.event) for e in holdout]
        labels = [e.y >= 0.5 for e in holdout]
        metrics.validation = len(holdout)
        metrics.accuracy = sum((p >= 0.5) == y for p, y in zip(ps, labels)) / len(holdout)
        metrics.teacher_accuracy = sum(e.teacher_surfaced == y for e, y in zip(holdout, labels)) / len(holdout)
        metrics.brier = sum((p - e.y) ** 2 for p, e in zip(ps, holdout)) / len(holdout)
        quiet = [y for p, y in zip(ps, labels) if p <= QUIET_P]
        metrics.quiet_coverage = len(quiet) / len(holdout)
        metrics.quiet_precision = (sum(not y for y in quiet) / len(quiet)) if quiet else None

    metrics.enabled, metrics.reason = _verdict(metrics)
    specialist = Specialist(weights=_fit(batch) if batch else np.zeros(DIM, dtype=np.float32), metrics=metrics)
    specialist.metrics.train_ms = (time.perf_counter() - started) * 1000
    return specialist


def _verdict(m: Metrics) -> tuple[bool, str]:
    if m.personal_labels < MIN_USER_LABELS:
        return False, f"needs {MIN_USER_LABELS - m.personal_labels} more answers"
    if m.validation < MIN_VALIDATION or m.accuracy is None:
        return False, "not enough answers to check it"
    if m.teacher_accuracy is not None and m.accuracy < m.teacher_accuracy - 0.02:
        return False, "not yet better than the general model"
    if m.quiet_precision is None:
        return False, "never sure enough to stay quiet alone"
    if m.quiet_precision < QUIET_PRECISION_FLOOR:
        return False, "stayed quiet on something you wanted"
    return True, "active"


# ---------------------------------------------------------------- routing


@dataclass(frozen=True)
class Route:
    """What tier 0 says about an event. `quiet` means: decide alone, stay
    silent. `shadow` means: it would have, but the resident model decides
    this one anyway, to keep measuring agreement."""

    p: float
    quiet: bool
    shadow: bool
    latency_ms: float


def route(specialist: Specialist | None, event: dict, *, rng: random.Random | None = None) -> Route | None:
    if specialist is None or event.get("kind") not in COVERED_KINDS:
        return None
    started = time.perf_counter()
    p = specialist.predict(event)
    latency = (time.perf_counter() - started) * 1000
    if not specialist.enabled or p > QUIET_P:
        return Route(p=p, quiet=False, shadow=False, latency_ms=latency)
    shadow = (rng or random).random() < SHADOW_RATE
    return Route(p=p, quiet=not shadow, shadow=shadow, latency_ms=latency)


def snapshot(conn: sqlite3.Connection, specialist: Specialist | None, *, since: float) -> dict:
    """For Mind: what the specialist is, how good, and how much it does."""
    row = conn.execute(
        """
        SELECT COUNT(*), SUM(tier = 'specialist'),
               AVG(CASE WHEN tier = 'specialist' THEN latency_ms END),
               AVG(CASE WHEN tier IS NOT 'specialist' AND readouts != '[]' THEN latency_ms END),
               SUM(specialist_p IS NOT NULL AND tier IS NOT 'specialist'),
               SUM(specialist_p IS NOT NULL AND tier IS NOT 'specialist'
                   AND ((specialist_p >= 0.5) = (action IN ('suggest', 'prepare') AND abstained = 0)))
        FROM decisions WHERE ts >= ? AND kind IN ({})
        """.format(",".join("?" for _ in COVERED_KINDS)),
        (since, *COVERED_KINDS),
    ).fetchone()
    total, alone, alone_ms, general_ms, compared, agreed = row
    metrics = asdict(specialist.metrics) if specialist else asdict(Metrics(reason=f"needs {MIN_USER_LABELS} answers"))
    return {
        "state": "active" if specialist and specialist.enabled else "learning",
        "metrics": metrics,
        "decisions": int(total or 0),
        "decided_alone": int(alone or 0),
        "alone_ms": round(float(alone_ms), 3) if alone_ms is not None else None,
        "general_ms": round(float(general_ms), 1) if general_ms is not None else None,
        "agreement_with_general": round(agreed / compared, 4) if compared else None,
        "compared": int(compared or 0),
    }


def labels_since(conn: sqlite3.Connection, ts: float) -> int:
    placeholders = ",".join("?" for _ in COVERED_KINDS)
    explicit = conn.execute(
        f"SELECT COUNT(*) FROM decisions WHERE kind IN ({placeholders}) AND response_ts >= ?", (*COVERED_KINDS, ts)
    ).fetchone()[0]
    implicit = conn.execute("SELECT COUNT(*) FROM labels WHERE ts >= ?", (ts,)).fetchone()[0]
    return int(explicit or 0) + int(implicit or 0)


__all__ = [
    "COVERED_KINDS",
    "Example",
    "Metrics",
    "QUIET_P",
    "Route",
    "Specialist",
    "ensure_schema",
    "examples",
    "feature_names",
    "labels_since",
    "normalized_subject",
    "record_implicit",
    "route",
    "snapshot",
    "train",
]
