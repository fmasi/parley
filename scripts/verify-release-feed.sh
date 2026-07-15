#!/usr/bin/env bash
# scripts/verify-release-feed.sh — assert the PUBLISHED Sparkle feed is intact (#119, #110).
#
# Everything scripts/release.sh guards is LOCAL (build/sign). This guards the published result:
# after `gh release create`, is the feed actually serving the right, signed, reachable update?
# A break here is silent today — every installed client just stops seeing updates with no error.
#
# Checks, each failing closed with the offending value:
#   1. releases/latest/download/appcast.xml resolves (200) and parses.
#   2. its newest item (by semver) is the version under test.
#   3. 'latest' actually redirects to this tag (real GitHub feed only).
#   4. every <enclosure url> returns 200.
#   5. the newest enclosure's sparkle:edSignature validates against the downloaded bytes
#      (public-key-only, via verify-ed-signature — no secret needed).
#
# Usage:
#   bash scripts/verify-release-feed.sh [<version>] [--feed-url <url>] [--pubkey <base64>]
#     <version>    defaults to the newest published release tag (gh release view)
#     --feed-url   defaults to the real feed; point at a localhost appcast for tests
#     --pubkey     defaults to packaging/Info.plist's SUPublicEDKey
#   env VERIFY_ED_SIGNATURE_BIN overrides the path to the verify-ed-signature executable.
#
# Compatible with stock macOS bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="fmasi/parley"
DEFAULT_FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
export PYTHONPATH="$SCRIPT_DIR"

VERSION=""
FEED_URL="$DEFAULT_FEED"
PUBKEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --feed-url) FEED_URL="$2"; shift 2;;
        --pubkey)   PUBKEY="$2"; shift 2;;
        --*)        echo "unknown option: $1" >&2; exit 2;;
        *)          VERSION="$1"; shift;;
    esac
done

fail() { echo "FEED CHECK FAILED: $*" >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
    VERSION="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null | sed 's/^v//')"
    [[ -n "$VERSION" ]] || { echo "error: could not determine latest release version (gh release view failed)" >&2; exit 2; }
fi
if [[ -z "$PUBKEY" ]]; then
    PUBKEY="$(plutil -extract SUPublicEDKey raw "$REPO_ROOT/packaging/Info.plist" 2>/dev/null || true)"
    [[ -n "$PUBKEY" ]] || { echo "error: could not read SUPublicEDKey from packaging/Info.plist" >&2; exit 2; }
fi

echo "Verifying feed for v$VERSION: $FEED_URL"

APPCAST_FILE="$(mktemp)"
ZIP_FILE=""
cleanup() { rm -f "$APPCAST_FILE" "${ZIP_FILE:-}"; }
trap cleanup EXIT

# 1. Fetch + parse.
curl -fsSL "$FEED_URL" -o "$APPCAST_FILE" || fail "appcast did not resolve (200) at $FEED_URL"
# Read the newest item's fields via `read`, never `eval`: the appcast is parsed here BEFORE its
# signature is verified (step 5), so a MITM-tampered feed must not be able to inject shell.
NEWEST_VERSION=""; NEWEST_URL=""; NEWEST_SIG=""
{
    IFS= read -r NEWEST_VERSION
    IFS= read -r NEWEST_URL
    IFS= read -r NEWEST_SIG
} < <(python3 - "$APPCAST_FILE" <<'PY'
import sys, appcast_lib
it = appcast_lib.newest_item(open(sys.argv[1]).read())
if it:
    print(it["version"])
    print(it["url"])
    print(it["ed_signature"] or "")
PY
) || true
[[ -n "$NEWEST_VERSION" ]] || fail "appcast at $FEED_URL has no items or did not parse"

# 2. Newest item is the version under test.
[[ "$NEWEST_VERSION" == "$VERSION" ]] || fail "newest appcast item is $NEWEST_VERSION, expected $VERSION"

# 3. 'latest' resolves to this tag (real GitHub feed only; a localhost fixture has no such redirect).
if [[ "$FEED_URL" == "$DEFAULT_FEED" ]]; then
    LOC="$(curl -sI "https://github.com/$REPO/releases/latest" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
    [[ "$LOC" == */tag/v"$VERSION" ]] || fail "'latest' resolves to '${LOC:-<none>}', expected .../tag/v$VERSION"
fi

# 4. Every enclosure URL is live.
while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    code="$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || echo 000)"
    [[ "$code" == 200 ]] || fail "enclosure URL not reachable ($code): $url"
done < <(python3 -c 'import sys, appcast_lib; print("\n".join(appcast_lib.all_enclosure_urls(open(sys.argv[1]).read())))' "$APPCAST_FILE")

# 5. Newest enclosure signature validates against the downloaded bytes.
VERIFY_BIN="${VERIFY_ED_SIGNATURE_BIN:-}"
if [[ -z "$VERIFY_BIN" ]]; then
    (cd "$REPO_ROOT" && swift build --product verify-ed-signature >/dev/null 2>&1) || true
    VERIFY_BIN="$(cd "$REPO_ROOT" && swift build --product verify-ed-signature --show-bin-path 2>/dev/null)/verify-ed-signature"
fi
[[ -x "$VERIFY_BIN" ]] || fail "verify-ed-signature not built (looked at ${VERIFY_BIN:-<empty>})"
[[ -n "$NEWEST_SIG" ]] || fail "newest item ($NEWEST_VERSION) has no sparkle:edSignature"
ZIP_FILE="$(mktemp)"
curl -fsSL "$NEWEST_URL" -o "$ZIP_FILE" || fail "could not download newest enclosure: $NEWEST_URL"
"$VERIFY_BIN" --pubkey "$PUBKEY" --signature "$NEWEST_SIG" --file "$ZIP_FILE" \
    || fail "EdDSA signature does not validate for v$VERSION ($NEWEST_URL)"

echo "Feed OK: v$VERSION — resolves, latest-correct, enclosures live, signature valid."
