#!/usr/bin/env python3
"""Fetch pinned research assets; never changes Bobb's shipping model manifest."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / ".runtime/decision-benchmark"
CUA_REV = "16818868b0cc7813808aae4e87b417657046ab79"
BASE_REV = "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"
SOURCE_REV = "657a0c9ea5768573af53b43473c1cbcc4021b2c4"
BASE_SHARDS = {
    "model.safetensors-00001-of-00002.safetensors": "26a93f066e1916adb13453dae5a0c707c0fbc71299ed98779571a907b8e74c61",
    "model.safetensors-00002-of-00002.safetensors": "cb544bd9bfae93dc59b0f22b292f5933573854a7f9b97835c67060d7d910e188",
}


def checksum(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def fetch(spec):
    url, relative, expected = spec
    path = DEST / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        actual = checksum(path)
        if expected is None or actual == expected:
            return {"path": relative, "url": url, "bytes": path.stat().st_size, "sha256": actual}
    partial = path.with_suffix(path.suffix + ".part")
    for attempt in range(3):
        try:
            digest = hashlib.sha256()
            received = 0
            with urllib.request.urlopen(url, timeout=90) as response, partial.open("wb") as out:
                while block := response.read(8 << 20):
                    out.write(block)
                    digest.update(block)
                    received += len(block)
                    if received % (256 << 20) == 0:
                        print(f"{relative}: {received / 1e9:.2f} GB", flush=True)
            actual = digest.hexdigest()
            if expected and actual != expected:
                raise ValueError(f"Checksum mismatch: {relative}")
            partial.replace(path)
            print(f"Ready {relative} ({received / 1e6:.1f} MB)", flush=True)
            return {"path": relative, "url": url, "bytes": received, "sha256": actual}
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--with-base", action="store_true", help="Download the original 9.3 GB Qwen checkpoint for the official MPS runtime")
    args = parser.parse_args()
    specs = [
        (f"https://raw.githubusercontent.com/trycua/cua/{SOURCE_REV}/libs/cua-s1/python/src/cua_s1/four_b.py", "source/four_b.py", "7ed1adfd92223bef7d533db7efbb4cbf468c4936c4380ae42aee12097e3b9ea7"),
        (f"https://raw.githubusercontent.com/trycua/cua/{SOURCE_REV}/LICENSE.md", "source/LICENSE.md", None),
        (f"https://huggingface.co/cua-ai/cua-s1-4b-0.2/resolve/{CUA_REV}/text/adapter_config.json", "cua-s1/text/adapter_config.json", "c246fce1fe1d44160ae5f246f9881dfeabb4fcd67fe4a777cef10a1dbcf16540"),
        (f"https://huggingface.co/cua-ai/cua-s1-4b-0.2/resolve/{CUA_REV}/text/adapter_model.safetensors", "cua-s1/text/adapter_model.safetensors", "9b59c5aed96171a50b26526613766bbf44347a5c7af70f81efe6bcc6e9dbfb0e"),
        (f"https://huggingface.co/cua-ai/cua-s1-4b-0.2/resolve/{CUA_REV}/README.md", "cua-s1/README.md", None),
    ]
    if args.with_base:
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "merges.txt", "vocab.json", "model.safetensors.index.json", "preprocessor_config.json", "video_preprocessor_config.json", "LICENSE", *BASE_SHARDS]:
            specs.append((f"https://huggingface.co/Qwen/Qwen3.5-4B/resolve/{BASE_REV}/{name}", "Qwen3.5-4B/" + name, BASE_SHARDS.get(name)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        files = list(pool.map(fetch, specs))
    manifest = {"cua_revision": CUA_REV, "base_revision": BASE_REV, "source_revision": SOURCE_REV, "files": files}
    (DEST / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"ready": True, "directory": str(DEST), "bytes": sum(f["bytes"] for f in files)}))


if __name__ == "__main__":
    main()
