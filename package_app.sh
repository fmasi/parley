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
# CFBundleVersion must increase monotonically across ALL builds Sparkle might compare -- including
# hotfixes cut from divergent maintenance branches. `git rev-list --count HEAD` only increases along
# a SINGLE lineage: a hotfix off release/v0.6.x gets a lower count than a later mainline build, so if
# it were ever the "latest" appcast it would look OLDER (#110). Use the HEAD commit's committer
# timestamp instead -- a commit made later always has a larger value regardless of branch, so the
# number is monotonic across the whole release graph. It's deterministic (fixed once committed) and
# needs only HEAD, so it works in a shallow clone with no guard. Safe transition: any %ct (~1.7e9) is
# far above the old count-based numbers (e.g. v0.7.0 = 412), so every future build still compares as
# newer than already-shipped builds.
BUILD_NUMBER="$(git show -s --format=%ct HEAD)"

echo "   Version: $VERSION (build: $BUILD_NUMBER, git: $GIT_DESCRIPTION)"

# Dev-build note: a build from a commit that isn't exactly a release tag gets a build number higher
# than the last release's, so Sparkle on THIS machine won't offer the real release as an update
# (installed build > appcast build). Harmless for a throwaway dev build -- flagged so it isn't
# mistaken for a broken updater. (#110)
if [[ -z "$(git describe --tags --exact-match 2>/dev/null)" ]]; then
    echo "   note: non-tagged commit -- CFBundleVersion ($BUILD_NUMBER) exceeds the last release's, so this local build won't see published updates via Sparkle."
fi

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

# ── Code sign ─────────────────────────────────────────────────────────────────
# Prefer a STABLE self-signed identity so macOS TCC permission grants (Microphone, Screen
# Recording, Calendar) survive Sparkle auto-updates: TCC pins each grant to the app's designated
# requirement, and a fixed certificate keeps that requirement constant across rebuilds. Ad-hoc
# signing (`-`) mints a fresh cdhash every build, so every update looks like a new app and drops
# all grants. Run scripts/setup-signing-cert.sh once to create the identity; without it we fall
# back to ad-hoc so CI / fresh clones still build (their updates just re-prompt for permissions).
SIGN_IDENTITY="Parley Self-Signed"
# Capture-then-grep, not `… | grep -qF`: grep's first-match exit SIGPIPEs security, and pipefail
# would then wrongly report the identity as absent and silently drop to ad-hoc signing.
if grep -qF "$SIGN_IDENTITY" <<<"$(security find-identity -v -p codesigning 2>/dev/null || true)"; then
    SIGN_ID="$SIGN_IDENTITY"
    echo "==> Signing with stable identity '$SIGN_IDENTITY' (TCC grants survive updates)..."
else
    SIGN_ID="-"
    echo "==> Signing ad-hoc — no stable identity found; updates will re-prompt for permissions."
    echo "    Run scripts/setup-signing-cert.sh once to make TCC grants persist across updates."
fi
# Sign inner components first, then the app bundle
# TODO(Developer ID): ad-hoc and self-signed don't require Hardened Runtime, but notarization with
# a real Developer ID cert does -- every codesign call below (Autoupdate, Updater.app, the
# framework, the XPC bundle, the app) will need --options runtime --timestamp added before the
# first notarized release, or notarization will reject them (--options runtime enables Hardened
# Runtime; --timestamp embeds a secure timestamp, required for stapling).
SPARKLE_VB="$FRAMEWORKS/Sparkle.framework/Versions/B"
if [[ ! -d "$SPARKLE_VB" ]]; then
    echo "error: Sparkle.framework/Versions/B not found -- Sparkle may have changed its internal bundle layout. Check $FRAMEWORKS/Sparkle.framework/Versions/ and update SPARKLE_VB."
    exit 1
fi
codesign --force --sign "$SIGN_ID" "$SPARKLE_VB/Autoupdate"
# Inner executable before its enclosing .app bundle -- codesign requires nested code to be signed
# innermost-first. Ad-hoc signing tolerates the wrong order today, but a real Developer ID cert
# would reject it, so get the order right now rather than only when that cert arrives.
codesign --force --sign "$SIGN_ID" "$SPARKLE_VB/Updater.app/Contents/MacOS/Updater"
codesign --force --sign "$SIGN_ID" "$SPARKLE_VB/Updater.app"
codesign --force --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework"
codesign --force --sign "$SIGN_ID" "$XPC_BUNDLE"
codesign --force --sign "$SIGN_ID" "$APP"
# Ad-hoc signing tolerates a lot (wrong nesting order, missing inner components) -- verify now so
# a subtle signing error is caught here, not at launch as a cryptic "damaged or incomplete" alert.
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"

# ── Install ───────────────────────────────────────────────────────────────────
if [[ "$INSTALL" == "1" ]]; then
    echo "==> Installing to /Applications ..."
    rm -rf "/Applications/Parley.app"
    cp -R "$APP" /Applications/
    echo "==> Installed: /Applications/Parley.app"
fi
