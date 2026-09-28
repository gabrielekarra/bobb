"""Async unix-socket server implementing the Leonard IPC contract.

NDJSON both ways over a single unix domain socket, one object per line. A
malformed line becomes an `error` frame, never a dropped connection:
`_dispatch` catches everything from a single frame's handling and reports it
rather than letting it propagate into the read loop. Unknown `t` values are
silently ignored, per the contract.

The socket is bound before the model is loaded. Loading a 2 GB checkpoint
takes seconds; during them the app can already connect, show "starting",
search and delete memory, and change settings. `hello` is answered with
`status` until the model is resident and with `ready` after, and `ready` is
broadcast to every connected client the moment loading finishes. A missing
checkpoint is a state (`model_missing`), not a crash: the app downloads it
and sends `reload`.

Inference runs on a single-worker executor so the asyncio loop stays free to
read other frames while a decision or a draft is in flight, and so two
requests are never advanced through the resident model's shared cache at
once. Generation runs as a background task so a `cancel` for it can be read
while it is still producing tokens.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from typing import Any

import numpy as np

from . import __version__
from . import audit as audit_mod
from . import compose
from . import settings as settings_mod
from .act import MAX_CANDIDATES, act_frame, score_action
from .attention import AttentionEngine
from .audit import fetch_decision, open_db, record_decision, record_response
from .gate import FrameGate
from .generation import GenerationUnavailable, stream_text, supports_generation
from .i18n import t as tr
from .learning import Personalizer
from .memory import MemoryStore, Observation
from .settings import Settings

PROTOCOL_VERSION = 1
DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Leonard"
DEFAULT_SOCKET_PATH = DEFAULT_DATA_DIR / "leonardd.sock"
SWEEP_INTERVAL_SECONDS = 6 * 3600

FEATURES = (
    "attention",
    "prepare.stream",
    "ask",
    "memory",
    "learning",
    "settings",
    "act",
    "status",
)

logger = logging.getLogger("leonardd")


def _now() -> float:
    return time.time()


def _error_frame(detail: str, **extra: Any) -> dict:
    return {"t": "error", "ts": _now(), "detail": detail, **extra}


def _decode_png_luminance(b64_data: str) -> np.ndarray:
    from PIL import Image

    raw = base64.b64decode(b64_data)
    image = Image.open(io.BytesIO(raw)).convert("L")
    return np.array(image, dtype=np.uint8)


def _event_from_row(row: dict) -> dict:
    return {
        "kind": row.get("kind", ""),
        "app": row.get("app"),
        "payload": json.loads(row["event_payload"]) if row.get("event_payload") else {},
    }


def mail_observation(event: dict) -> Observation | None:
    """A displayed email is screen content like any other: it goes into
    memory so "what did Marco say about the quote" finds it later."""
    if event.get("kind") != "mail.opened":
        return None
    p = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    body = str(p.get("body") or "")
    if not body.strip():
        return None
    subject = str(p.get("subject") or "")
    text = f"From: {p.get('sender', '')}\nSubject: {subject}\n\n{body}"
    ts = event.get("ts")
    return Observation(
        app=str(event.get("app") or "Mail"),
        bundle_id=p.get("bundle_id") if isinstance(p.get("bundle_id"), str) else "com.apple.mail",
        window=subject,
        text=text,
        source="mail",
        ts=ts if isinstance(ts, (int, float)) and ts > 1e9 else None,
    )


class _Client:
    """One connected app: its writer, and a lock so frames from concurrent
    tasks never interleave mid-line."""

    def __init__(self, writer: asyncio.StreamWriter):
        self.writer = writer
        self.lock = asyncio.Lock()

    async def send(self, frame: dict) -> None:
        async with self.lock:
            self.writer.write((json.dumps(frame, ensure_ascii=False) + "\n").encode("utf-8"))
            await self.writer.drain()


class LeonardServer:
    def __init__(
        self,
        attention: AttentionEngine | None,
        conn,
        *,
        socket_path: Path | str = DEFAULT_SOCKET_PATH,
        model_name: str = "",
        prime_ms: float = 0.0,
        decide_ms: float = 0.0,
        gate: FrameGate | None = None,
        memory: MemoryStore | None = None,
        settings: Settings | None = None,
        settings_path: Path | None = None,
        personalizer: Personalizer | None = None,
        state: str | None = None,
    ):
        self.attention = attention
        self.conn = conn
        self.socket_path = Path(socket_path)
        self.model_name = model_name
        self.prime_ms = prime_ms
        self.decide_ms = decide_ms
        self.gate = gate or FrameGate()
        self.memory = memory
        self.settings_path = settings_path
        self.personalizer = personalizer if personalizer is not None else Personalizer(conn)
        if settings is None:
            settings = attention.settings if attention is not None else Settings()
        self.settings = settings
        self.state = state or ("ready" if attention is not None else "loading")
        self.state_detail = ""
        self._apply_settings_to_attention()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="leonardd-model")
        self._clients: set[_Client] = set()
        self._cancels: dict[str, threading.Event] = {}
        self._tasks: set[asyncio.Task] = set()
        self._reload_hook = None

    # ------------------------------------------------------------ lifecycle

    async def start(self) -> asyncio.base_events.Server:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            self.socket_path.unlink()
        server = await asyncio.start_unix_server(self._handle_client, path=str(self.socket_path))
        os.chmod(self.socket_path, 0o600)
        return server

    def close(self) -> None:
        for cancel in self._cancels.values():
            cancel.set()
        for task in list(self._tasks):
            task.cancel()
        self._executor.shutdown(wait=False, cancel_futures=True)
        self.conn.close()
        if self.memory is not None:
            self.memory.close()

    def set_ready(self, attention: AttentionEngine, *, model_name: str, prime_ms: float, decide_ms: float) -> None:
        attention.personalizer = self.personalizer
        self.attention = attention
        self.model_name = model_name
        self.prime_ms = prime_ms
        self.decide_ms = decide_ms
        self.state = "ready"
        self.state_detail = ""
        self._apply_settings_to_attention()

    def set_state(self, state: str, detail: str = "") -> None:
        self.state = state
        self.state_detail = detail

    async def broadcast(self, frame: dict) -> None:
        for client in list(self._clients):
            try:
                await client.send(frame)
            except (ConnectionError, RuntimeError):
                self._clients.discard(client)

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def _run_model(self, fn, *args, **kwargs):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._executor, lambda: fn(*args, **kwargs))

    # ------------------------------------------------------------ settings

    def _apply_settings_to_attention(self) -> None:
        if self.attention is not None:
            self.attention.settings = self.settings
            if self.attention.personalizer is None:
                self.attention.personalizer = self.personalizer

    def apply_settings(self, frame: dict) -> None:
        self.settings = settings_mod.apply(self.settings, frame)
        self._apply_settings_to_attention()
        if self.settings_path is not None:
            settings_mod.save(self.settings, self.settings_path)

    def sweep(self, now: float | None = None) -> dict:
        memory_rows = self.memory.sweep(self.settings.memory_retention_days, now=now) if self.memory else 0
        decisions = audit_mod.sweep(self.conn, self.settings.history_retention_days, now=now)
        if memory_rows or decisions:
            logger.info("retention: forgot %d memory rows, %d decisions", memory_rows, decisions)
        return {"memory": memory_rows, "decisions": decisions}

    # ------------------------------------------------------------ plumbing

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        client = _Client(writer)
        self._clients.add(client)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if not line.strip():
                    continue
                await self._dispatch(line, client)
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            self._clients.discard(client)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _dispatch(self, line: bytes, client: _Client) -> None:
        try:
            frame = json.loads(line)
        except json.JSONDecodeError as exc:
            await client.send(_error_frame(f"malformed json: {exc}"))
            return
        if not isinstance(frame, dict) or "t" not in frame:
            await client.send(_error_frame("frame missing 't'"))
            return

        kind = frame.get("t")
        handler = {
            "hello": self._on_hello,
            "settings": self._on_settings,
            "event": self._on_event,
            "approve": lambda f, c: self._on_response(f, c, "approve"),
            "dismiss": lambda f, c: self._on_response(f, c, "dismiss"),
            "regenerate": self._on_regenerate,
            "policy": self._on_policy,
            "frame": self._on_frame,
            "observe": self._on_observe,
            "ask": self._on_ask,
            "cancel": self._on_cancel,
            "memory.observe": self._on_memory_observe,
            "memory.search": self._on_memory_search,
            "memory.recent": self._on_memory_recent,
            "memory.delete": self._on_memory_delete,
            "memory.stats": self._on_memory_stats,
            "stats": self._on_stats,
            "learning.forget": self._on_learning_forget,
            "learning.mute": self._on_learning_mute,
            "reload": self._on_reload,
            "history.delete": self._on_history_delete,
        }.get(kind)
        if handler is None:
            return
        try:
            await handler(frame, client)
        except Exception as exc:
            logger.warning("error handling %s frame: %s", kind, type(exc).__name__)
            await client.send(_error_frame(f"{kind}: {exc}", request_id=frame.get("id")))

    # ------------------------------------------------------------ handshake and settings

    def _ready_frame(self) -> dict:
        return {
            "t": "ready",
            "ts": _now(),
            "model": self.model_name,
            "prime_ms": self.prime_ms,
            "decide_ms": self.decide_ms,
            "floor": self.settings.floor,
            "protocol": PROTOCOL_VERSION,
            "version": __version__,
            "features": list(FEATURES),
            "locale": self.settings.locale,
        }

    def _status_frame(self) -> dict:
        return {
            "t": "status",
            "ts": _now(),
            "state": self.state,
            "detail": self.state_detail,
            "model": self.model_name,
            "protocol": PROTOCOL_VERSION,
            "version": __version__,
        }

    async def _on_hello(self, frame: dict, client: _Client) -> None:
        if isinstance(frame.get("locale"), str):
            self.apply_settings({"locale": frame["locale"]})
        await client.send(self._ready_frame() if self.state == "ready" else self._status_frame())

    async def _on_settings(self, frame: dict, client: _Client) -> None:
        # Turning memory off stops new writes; what is already stored stays
        # until the user deletes it, which is a separate, explicit action.
        self.apply_settings(frame)
        await client.send({**self.settings.to_frame(), "ts": _now()})

    async def _on_policy(self, frame: dict, client: _Client) -> None:
        floor = frame.get("floor")
        if isinstance(floor, (int, float)) and not isinstance(floor, bool) and 0.0 <= floor <= 1.0:
            self.apply_settings({"floor": float(floor)})

    async def _on_reload(self, frame: dict, client: _Client) -> None:
        if self._reload_hook is not None and self.state != "ready":
            self._spawn(self._reload_hook())

    # ------------------------------------------------------------ attention

    async def _on_event(self, event: dict, client: _Client) -> None:
        obs = mail_observation(event)
        if obs is not None and self.memory is not None and self.settings.memory_enabled:
            protected = settings_mod.is_protected(self.settings, app=obs.app, bundle_id=obs.bundle_id)
            self.memory.observe(obs, protected=protected)

        if self.attention is None:
            decision = {
                "t": "decision",
                "ts": _now(),
                "id": f"dec_{os.urandom(10).hex()}",
                "event_id": event.get("id", ""),
                "action": "ignore",
                "confidence": 1.0,
                "schema_mass": 1.0,
                "latency_ms": 0.0,
                "hypotheses": [],
                "readouts": [],
                "why": f"model {self.state}",
                "explanation": tr("outcome.loading", self.settings.locale),
            }
        else:
            decision = await self._run_model(self.attention.decide_event, event)
        record_decision(self.conn, decision, event, floor=decision.get("floor", self.settings.floor), model=self.model_name)
        await client.send(
            {
                "t": "trace",
                "ts": _now(),
                "event_id": event.get("id", ""),
                "stage": "attention",
                "detail": decision["action"],
                "ms": decision["latency_ms"],
            }
        )
        await client.send(decision)

    async def _on_response(self, frame: dict, client: _Client, response: str) -> None:
        decision_id = frame.get("decision_id", "")
        reason = frame.get("reason") if frame.get("reason") in audit_mod.RESPONSE_REASONS else None
        found = record_response(self.conn, decision_id, response, frame.get("ts"), reason=reason)
        if not found:
            await client.send(_error_frame(f"unknown decision_id {decision_id!r}"))
            return
        self.personalizer.refresh()
        if response != "approve":
            return
        self._spawn(self._prepare(decision_id, client, instruction=""))

    async def _on_regenerate(self, frame: dict, client: _Client) -> None:
        decision_id = frame.get("decision_id", "")
        if fetch_decision(self.conn, decision_id) is None:
            await client.send(_error_frame(f"unknown decision_id {decision_id!r}"))
            return
        self._spawn(self._prepare(decision_id, client, instruction=str(frame.get("instruction") or "")))

    async def _prepare(self, decision_id: str, client: _Client, *, instruction: str) -> None:
        row = fetch_decision(self.conn, decision_id)
        suggestion = json.loads(row["suggestion"]) if row and row.get("suggestion") else None
        if not suggestion:
            return
        action_id = suggestion.get("action_id", "")
        event = _event_from_row(row)
        locale = self.settings.locale
        started = time.perf_counter()
        try:
            task = compose.for_action(action_id, event, self.memory, locale)
            if instruction and action_id == "draft_reply":
                task = compose.draft_reply(event, self.memory, locale, instruction=instruction)
        except KeyError:
            await client.send(self._prepared_error(decision_id, action_id, "unsupported action", started))
            return

        def delta_frame(text: str) -> dict:
            return {"t": "prepared.delta", "ts": _now(), "decision_id": decision_id, "text": text}

        result = await self._generate(task, decision_id, client, delta_frame)
        if result is None:
            await client.send(self._prepared_error(decision_id, action_id, "generation unavailable", started))
            return
        payload = event.get("payload") or {}
        body = {
            "kind": task.result_kind,
            "body": result.text,
            "sources": [s.to_frame() for s in compose.cited(result.text, task.sources)],
            "unsupported": compose.unsupported(result.text, task.grounding, prefix=task.prefix),
        }
        if task.result_kind == "reply":
            body["to"] = payload.get("sender", "")
            body["subject"] = payload.get("subject", "")
            if payload.get("message_id"):
                body["message_id"] = payload["message_id"]
        await client.send(
            {
                "t": "prepared",
                "ts": _now(),
                "decision_id": decision_id,
                "action_id": action_id,
                "result": body,
                "latency_ms": (time.perf_counter() - started) * 1000,
                "first_token_ms": result.first_token_ms,
                "cancelled": result.cancelled,
            }
        )

    def _prepared_error(self, decision_id: str, action_id: str, detail: str, started: float) -> dict:
        return {
            "t": "prepared",
            "ts": _now(),
            "decision_id": decision_id,
            "action_id": action_id,
            "result": {"kind": "error", "body": detail},
            "latency_ms": (time.perf_counter() - started) * 1000,
        }

    async def _generate(self, task: compose.Task, request_id: str, client: _Client, delta_frame):
        """Run `task` on the model, streaming deltas to `client`. Returns the
        `Generated` result, or `None` when this engine cannot generate."""
        if self.attention is None or not supports_generation(self.attention.engine):
            return None
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue = asyncio.Queue()
        cancel = threading.Event()
        self._cancels[request_id] = cancel
        done = object()

        async def pump() -> None:
            while True:
                item = await queue.get()
                if item is done:
                    return
                await client.send(delta_frame(item))

        pumping = asyncio.create_task(pump())

        def on_delta(text: str) -> None:
            loop.call_soon_threadsafe(queue.put_nowait, text)

        try:
            result = await self._run_model(
                stream_text,
                self.attention.engine,
                task.messages,
                max_tokens=task.max_tokens,
                on_delta=on_delta,
                cancel=cancel,
                temperature=task.temperature,
                prefix=task.prefix,
            )
        except GenerationUnavailable:
            result = None
        finally:
            loop.call_soon_threadsafe(queue.put_nowait, done)
            await pumping
            self._cancels.pop(request_id, None)
        return result

    # ------------------------------------------------------------ the command bar

    async def _on_ask(self, frame: dict, client: _Client) -> None:
        request_id = str(frame.get("id") or f"ask_{os.urandom(8).hex()}")
        request = compose.Request(
            prompt=str(frame.get("prompt") or ""),
            mode=str(frame.get("mode") or "ask"),
            selection=str(frame.get("selection") or ""),
            app=str(frame.get("app") or ""),
            window=str(frame.get("window") or ""),
        )
        if not request.prompt.strip() and not request.selection.strip():
            await client.send(_error_frame("ask needs a prompt or a selection", request_id=request_id))
            return
        self._spawn(self._answer(request_id, request, client))

    async def _answer(self, request_id: str, request: compose.Request, client: _Client) -> None:
        started = time.perf_counter()
        task = compose.for_request(request, self.memory, self.settings.locale)

        def delta_frame(text: str) -> dict:
            return {"t": "answer.delta", "ts": _now(), "request_id": request_id, "text": text}

        if self.attention is None:
            await client.send(
                {"t": "answer", "ts": _now(), "request_id": request_id, "ok": False, "error": f"model {self.state}",
                 "text": "", "sources": [], "mode": task.kind, "result_kind": task.result_kind,
                 "latency_ms": 0.0}
            )
            return
        result = await self._generate(task, request_id, client, delta_frame)
        if result is None:
            await client.send(
                {"t": "answer", "ts": _now(), "request_id": request_id, "ok": False,
                 "error": "generation unavailable", "text": "", "sources": [], "mode": task.kind,
                 "result_kind": task.result_kind, "latency_ms": (time.perf_counter() - started) * 1000}
            )
            return
        await client.send(
            {
                "t": "answer",
                "ts": _now(),
                "request_id": request_id,
                "ok": True,
                "text": result.text,
                "mode": task.kind,
                "result_kind": task.result_kind,
                "sources": [s.to_frame() for s in compose.cited(result.text, task.sources)],
                "unsupported": compose.unsupported(result.text, task.grounding, prefix=task.prefix),
                "latency_ms": (time.perf_counter() - started) * 1000,
                "first_token_ms": result.first_token_ms,
                "cancelled": result.cancelled,
            }
        )

    async def _on_cancel(self, frame: dict, client: _Client) -> None:
        request_id = str(frame.get("request_id") or frame.get("decision_id") or "")
        cancel = self._cancels.get(request_id)
        if cancel is not None:
            cancel.set()

    # ------------------------------------------------------------ memory

    async def _on_memory_observe(self, frame: dict, client: _Client) -> None:
        if self.memory is None or not self.settings.memory_enabled:
            return
        app = str(frame.get("app") or "")
        bundle_id = frame.get("bundle_id") if isinstance(frame.get("bundle_id"), str) else None
        protected = settings_mod.is_protected(self.settings, app=app, bundle_id=bundle_id)
        ts = frame.get("ts")
        result = self.memory.observe(
            Observation(
                app=app,
                bundle_id=bundle_id,
                window=str(frame.get("window") or ""),
                text=str(frame.get("text") or ""),
                url=frame.get("url") if isinstance(frame.get("url"), str) else None,
                source=str(frame.get("source") or "screen"),
                ts=ts if isinstance(ts, (int, float)) and ts > 1e9 else None,
            ),
            protected=protected,
        )
        if frame.get("id"):
            await client.send(
                {"t": "memory.observed", "ts": _now(), "request_id": frame["id"], "outcome": result.outcome,
                 "row_id": result.row_id, "redactions": result.redactions}
            )

    async def _on_memory_search(self, frame: dict, client: _Client) -> None:
        hits, terms = ([], [])
        if self.memory is not None:
            limit = frame.get("limit") if isinstance(frame.get("limit"), int) else 20
            hits, terms = self.memory.search(str(frame.get("query") or ""), limit=max(1, min(limit, 100)),
                                             app=frame.get("app") or None)
        await client.send(
            {"t": "memory.results", "ts": _now(), "request_id": frame.get("id"), "terms": terms,
             "results": [h.to_frame(terms) for h in hits]}
        )

    async def _on_memory_recent(self, frame: dict, client: _Client) -> None:
        hits = []
        if self.memory is not None:
            limit = frame.get("limit") if isinstance(frame.get("limit"), int) else 50
            hits = self.memory.recent(limit=max(1, min(limit, 200)), app=frame.get("app") or None)
        await client.send(
            {"t": "memory.results", "ts": _now(), "request_id": frame.get("id"), "terms": [],
             "results": [h.to_frame() for h in hits]}
        )

    async def _on_memory_delete(self, frame: dict, client: _Client) -> None:
        count = 0
        if self.memory is not None:
            scope = frame.get("scope")
            if scope == "row" and isinstance(frame.get("row_id"), int):
                count = self.memory.delete(row_id=frame["row_id"])
            elif scope == "app" and frame.get("app"):
                count = self.memory.delete(app=str(frame["app"]))
            elif scope == "range":
                since = frame.get("since") if isinstance(frame.get("since"), (int, float)) else None
                until = frame.get("until") if isinstance(frame.get("until"), (int, float)) else None
                if since is None and until is None:
                    raise ValueError("range delete needs since or until")
                count = self.memory.delete(since=since, until=until, app=frame.get("app") or None)
            elif scope == "query" and frame.get("query"):
                count = self.memory.delete(query=str(frame["query"]))
            elif scope == "all":
                count = self.memory.delete(everything=True)
            else:
                raise ValueError(f"unknown delete scope {scope!r}")
            if count >= 50 or scope == "all":
                await self._run_model(self.memory.compact)
        await client.send({"t": "memory.deleted", "ts": _now(), "request_id": frame.get("id"), "count": count})

    async def _on_memory_stats(self, frame: dict, client: _Client) -> None:
        stats = self.memory.stats() if self.memory is not None else {"rows": 0, "apps": []}
        await client.send({"t": "memory.stats", "ts": _now(), "request_id": frame.get("id"), **stats})

    async def _on_history_delete(self, frame: dict, client: _Client) -> None:
        count = audit_mod.delete_all(self.conn)
        self.personalizer.refresh()
        await client.send({"t": "history.deleted", "ts": _now(), "request_id": frame.get("id"), "count": count})

    # ------------------------------------------------------------ learning and stats

    async def _on_stats(self, frame: dict, client: _Client) -> None:
        days = frame.get("days") if isinstance(frame.get("days"), int) else 30
        await client.send(
            {
                "t": "stats",
                "ts": _now(),
                "request_id": frame.get("id"),
                "decisions": audit_mod.summary(self.conn, since=_now() - days * 86400),
                "learning": self.personalizer.snapshot(self.settings.floor),
                "memory": self.memory.stats() if self.memory is not None else None,
                "state": self.state,
                "model": self.model_name,
            }
        )

    async def _on_learning_forget(self, frame: dict, client: _Client) -> None:
        self.personalizer.forget(str(frame.get("rule_id") or ""))
        await self._on_stats(frame, client)

    async def _on_learning_mute(self, frame: dict, client: _Client) -> None:
        sender = str(frame.get("sender") or "").strip()
        if not sender:
            raise ValueError("learning.mute needs a sender")
        self.personalizer.mute(sender)
        await self._on_stats(frame, client)

    # ------------------------------------------------------------ gate and action loop

    async def _on_frame(self, frame: dict, client: _Client) -> None:
        event_id = frame.get("id") or frame.get("event_id") or ""
        data = frame.get("data") or frame.get("png") or frame.get("image")
        if not data:
            await client.send(_error_frame("frame missing image data"))
            return
        started = time.perf_counter()
        luminance = _decode_png_luminance(data)
        verdict = self.gate(luminance)
        ms = (time.perf_counter() - started) * 1000
        await client.send(
            {
                "t": "trace",
                "ts": _now(),
                "event_id": event_id,
                "stage": "gate",
                "detail": f"{verdict.reason} {verdict.distance:.4f} vs {self.gate.threshold}",
                "ms": ms,
            }
        )

    async def _on_observe(self, frame: dict, client: _Client) -> None:
        observation_id = str(frame.get("id") or "")
        if self.attention is None:
            await client.send(_error_frame(f"model {self.state}", request_id=observation_id))
            return
        candidates = frame.get("candidates") or []
        if len(candidates) > MAX_CANDIDATES:
            raise ValueError(f"too many candidates ({len(candidates)} > {MAX_CANDIDATES})")
        result = await self._run_model(score_action, self.attention.engine, frame, floor=self.settings.floor)
        await client.send(act_frame(observation_id, result))


# ---------------------------------------------------------------- serve


class _Loader:
    """Loads the model off the event loop and hands it to the server."""

    def __init__(self, server: LeonardServer, model_id: str):
        self.server = server
        self.model_id = model_id
        self.lock = asyncio.Lock()

    def available(self) -> bool:
        from .engine import resolve_local

        resolved = Path(resolve_local(self.model_id))
        return (resolved / "config.json").is_file()

    async def __call__(self) -> None:
        async with self.lock:
            if self.server.state == "ready":
                return
            if not self.available():
                self.server.set_state("model_missing", self.model_id)
                await self.server.broadcast(self.server._status_frame())
                logger.info("model %s is not installed; waiting for reload", self.model_id)
                return
            self.server.set_state("loading", self.model_id)
            await self.server.broadcast(self.server._status_frame())
            loop = asyncio.get_running_loop()
            try:
                attention, timings = await loop.run_in_executor(None, self._load)
            except Exception as exc:  # a corrupt checkpoint must not take the daemon down
                logger.error("model load failed: %s", type(exc).__name__)
                self.server.set_state("error", f"{type(exc).__name__}: {exc}")
                await self.server.broadcast(self.server._status_frame())
                return
            self.server.set_ready(attention, model_name=self.model_id, **timings)
            logger.info("model ready (prime %.0fms, warm decide %.0fms)", timings["prime_ms"], timings["decide_ms"])
            await self.server.broadcast(self.server._ready_frame())

    def _load(self):
        from .engine import ResidentMLX

        t0 = time.perf_counter()
        engine = ResidentMLX(self.model_id)
        t1 = time.perf_counter()
        logger.info("weights loaded in %.0fms", (t1 - t0) * 1000)
        attention = AttentionEngine(
            engine, settings=self.server.settings, personalizer=self.server.personalizer
        )
        prime_ms = (time.perf_counter() - t1) * 1000
        t2 = time.perf_counter()
        warm_settings = replace(self.server.settings, proactive_kinds=frozenset({"mail.opened"}))
        attention.settings = warm_settings
        attention.decide_event(_WARMUP_EVENT)
        attention.settings = self.server.settings
        attention.tracker = type(attention.tracker)()
        decide_ms = (time.perf_counter() - t2) * 1000
        return attention, {"prime_ms": prime_ms, "decide_ms": decide_ms}


async def serve(
    *,
    model_id: str,
    floor: float | None = None,
    socket_path: Path | str = DEFAULT_SOCKET_PATH,
    data_dir: Path | str = DEFAULT_DATA_DIR,
    audit_path: Path | str | None = None,
    stop: asyncio.Event | None = None,
) -> None:
    data_dir = Path(data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(data_dir, 0o700)
    settings_path = data_dir / "settings.json"
    settings = settings_mod.load(settings_path)
    if floor is not None:
        settings = replace(settings, floor=floor)

    conn = open_db(audit_path if audit_path is not None else data_dir / "audit.db")
    memory = MemoryStore(data_dir / "memory.db")
    server_impl = LeonardServer(
        None,
        conn,
        socket_path=socket_path,
        model_name=model_id,
        memory=memory,
        settings=settings,
        settings_path=settings_path,
        state="loading",
    )
    server_impl.sweep()
    loader = _Loader(server_impl, model_id)
    server_impl._reload_hook = loader

    asyncio_server = await server_impl.start()
    logger.info("listening on %s (protocol %d, v%s)", socket_path, PROTOCOL_VERSION, __version__)
    server_impl._spawn(loader())

    async def sweeper() -> None:
        while True:
            await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
            server_impl.sweep()

    server_impl._spawn(sweeper())
    try:
        async with asyncio_server:
            if stop is None:
                await asyncio_server.serve_forever()
            else:
                await stop.wait()
    finally:
        server_impl.close()
        try:
            Path(socket_path).unlink()
        except OSError:
            pass


_WARMUP_EVENT = {
    "t": "event",
    "ts": 0.0,
    "id": "evt_warmup",
    "kind": "mail.opened",
    "app": "Mail",
    "payload": {
        "sender": "Leonard <leonard@localhost>",
        "subject": "warm-up",
        "body": "This message exists only to warm the model's kernels and caches at startup.",
        "thread_len": 1,
        "unread": True,
    },
}


__all__ = ["LeonardServer", "serve", "DEFAULT_SOCKET_PATH", "DEFAULT_DATA_DIR", "PROTOCOL_VERSION", "mail_observation"]
