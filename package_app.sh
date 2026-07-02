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
# count instead -- it only ever goes up. But `git rev-list --count HEAD` returns a TRUNCATED
# count in a shallow clone (silently, no error) -- guard against that breaking monotonicity.
# Only enforced for --release: monotonicity only matters for builds that get distributed via
# Sparkle, so a debug build (routine local iteration) shouldn't be blocked by a shallow checkout.
# != "false" (not == "true") so pre-2.15 git, where --is-shallow-repository exits non-zero and
# this captures an empty string, fails closed instead of silently passing the guard.
if [[ "$CONFIG" == "release" ]] && [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != "false" ]]; then
    echo "error: shallow clone detected (or git is too old to check -- need >= 2.15) -- git rev-list --count HEAD would return a truncated commit count, breaking CFBundleVersion monotonicity. Use a full clone (git fetch --unshallow)."
    exit 1
fi
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

# ── Embed Sparkle.framework ───────────────────────────────────────────────────
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_FW="$BUILD_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
    echo "error: Sparkle.framework not found at $SPARKLE_FW (did swift build resolve the SPM dependency?)"
    exit 1
fi
# -a preserves symlinks — required so the framework's Versions/Current link stays intact.
cp -a "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"

# Parley is not sandboxed, so it must not use Sparkle's XPC installer/downloader services
# (see Sparkle's "Removing the XPC Services" doc). Strip them from the embedded copy, including the
# top-level Versions/Current-relative convenience symlink -- cp -a preserves it, and leaving it
# dangling after removing its target can make codesign reject the framework as malformed.
rm -rf "$FRAMEWORKS/Sparkle.framework/Versions/B/XPCServices"
rm -rf "$FRAMEWORKS/Sparkle.framework/XPCServices"

# SPM builds the executable with rpath=@loader_path (i.e. Contents/MacOS/), not the app-bundle
# convention of @executable_path/../Frameworks -- Xcode's "Embed Frameworks" phase adds that
# automatically, but a hand-assembled SPM bundle doesn't get it for free. Without this the app
# fails to launch (DYLD: Library not loaded: @rpath/Sparkle.framework/...).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Parley"

# ── Code sign (ad-hoc) ────────────────────────────────────────────────────────
echo "==> Signing (ad-hoc)..."
# Sign inner components first, then the app bundle
# TODO(Developer ID): ad-hoc signing doesn't require Hardened Runtime, but notarization with a
# real Developer ID cert does -- every codesign call below (Autoupdate, Updater.app, the
# framework, the XPC bundle, the app) will need --options runtime --timestamp added before the
# first notarized release, or notarization will reject them (--options runtime enables Hardened
# Runtime; --timestamp embeds a secure timestamp, required for stapling).
SPARKLE_VB="$FRAMEWORKS/Sparkle.framework/Versions/B"
codesign --force --sign - "$SPARKLE_VB/Autoupdate"
# Inner executable before its enclosing .app bundle -- codesign requires nested code to be signed
# innermost-first. Ad-hoc signing tolerates the wrong order today, but a real Developer ID cert
# would reject it, so get the order right now rather than only when that cert arrives.
codesign --force --sign - "$SPARKLE_VB/Updater.app/Contents/MacOS/Updater"
codesign --force --sign - "$SPARKLE_VB/Updater.app"
codesign --force --sign - "$FRAMEWORKS/Sparkle.framework"
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
