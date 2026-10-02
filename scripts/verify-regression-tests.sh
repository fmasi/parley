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
#      onto it, and run just the test suites declared in those files. The run is four steps, and
#      each outcome is classified — a non-zero exit is NOT RED by itself:
#        a. `swift package resolve` fails            -> BROKEN. Nothing was compiled, so nothing
#           was learned about the tests.
#        b. `swift build` (everything but the test target) fails -> BROKEN. The parent's own code
#           and its dependencies built when that commit merged; if they do not build now, the
#           machine is at fault, not the tests.
#        c. `swift build --build-tests` fails        -> RED only if the compiler reports an error
#           IN ONE OF THE OVERLAID TEST FILES (a new test referencing a symbol the fix introduces
#           cannot compile at the parent — it cannot pass there, which is the property this gate
#           needs). A failure with no such error (linker, toolchain, an error somewhere else) is
#           BROKEN.
#        d. `swift test` exits non-zero              -> RED only if Swift Testing printed its
#           summary "Test run with N tests ... failed" with N >= 1. No summary (a crash, a kill, a
#           runner that never started) is BROKEN.
#        - Exit 0 with >= 1 test executed means the tests PASS at the parent: the gate fails.
#        - Exit 0 with 0 tests executed means the tests silently skipped or the suite filter
#          matched nothing: the gate fails — a skip is not RED.
#      BROKEN fails the gate with "could not build the parent — not RED" and the cause. It once
#      did not: SwiftPM could not check out a dependency in the throwaway worktree ("Couldn't
#      check out revision ... unable to read tree"), nothing compiled, and the gate printed
#      "OK: RED at parent" and passed on six consecutive pushes (#260).
#   4. Run the same four steps at HEAD and require exit 0 with >= 1 test executed (GREEN). The
#      same classification applies, so a resolution, linker or runner failure at HEAD is reported
#      as BROKEN ("could not build or run HEAD"), not as "the tests do not pass".
#
#   Known limit: a test that CRASHES the test process at the parent (a trap the fix removes) ends
#   the run without a summary and is therefore BROKEN, not RED. Make it fail with an assertion.
#
# EXEMPTION
#   A changed test file containing the literal marker "RED-FIRST-EXEMPT:" (in a comment, with
#   a reason after the colon) is excluded from the gate. Use it for characterization tests of
#   existing behaviour added alongside production changes. The marker is greppable and shows
#   up in the diff, so an exemption is an explicit, reviewable act — not a silent bypass.
#
#   A MARKER LASTS AS LONG AS IT IS IN THE FILE. It exempts the whole file from this gate in
#   every later PR too, not just the one that added it. A reason of the form "this file's only
#   change in this PR is ..." stops being true the moment that PR merges, so remove the marker
#   when its reason expires — in the same PR if the reason is about that PR alone (add it,
#   merge, and the next PR that touches the file deletes it), otherwise as soon as it no longer
#   holds. A PR that later adds a characterization test to the file next to a production change
#   adds a fresh marker with its own reason; that is the intended use.
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
PROD_PATHS="TranscriberCore TranscriberApp AudioCaptureHelper AudioCaptureProtocol Package.swift"

# Flags matching the documented `swift test` invocation (CommandLineTools frameworks). The two
# `swift build` steps and `swift test` share them, so the test step reuses the build.
BUILD_FLAGS="-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/"
# --no-parallel for the same reason as the CI test job: concurrent AVFoundation/CoreML tests
# can wedge a shared media daemon on a headless runner and hang the run. This gate invokes
# swift test TWICE per run (merge base, then HEAD), so it is doubly exposed.
TEST_FLAGS="--no-parallel"

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
  # grep -c, not -q: -q exits at the first match, and a large file then SIGPIPEs `git show`,
  # which `pipefail` turns into "not exempt".
  if git show "$HEAD_SHA:$f" | grep -c 'RED-FIRST-EXEMPT:' >/dev/null; then
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

# --- 3. Helper: build and run the gated suites in a tree, and classify the outcome ---------------
#
#   run_suites TREE SIDE     SIDE is "parent" or "head".
#   Sets RUN_STATUS to one of
#     green   exit 0, >= 1 test executed
#     none    exit 0, 0 tests executed
#     red     the tests failed, or (see below) did not compile
#     broken  the tree could not be resolved, built, linked or run: no verdict on the tests
#   and RUN_WHY to one line naming the step and the cause.
#
#   A compile error counts as "red" at the parent only when it is in an overlaid test file. At
#   HEAD any compile error in the repository's own sources is "red" (the PR does not compile).

# The compiler reports an error in one of two shapes, depending on the toolchain and the kind of
# error; both are recognised:
#     /path/File.swift:12:5: error: cannot find 'x' in scope
#     error: /path/File.swift:12:5 expected expression after operator
# Newer toolchains colour the first shape even when the output is a file, so every log is
# stripped of ANSI escapes before it is read (strip_ansi).

ESC=$(printf '\033')
strip_ansi() {
  local tmp
  tmp=$(mktemp)
  sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$1" >"$tmp" && cat "$tmp" >"$1"
  rm -f "$tmp"
}

# Compiler errors in the tree's own sources (not in a dependency checkout under .build/).
own_compile_errors() {
  grep -E '(\.swift:[0-9]+:[0-9]+: error: |^error: [^ ]*\.swift:[0-9]+:[0-9]+[: ])' "$1" \
    | grep -v '/\.build/' || true
}

# Compiler errors located in one of the given files: the file's path, then line:column, in either
# shape. awk's index() matches the path literally, whatever it contains.
#   compile_errors_in LOG "FILE FILE ..."
compile_errors_in() {
  local log="$1" f
  for f in $2; do
    awk -v f="/$f:" '{
      i = index($0, f); if (!i) next
      rest = substr($0, i + length(f))
      if (rest ~ /^[0-9]+:[0-9]+: error: / || ($0 ~ /^error: / && rest ~ /^[0-9]+:[0-9]+[: ]/)) print
    }' "$log"
  done
}

run_suites() {
  local tree="$1" side="$2" log ec tests_run hits others gated_hits
  RUN_STATUS="broken"
  RUN_WHY="not classified"
  log=$(mktemp)

  # a. Resolve and check out the dependencies. Nothing is compiled here, so a failure says
  #    nothing about the tests.
  ec=0
  (cd "$tree" && swift package resolve) >"$log" 2>&1 || ec=$?
  strip_ansi "$log"
  if [ "$ec" -ne 0 ]; then
    tail -30 "$log"
    rm -f "$log"
    RUN_WHY="package resolution or checkout failed ('swift package resolve' exited $ec)"
    return 0
  fi

  # b. Everything except the test target: the dependencies and the production targets.
  ec=0
  # shellcheck disable=SC2086  # BUILD_FLAGS is intentionally word-split
  (cd "$tree" && swift build $BUILD_FLAGS) >"$log" 2>&1 || ec=$?
  strip_ansi "$log"
  if [ "$ec" -ne 0 ]; then
    tail -30 "$log"
    hits=$(own_compile_errors "$log")
    rm -f "$log"
    if [ "$side" = "head" ] && [ -n "$hits" ]; then
      RUN_STATUS="red"
      RUN_WHY="the production code does not compile ('swift build' exited $ec)"
    else
      RUN_WHY="the dependencies or the production targets did not build ('swift build' exited $ec), before any test file was compiled"
    fi
    return 0
  fi

  # c. The test target. Only this step compiles the overlaid test files.
  ec=0
  # shellcheck disable=SC2086  # BUILD_FLAGS is intentionally word-split
  (cd "$tree" && swift build --build-tests $BUILD_FLAGS) >"$log" 2>&1 || ec=$?
  strip_ansi "$log"
  if [ "$ec" -ne 0 ]; then
    tail -30 "$log"
    others=$(own_compile_errors "$log")
    if [ "$side" = "head" ]; then
      hits="$others"
    else
      hits=$(compile_errors_in "$log" "$changed_test_files")
      gated_hits=$(compile_errors_in "$log" "$gated_files")
    fi
    rm -f "$log"
    if [ -n "$hits" ]; then
      RUN_STATUS="red"
      if [ "$side" = "head" ]; then
        RUN_WHY="the tests do not compile"
      else
        RUN_WHY="compile error in the changed test files — they cannot compile, so cannot pass, without the fix"
        echo
        echo "compile errors in the changed test files:"
        echo "$hits" | head -10
        if [ -z "$gated_hits" ]; then
          echo "NOTE: none of these is in a GATED file — they are all in RED-FIRST-EXEMPT files. The"
          echo "gated suites could not be run at the parent, so this RED rests on the exempt files"
          echo "alone. An exempt file that does not compile at the parent is not characterizing"
          echo "existing behaviour: check its marker."
        fi
      fi
    elif [ -n "$others" ]; then
      RUN_WHY="the test target did not build ('swift build --build-tests' exited $ec): the compiler reported errors, but none in a changed test file, so they are not evidence about the changed tests"
      echo
      echo "compile errors, none of them in a changed test file:"
      echo "$others" | head -10
    else
      RUN_WHY="the test target did not build ('swift build --build-tests' exited $ec) and the compiler reported no error in a source file (linker or toolchain failure)"
    fi
    return 0
  fi

  # d. Run the gated suites.
  ec=0
  # shellcheck disable=SC2086  # the flag variables are intentionally word-split
  (cd "$tree" && swift test --filter "($suites)" $TEST_FLAGS $BUILD_FLAGS) >"$log" 2>&1 || ec=$?
  strip_ansi "$log"
  # swift-testing summary line: "Test run with N tests in M suites passed/failed after ..."
  tests_run=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | tail -1 || true)
  if [ "$ec" -ne 0 ]; then
    if grep -E 'Test run with [0-9]+ tests? .*failed' "$log" >/dev/null \
      && [ -n "$tests_run" ] && [ "$tests_run" -gt 0 ]; then
      RUN_STATUS="red"
      RUN_WHY="tests executed: $tests_run, and the run failed"
    else
      RUN_WHY="'swift test' exited $ec without a Swift Testing summary of a failed run (a crash, a kill, or the runner never started)"
    fi
  elif [ -z "$tests_run" ] || [ "$tests_run" -eq 0 ]; then
    RUN_STATUS="none"
    RUN_WHY="0 tests executed"
  else
    RUN_STATUS="green"
    RUN_WHY="tests executed: $tests_run, all passed"
  fi
  tail -30 "$log"
  rm -f "$log"
}

# --- 4. RED at the parent -------------------------------------------------------------------------

parent_tree=$(mktemp -d)
cleanup() { git worktree remove --force "$parent_tree" 2>/dev/null || rm -rf "$parent_tree"; }
trap cleanup EXIT

if ! git worktree add --detach "$parent_tree" "$BASE_SHA" >/dev/null 2>&1; then
  echo "FAIL: could not create a worktree at the parent commit ($BASE_SHA) — not RED."
  exit 1
fi
# Overlay ALL changed test files (exempt ones and helpers too — gated tests may depend on
# them), but execute only the gated suites.
for f in $changed_test_files; do
  mkdir -p "$parent_tree/$(dirname "$f")"
  git show "$HEAD_SHA:$f" > "$parent_tree/$f"
done

echo
echo "=== Running gated suites at PARENT ($BASE_SHA) — requiring RED ==="
run_suites "$parent_tree" parent
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
    echo "OK: RED at parent ($RUN_WHY)."
    ;;
  *)
    # "broken", and anything this script failed to classify: never RED.
    echo
    echo "FAIL: could not build the parent — not RED."
    echo "Cause: $RUN_WHY."
    echo "This is a failure of the machine or the toolchain, not evidence about the tests: they"
    echo "were never shown to fail without the fix. Fix the cause and run the gate again."
    echo "If the log above says \"Couldn't check out revision\" or \"unable to read tree\", the"
    echo "local SwiftPM cache is damaged: run 'swift package purge-cache' and retry."
    exit 1
    ;;
esac

# --- 5. GREEN at HEAD ------------------------------------------------------------------------------

echo
echo "=== Running gated suites at HEAD ($HEAD_SHA) — requiring GREEN ==="
run_suites "$REPO_ROOT" head
case "$RUN_STATUS" in
  green) echo "OK: GREEN at HEAD." ;;
  none)
    echo "FAIL: the gated suites executed 0 tests at HEAD — they are skipping, not passing."
    exit 1
    ;;
  red)
    echo "FAIL: the gated suites do not pass at HEAD ($RUN_WHY)."
    exit 1
    ;;
  *)
    echo
    echo "FAIL: could not build or run HEAD — not a verdict on the tests."
    echo "Cause: $RUN_WHY."
    echo "This is a failure of the machine or the toolchain, not a failing test. Fix the cause"
    echo "and run the gate again."
    exit 1
    ;;
esac

echo
echo "Red-first gate passed: RED at parent, GREEN at HEAD."
