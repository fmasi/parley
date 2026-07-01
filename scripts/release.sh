#!/usr/bin/env bash
# scripts/release.sh — Build, archive, and generate a signed Sparkle appcast for a release.
#
# Usage:
#   bash scripts/release.sh <version>          # e.g. bash scripts/release.sh 0.7.0
#
# Prerequisites:
#   - HEAD is checked out at tag v<version> (package_app.sh reads CFBundleShortVersionString from
#     the nearest tag, and this script cross-checks the built version matches).
#   - The Sparkle EdDSA private key exists in your login Keychain (see generate_keys) -- signing
#     happens locally via generate_appcast, the key never leaves this machine.
#   - `swift build` has been run at least once, so the Sparkle SPM dependency (and its bundled
#     command-line tools) are resolved under .build/artifacts/.
#
# Output (all under release/, git-ignored -- this is release-machine tooling output, not source):
#   release/Parley-<version>.zip     -- the archived .app, symlinks preserved
#   release/updates/appcast.xml      -- signed feed (matches SUFeedURL: releases/latest/download/appcast.xml)
#   release/updates/*.delta          -- incremental update patches vs prior releases already in updates/
#
# This script does NOT publish anything -- see docs/release-checklist.md for the manual
# `gh release create` step once you've reviewed the output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

if [[ $# -ne 1 ]]; then
    echo "Usage: bash scripts/release.sh <version>   (e.g. 0.7.0)"
    exit 1
fi
VERSION="$1"
TAG="v$VERSION"

# ── Preconditions ─────────────────────────────────────────────────────────────
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG not found. Create it first: git tag $TAG && git push origin $TAG"
    exit 1
fi

CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || echo '')"
if [[ "$CURRENT_TAG" != "$TAG" ]]; then
    echo "error: HEAD is not exactly at $TAG (currently: ${CURRENT_TAG:-untagged}). Check out the tag first: git checkout $TAG"
    exit 1
fi

if ! git diff --quiet HEAD || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "error: working tree is dirty (modified or untracked files) — commit or stash changes before cutting a release (the built .app must match the tagged commit exactly)"
    exit 1
fi

SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "error: $GENERATE_APPCAST not found. Run 'swift build' first to resolve the Sparkle SPM dependency."
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
echo "==> Building release ($TAG)..."
bash package_app.sh --release

ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw dist/Parley.app/Contents/Info.plist)"
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
    echo "error: built version ($ACTUAL_VERSION) doesn't match requested version ($VERSION)."
    exit 1
fi

# ── Archive ───────────────────────────────────────────────────────────────────
# -k (zip) with -c --sequesterRsrc --keepParent preserves symlinks, which matters here:
# Sparkle.framework's Versions/Current -> B symlink must survive or the framework is broken.
RELEASE_DIR="release"
UPDATES_DIR="$RELEASE_DIR/updates"
mkdir -p "$UPDATES_DIR"
ZIP_NAME="Parley-$VERSION.zip"
echo "==> Archiving to $RELEASE_DIR/$ZIP_NAME ..."
rm -f "$RELEASE_DIR/$ZIP_NAME" "$UPDATES_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "dist/Parley.app" "$RELEASE_DIR/$ZIP_NAME"
cp "$RELEASE_DIR/$ZIP_NAME" "$UPDATES_DIR/$ZIP_NAME"

# ── Sign + generate the appcast ──────────────────────────────────────────────
# generate_appcast signs every archive under updates/ with the EdDSA key from the login Keychain
# and (re)writes appcast.xml + *.delta covering all releases ever placed in this folder -- so
# updates/ is a persistent accumulation point across releases, not per-release scratch space.
#
# --download-url-prefix is required: without it, generate_appcast writes only the bare filename
# as the enclosure URL, which Sparkle resolves relative to SUFeedURL
# (releases/latest/download/...) -- that only works for the CURRENT latest release; once the next
# version ships, this release's zip is no longer a "latest" asset and downloads 404. GitHub's
# actual per-release asset URLs are versioned (releases/download/<tag>/<file>), so point there.
echo "==> Generating signed appcast (Keychain access may prompt)..."
"$GENERATE_APPCAST" --download-url-prefix "https://github.com/fmasi/parley/releases/download/$TAG/" "$UPDATES_DIR"

# generate_appcast applies --download-url-prefix to EVERY entry it (re)writes, including older
# releases already accumulated in updates/ for delta generation -- so on the 2nd+ release, this
# just stamped THIS release's tag onto every older entry's URL too, breaking their downloads.
# Restore each entry's URL to reference its own version's tag, parsed from its filename.
echo "==> Fixing older entries' download URLs to their own release tags..."
python3 "$SCRIPT_DIR/scripts/fix_appcast_urls.py" "$UPDATES_DIR/appcast.xml"

echo
echo "==> Done."
echo "    $RELEASE_DIR/$ZIP_NAME       -- upload as a release asset"
echo "    $UPDATES_DIR/appcast.xml     -- upload as a release asset (SUFeedURL: releases/latest/download/appcast.xml)"
echo "    $UPDATES_DIR/*.delta         -- upload any present (incremental updates)"
echo
echo "See docs/release-checklist.md for the remaining manual steps (release notes, gh release create, verification)."
