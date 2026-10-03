#!/usr/bin/env python3
"""Real local models: reply offer -> explicit approval -> streamed draft.

Uses a temporary database and synthetic emails; never opens Mail or sends.
Native compose detection is covered separately by BobbCore's Swift tests.
"""
import asyncio
import argparse
import json
import os
from pathlib import Path
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


async def run(output):
    with tempfile.TemporaryDirectory(prefix="bobb-reply-", dir="/private/tmp") as directory:
        path = Path(directory)
        log = (path / "daemon.log").open("w")
        process = await asyncio.create_subprocess_exec(str(ROOT / "bobbd/.venv/bin/python"), "-m", "bobbd",
            "--data-dir", directory, "--socket", str(path / "b.sock"), cwd=ROOT / "bobbd",
            env={**os.environ, "BOBB_MODELS_DIR": str(ROOT / ".runtime/models")}, stdout=log, stderr=log)
        writer = None
        try:
            for _ in range(240):
                if process.returncode is not None: raise RuntimeError((path / "daemon.log").read_text())
                if (path / "b.sock").exists(): break
                await asyncio.sleep(.25)
            reader, writer = await asyncio.open_unix_connection(str(path / "b.sock"))
            async def send(frame):
                writer.write((json.dumps(frame) + "\n").encode()); await writer.drain()
            async def receive(kind):
                while True:
                    raw = await asyncio.wait_for(reader.readline(), 90)
                    if not raw: raise RuntimeError("Daemon disconnected")
                    frame = json.loads(raw)
                    if frame["t"] == "error": raise RuntimeError(frame)
                    if frame["t"] == kind: return frame
            await send({"t": "hello", "locale": "it"})
            await receive("ready")
            await send({"t": "settings", "proactive_kinds": ["mail.reply_started"], "context_proactive": False,
                        "memory_enabled": False, "quiet_hours": None})
            await receive("settings")
            cases = [
                ("confirmation", "Marco Rossi <marco@example.test>", "Preventivo", "Ciao Gabriele, mi confermi il preventivo di 450 euro? Grazie, Marco"),
                ("document", "Maria Bianchi <maria@example.test>", "Pratica Rossi", "Buongiorno Gabriele, per completare la pratica Rossi manca la procura firmata. Puoi inviarmela? Grazie, Maria"),
                ("english", "Dana Smith <dana@example.test>", "Design review", "Hi Gabriele, can you suggest a time for the design review? Thanks, Dana"),
            ]
            rows = []
            for name, sender, subject, body in cases:
                event = {"t": "event", "id": name, "kind": "mail.reply_started", "app": "Mail", "payload": {
                    "sender": sender, "subject": subject, "body": body, "message_id": f"<{name}@example.test>",
                    "compose_id": name, "draft": "", "typing": False, "idle": False}}
                started = time.monotonic()
                await send(event)
                decision = await receive("decision")
                offer_ms = (time.monotonic() - started) * 1000
                assert decision["action"] == "suggest" and decision["tier"] == "gesture", decision
                # A timeout must not count as rejection; dismissing explicitly
                # must not start generation. A new compose has its own offer.
                if name == "confirmation":
                    await send({"t": "dismiss", "decision_id": decision["id"], "reason": "user"})
                    await send({**event, "id": "repeat"})
                    assert (await receive("decision"))["action"] == "ignore"
                    event["id"] = "confirmation-new"
                    event["payload"]["compose_id"] = "confirmation-new"
                    await send(event)
                    decision = await receive("decision")
                started = time.monotonic()
                await send({"t": "approve", "decision_id": decision["id"]})
                first_ms = None
                streamed = ""
                deltas = 0
                while True:
                    raw = await asyncio.wait_for(reader.readline(), 90)
                    frame = json.loads(raw)
                    if frame["t"] == "error": raise RuntimeError(frame)
                    if frame.get("decision_id") != decision["id"]: continue
                    if frame["t"] == "prepared.delta" and frame.get("text"):
                        streamed += frame["text"]
                        deltas += 1
                        if deltas > 1 and first_ms is None and frame["text"].strip():
                            first_ms = (time.monotonic() - started) * 1000
                    if frame["t"] == "prepared": break
                assert "error" not in frame and frame["result"]["kind"] == "reply", frame
                assert frame["result"]["message_id"] == event["payload"]["message_id"]
                assert frame["result"]["body"] and first_ms is not None
                row = {"case": name, "source": body, "offer_ms": round(offer_ms, 2),
                       "first_draft_text_ms": round(first_ms, 1), "complete_ms": round((time.monotonic()-started)*1000, 1),
                       "draft": frame["result"]["body"], "unsupported": frame["result"]["unsupported"],
                       "generation_first_token_ms": frame.get("first_token_ms")}
                rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
            await send({"t": "bobb.command", "id": "snapshot", "op": "list", "payload": {}})
            snapshot = await receive("bobb.state")
            assert not snapshot["runs"], "Drafting enqueued an app action"
            result = {"passed": True, "scope": "Real Qwen3.5-4B + Kev daemon via Unix socket, synthetic emails; does not prove native Mail detection.",
                      "requires_approval": True, "duplicate_offer_suppressed": True, "no_app_actions": True, "cases": rows}
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        finally:
            if writer: writer.close(); await writer.wait_closed()
            if process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 10)
                except asyncio.TimeoutError: process.kill(); await process.wait()
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "docs/benchmarks/mail-reply-2026-10-03.json")
    asyncio.run(run(parser.parse_args().output))
