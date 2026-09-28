"""`python -m leonardd`: load the model, bind the socket, serve forever."""

from __future__ import annotations

import argparse
import asyncio
import logging

from .attention import DEFAULT_FLOOR
from .server import DEFAULT_SOCKET_PATH, serve

DEFAULT_MODEL = "mlx-community/Llama-3.2-3B-Instruct-4bit"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="leonardd")
    parser.add_argument("--floor", type=float, default=DEFAULT_FLOOR)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--socket", default=str(DEFAULT_SOCKET_PATH))
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if not (0.0 <= args.floor <= 1.0):
        raise SystemExit(f"--floor must be in [0, 1], got {args.floor}")
    try:
        asyncio.run(serve(model_id=args.model, floor=args.floor, socket_path=args.socket))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
