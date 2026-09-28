#!/usr/bin/env bash
# Builds the development app and launches it against this checkout's daemon
# (`uv run` in leonardd/). Extra arguments go to the app, e.g.
#   scripts/run.sh --mock-events     # scripted demo events, no Mail needed
#   scripts/run.sh --no-daemon       # connect to a daemon you started yourself
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"
echo "==> launching $ROOT/dist/Leonard.app"
open "$ROOT/dist/Leonard.app" --args --daemon-dir "$ROOT/leonardd" "$@"
