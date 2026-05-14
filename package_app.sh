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

# ── Compute version from git ─────────────────────────────────────────────────
GIT_DESCRIPTION="$(git describe --tags --always --dirty 2>/dev/null || echo 'unknown')"
# Strip 'v' prefix for CFBundleShortVersionString: "v0.6.1" -> "0.6.1"
TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
if [[ -n "$TAG" ]]; then
    VERSION="${TAG#v}"
else
    VERSION="0.0.0"
fi
# Commit distance for CFBundleVersion: "v0.6.1-12-ga3f9c12" -> "12", on tag -> "0"
if [[ "$GIT_DESCRIPTION" == *-*-g* ]]; then
    # Has distance component
    DISTANCE="$(echo "$GIT_DESCRIPTION" | sed -E 's/^v?[0-9]+\.[0-9]+\.[0-9]+-([0-9]+)-g.*/\1/')"
else
    DISTANCE="0"
fi

echo "   Version: $VERSION (distance: $DISTANCE, git: $GIT_DESCRIPTION)"

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
# Info plist with version injection
cp packaging/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$DISTANCE" "$CONTENTS/Info.plist"
plutil -insert ATGitDescription -string "$GIT_DESCRIPTION" "$CONTENTS/Info.plist"
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
