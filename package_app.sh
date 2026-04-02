#!/usr/bin/env bash
# package_app.sh — Build and package AudioTranscribe.app (SwiftUI + XPC)
#
# Usage:
#   bash package_app.sh [--release] [--install]
#
#   --release        Build in release mode (default: debug)
#   --install        Copy finished .app to /Applications
#
# Output: dist/AudioTranscribe.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Parse flags ────────────────────────────────────────────────────────────────
CONFIG="debug"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --release)  CONFIG="release" ;;
        --install)  INSTALL=1 ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# ── Build ─────────────────────────────────────────────────────────────────────
echo "==> Building ($CONFIG)..."
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
else
    swift build
fi

BUILD_DIR=".build/arm64-apple-macosx/$CONFIG"

# ── Assemble app bundle ───────────────────────────────────────────────────────
APP="dist/AudioTranscribe.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
XPC_BUNDLE="$CONTENTS/XPCServices/com.audio-transcribe.capture-helper.xpc"
XPC_MACOS="$XPC_BUNDLE/Contents/MacOS"

echo "==> Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$XPC_MACOS"

# Info plists
cp packaging/Info.plist                  "$CONTENTS/Info.plist"
cp packaging/AudioCaptureHelper-Info.plist "$XPC_BUNDLE/Contents/Info.plist"

# App icon
cp packaging/AppIcon.icns "$RESOURCES/AppIcon.icns"

# Binaries
cp "$BUILD_DIR/AudioTranscribe"           "$MACOS/AudioTranscribe"
cp "$BUILD_DIR/audio-capture-helper-xpc"  "$XPC_MACOS/audio-capture-helper-xpc"

# ── Code sign (ad-hoc) ────────────────────────────────────────────────────────
echo "==> Signing (ad-hoc)..."
# Sign inner components first, then the app bundle
codesign --force --sign - "$XPC_BUNDLE"
codesign --force --sign - "$APP"

echo "==> Done: $APP"

# ── Install ───────────────────────────────────────────────────────────────────
if [[ "$INSTALL" == "1" ]]; then
    echo "==> Installing to /Applications ..."
    rm -rf "/Applications/AudioTranscribe.app"
    cp -R "$APP" /Applications/
    echo "==> Installed: /Applications/AudioTranscribe.app"
fi
