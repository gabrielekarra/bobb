#!/usr/bin/env bash
# Builds Leonard.app (scripts/build.sh) and launches it. Any arguments are
# forwarded to the app, e.g. `./run.sh --mock-events` for the scripted
# demo scenario instead of the real WorkspaceEventSource.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/../LeonardApp/build/Leonard.app"

"$SCRIPT_DIR/build.sh"

echo "==> launching $APP_BUNDLE"
open "$APP_BUNDLE" --args "$@"
