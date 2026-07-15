#!/usr/bin/env bash
# scripts/publish.sh — guarded GitHub release publish for a Parley version.
#
# Wraps `gh release create` with the checklist's manual guards so the error-prone copy-paste step
# (deltas glob, --notes-file, and above all the --latest flag) can't go wrong:
#   - --latest is ALWAYS explicit. Implicit 'latest' is what silently broke the feed in #110.
#   - The two-line rule: only the current (live Sparkle) line takes latest; a stable 0.8.x patch
#     publishes --latest=false so it cannot hijack the 0.9.x feed.
#   - Required artifacts (zip, appcast, notes markdown) must exist and be non-empty.
# On a real publish it runs scripts/verify-release-feed.sh immediately after.
#
# Usage:
#   bash scripts/publish.sh <version> [--line current|stable] [--dry-run]
# Test seams: RELEASE_ROOT (default '.'), SKIP_GIT_PRECHECKS=1 (skip tag/HEAD/clean-tree checks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
REPO="fmasi/parley"
RELEASE_ROOT="${RELEASE_ROOT:-.}"

usage() { echo "usage: bash scripts/publish.sh <version> [--line current|stable] [--dry-run]"; }

VERSION=""
LINE=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --line) LINE="$2"; shift 2;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        --*) echo "unknown option: $1" >&2; usage; exit 2;;
        *) VERSION="$1"; shift;;
    esac
done
[[ -n "$VERSION" ]] || { usage >&2; exit 2; }
# --line is REQUIRED, never defaulted: defaulting to 'current' would make a forgotten flag on a
# 0.8.x maintenance release silently take 'latest' and 404 the 0.9.x feed (#110). Force the choice.
case "$LINE" in
    current|stable) ;;
    "") echo "error: --line is required (current|stable). 'current' is the live 0.9.x Sparkle line" >&2
        echo "       (takes latest); 'stable' is a 0.8.x patch (never latest). See docs/release-checklist.md." >&2
        exit 2;;
    *)  echo "error: --line must be 'current' or 'stable' (got '$LINE')" >&2; exit 2;;
esac

TAG="v$VERSION"
if [[ "$LINE" == current ]]; then LATEST="true"; else LATEST="false"; fi

if [[ "${SKIP_GIT_PRECHECKS:-0}" != 1 ]]; then
    git rev-parse "$TAG" >/dev/null 2>&1 || { echo "error: tag $TAG not found (git tag $TAG && git push origin $TAG)" >&2; exit 1; }
    CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || echo '')"
    [[ "$CURRENT_TAG" == "$TAG" ]] || { echo "error: HEAD is not exactly at $TAG (currently ${CURRENT_TAG:-untagged})" >&2; exit 1; }
    if ! git diff --quiet HEAD || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        echo "error: working tree is dirty — the published build must match the tagged commit" >&2; exit 1
    fi
fi

ZIP="$RELEASE_ROOT/release/Parley-$VERSION.zip"
APPCAST="$RELEASE_ROOT/release/updates/appcast.xml"
NOTES="$RELEASE_ROOT/release/release-notes/$VERSION.md"
for f in "$ZIP" "$APPCAST" "$NOTES"; do
    [[ -s "$f" ]] || { echo "error: required release artifact missing or empty: $f" >&2; exit 1; }
done

# Safe deltas glob (bash 3.2: never expand an empty array under set -u).
deltas=("$RELEASE_ROOT"/release/updates/*.delta)
[[ -e "${deltas[0]}" ]] || deltas=()

assets=("$ZIP" "$APPCAST")
if [[ ${#deltas[@]} -gt 0 ]]; then assets+=("${deltas[@]}"); fi

cmd=(gh release create "$TAG" "${assets[@]}"
    --repo "$REPO"
    --title "Parley $VERSION"
    --notes-file "$NOTES"
    "--latest=$LATEST")

if [[ "$DRY_RUN" == 1 ]]; then
    printf '%q ' "${cmd[@]}"; echo
    echo "(dry-run: would publish $TAG on the '$LINE' line with --latest=$LATEST, then verify the feed)"
    exit 0
fi

echo "==> Publishing $TAG (line=$LINE, --latest=$LATEST)..."
"${cmd[@]}"
echo "==> Verifying the published feed..."
bash "$SCRIPT_DIR/scripts/verify-release-feed.sh" "$VERSION"
