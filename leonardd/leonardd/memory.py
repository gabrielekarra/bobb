"""Screen memory: everything shown on screen, as text, searchable, local.

See `docs/SCREEN-MEMORY.md` for the design. This module is the store and the
retrieval, nothing else: it never reads the screen (the app does, from the
accessibility tree) and it never calls a model.

Three properties this module is responsible for, each tested:

**Deduplication is the cost model.** A window is nearly always what it was a
moment ago. An observation is compared with the last one *stored* for the
same app and window, never with the last one *seen*, so a slow drift cannot
walk past the threshold one step at a time. Near-identical text refreshes
`last_seen` on the stored row; text that only grew (a message finished
loading, the user scrolled further) replaces it; anything else is a new row.

**What must never be stored, is not.** Protected apps are refused outright,
before any text is looked at. Secrets that appear in otherwise ordinary
windows — card numbers, private keys, API tokens, one-time codes, a
`password:` line — are redacted before the text reaches the database, so
they are not in the FTS index either. Redaction is best-effort pattern
matching and the docs say so; the protected-app list is the real boundary.

**Deletion is real.** Rows are deleted from the content table and the FTS
index together (the triggers keep them in step), and a large delete is
followed by `VACUUM` via `compact()`, so a deleted string does not survive in
free pages of the file.
"""

from __future__ import annotations

import hashlib
import math
import re
import sqlite3
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

MAX_TEXT_CHARS = 20_000
MIN_TEXT_CHARS = 20
MERGE_WINDOW_SECONDS = 24 * 3600
GROW_WINDOW_SECONDS = 15 * 60
CONTAINMENT_THRESHOLD = 0.9

_SCHEMA = """
CREATE TABLE IF NOT EXISTS observations (
    id         INTEGER PRIMARY KEY,
    ts         REAL NOT NULL,
    last_seen  REAL NOT NULL,
    app        TEXT NOT NULL,
    bundle_id  TEXT,
    window     TEXT NOT NULL DEFAULT '',
    url        TEXT,
    source     TEXT NOT NULL DEFAULT 'screen',
    text       TEXT NOT NULL,
    digest     TEXT NOT NULL,
    chars      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_app_window ON observations(app, window, ts);
CREATE INDEX IF NOT EXISTS idx_obs_ts ON observations(ts);
CREATE INDEX IF NOT EXISTS idx_obs_digest ON observations(digest);

CREATE VIRTUAL TABLE IF NOT EXISTS observations_fts USING fts5(
    text, window, app,
    content='observations', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS observations_ai AFTER INSERT ON observations BEGIN
    INSERT INTO observations_fts(rowid, text, window, app) VALUES (new.id, new.text, new.window, new.app);
END;
CREATE TRIGGER IF NOT EXISTS observations_ad AFTER DELETE ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, text, window, app)
    VALUES ('delete', old.id, old.text, old.window, old.app);
END;
CREATE TRIGGER IF NOT EXISTS observations_au AFTER UPDATE OF text, window, app ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, text, window, app)
    VALUES ('delete', old.id, old.text, old.window, old.app);
    INSERT INTO observations_fts(rowid, text, window, app) VALUES (new.id, new.text, new.window, new.app);
END;
"""

# ---------------------------------------------------------------- redaction

_CARD = re.compile(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)")
# An IBAN is something a person wants to find again ("what was the IBAN Marco
# sent?"), not a credential, and its digit groups can pass a Luhn check by
# chance. Card redaction skips anything inside one.
_IBAN = re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b")
_PRIVATE_KEY = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.DOTALL
)
_TOKENS = re.compile(
    r"\b(?:"
    r"sk-[A-Za-z0-9_-]{20,}"  # OpenAI-style and Anthropic-style secret keys
    r"|gh[pousr]_[A-Za-z0-9]{30,}"  # GitHub tokens
    r"|AKIA[0-9A-Z]{16}"  # AWS access key ids
    r"|xox[abprs]-[A-Za-z0-9-]{10,}"  # Slack tokens
    r"|AIza[0-9A-Za-z_-]{35}"  # Google API keys
    r")\b"
)
_SECRET_LINE = re.compile(
    r"(?im)^(\s*(?:password|passwd|pwd|passcode|pin|cvv|cvc|secret|api[ _-]?key|token"
    r"|parola ?chiave|codice segreto)\s*[:=]\s*)(\S.*)$"
)
_OTP = re.compile(
    r"(?i)\b(code|codice|otp|verification|verifica|one[- ]time|pin)\b([^\n\d]{0,30})(\d{4,8})\b"
)

REDACTED = "[redatto]"


def _luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = ord(ch) - 48
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def redact(text: str) -> tuple[str, int]:
    """`text` with recognizable secrets replaced, and how many were."""
    count = 0

    def sub(pattern: re.Pattern, repl, value: str) -> str:
        nonlocal count
        new, n = pattern.subn(repl, value)
        count += n
        return new

    text = sub(_PRIVATE_KEY, REDACTED, text)
    text = sub(_TOKENS, REDACTED, text)
    text = sub(_SECRET_LINE, lambda m: m.group(1) + REDACTED, text)
    text = sub(_OTP, lambda m: m.group(1) + m.group(2) + REDACTED, text)

    iban_spans = [m.span() for m in _IBAN.finditer(text)]

    def card(match: re.Match) -> str:
        nonlocal count
        if any(start <= match.start() < end for start, end in iban_spans):
            return match.group(0)
        digits = re.sub(r"\D", "", match.group(0))
        if 13 <= len(digits) <= 19 and _luhn_ok(digits):
            count += 1
            return REDACTED
        return match.group(0)

    text = _CARD.sub(card, text)
    return text, count


# ---------------------------------------------------------------- normalization

_WS = re.compile(r"[ \t ]+")


def normalize(text: str) -> str:
    """Collapse runs of spaces per line, drop blank lines, keep line breaks."""
    text = unicodedata.normalize("NFC", text)
    lines = (_WS.sub(" ", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if line)


def _paragraphs(text: str) -> set[str]:
    return {line.casefold() for line in text.split("\n") if len(line) >= 3}


def _containment(inner: set[str], outer: set[str]) -> float:
    if not inner:
        return 1.0
    return len(inner & outer) / len(inner)


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- query building

_STOPWORDS = frozenset(
    """
    a about above after again all also am an and any are as at be because been before being
    but by can could did do does doing down during each few for from further had has have
    having he her here hers him his how i if in into is it its just me more most my no nor
    not of off on once only or other our out over own same she should so some such than that
    the their them then there these they this those through to too under until up very was
    we were what when where which while who whom why will with would you your yours
    what's whats tell show find give remind please thing things said say says sent send
    il lo la i gli le un uno una di da in con su per tra fra e ed o ma se che chi cui non
    del dello della dei degli delle al allo alla ai agli alle dal dallo dalla dai dagli dalle
    nel nello nella nei negli nelle sul sullo sulla sui sugli sulle è era sono ho hai ha
    abbiamo avete hanno mi ti ci vi si ne come cosa quale quali quando dove perché perche
    questo questa questi queste quello quella quelli quelle mio mia miei mie tuo tua suo sua
    nostro nostra loro più piu anche già gia ancora molto poco tutto tutti fammi dimmi
    trova mostra ricordami detto scritto mandato inviato
    """.split()
)

_WORD = re.compile(r"[\w@.+-]+", re.UNICODE)


def query_terms(text: str, limit: int = 12) -> list[str]:
    """Content words from a natural-language question, in order, deduplicated."""
    terms: list[str] = []
    seen: set[str] = set()
    for raw in _WORD.findall(text.casefold()):
        word = raw.strip(".-+@")
        if len(word) < 2 or word in _STOPWORDS or word in seen:
            continue
        seen.add(word)
        terms.append(word)
        if len(terms) >= limit:
            break
    return terms


def _fts_term(term: str) -> str:
    """One FTS5 match expression for `term`.

    A long word is matched on a prefix of itself so the Italian plural finds
    the singular (`preventivi` finds `preventivo`) and the English plural
    finds the singular. Short words and anything with digits match exactly:
    an invoice number is not a stem.
    """
    cleaned = re.sub(r"[^\w]", " ", term).strip()
    parts = [p for p in cleaned.split() if p]
    if not parts:
        return ""
    if len(parts) > 1:
        return '"' + " ".join(parts) + '"'
    word = parts[0]
    if len(word) >= 6 and not any(ch.isdigit() for ch in word):
        return f'"{word[: len(word) - 2]}"*'
    return f'"{word}"'


def fts_query(terms: list[str]) -> str:
    return " OR ".join(t for t in (_fts_term(term) for term in terms) if t)


# ---------------------------------------------------------------- store


@dataclass(frozen=True)
class Observation:
    app: str
    text: str
    window: str = ""
    bundle_id: str | None = None
    url: str | None = None
    source: str = "screen"
    ts: float | None = None


@dataclass(frozen=True)
class ObserveResult:
    outcome: str  # "stored" | "merged" | "grew" | "refused"
    row_id: int | None
    reason: str = ""
    redactions: int = 0


@dataclass(frozen=True)
class Hit:
    id: int
    ts: float
    last_seen: float
    app: str
    window: str
    url: str | None
    source: str
    text: str
    score: float

    def excerpt(self, terms: list[str], width: int = 700) -> str:
        """A window of `text` around the first matched term."""
        if len(self.text) <= width:
            return self.text
        folded = self.text.casefold()
        positions = [folded.find(t[:6]) for t in terms if t]
        positions = [p for p in positions if p >= 0]
        center = min(positions) if positions else 0
        start = max(0, center - width // 3)
        end = min(len(self.text), start + width)
        start = max(0, end - width)
        prefix = "…" if start > 0 else ""
        suffix = "…" if end < len(self.text) else ""
        return prefix + self.text[start:end].strip() + suffix

    def to_frame(self, terms: list[str] | None = None) -> dict:
        return {
            "id": self.id,
            "ts": self.ts,
            "last_seen": self.last_seen,
            "app": self.app,
            "window": self.window,
            "url": self.url,
            "source": self.source,
            "snippet": self.excerpt(terms or [], width=280),
        }


class MemoryStore:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        if str(path) != ":memory:":
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(path), check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute("PRAGMA secure_delete=ON")
        self.conn.executescript(_SCHEMA)
        self.conn.commit()
        if str(path) != ":memory:":
            try:
                self.path.chmod(0o600)
            except OSError:
                pass

    def close(self) -> None:
        self.conn.close()

    # ---- writing

    def observe(self, obs: Observation, *, protected: bool = False) -> ObserveResult:
        if protected:
            return ObserveResult("refused", None, "protected app")
        app = (obs.app or "").strip()
        if not app:
            return ObserveResult("refused", None, "no app")
        text = normalize(obs.text or "")[:MAX_TEXT_CHARS]
        text, redactions = redact(text)
        if len(text) < MIN_TEXT_CHARS:
            return ObserveResult("refused", None, "too short", redactions)
        window = normalize(obs.window or "")[:300]
        now = obs.ts if obs.ts is not None else time.time()
        digest = _digest(text)

        last = self.conn.execute(
            "SELECT id, ts, text, digest FROM observations WHERE app = ? AND window = ? "
            "ORDER BY ts DESC LIMIT 1",
            (app, window),
        ).fetchone()
        if last is not None and now - last[1] <= MERGE_WINDOW_SECONDS:
            last_id, last_ts, last_text, last_digest = last
            new_paras = _paragraphs(text)
            old_paras = _paragraphs(last_text)
            if last_digest == digest or _containment(new_paras, old_paras) >= CONTAINMENT_THRESHOLD:
                self.conn.execute("UPDATE observations SET last_seen = ? WHERE id = ?", (now, last_id))
                self.conn.commit()
                return ObserveResult("merged", last_id, redactions=redactions)
            if now - last_ts <= GROW_WINDOW_SECONDS and _containment(old_paras, new_paras) >= CONTAINMENT_THRESHOLD:
                self.conn.execute(
                    "UPDATE observations SET text = ?, digest = ?, chars = ?, last_seen = ?, url = COALESCE(?, url) "
                    "WHERE id = ?",
                    (text, digest, len(text), now, obs.url, last_id),
                )
                self.conn.commit()
                return ObserveResult("grew", last_id, redactions=redactions)

        dup = self.conn.execute(
            "SELECT id FROM observations WHERE digest = ? AND ts >= ? LIMIT 1",
            (digest, now - MERGE_WINDOW_SECONDS),
        ).fetchone()
        if dup is not None:
            self.conn.execute("UPDATE observations SET last_seen = ? WHERE id = ?", (now, dup[0]))
            self.conn.commit()
            return ObserveResult("merged", dup[0], redactions=redactions)

        cursor = self.conn.execute(
            "INSERT INTO observations (ts, last_seen, app, bundle_id, window, url, source, text, digest, chars) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (now, now, app, obs.bundle_id, window, obs.url, obs.source, text, digest, len(text)),
        )
        self.conn.commit()
        return ObserveResult("stored", cursor.lastrowid, redactions=redactions)

    # ---- reading

    def search(
        self,
        query: str,
        *,
        limit: int = 8,
        app: str | None = None,
        exclude_ids: set[int] | None = None,
        now: float | None = None,
        half_life_days: float = 21.0,
    ) -> tuple[list[Hit], list[str]]:
        """Best matches for a natural-language `query`, and the terms used.

        BM25 decides relevance; recency breaks near-ties, never overrides a
        clearly better match: the score is BM25 relevance scaled into
        [0.6, 1.0] by age, so a month-old exact answer still beats a
        vague match from this morning.
        """
        terms = query_terms(query)
        expression = fts_query(terms)
        if not expression:
            return [], terms
        now = now if now is not None else time.time()
        sql = (
            "SELECT o.id, o.ts, o.last_seen, o.app, o.window, o.url, o.source, o.text, "
            "bm25(observations_fts, 1.0, 0.6, 0.2) AS rank "
            "FROM observations_fts JOIN observations o ON o.id = observations_fts.rowid "
            "WHERE observations_fts MATCH ?"
        )
        params: list = [expression]
        if app:
            sql += " AND o.app = ?"
            params.append(app)
        sql += " ORDER BY rank LIMIT 60"
        try:
            rows = self.conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError:
            return [], terms
        exclude_ids = exclude_ids or set()
        hits = []
        for row_id, ts, last_seen, row_app, window, url, source, text, rank in rows:
            if row_id in exclude_ids:
                continue
            relevance = -float(rank)
            age_days = max(0.0, (now - last_seen) / 86400.0)
            recency = math.exp(-age_days * math.log(2) / half_life_days)
            hits.append(
                Hit(row_id, ts, last_seen, row_app, window, url, source, text, relevance * (0.6 + 0.4 * recency))
            )
        hits.sort(key=lambda h: h.score, reverse=True)
        return hits[:limit], terms

    def recent(self, *, limit: int = 20, app: str | None = None) -> list[Hit]:
        sql = "SELECT id, ts, last_seen, app, window, url, source, text FROM observations"
        params: list = []
        if app:
            sql += " WHERE app = ?"
            params.append(app)
        sql += " ORDER BY last_seen DESC LIMIT ?"
        params.append(limit)
        return [Hit(*row, score=0.0) for row in self.conn.execute(sql, params).fetchall()]

    def get(self, row_id: int) -> Hit | None:
        row = self.conn.execute(
            "SELECT id, ts, last_seen, app, window, url, source, text FROM observations WHERE id = ?",
            (row_id,),
        ).fetchone()
        return Hit(*row, score=0.0) if row else None

    def stats(self) -> dict:
        rows, chars, oldest, newest = self.conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(chars), 0), MIN(ts), MAX(last_seen) FROM observations"
        ).fetchone()
        apps = self.conn.execute(
            "SELECT app, COUNT(*), MAX(last_seen) FROM observations GROUP BY app ORDER BY COUNT(*) DESC LIMIT 50"
        ).fetchall()
        size = 0
        if str(self.path) != ":memory:":
            for suffix in ("", "-wal"):
                try:
                    size += Path(str(self.path) + suffix).stat().st_size
                except OSError:
                    pass
        return {
            "rows": rows,
            "chars": chars,
            "bytes": size,
            "oldest_ts": oldest,
            "newest_ts": newest,
            "apps": [{"app": a, "rows": n, "last_seen": ls} for a, n, ls in apps],
        }

    # ---- deleting

    def delete(
        self,
        *,
        row_id: int | None = None,
        app: str | None = None,
        since: float | None = None,
        until: float | None = None,
        query: str | None = None,
        everything: bool = False,
    ) -> int:
        """Delete by exactly one scope. Returns rows deleted.

        A time range may be combined with `app`. `query` deletes every row the
        same search would find, which is how "forget everything about X"
        works.
        """
        if everything:
            count = self.conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
            self.conn.execute("DELETE FROM observations")
            self.conn.commit()
            return count
        if row_id is not None:
            cursor = self.conn.execute("DELETE FROM observations WHERE id = ?", (row_id,))
            self.conn.commit()
            return cursor.rowcount
        if query:
            expression = fts_query(query_terms(query, limit=8))
            if not expression:
                return 0
            ids = [
                r[0]
                for r in self.conn.execute(
                    "SELECT rowid FROM observations_fts WHERE observations_fts MATCH ?", (expression,)
                ).fetchall()
            ]
            if not ids:
                return 0
            self.conn.executemany("DELETE FROM observations WHERE id = ?", [(i,) for i in ids])
            self.conn.commit()
            return len(ids)
        clauses, params = [], []
        if app:
            clauses.append("app = ?")
            params.append(app)
        if since is not None:
            clauses.append("last_seen >= ?")
            params.append(since)
        if until is not None:
            clauses.append("ts < ?")
            params.append(until)
        if not clauses:
            raise ValueError("delete needs a scope: row_id, app, since/until, query, or everything")
        cursor = self.conn.execute(f"DELETE FROM observations WHERE {' AND '.join(clauses)}", params)
        self.conn.commit()
        return cursor.rowcount

    def sweep(self, retention_days: int, *, now: float | None = None) -> int:
        """Forget everything not seen within `retention_days`."""
        now = now if now is not None else time.time()
        cutoff = now - retention_days * 86400
        cursor = self.conn.execute("DELETE FROM observations WHERE last_seen < ?", (cutoff,))
        self.conn.commit()
        return cursor.rowcount

    def compact(self) -> None:
        self.conn.execute("INSERT INTO observations_fts(observations_fts) VALUES ('optimize')")
        self.conn.commit()
        self.conn.execute("VACUUM")


__all__ = [
    "MemoryStore",
    "Observation",
    "ObserveResult",
    "Hit",
    "redact",
    "normalize",
    "query_terms",
    "fts_query",
    "REDACTED",
]
