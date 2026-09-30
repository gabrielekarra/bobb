"""Bobb's license keys: generate the signing key, issue keys, verify them.

A key is `BOBB-<base64url(payload)>.<base64url(signature)>`, where the
payload is compact JSON and the signature is Ed25519 over its exact bytes.
The app verifies it offline with the public key stamped into Info.plist;
see `BobbApp/Sources/BobbCore/License/License.swift`.

    uv run python license_tool.py keygen --out ~/secure/bobb-signing.key
    uv run python license_tool.py issue --key ~/secure/bobb-signing.key \\
        --name "Studio Rossi" --email marco@studiorossi.it --edition pro --seats 3
    uv run python license_tool.py verify --public <base64url> BOBB-...

The signing key is the business. Keep it offline, back it up twice, never
commit it. `dev-signing.key` in this directory is the *development* key: its
public half is baked into development builds only, and `scripts/package.sh
--release` refuses to build unless a production public key is supplied.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import secrets
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

PREFIX = "BOBB-"
EDITIONS = ("personal", "pro", "team")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def load_private(path: Path) -> Ed25519PrivateKey:
    raw = unb64url(path.read_text().strip())
    return Ed25519PrivateKey.from_private_bytes(raw)


def public_b64(private: Ed25519PrivateKey) -> str:
    raw = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return b64url(raw)


def keygen(out: Path) -> str:
    if out.exists():
        raise SystemExit(f"{out} exists; refusing to overwrite a signing key")
    private = Ed25519PrivateKey.generate()
    raw = private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(b64url(raw) + "\n")
    out.chmod(0o600)
    return public_b64(private)


def issue(private: Ed25519PrivateKey, *, name: str, email: str, edition: str, seats: int,
          issued: dt.date | None = None, update_years: int = 1, license_id: str | None = None) -> str:
    if edition not in EDITIONS:
        raise ValueError(f"edition must be one of {EDITIONS}")
    issued = issued or dt.date.today()
    try:
        until = issued.replace(year=issued.year + update_years)
    except ValueError:  # 29 February
        until = issued.replace(year=issued.year + update_years, day=28)
    payload = {
        "v": 1,
        "id": license_id or "lic_" + secrets.token_hex(8),
        "name": name,
        "email": email,
        "edition": edition,
        "seats": seats,
        "issued": issued.isoformat(),
        "updates_until": until.isoformat(),
    }
    data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return PREFIX + b64url(data) + "." + b64url(private.sign(data))


def verify(key: str, public: str) -> dict:
    compact = "".join(key.split())
    if not compact.startswith(PREFIX):
        raise ValueError("not a Bobb license key")
    payload_b64, _, signature_b64 = compact[len(PREFIX):].partition(".")
    data = unb64url(payload_b64)
    Ed25519PublicKey.from_public_bytes(unb64url(public)).verify(unb64url(signature_b64), data)
    return json.loads(data)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    k = sub.add_parser("keygen")
    k.add_argument("--out", type=Path, required=True)
    i = sub.add_parser("issue")
    i.add_argument("--key", type=Path, required=True)
    i.add_argument("--name", required=True)
    i.add_argument("--email", required=True)
    i.add_argument("--edition", choices=EDITIONS, default="personal")
    i.add_argument("--seats", type=int, default=1)
    i.add_argument("--update-years", type=int, default=1)
    i.add_argument("--id", help="license id; reuse lic_ls_<order> to re-issue the worker's exact key")
    i.add_argument("--issued", type=dt.date.fromisoformat, help="issue date, YYYY-MM-DD (default: today)")
    v = sub.add_parser("verify")
    v.add_argument("--public", required=True)
    v.add_argument("key")
    p = sub.add_parser("public")
    p.add_argument("--key", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == "keygen":
        print(keygen(args.out))
    elif args.command == "issue":
        print(issue(load_private(args.key), name=args.name, email=args.email, edition=args.edition,
                    seats=args.seats, update_years=args.update_years, issued=args.issued, license_id=args.id))
    elif args.command == "verify":
        print(json.dumps(verify(args.key, args.public), indent=2, ensure_ascii=False))
    elif args.command == "public":
        print(public_b64(load_private(args.key)))


if __name__ == "__main__":
    sys.exit(main())
