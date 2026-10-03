#!/usr/bin/env bash
# Builds the development app and launches it against this checkout's daemon
# (the virtual environment in bobbd/). Extra arguments go to the app, e.g.
#   scripts/run.sh --mock-events     # scripted demo events, no Mail needed
#   scripts/run.sh --no-daemon       # connect to a daemon you started yourself
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START_DAEMON=1
for arg in "$@"; do
    case "$arg" in --mock-events|--no-daemon) START_DAEMON=0 ;; esac
done
if [[ "$START_DAEMON" == 1 ]]; then
    uv sync --project "$ROOT/bobbd" --frozen
fi
"$ROOT/scripts/build.sh"
echo "==> launching $ROOT/dist/Bobb.app"
open "$ROOT/dist/Bobb.app" --args "$@"
