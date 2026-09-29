#!/usr/bin/env bash
# Development build: Leonard.app in dist/, ad-hoc signed, without the bundled
# Python. Run it with scripts/run.sh, which points the app at this checkout's
# leonardd through uv. For the full, self-contained product use
# scripts/package.sh.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/package.sh" --app-only
