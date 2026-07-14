#!/bin/bash
#
# Red-first gate: a regression test must FAIL at the parent commit.
#
# WHY THIS EXISTS
#   A test that passes both with and without the fix it claims to guard is not evidence of
#   anything. This repo shipped exactly that, twice:
#     - TranscriptMerger had 6 passing tests while production hand-rolled a duplicate inline,
#       so the tested function shipped ZERO bytes. Its tests pass at the parent commit of any
#       "fix" — they guard dead code.
#     - The diarization regression test skipped silently in CI (fixture absent), so it passed
#       everywhere while asserting nothing about speaker separation.
#   Both are caught by one mechanical check: take the PR's new/changed test files, run them
#   against the code BEFORE the PR, and require them to fail (RED). Then run them against the
#   PR's code and require them to pass (GREEN). A regression test that is green at the parent
#   is guarding dead code, asserting nothing, or silently skipping.
#
# HOW IT WORKS
#   1. Diff BASE...HEAD for added/modified files under SwiftTests/TranscriberTests/.
#   2. Trivially pass when the gate does not apply:
#        - no test files changed, or
#        - no production code changed (a tests-only PR adds characterization tests for
#          EXISTING behaviour — those are green at the parent by definition), or
#        - every changed test file is explicitly exempted (see below).
#   3. Create a throwaway git worktree at BASE, overlay ONLY the changed test files from HEAD
#      onto it, and run just the test suites declared in those files.
#        - RED can mean test failures OR a compile error (a new test referencing a symbol the
#          fix introduces cannot compile at the parent — it still cannot pass there, which is
#          the property this gate needs).
#        - Exit 0 with >= 1 test executed means the tests PASS at the parent: the gate fails.
#        - Exit 0 with 0 tests executed means the tests silently skipped or the suite filter
#          matched nothing: the gate fails — a skip is not RED.
#   4. Run the same suites at HEAD and require exit 0 with >= 1 test executed (GREEN).
#
# EXEMPTION
#   A changed test file containing the literal marker "RED-FIRST-EXEMPT:" (in a comment, with
#   a reason after the colon) is excluded from the gate. Use it for characterization tests of
#   existing behaviour added alongside production changes. The marker is greppable and shows
#   up in the diff, so an exemption is an explicit, reviewable act — not a silent bypass.
#
# USAGE
#   scripts/verify-regression-tests.sh [BASE_SHA]
#     BASE_SHA  commit the changed tests must be RED against (default: HEAD~1;
#               CI passes the merge-base with the PR's base branch).
#     The GREEN side always runs at the currently checked-out HEAD.
#
# Compatible with the stock macOS bash 3.2 — no mapfile, no ${arr[@]} on possibly-empty arrays.

set -euo pipefail

BASE_SHA=$(git rev-parse "${1:-HEAD~1}")
HEAD_SHA=$(git rev-parse HEAD)
REPO_ROOT=$(git rev-parse --show-toplevel)

TEST_DIR="SwiftTests/TranscriberTests"
PROD_PATHS="TranscriberCore TranscriberApp AudioCaptureHelper AudioCaptureProtocol audio_capture_helper Package.swift"

# Flags matching the documented `swift test` invocation (CommandLineTools frameworks).
SWIFT_FLAGS="-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/"

echo "Red-first gate: BASE=$BASE_SHA HEAD=$HEAD_SHA"

# --- 1. Collect changed test files ---------------------------------------------------------------

changed_test_files=$(
  git diff --name-only --diff-filter=AM "$BASE_SHA...$HEAD_SHA" -- "$TEST_DIR" | grep '\.swift$' || true
)

if [ -z "$changed_test_files" ]; then
  echo "PASS (trivially): no test files changed."
  exit 0
fi

# shellcheck disable=SC2086  # PROD_PATHS is intentionally word-split
if git diff --quiet "$BASE_SHA...$HEAD_SHA" -- $PROD_PATHS; then
  echo "PASS (trivially): no production code changed — a tests-only PR adds characterization"
  echo "tests of existing behaviour, which are green at the parent by definition."
  exit 0
fi

# --- 2. Apply exemptions, derive the suites to run -----------------------------------------------

gated_files=""
for f in $changed_test_files; do
  if git show "$HEAD_SHA:$f" | grep -q 'RED-FIRST-EXEMPT:'; then
    echo "exempt: $f ($(git show "$HEAD_SHA:$f" | grep -o 'RED-FIRST-EXEMPT:.*' | head -1))"
  else
    gated_files="$gated_files $f"
  fi
done

if [ -z "${gated_files// /}" ]; then
  echo "PASS (trivially): every changed test file is RED-FIRST-EXEMPT."
  exit 0
fi

# Suite names = top-level types declared in the gated files. Over-matching (helper types) is
# harmless: the filter is an OR-regex and non-suite names simply match no tests.
suites=$(
  for f in $gated_files; do git show "$HEAD_SHA:$f"; done \
    | grep -oE '(struct|final class|class|actor|enum) +[A-Za-z0-9_]+' \
    | awk '{print $NF}' | sort -u | paste -s -d '|' -
)
if [ -z "$suites" ]; then
  echo "FAIL: changed test files declare no types — cannot derive a test filter."
  echo "$gated_files"
  exit 1
fi
echo "gated files:$gated_files"
echo "test filter: ($suites)"

# --- 3. Helper: run the gated suites in a tree; sets RUN_STATUS to green|red|none ----------------

run_suites() {
  local tree="$1" log ec tests_run
  log=$(mktemp)
  ec=0
  # shellcheck disable=SC2086  # SWIFT_FLAGS is intentionally word-split
  (cd "$tree" && swift test --filter "($suites)" $SWIFT_FLAGS) >"$log" 2>&1 || ec=$?
  # swift-testing summary line: "Test run with N tests in M suites passed/failed after ..."
  tests_run=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | tail -1 || true)
  if [ "$ec" -ne 0 ]; then
    RUN_STATUS="red"
  elif [ -z "$tests_run" ] || [ "$tests_run" -eq 0 ]; then
    RUN_STATUS="none"
  else
    RUN_STATUS="green"
  fi
  tail -30 "$log"
  rm -f "$log"
}

# --- 4. RED at the parent -------------------------------------------------------------------------

parent_tree=$(mktemp -d)
cleanup() { git worktree remove --force "$parent_tree" 2>/dev/null || rm -rf "$parent_tree"; }
trap cleanup EXIT

git worktree add --detach "$parent_tree" "$BASE_SHA" >/dev/null 2>&1
# Overlay ALL changed test files (exempt ones and helpers too — gated tests may depend on
# them), but execute only the gated suites.
for f in $changed_test_files; do
  mkdir -p "$parent_tree/$(dirname "$f")"
  git show "$HEAD_SHA:$f" > "$parent_tree/$f"
done

echo
echo "=== Running gated suites at PARENT ($BASE_SHA) — requiring RED ==="
run_suites "$parent_tree"
case "$RUN_STATUS" in
  green)
    echo
    echo "FAIL: the changed tests PASS at the parent commit."
    echo "They cannot be guarding the fix in this PR — they guard dead code, assert nothing,"
    echo "silently skip (a skipped test counts as passed), or duplicate existing coverage."
    echo "Make them fail without the fix, or mark intentional characterization tests with a"
    echo "'RED-FIRST-EXEMPT: <reason>' comment."
    exit 1
    ;;
  none)
    echo
    echo "FAIL: the gated suites executed 0 tests at the parent commit (exit 0)."
    echo "A silent skip is not RED — check .enabled(if:) conditions and the suite filter."
    exit 1
    ;;
  red)
    echo "OK: RED at parent (test or compile failure — either proves the tests cannot pass without the fix)."
    ;;
esac

# --- 5. GREEN at HEAD ------------------------------------------------------------------------------

echo
echo "=== Running gated suites at HEAD ($HEAD_SHA) — requiring GREEN ==="
run_suites "$REPO_ROOT"
case "$RUN_STATUS" in
  green) echo "OK: GREEN at HEAD." ;;
  none)
    echo "FAIL: the gated suites executed 0 tests at HEAD — they are skipping, not passing."
    exit 1
    ;;
  red)
    echo "FAIL: the gated suites do not pass at HEAD."
    exit 1
    ;;
esac

echo
echo "Red-first gate passed: RED at parent, GREEN at HEAD."
