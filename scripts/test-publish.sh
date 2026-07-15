#!/bin/bash
# Unit test for scripts/publish.sh: --dry-run must emit the correct gh flags for each line.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/release/updates" "$tmp/release/release-notes"
echo zip > "$tmp/release/Parley-0.9.0.zip"
echo '<rss/>' > "$tmp/release/updates/appcast.xml"
echo 'notes' > "$tmp/release/release-notes/0.9.0.md"

run() { RELEASE_ROOT="$tmp" SKIP_GIT_PRECHECKS=1 bash scripts/publish.sh "$@"; }

out="$(run 0.9.0 --line current --dry-run)"
grep -q -- '--latest=true' <<<"$out"  || { echo "FAIL: current line is not --latest=true"; echo "$out"; exit 1; }
grep -q 'release/release-notes/0.9.0.md' <<<"$out" || { echo "FAIL: --notes-file missing"; echo "$out"; exit 1; }
grep -q 'Parley-0.9.0.zip' <<<"$out"   || { echo "FAIL: zip asset missing"; echo "$out"; exit 1; }
echo "  current line: PASS"

out="$(run 0.9.0 --line stable --dry-run)"
grep -q -- '--latest=false' <<<"$out" || { echo "FAIL: stable line is not --latest=false"; echo "$out"; exit 1; }
echo "  stable line:  PASS"

# --line is required: forgetting it must NOT silently default to latest and hijack the feed.
if run 0.9.0 --dry-run >/dev/null 2>&1; then
    echo "FAIL: missing --line was accepted (would default to latest)"; exit 1
fi
echo "  missing --line: correctly rejected"

# Missing artifact must fail closed.
rm "$tmp/release/release-notes/0.9.0.md"
if run 0.9.0 --line current --dry-run >/dev/null 2>&1; then
    echo "FAIL: missing notes file was not rejected"; exit 1
fi
echo "  missing artifact: correctly rejected"

echo "PASS"
