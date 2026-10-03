#!/usr/bin/env python3
"""Install the pinned official CUA macOS driver into the local runtime."""
import argparse
import hashlib
import shutil
import tarfile
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.31.0"
ASSET = f"cua-driver-rs-{VERSION}-darwin-arm64.tar.gz"
SHA256 = "a11af736adefc875c291b0a764f612e8eecc450cb0f44d29be5219cbc6fa3826"
URL = f"https://github.com/trycua/cua/releases/download/cua-driver-rs-v{VERSION}/{ASSET}"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT/".runtime/cua-driver")
    args = parser.parse_args(); args.directory.mkdir(parents=True,exist_ok=True)
    archive = args.directory/"driver.tar.gz"
    def verified():
        if not archive.is_file(): return False
        with archive.open("rb") as f: return hashlib.file_digest(f,"sha256").hexdigest()==SHA256
    if not verified():
        temporary = archive.with_suffix(".partial")
        with urlopen(URL,timeout=90) as response, temporary.open("wb") as out: shutil.copyfileobj(response,out)
        temporary.replace(archive)
        if not verified(): raise ValueError("CUA driver checksum mismatch")
    target = args.directory/"pinned"; target.mkdir(exist_ok=True)
    with tarfile.open(archive) as files: files.extractall(target,filter="data")
    binary = target/f"cua-driver-rs-{VERSION}-darwin-arm64"/"cua-driver"
    if not binary.is_file(): raise ValueError("CUA driver is missing from the verified archive")
    print("Verified CUA macOS driver:",binary)

if __name__=="__main__":main()
