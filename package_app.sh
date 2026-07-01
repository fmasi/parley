#!/usr/bin/env bash
# package_app.sh — Build and package Parley.app (SwiftUI + XPC)
#
# Usage:
#   bash package_app.sh [--release] [--install]
#
#   --release        Build in release mode (default: debug)
#   --install        Copy finished .app to /Applications
#
# Output: dist/Parley.app

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
# CFBundleVersion must increase monotonically across builds for Sparkle to detect updates.
# Commit distance from `git describe` resets to 0 on every tag, so use the total commit
# count instead -- it only ever goes up.
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "   Version: $VERSION (build: $BUILD_NUMBER, git: $GIT_DESCRIPTION)"

# ── Assemble app bundle ───────────────────────────────────────────────────────
APP="dist/Parley.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
XPC_BUNDLE="$CONTENTS/XPCServices/eu.fmasi.parley.capture-helper.xpc"
XPC_MACOS="$XPC_BUNDLE/Contents/MacOS"

echo "==> Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$XPC_MACOS"

# Info plists
# Info plist with version injection
cp packaging/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
plutil -insert ATGitDescription -string "$GIT_DESCRIPTION" "$CONTENTS/Info.plist"
cp packaging/AudioCaptureHelper-Info.plist "$XPC_BUNDLE/Contents/Info.plist"

# App icon
cp packaging/AppIcon.icns "$RESOURCES/AppIcon.icns"

# Binaries
cp "$BUILD_DIR/Parley"           "$MACOS/Parley"
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
    rm -rf "/Applications/Parley.app"
    cp -R "$APP" /Applications/
    echo "==> Installed: /Applications/Parley.app"
fi
