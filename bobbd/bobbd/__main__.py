"""`python -m bobbd`: bind the socket, load the model, serve until told to stop.

In the shipped app the daemon is a child of Bobb.app, which passes
`--parent-pid`. If that process disappears — a crash, a force quit — the
daemon exits within a few seconds instead of holding the model weights in
unified memory for nobody. A lock file in the data directory makes a second
daemon on the same data exit immediately rather than fight the first over
the socket.

Logs carry timings, states and error *types*. They never carry message
bodies, screen text, prompts or generated text (`docs/CONTRACT.md`,
invariant 5); `tests/test_main.py` holds that line.
"""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import logging
import logging.handlers
import os
import signal
import sys
from pathlib import Path

from . import __version__
from .server import DEFAULT_DATA_DIR, serve

DEFAULT_MODEL = "mlx-community/Qwen3.5-4B-4bit"
PARENT_POLL_SECONDS = 2.0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="bobbd", description="Bobb's on-device daemon.")
    parser.add_argument("--version", action="version", version=f"bobbd {__version__}")
    parser.add_argument("--floor", type=float, default=None, help="override the saved interruption floor")
    parser.add_argument("--model", default=os.environ.get("BOBB_MODEL", DEFAULT_MODEL))
    parser.add_argument("--data-dir", default=os.environ.get("BOBB_DATA_DIR", str(DEFAULT_DATA_DIR)))
    parser.add_argument("--socket", default=None, help="defaults to <data-dir>/bobbd.sock")
    parser.add_argument("--log-file", default=None, help="rotating log file; stderr when omitted")
    parser.add_argument("--log-level", default="INFO")
    parser.add_argument("--parent-pid", type=int, default=None, help="exit when this process exits")
    return parser.parse_args(argv)


def configure_logging(level: str, log_file: str | None) -> None:
    handlers: list[logging.Handler]
    if log_file:
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        handlers = [logging.handlers.RotatingFileHandler(log_file, maxBytes=2_000_000, backupCount=3)]
    else:
        handlers = [logging.StreamHandler(sys.stderr)]
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
        force=True,
    )
    # Third-party libraries log at INFO with arguments we do not control.
    for noisy in ("transformers", "huggingface_hub", "urllib3", "filelock"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def acquire_lock(data_dir: Path):
    """An exclusive, non-blocking lock held for the life of the process.
    Returns the open file (keep a reference) or None if another daemon has it."""
    data_dir.mkdir(parents=True, exist_ok=True)
    handle = open(data_dir / "bobbd.lock", "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def parent_alive(pid: int) -> bool:
    if os.getppid() != pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


async def _run(args: argparse.Namespace) -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    if args.parent_pid:
        async def watch_parent() -> None:
            while not stop.is_set():
                if not parent_alive(args.parent_pid):
                    logging.getLogger("bobbd").info("parent %d is gone; shutting down", args.parent_pid)
                    stop.set()
                    return
                await asyncio.sleep(PARENT_POLL_SECONDS)

        watcher = asyncio.create_task(watch_parent())
    else:
        watcher = None

    data_dir = Path(args.data_dir)
    socket_path = Path(args.socket) if args.socket else data_dir / "bobbd.sock"
    try:
        await serve(model_id=args.model, floor=args.floor, socket_path=socket_path, data_dir=data_dir, stop=stop)
    finally:
        if watcher is not None:
            watcher.cancel()


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    if args.floor is not None and not (0.0 <= args.floor <= 1.0):
        raise SystemExit(f"--floor must be in [0, 1], got {args.floor}")
    configure_logging(args.log_level, args.log_file)
    lock = acquire_lock(Path(args.data_dir))
    if lock is None:
        logging.getLogger("bobbd").error("another bobbd is already running on %s", args.data_dir)
        raise SystemExit(3)
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        pass
    finally:
        lock.close()


if __name__ == "__main__":
    main()
