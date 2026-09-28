#!/usr/bin/env bash
# Builds LeonardApp without Xcode: `swift build -c release`, then hand-
# assembles Contents/MacOS + Contents/Resources + Info.plist and ad-hoc
# signs the result. Idempotent — safe to rerun; always produces a clean
# build/Leonard.app at the fixed bundle id com.leonard.app so a granted
# TCC permission survives rebuilds (ADR-003).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../LeonardApp" && pwd)"
BUILD_DIR="$APP_DIR/build"
APP_BUNDLE="$BUILD_DIR/Leonard.app"
BUNDLE_ID="com.leonard.app"

cd "$APP_DIR"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_PATH/LeonardApp"

if [ ! -x "$EXECUTABLE" ]; then
    echo "error: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/LeonardApp"
cp "$APP_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> ad-hoc signing ($BUNDLE_ID)"
codesign -s - --force "$APP_BUNDLE"

echo "==> verifying signature"
codesign --verify --verbose=2 "$APP_BUNDLE"

echo ""
echo "Built $APP_BUNDLE"
