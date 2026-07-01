#!/usr/bin/env bash
# build.sh — compile the #103 tap spike and package it as a signed .app bundle.
#
# A bare `swift run` will NOT get the System Audio Recording TCC grant: the grant is keyed off
# a code signature + an Info.plist with NSAudioCaptureUsageDescription. So we assemble a minimal
# .app (stable bundle id eu.fmasi.parley.spike), ad-hoc sign it, and run the inner binary from
# Terminal — that way we keep live stdout while TCC attributes capture to the signed bundle.
#
# Usage:
#   bash build.sh            # build + package, then print the run command
#   bash build.sh --run      # build + package + run immediately
#
# NOTE: ad-hoc signatures change cdhash every rebuild, so macOS may re-prompt (or you may need
#   tccutil reset All eu.fmasi.parley.spike) after each build. Expected dev-time friction.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

echo "==> Building (release)..."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/system-tap-spike"

APP="dist/ParleySpike.app"
MACOS="$APP/Contents/MacOS"
echo "==> Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$MACOS/system-tap-spike"

echo "==> Signing (ad-hoc)..."
codesign --force --sign - "$APP"

RUN_CMD="$MACOS/system-tap-spike"
echo "==> Done: $APP"

if [[ "$RUN" == "1" ]]; then
    echo "==> Running (Ctrl-C to stop)..."
    exec "$RUN_CMD"
else
    echo ""
    echo "Run it (keeps live RMS in your terminal; grant the System Audio prompt on first run):"
    echo "  \"$SCRIPT_DIR/$RUN_CMD\""
    echo ""
    echo "Optional: pass an output WAV path as arg 1 (default ~/Desktop/parley-tap-spike.wav)."
fi
