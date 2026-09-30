"""A realistic working day, replayable over the contract socket.

This is the demo timeline, not an evaluation fixture. It is written to show
the product working rather than to score it: the events carry no labels, and
the point is what Bobb decides unprompted.

It exercises every mail event kind, including the four that exist only so the
specialist can learn from behaviour — `mail.arrived`, `mail.closed`,
`mail.archived`, `mail.deleted`. Those are most of the traffic here, as they
will be in real use, which is itself part of what the demo shows: Bobb
spends the day mostly staying quiet.

Replay with `python -m demo.day --speed 60` to compress an eight-hour day
into eight minutes, or `--speed 0` to fire everything as fast as the daemon
will answer.
"""

from __future__ import annotations

import argparse
import json
import socket
import time
import uuid
from pathlib import Path

SOCKET = Path.home() / "Library/Application Support/Bobb/bobbd.sock"

_T0 = 9 * 3600


def _at(h: int, m: int) -> int:
    return h * 3600 + m * 60 - _T0


def _mail(sender: str, subject: str, body: str, **kw) -> dict:
    return {"sender": sender, "subject": subject, "body": body, **kw}


MARCO = "Marco Rossi <marco@studiorossi.it>"
GIULIA = "Giulia Ferrara <g.ferrara@nordventures.com>"
OPS = "Atlas Cloud <billing@atlascloud.io>"
NEWS = "Techmeme <no-reply@techmeme.com>"
RECRUIT = "Dana Whitfield <dana@apexsearch.co>"

TIMELINE: list[tuple[int, str, str, dict]] = [
    (_at(9, 2), "app.activated", "Mail", {"typing": False}),

    (_at(9, 3), "mail.arrived", "Mail", _mail(
        NEWS, "Techmeme Daily — 20 September",
        "Today's top stories in tech. Unsubscribe at any time.",
        thread_len=1, unread=True, thread_id="t-news-0920", typing=False)),
    (_at(9, 4), "mail.archived", "Mail", {
        "thread_id": "t-news-0920", "sender": NEWS, "subject": "Techmeme Daily",
        "was_opened": False, "typing": False}),

    (_at(9, 11), "mail.arrived", "Mail", _mail(
        MARCO, "Preventivo revisione — mi confermi entro venerdì?",
        "Ciao Gabriele, ho rivisto i numeri del preventivo. Mi serve una "
        "conferma entro venerdì per bloccare la disponibilità del team. "
        "Ti torna la cifra? Marco",
        thread_len=3, unread=True, thread_id="t-marco-prev", typing=False)),
    (_at(9, 12), "mail.opened", "Mail", _mail(
        MARCO, "Preventivo revisione — mi confermi entro venerdì?",
        "Ciao Gabriele, ho rivisto i numeri del preventivo. Mi serve una "
        "conferma entro venerdì per bloccare la disponibilità del team. "
        "Ti torna la cifra? Marco",
        thread_len=3, unread=True, thread_id="t-marco-prev", typing=False)),

    (_at(9, 14), "mail.composing", "Mail", {
        "thread_id": "t-marco-prev", "recipient": MARCO, "typing": True}),

    (_at(9, 21), "app.activated", "Xcode", {"typing": False}),
    (_at(9, 22), "window.changed", "Xcode", {"title": "Bobb — attention.py", "typing": True}),

    (_at(10, 5), "mail.arrived", "Mail", _mail(
        OPS, "Your Atlas Cloud invoice is ready",
        "Invoice #4471 for September is available. Amount due: EUR 128.40. "
        "Payment will be taken automatically on 25 September.",
        thread_len=1, unread=True, thread_id="t-atlas-inv", typing=True)),

    (_at(10, 40), "idle.entered", "Xcode", {"idle": True, "typing": False}),
    (_at(11, 15), "idle.left", "Xcode", {"idle": False, "typing": False}),

    (_at(11, 18), "mail.arrived", "Mail", _mail(
        GIULIA, "Follow-up: term sheet e call di giovedì",
        "Gabriele, ti allego il term sheet rivisto dopo la call con il "
        "comitato. Due punti aperti sulla vesting e sulla governance. "
        "Riusciamo a sentirci giovedì mattina? Giulia",
        thread_len=5, unread=True, thread_id="t-giulia-ts", typing=False)),
    (_at(11, 19), "app.activated", "Mail", {"typing": False}),
    (_at(11, 19), "mail.opened", "Mail", _mail(
        GIULIA, "Follow-up: term sheet e call di giovedì",
        "Gabriele, ti allego il term sheet rivisto dopo la call con il "
        "comitato. Due punti aperti sulla vesting e sulla governance. "
        "Riusciamo a sentirci giovedì mattina? Giulia",
        thread_len=5, unread=True, thread_id="t-giulia-ts", typing=False)),
    (_at(11, 20), "app.activated", "Calendar", {"typing": False}),

    (_at(11, 26), "app.activated", "Mail", {"typing": False}),
    (_at(11, 26), "mail.closed", "Mail", {
        "thread_id": "t-atlas-inv", "sender": OPS, "dwell_ms": 4200,
        "still_unread": False, "typing": False}),

    (_at(12, 2), "mail.arrived", "Mail", _mail(
        RECRUIT, "Senior iOS role — worth a conversation?",
        "Hi Gabriele, I'm working with a Series B fintech looking for a "
        "senior iOS engineer. Would you be open to a short call this week?",
        thread_len=1, unread=True, thread_id="t-recruit-1", typing=False)),

    (_at(14, 30), "app.activated", "Xcode", {"typing": True}),
    (_at(15, 45), "mail.arrived", "Mail", _mail(
        MARCO, "Re: Preventivo revisione — sollecito",
        "Gabriele, scusa l'insistenza: il team mi chiede una risposta entro "
        "domani mattina, altrimenti perdiamo lo slot. Marco",
        thread_len=4, unread=True, thread_id="t-marco-prev", typing=True)),

    (_at(16, 10), "idle.entered", "Xcode", {"idle": True, "typing": False}),
    (_at(16, 55), "idle.left", "Mail", {"idle": False, "typing": False}),
    (_at(16, 56), "mail.opened", "Mail", _mail(
        MARCO, "Re: Preventivo revisione — sollecito",
        "Gabriele, scusa l'insistenza: il team mi chiede una risposta entro "
        "domani mattina, altrimenti perdiamo lo slot. Marco",
        thread_len=4, unread=True, thread_id="t-marco-prev", typing=False)),

    (_at(17, 30), "mail.closed", "Mail", {
        "thread_id": "t-recruit-1", "sender": RECRUIT, "dwell_ms": 51000,
        "still_unread": True, "typing": False}),
    (_at(17, 31), "mail.deleted", "Mail", {
        "thread_id": "t-recruit-1", "sender": RECRUIT, "was_opened": True,
        "typing": False}),
]


def frames(start: float) -> list[dict]:
    return [
        {"t": "event", "ts": start + offset, "id": "evt_" + uuid.uuid4().hex[:8],
         "kind": kind, "app": app, "payload": payload}
        for offset, kind, app, payload in TIMELINE
    ]


def replay(speed: float, socket_path: Path = SOCKET) -> None:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(str(socket_path))
    f = s.makefile("rwb")

    def send(obj: dict) -> None:
        f.write((json.dumps(obj) + "\n").encode())
        f.flush()

    send({"t": "hello", "client": "demo.day", "version": "0.1"})

    started = time.time()
    pending = frames(started)
    sent = 0
    spoke = 0

    for frame, (offset, kind, _, _) in zip(pending, TIMELINE):
        if speed > 0 and sent:
            delay = (offset - TIMELINE[sent - 1][0]) / speed
            if delay > 0:
                time.sleep(delay)
        send(frame)
        sent += 1
        print(f"  → {kind}")

    deadline = time.time() + 180
    while sent and time.time() < deadline:
        line = f.readline()
        if not line:
            break
        msg = json.loads(line)
        if msg.get("t") != "decision":
            continue
        sent -= 1
        mark = "!" if msg["action"] == "suggest" else " "
        note = " (abstained)" if msg.get("abstained") else ""
        print(f"{mark} {msg['action']:<8} {msg['confidence']:.2f}{note}")
        if msg.get("suggestion"):
            spoke += 1
            print(f"    ▸ {msg['suggestion'].get('title')}")

    print(f"\n{len(TIMELINE)} events, spoke {spoke} times")
    s.close()


def main() -> None:
    ap = argparse.ArgumentParser(prog="demo.day")
    ap.add_argument("--speed", type=float, default=0.0,
                    help="wall-clock compression; 60 turns an hour into a minute, 0 fires immediately")
    ap.add_argument("--socket", default=str(SOCKET))
    args = ap.parse_args()
    replay(args.speed, Path(args.socket))


if __name__ == "__main__":
    main()
