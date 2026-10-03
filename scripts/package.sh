#!/usr/bin/env bash
# Builds Bobb.app and, unless --app-only, the complete, self-contained
# product: the Swift app, a relocatable Python with bobbd and its locked
# dependencies inside the bundle, code signatures, a DMG, and notarization.
#
#   scripts/package.sh --app-only      # dev: app bundle only, ad-hoc signed
#   scripts/package.sh                 # full bundle + DMG, ad-hoc signed
#   scripts/package.sh --release       # full bundle + DMG, Developer ID,
#                                      # notarized; refuses without secrets
#
# Environment:
#   BOBB_VERSION              marketing version (default: ./VERSION)
#   BOBB_BUILD                build number (default: git commit count)
#   BOBB_SWIFT_SDK            optional SDK path for a matching installed toolchain
#   BOBB_SWIFT_BUILD_SYSTEM   optional SwiftPM build system (e.g. native)
#   DEVELOPER_ID_APPLICATION     codesign identity, e.g. "Developer ID
#                                Application: Bobb S.r.l. (TEAMID)"
#   NOTARY_PROFILE               notarytool keychain profile, or
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#
# Everything runs on macOS on Apple silicon; MLX has no Intel build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/BobbApp"
DIST="$ROOT/dist"
WORK="$DIST/work"
APP="$DIST/Bobb.app"
PYTHON_SERIES="3.12"

MODE="full"
RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --app-only) MODE="app" ;;
        --release) RELEASE=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${BOBB_VERSION:-$(cat "$ROOT/VERSION")}"
BUILD="${BOBB_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
BUILD_DATE="$(date -u +%Y-%m-%d)"
IDENTITY="${DEVELOPER_ID_APPLICATION:--}"

if [[ $RELEASE == 1 ]]; then
    [[ "$IDENTITY" != "-" ]] || { echo "error: --release needs DEVELOPER_ID_APPLICATION" >&2; exit 1; }
    [[ "$MODE" == "full" ]] || { echo "error: --release builds the full bundle" >&2; exit 1; }
fi

step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- the app
step "swift build (release, arm64)"
SWIFT_OPTIONS=(-c release --arch arm64)
if [[ -n "${BOBB_SWIFT_SDK:-}" ]]; then
    # SwiftPM also compiles Package.swift; --sdk alone can leave that
    # manifest on the system's different default SDK.
    export SDKROOT="$BOBB_SWIFT_SDK"
    SWIFT_OPTIONS+=(--sdk "$BOBB_SWIFT_SDK")
fi
if [[ -n "${BOBB_SWIFT_BUILD_SYSTEM:-}" ]]; then SWIFT_OPTIONS+=(--build-system "$BOBB_SWIFT_BUILD_SYSTEM"); fi
(cd "$APP_SRC" && swift build "${SWIFT_OPTIONS[@]}")
BIN="$(cd "$APP_SRC" && swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"
# Preserve the last usable app if compilation fails.
rm -rf "$APP" "$WORK"
mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BobbApp" "$APP/Contents/MacOS/BobbApp"

step "Info.plist ($VERSION, build $BUILD, $BUILD_DATE)"
cp "$APP_SRC/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
plutil -replace BobbBuildDate -string "$BUILD_DATE" "$PLIST"
if [[ "$MODE" == "app" ]]; then
    # Persist the development runtime: Finder, permission-related restarts
    # and login items do not preserve the arguments from scripts/run.sh.
    plutil -insert BobbDevelopmentDaemonDirectory -string "$ROOT/bobbd" "$PLIST"
    if [[ -d "$ROOT/.runtime/models" ]]; then
        plutil -insert BobbDevelopmentModelsDirectory -string "$ROOT/.runtime/models" "$PLIST"
    fi
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "resources"
iconutil -c icns "$APP_SRC/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp -R "$APP_SRC/Resources/en.lproj" "$APP_SRC/Resources/it.lproj" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

step "official CUA macOS driver (pinned release, checksum-verified)"
python3 "$ROOT/scripts/download_driver.py"
CUA="$ROOT/.runtime/cua-driver/pinned/cua-driver-rs-0.31.0-darwin-arm64"
mkdir -p "$APP/Contents/Resources/drivers"
cp "$CUA/cua-driver" "$CUA/LICENSE" "$APP/Contents/Resources/drivers/"

# ---------------------------------------------------------------- the daemon
if [[ "$MODE" == "full" ]]; then
    command -v uv >/dev/null || { echo "error: uv is required (https://docs.astral.sh/uv/)" >&2; exit 1; }
    DAEMON="$APP/Contents/Resources/daemon"
    mkdir -p "$DAEMON"

    step "relocatable Python $PYTHON_SERIES (python-build-standalone via uv, checksum-verified)"
    uv python install "cpython-$PYTHON_SERIES-macos-aarch64-none" --install-dir "$WORK/python" --no-bin
    PY_HOME="$(find "$WORK/python" -maxdepth 1 -type d -name "cpython-$PYTHON_SERIES*" | head -1)"
    [[ -n "$PY_HOME" ]] || { echo "error: python install not found" >&2; exit 1; }
    cp -R "$PY_HOME" "$DAEMON/python"
    PY="$DAEMON/python/bin/python3"
    rm -f "$DAEMON/python/lib/python$PYTHON_SERIES/EXTERNALLY-MANAGED"

    step "bobbd dependencies (from uv.lock, hash-checked, wheels only)"
    uv export --project "$ROOT/bobbd" --frozen --no-dev --no-emit-project --format requirements-txt > "$WORK/requirements.txt"
    "$PY" -m pip install --quiet --no-cache-dir --no-deps --require-hashes --only-binary=:all: -r "$WORK/requirements.txt"
    SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
    cp -R "$ROOT/bobbd/bobbd" "$SITE/bobbd"
    find "$SITE/bobbd" -name '__pycache__' -type d -prune -exec rm -rf {} +

    step "slimming"
    find "$DAEMON/python" -type d \( -name 'test' -o -name 'tests' -o -name 'idle_test' -o -name '__pycache__' \) -prune -exec rm -rf {} +
    rm -rf "$DAEMON/python/lib/python$PYTHON_SERIES/ensurepip" "$DAEMON/python/lib/python$PYTHON_SERIES/idlelib" \
           "$DAEMON/python/lib/python$PYTHON_SERIES/tkinter" "$DAEMON/python/lib/python$PYTHON_SERIES/turtledemo" \
           "$DAEMON/python/share" "$DAEMON/python/include"
    "$PY" -m compileall -q -j 0 "$DAEMON/python/lib" >/dev/null || true

    step "smoke test: the bundled daemon starts with no network and reports the missing model"
    PYTHONNOUSERSITE=1 HF_HUB_OFFLINE=1 "$PY" -s -m bobbd --version
    SMOKE="$(mktemp -d /tmp/bobb-smoke.XXXXXX)"
    BOBB_MODELS_DIR="$SMOKE/models" PYTHONNOUSERSITE=1 HF_HUB_OFFLINE=1 \
        "$PY" -s -m bobbd --data-dir "$SMOKE/data" --socket "$SMOKE/s.sock" --log-file "$SMOKE/bobbd.log" &
    DPID=$!
    "$PY" -s - "$SMOKE/s.sock" <<'PYEOF'
import json, socket, sys, time
path = sys.argv[1]
for _ in range(200):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(path); break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit("daemon never bound its socket")
s.sendall(b'{"t":"hello"}\n')
f = s.makefile()
for _ in range(3):
    frame = json.loads(f.readline())
    if frame.get("state") == "model_missing":
        print("daemon ok:", frame["t"], frame["state"], "protocol", frame["protocol"])
        sys.exit(0)
sys.exit(f"unexpected frames, last: {frame}")
PYEOF
    kill "$DPID"; wait "$DPID" 2>/dev/null || true
    rm -rf "$SMOKE"
    du -sh "$DAEMON" | awk '{print "daemon bundle: " $1}'
fi

# ---------------------------------------------------------------- signing
step "signing (identity: $IDENTITY)"
SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" == "-" ]] && SIGN=(codesign --force --sign -)
"${SIGN[@]}" "$APP/Contents/Resources/drivers/cua-driver"
if [[ "$MODE" == "full" ]]; then
    # Inside out: every library, then the interpreter with its entitlements.
    while IFS= read -r -d '' file; do
        if file "$file" | grep -q 'Mach-O'; then "${SIGN[@]}" "$file" >/dev/null; fi
    done < <(find "$APP/Contents/Resources/daemon" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)
    for exe in "$APP/Contents/Resources/daemon/python/bin/"python3.*; do
        [[ -L "$exe" ]] && continue
        file "$exe" | grep -q 'Mach-O' && "${SIGN[@]}" --entitlements "$APP_SRC/Resources/daemon.entitlements" "$exe" >/dev/null
    done
fi
"${SIGN[@]}" --entitlements "$APP_SRC/Resources/Bobb.entitlements" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

[[ "$MODE" == "app" ]] && { echo; echo "Built $APP"; exit 0; }

# ---------------------------------------------------------------- DMG
step "DMG"
DMG="$DIST/Bobb-$VERSION.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Bobb $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
[[ "$IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---------------------------------------------------------------- notarization
if [[ $RELEASE == 1 ]]; then
    step "notarization"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    fi
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
du -h "$DMG" | awk '{print "DMG: " $1}'
echo "Built $DMG"
