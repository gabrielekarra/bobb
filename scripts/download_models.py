#!/usr/bin/env python3
"""Fetch Bobb's pinned local models, checking every byte before installation.

Developer convenience; inference never calls this script or accesses the network.
The app implements the same manifest download in ModelDownloader.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def download(model, directory):
    name = model['id'].split('/')[-1]
    target = directory / name
    staging = directory / ('.download-' + name)
    staging.mkdir(parents=True, exist_ok=True)
    install_files = []
    for file in model['files']:
        destination = staging / file['name']
        installed = target / file['name']
        if installed.is_file() and installed.stat().st_size == file['size'] and digest(installed) == file['sha256']:
            continue
        if not (destination.is_file() and destination.stat().st_size == file['size'] and digest(destination) == file['sha256']):
            print(f"Downloading {name}/{file['name']} ({file['size'] / 1e6:.1f} MB)", flush=True)
            temporary = destination.with_suffix(destination.suffix + '.partial')
            base = model.get('sourceBaseURL') or f"https://huggingface.co/{model['id']}/resolve/{model['revision']}"
            url = f"{base}/{file['name']}"
            hasher, received, last = hashlib.sha256(), 0, time.monotonic()
            with urlopen(url, timeout=120) as response, temporary.open('wb') as output:
                while chunk := response.read(8 << 20):
                    output.write(chunk)
                    hasher.update(chunk)
                    received += len(chunk)
                    if time.monotonic() - last >= 30:
                        print(f'{name}: {received / file["size"]:.0%}', flush=True)
                        last = time.monotonic()
            if received != file['size'] or hasher.hexdigest() != file['sha256']:
                raise ValueError(f"Checksum mismatch: {name}/{file['name']}")
            temporary.replace(destination)
        install_files.append(file)
    # Keep existing valid files without reading multi-GB weights into Python memory.
    target.mkdir(parents=True, exist_ok=True)
    for file in install_files:
        destination = target / file['name']
        staged = staging / file['name']
        if staged.is_file():
            staged.replace(destination)
    print(f"Installed and verified {model['id']}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models-dir', type=Path, default=ROOT / '.runtime/models')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'bobbd/bobbd/model-manifest.json').read_text())
    for model in manifest['models']:
        download(model, args.models_dir)


if __name__ == '__main__':
    main()
