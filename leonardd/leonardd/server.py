"""Async unix-socket server implementing the Leonard IPC contract.

NDJSON both ways over a single unix domain socket, one object per line. A
malformed line becomes an `error` frame, never a dropped connection: `_dispatch`
catches everything from a single frame's handling and reports it rather than
letting it propagate into the read loop. Unknown `t` values are silently
ignored, per the contract.

Inference runs on a single-worker executor so the asyncio loop stays free to
read/write other connections while a decision is in flight, and so two
events are never advanced through the resident model's shared cache at once.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np

from .attention import AttentionEngine
from .audit import fetch_decision, open_db, record_decision, record_response
from .draft import draft_reply, supports_generation
from .gate import FrameGate

DEFAULT_SOCKET_PATH = Path.home() / "Library" / "Application Support" / "Leonard" / "leonardd.sock"

logger = logging.getLogger("leonardd")


def _now() -> float:
    return time.time()


def _error_frame(detail: str) -> dict:
    return {"t": "error", "ts": _now(), "detail": detail}


def _decode_png_luminance(b64_data: str) -> np.ndarray:
    from PIL import Image

    raw = base64.b64decode(b64_data)
    image = Image.open(io.BytesIO(raw)).convert("L")
    return np.array(image, dtype=np.uint8)


def _prepare_placeholder(suggestion: dict) -> dict:
    action_id = suggestion.get("action_id", "")
    return {
        "kind": "text",
        "body": f"[{action_id}: generazione del contenuto non ancora implementata in leonardd]",
    }


def _event_from_row(row: dict) -> dict:
    return {
        "kind": row.get("kind", ""),
        "app": row.get("app"),
        "payload": json.loads(row["event_payload"]) if row.get("event_payload") else {},
    }


class LeonardServer:
    def __init__(
        self,
        attention: AttentionEngine,
        conn,
        *,
        socket_path: Path | str = DEFAULT_SOCKET_PATH,
        model_name: str = "",
        prime_ms: float = 0.0,
        decide_ms: float = 0.0,
        gate: FrameGate | None = None,
    ):
        self.attention = attention
        self.conn = conn
        self.socket_path = Path(socket_path)
        self.model_name = model_name
        self.prime_ms = prime_ms
        self.decide_ms = decide_ms
        self.gate = gate or FrameGate()
        self._executor = ThreadPoolExecutor(max_workers=1)

    async def start(self) -> asyncio.base_events.Server:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            self.socket_path.unlink()
        server = await asyncio.start_unix_server(self._handle_client, path=str(self.socket_path))
        os.chmod(self.socket_path, 0o600)
        return server

    def close(self) -> None:
        self._executor.shutdown(wait=False)
        self.conn.close()

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if not line.strip():
                    continue
                await self._dispatch(line, writer)
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _send(self, writer: asyncio.StreamWriter, frame: dict) -> None:
        writer.write((json.dumps(frame) + "\n").encode("utf-8"))
        await writer.drain()

    async def _dispatch(self, line: bytes, writer: asyncio.StreamWriter) -> None:
        try:
            frame = json.loads(line)
        except json.JSONDecodeError as exc:
            await self._send(writer, _error_frame(f"malformed json: {exc}"))
            return
        if not isinstance(frame, dict) or "t" not in frame:
            await self._send(writer, _error_frame("frame missing 't'"))
            return

        kind = frame.get("t")
        handler = {
            "hello": self._on_hello,
            "event": self._on_event,
            "approve": lambda f, w: self._on_response(f, w, "approve"),
            "dismiss": lambda f, w: self._on_response(f, w, "dismiss"),
            "policy": self._on_policy,
            "frame": self._on_frame,
        }.get(kind)
        if handler is None:
            return
        try:
            await handler(frame, writer)
        except Exception as exc:
            logger.warning("error handling %s frame: %s", kind, exc)
            await self._send(writer, _error_frame(f"{kind}: {exc}"))

    async def _on_hello(self, frame: dict, writer: asyncio.StreamWriter) -> None:
        await self._send(
            writer,
            {
                "t": "ready",
                "ts": _now(),
                "model": self.model_name,
                "prime_ms": self.prime_ms,
                "decide_ms": self.decide_ms,
                "floor": self.attention.floor,
            },
        )

    async def _on_event(self, event: dict, writer: asyncio.StreamWriter) -> None:
        loop = asyncio.get_running_loop()
        decision: dict[str, Any] = await loop.run_in_executor(self._executor, self.attention.decide_event, event)
        record_decision(self.conn, decision, event, floor=self.attention.floor, model=self.model_name)
        await self._send(
            writer,
            {
                "t": "trace",
                "ts": _now(),
                "event_id": event.get("id", ""),
                "stage": "attention",
                "detail": decision["action"],
                "ms": decision["latency_ms"],
            },
        )
        await self._send(writer, decision)

    async def _on_response(self, frame: dict, writer: asyncio.StreamWriter, response: str) -> None:
        decision_id = frame.get("decision_id", "")
        found = record_response(self.conn, decision_id, response, frame.get("ts"))
        if not found:
            await self._send(writer, _error_frame(f"unknown decision_id {decision_id!r}"))
            return
        if response != "approve":
            return
        row = fetch_decision(self.conn, decision_id)
        suggestion_json = row.get("suggestion") if row else None
        if not suggestion_json:
            return
        suggestion = json.loads(suggestion_json)
        started = time.perf_counter()
        if suggestion.get("action_id") == "draft_reply" and supports_generation(self.attention.engine):
            loop = asyncio.get_running_loop()
            event = _event_from_row(row)
            body = await loop.run_in_executor(
                self._executor, draft_reply, self.attention.engine, event
            )
            result = {"kind": "text", "body": body}
        else:
            result = _prepare_placeholder(suggestion)
        await self._send(
            writer,
            {
                "t": "prepared",
                "ts": _now(),
                "decision_id": decision_id,
                "action_id": suggestion.get("action_id", ""),
                "result": result,
                "latency_ms": (time.perf_counter() - started) * 1000,
            },
        )

    async def _on_policy(self, frame: dict, writer: asyncio.StreamWriter) -> None:
        floor = frame.get("floor")
        if isinstance(floor, (int, float)) and 0.0 <= floor <= 1.0:
            self.attention.set_floor(float(floor))

    async def _on_frame(self, frame: dict, writer: asyncio.StreamWriter) -> None:
        event_id = frame.get("id") or frame.get("event_id") or ""
        data = frame.get("data") or frame.get("png") or frame.get("image")
        if not data:
            await self._send(writer, _error_frame("frame missing image data"))
            return
        started = time.perf_counter()
        luminance = _decode_png_luminance(data)
        verdict = self.gate(luminance)
        ms = (time.perf_counter() - started) * 1000
        await self._send(
            writer,
            {
                "t": "trace",
                "ts": _now(),
                "event_id": event_id,
                "stage": "gate",
                "detail": f"{verdict.reason} {verdict.distance:.4f} vs {self.gate.threshold}",
                "ms": ms,
            },
        )


async def serve(
    *,
    model_id: str,
    floor: float,
    socket_path: Path | str = DEFAULT_SOCKET_PATH,
    audit_path: Path | str | None = None,
) -> None:
    from .audit import DEFAULT_PATH
    from .engine import ResidentMLX

    logger.info("loading %s", model_id)
    t0 = time.perf_counter()
    engine = ResidentMLX(model_id)
    load_ms = (time.perf_counter() - t0) * 1000

    t1 = time.perf_counter()
    attention = AttentionEngine(engine, floor=floor)
    prime_ms = (time.perf_counter() - t1) * 1000

    t2 = time.perf_counter()
    attention.decide_event(_WARMUP_EVENT)
    decide_ms = (time.perf_counter() - t2) * 1000

    conn = open_db(audit_path if audit_path is not None else DEFAULT_PATH)
    server_impl = LeonardServer(
        attention,
        conn,
        socket_path=socket_path,
        model_name=model_id,
        prime_ms=prime_ms,
        decide_ms=decide_ms,
    )
    asyncio_server = await server_impl.start()
    logger.info(
        "listening on %s (load %.1fms, prime %.1fms, warm decide %.1fms, floor %.2f)",
        socket_path,
        load_ms,
        prime_ms,
        decide_ms,
        floor,
    )
    async with asyncio_server:
        await asyncio_server.serve_forever()


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


__all__ = ["LeonardServer", "serve", "DEFAULT_SOCKET_PATH"]
