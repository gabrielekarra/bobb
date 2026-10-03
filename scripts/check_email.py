#!/usr/bin/env python3
"""Exercise every Email writing tool on the real local daemon.

Synthetic mail and a temporary database only. An optional native binary
also tests and captures the production Email view without invoking Mail.
"""
import argparse
import asyncio
import json
import os
import re
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


async def run(args):
    with tempfile.TemporaryDirectory(prefix="bobb-email-", dir="/private/tmp") as directory:
        path = Path(directory)
        log = (path / "daemon.log").open("w")
        process = await asyncio.create_subprocess_exec(str(ROOT / "bobbd/.venv/bin/python"), "-m", "bobbd",
            "--data-dir", directory, "--socket", str(path / "b.sock"), cwd=ROOT / "bobbd",
            env={**os.environ, "BOBB_MODELS_DIR": str(ROOT / ".runtime/models")}, stdout=log, stderr=log)
        writer = None
        try:
            for _ in range(240):
                if process.returncode is not None: raise RuntimeError((path / "daemon.log").read_text()[-4000:])
                if (path / "b.sock").exists(): break
                await asyncio.sleep(.25)
            reader, writer = await asyncio.open_unix_connection(str(path / "b.sock"), limit=1024 * 1024)
            async def send(frame):
                writer.write((json.dumps(frame) + "\n").encode()); await writer.drain()
            async def receive(kind):
                while True:
                    raw = await asyncio.wait_for(reader.readline(), 120)
                    if not raw: raise RuntimeError("Daemon disconnected")
                    frame = json.loads(raw)
                    if frame["t"] == "error": raise RuntimeError(frame)
                    if frame["t"] == kind: return frame
            await send({"t": "hello", "locale": "it"})
            ready = await receive("ready")
            await send({"t": "settings", "proactive_kinds": [], "context_proactive": False,
                        "memory_enabled": True, "quiet_hours": None, "timezone": "Europe/Rome"})
            await receive("settings")
            now = time.time()
            incoming = {"message_id": "incoming@example.test", "sender": "Marco Rossi <marco@example.test>",
                        "to": "Gabriele <gabriele@example.test>", "subject": "Consegna preventivo", "sent_at": now,
                        "body": "Ciao Gabriele, puoi confermare il preventivo di 450 euro entro domani alle 15:30? Qual è la data prevista di consegna? Grazie, Marco",
                        "attachments": ["preventivo.pdf"]}
            outgoing = {"message_id": "outgoing@example.test", "sender": "Gabriele <gabriele@example.test>",
                        "to": "Marco Rossi <marco@example.test>", "subject": "Documentazione progetto", "sent_at": now - 86400,
                        "direction": "sent", "body": "Ciao Marco, puoi inviarmi le misure del lotto per completare il confronto? Grazie, Gabriele"}
            await send({"t": "email.command", "id": "email_ingest", "op": "ingest", "payload": {"items": [incoming, outgoing]}})
            initial = await receive("email.state")
            assert initial["counts"]["all"] == 2 and initial["counts"]["reply"] == 1
            cases = [
                ("summary", {}), ("actions", {}), ("questions", {"instruction": "Qual è il prezzo e cosa manca per decidere?"}),
                ("reply", {}), ("reply_accept", {"instruction": "accept"}),
                ("followup", {"message_id": outgoing["message_id"]}),
                ("forward", {"instruction": "Introduci questo messaggio a una collega chiedendo un parere, senza decidere."}),
                ("new", {"instruction": "Scrivi a Marco chiedendo le misure del lotto per preparare il confronto. Firma Gabriele."}),
                ("rewrite", {"instruction": "Rendi questa bozza più cordiale, senza cambiare la data.", "draft": "Ciao Marco, la data proposta è il 15 ottobre. Attendo conferma. Gabriele"}),
                ("translate", {"target": "English", "draft": "La data proposta è il 15 ottobre, in attesa di conferma."}),
                ("digest", {}), ("meeting", {}),
            ]
            rows = []
            for name, overrides in cases:
                operation = "reply" if name == "reply_accept" else name
                payload = {"message_id": incoming["message_id"], **overrides}
                identifier = "email_" + name
                started = time.monotonic()
                await send({"t": "email.command", "id": identifier, "op": operation, "payload": payload})
                streamed, first, deltas = "", None, 0
                while True:
                    frame = json.loads(await asyncio.wait_for(reader.readline(), 120))
                    if frame["t"] == "error": raise RuntimeError(frame)
                    if frame.get("request_id") != identifier: continue
                    if frame["t"] == "email.delta":
                        streamed += frame["text"]; deltas += 1
                        if first is None: first = (time.monotonic() - started) * 1000
                    elif frame["t"] == "email.state": break
                result = frame["result"]
                ok = bool(result["text"].strip()) and not result.get("error") and result.get("cancelled") is not True
                assert ok, result
                if name == "reply":
                    assert not re.search(r"(?i)\b(?:accetto|confermo il preventivo|i accept|i confirm the quote)\b", result["text"]), result
                    assert not re.search(r"(?i)\b(?:resto in attesa|waiting for your)\b", result["text"]), result
                if name == "reply_accept":
                    assert not re.search(r"(?i)(?:giorno successivo|ricezione del pagamento|after.{0,30}payment)", result["text"]), result
                if name == "rewrite": assert "15" in result["text"], result
                rows.append({"case": name, "ok": ok, "first_delta_ms": round(first, 2) if first is not None else None,
                             "completion_ms": round((time.monotonic() - started) * 1000, 2), "deltas": deltas,
                             "result_kind": result["result_kind"], "text": result["text"], "unsupported": result.get("unsupported", []), "review_notes": result.get("review_notes", [])})
                print(f"{name}: passed, {rows[-1]['completion_ms']} ms", flush=True)
            native = None
            if args.native_binary:
                native_report = Path(args.output).with_name("email-ui-2026-10-03.json")
                native = await asyncio.create_subprocess_exec(args.native_binary, "--check-email", "--socket", str(path / "b.sock"),
                    "--report", str(native_report), "--screenshots", args.screenshots, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
                output, _ = await asyncio.wait_for(native.communicate(), 180)
                if native.returncode != 0: raise RuntimeError(output.decode()[-4000:])
                native = json.loads(native_report.read_text())
                assert native["passed"], native
                print("native email workspace: passed", flush=True)
            report = {"passed": True, "scope": "Real local model, Unix socket, temporary database and synthetic emails; live Mail insertion is separate.",
                      "model": ready["model"], "cases": rows, "native": native,
                      "seconds": round(sum(r["completion_ms"] for r in rows) / 1000, 2)}
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
            print("Report: " + args.output, flush=True)
        finally:
            if writer is not None: writer.close()
            if process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 15)
                except asyncio.TimeoutError: process.kill(); await process.wait()
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(ROOT / "docs/benchmarks/email-2026-10-03.json"))
    parser.add_argument("--native-binary")
    parser.add_argument("--screenshots", default=str(ROOT / "docs/images/email"))
    asyncio.run(run(parser.parse_args()))
