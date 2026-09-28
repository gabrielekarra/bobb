#!/usr/bin/env bash
# Runs `swift test` for LeonardCore, retrying clean builds a few times.
#
# On this machine's Command Line Tools toolchain (Swift 6.4, no Xcode), the
# swift-testing macro plugin is intermittently not resolved for one
# frontend job of this test target — a toolchain-level race, not a code
# issue: every run that gets past compilation passes all tests, and a
# retried *clean* build (not an incremental one; incremental retries just
# repeat the same failure) has each time been enough to get past it within
# a handful of attempts. See LeonardApp/README.md for the full story.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../LeonardApp" && pwd)"
MAX_ATTEMPTS="${1:-8}"

cd "$APP_DIR"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "==> swift test attempt $attempt/$MAX_ATTEMPTS"
    rm -rf .build
    if swift test -j 1; then
        echo "==> passed on attempt $attempt"
        exit 0
    fi
    echo "==> attempt $attempt failed (see above); retrying with a clean .build"
done

echo "error: swift test did not succeed in $MAX_ATTEMPTS attempts" >&2
exit 1
