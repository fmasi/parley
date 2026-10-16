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
#   1. Diff BASE...HEAD for added, modified, and renamed-and-modified files under
#      SwiftTests/TranscriberTests/ (#297: with only added/modified, a test file renamed and
#      changed in the same PR was not gated at all). A rename with no change brings no new test,
#      so it is not gated. A renamed file is gated under its new name.
#   2. Trivially pass when the gate does not apply:
#        - no test files changed, or
#        - no production code changed (a tests-only PR adds characterization tests for
#          EXISTING behaviour — those are green at the parent by definition), or
#        - every changed test file is explicitly exempted (see below).
#   3. Create a throwaway git worktree at BASE, overlay the changed test files from HEAD
#      onto it (and the test files renamed without a change, under their new names), delete from
#      it every test file the PR deletes (a renamed file's old copy, or a file
#      whose types moved elsewhere, would otherwise declare those types a second time and fail to
#      compile: a false RED or BROKEN), and run just the test suites declared in the changed files.
#      The run is four steps, and
#      each outcome is classified — a non-zero exit is NOT RED by itself:
#        a. `swift package resolve` fails            -> BROKEN. Nothing was compiled, so nothing
#           was learned about the tests.
#        b. `swift build` (everything but the test target) fails -> BROKEN. The parent's own code
#           and its dependencies built when that commit merged; if they do not build now, the
#           machine is at fault, not the tests.
#        c. `swift build --build-tests` fails        -> RED only if the compiler reports an error
#           IN ONE OF THE GATED TEST FILES (a new test referencing a symbol the fix introduces
#           cannot compile at the parent — it cannot pass there, which is the property this gate
#           needs). Errors only in RED-FIRST-EXEMPT changed files are NOT RED (#297): the gated
#           suites never ran, so nothing shows they fail without the fix, and an exempt file that
#           does not compile at the parent is not the characterization its marker claims. A
#           failure with no error in a changed file (linker, toolchain, an error somewhere else)
#           is BROKEN.
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
#   Known limit: a test file the PR deletes is removed from the parent tree. If the PR moves a type
#   from a deleted test file into production code (behind a seam in TranscriberCore), unchanged tests
#   that use it no longer compile at the parent: BROKEN, never a false RED. Keep the type in a test
#   file in that PR, or move it in a PR of its own.
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

# Run from a git hook, this script inherits GIT_DIR and its siblings. SwiftPM checks dependencies out
# with git, and with that environment a tree with no build directory yet — the throwaway parent
# worktree below is always one — fails to resolve its packages, which used to read as RED (#260).
# Git finds the repository from the working directory without them.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

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
# Both trees' tests run with a throwaway home: the parent's tests are the old ones, and an old test
# may still resolve the user's real folders (#313). Each side gets a fresh one (run_suites), so what
# the parent's tests leave in it cannot change HEAD's result. A home the caller set is used for both
# and checked like a new one: empty, missing or the real home, and nothing runs.
# The home is given to `swift test` only. SwiftPM honours it too: exported to `swift package resolve`
# and `swift build`, it would put SwiftPM's cache, mirrors and fingerprints in the empty home, and
# every run would clone each dependency from the network again.
TEST_HOME_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-home.sh"
CALLER_HOME="${CFFIXED_USER_HOME:-}"
unset CFFIXED_USER_HOME
# The homes this gate made, one per side, removed on exit (each holds a clone of, or on CI a link to,
# the model cache; rm -rf removes a link, never what it points at).
PARENT_HOME=""
HEAD_HOME=""
if [ -n "$CALLER_HOME" ]; then
  bash "$TEST_HOME_SH" --check "$CALLER_HOME"
fi

echo "Red-first gate: BASE=$BASE_SHA HEAD=$HEAD_SHA"

# --- 1. Collect changed test files ---------------------------------------------------------------

# Added (A), modified (M) and renamed (R, with rename detection forced on: `-M`). A rename's line is
# "R<similarity>\told\tnew"; R100 is a rename with no change, which adds no test and is skipped.
test_changes=$(git diff --name-status -M --diff-filter=AMR "$BASE_SHA...$HEAD_SHA" -- "$TEST_DIR")
changed_test_files=$(
  printf '%s\n' "$test_changes" | awk -F '\t' '$1 != "R100" && $NF ~ /\.swift$/ { print $NF }'
)
# The new paths of the test files renamed WITHOUT a change: not gated, but copied into the parent
# tree with the changed files, since the old path is removed from it below.
moved_test_files=$(
  printf '%s\n' "$test_changes" | awk -F '\t' '$1 == "R100" && $NF ~ /\.swift$/ { print $NF }'
)
# Every test file HEAD no longer has: the parent tree must not keep them (step 4), or a type that
# moved to another file is declared twice and the test target fails to compile — a false RED, or
# BROKEN. `--no-renames` lists a rename's old path as deleted too, whatever git's rename detection
# makes of it: a file renamed and rewritten past its 50 % threshold shows only as a delete and an add.
# Swift files only: that is all the duplicate-type problem needs, and a fixture the parent's tests
# read stays where the parent expects it.
removed_test_files=$(
  git diff --name-only --no-renames --diff-filter=D "$BASE_SHA...$HEAD_SHA" -- "$TEST_DIR" | grep '\.swift$' || :
)

# The lists below are split on whitespace (bash 3.2, no arrays of possibly-empty lists). A path with
# a space would be split into fragments: an `rm -f` of a deleted file would then miss it and leave
# its types declared twice. No test file has one; refuse rather than misclassify.
if printf '%s\n' "$changed_test_files" "$moved_test_files" "$removed_test_files" | grep -c '[[:space:]]' >/dev/null; then
  echo "FAIL: a changed, renamed or deleted test file has whitespace in its path, which this gate cannot handle:"
  printf '%s\n' "$changed_test_files" "$moved_test_files" "$removed_test_files" | grep '[[:space:]]' || :
  exit 1
fi

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
    echo "exempt: $f ($(git show "$HEAD_SHA:$f" | grep -m1 -o 'RED-FIRST-EXEMPT:.*'))"
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
  local tree="$1" side="$2" log ec tests_run hits others gated_hits home
  RUN_STATUS="broken"
  RUN_WHY="not classified"

  # A fresh throwaway home for this side, made and checked in statements of their own (#313). It is
  # recorded before the check, so cleanup() removes it even when the check refuses it.
  if [ -n "$CALLER_HOME" ]; then
    home="$CALLER_HOME"
  else
    if ! home=$(bash "$TEST_HOME_SH"); then
      echo "FAIL: could not make a throwaway home for the $side run — nothing was run (#313)."
      exit 1
    fi
    if [ "$side" = parent ]; then PARENT_HOME="$home"; else HEAD_HOME="$home"; fi
    if ! bash "$TEST_HOME_SH" --check "$home"; then
      echo "FAIL: the throwaway home for the $side run is not usable — nothing was run (#313)."
      exit 1
    fi
  fi
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
        printf '%s\n' "$hits" | sed -n '1,10p'   # not head: under pipefail its early exit fails the gate (broken pipe)
        if [ -z "$gated_hits" ]; then
          # #297: not RED. The gated suites never ran at the parent.
          RUN_STATUS="exempt-only"
          RUN_WHY="every compile error is in a RED-FIRST-EXEMPT file"
        fi
      fi
    elif [ -n "$others" ]; then
      RUN_WHY="the test target did not build ('swift build --build-tests' exited $ec): the compiler reported errors, but none in a changed test file, so they are not evidence about the changed tests"
      echo
      echo "compile errors, none of them in a changed test file:"
      printf '%s\n' "$others" | sed -n '1,10p'   # not head: under pipefail its early exit fails the gate (broken pipe)
    else
      RUN_WHY="the test target did not build ('swift build --build-tests' exited $ec) and the compiler reported no error in a source file (linker or toolchain failure)"
    fi
    return 0
  fi

  # d. Run the gated suites.
  ec=0
  # shellcheck disable=SC2086  # the flag variables are intentionally word-split
  (cd "$tree" && CFFIXED_USER_HOME="$home" swift test --filter "($suites)" $TEST_FLAGS $BUILD_FLAGS) >"$log" 2>&1 || ec=$?
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
cleanup() {
  local h
  git worktree remove --force "$parent_tree" 2>/dev/null || rm -rf "$parent_tree"
  # Quoted, and only a path test-home.sh makes: never the caller's home, never a split path.
  for h in "$PARENT_HOME" "$HEAD_HOME"; do
    case "$h" in */parley-test-home.*) rm -rf "$h" ;; esac
  done
}
trap cleanup EXIT

if ! git worktree add --detach "$parent_tree" "$BASE_SHA" >/dev/null 2>&1; then
  echo "FAIL: could not create a worktree at the parent commit ($BASE_SHA) — not RED."
  exit 1
fi
# Overlay ALL changed test files (exempt ones and helpers too — gated tests may depend on
# them) and the ones renamed without a change, but execute only the gated suites.
for f in $removed_test_files; do
  rm -f "$parent_tree/$f"
done
for f in $changed_test_files $moved_test_files; do
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
  exempt-only)
    echo
    echo "FAIL: not RED — the compile errors at the parent are only in RED-FIRST-EXEMPT files."
    echo "The gated suites could not be run there, so nothing shows they fail without the fix."
    echo "An exempt file that does not compile at the parent is not characterizing existing"
    echo "behaviour: remove its marker (it is then gated) or make it compile at the parent."
    exit 1
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
