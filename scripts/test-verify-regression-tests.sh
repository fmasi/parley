#!/bin/bash
# Test for scripts/verify-regression-tests.sh (the red-first gate): every outcome of the parent
# run and of the HEAD run must be classified correctly, and a failure to resolve, build, link or
# run must never be reported as RED (#260).
#
# Hermetic and fast (a few seconds): it builds a throwaway git repo laid out like this one and
# puts a FAKE `swift` first on PATH. The fake prints a canned log and exits with a canned status
# for each (side, step) the gate runs, so no package is resolved and nothing is compiled. The
# canned logs are excerpts of what the real toolchain printed for the same situations (a tiny
# real package, Swift 6.4), the checkout failure reported in #260, and the uncoloured shape that
# older toolchains print.
#
# Compatible with the stock macOS bash 3.2.
set -euo pipefail

# A git hook exports GIT_DIR and its siblings, and the pre-push hook is where `just ci` runs this. With
# them set, every `git` call below — the `init`, the commits, the branches of the throwaway repo —
# would act on the REAL repository instead. Drop them before anything touches git.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

GATE="$(cd "$(dirname "$0")" && pwd)/verify-regression-tests.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The gate compares paths the way the compiler prints them, so use the physical path.
tmp=$(cd "$tmp" && pwd -P)

repo="$tmp/repo"
fake="$tmp/fake"       # the scenario: <side>.<step>.log and <side>.<step>.rc, plus `calls`
bin="$tmp/bin"
mkdir -p "$repo" "$fake" "$bin" "$tmp/home"

# --- the fake swift ------------------------------------------------------------------------------

cat >"$bin/swift" <<'FAKE'
#!/bin/bash
# side: the repository itself is HEAD; any other tree is the gate's throwaway parent worktree.
if [ "$(pwd -P)" = "$FAKE_HEAD" ]; then side=head; else side=parent; fi
case "$1 ${2:-}" in
  "package resolve")     step=resolve ;;
  "build --build-tests") step=testbuild ;;
  build*)                step=build ;;
  test*)                 step=run ;;
  *) echo "fake swift: unexpected arguments: $*" >&2; exit 97 ;;
esac
echo "$side.$step" >>"$FAKE_DIR/calls"
# What the tree under test actually contains when the test target is compiled.
if [ "$step" = testbuild ]; then
  cat SwiftTests/TranscriberTests/CalcTests.swift >"$FAKE_DIR/$side.seen-test" 2>/dev/null || :
  cat TranscriberCore/Calc.swift >"$FAKE_DIR/$side.seen-prod"
  ls SwiftTests/TranscriberTests >"$FAKE_DIR/$side.seen-files"
fi
if [ -f "$FAKE_DIR/$side.$step.log" ]; then
  sed "s|@TREE@|$(pwd -P)|g" "$FAKE_DIR/$side.$step.log"
fi
if [ -f "$FAKE_DIR/$side.$step.rc" ]; then exit "$(cat "$FAKE_DIR/$side.$step.rc")"; fi
exit 0
FAKE
chmod +x "$bin/swift"

# --- the throwaway repository --------------------------------------------------------------------

g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

g init -q .
mkdir -p "$repo/TranscriberCore" "$repo/SwiftTests/TranscriberTests"
echo '// swift-tools-version: 5.9' >"$repo/Package.swift"
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a - b } }' >"$repo/TranscriberCore/Calc.swift"
echo 'struct CalcTests {}' >"$repo/SwiftTests/TranscriberTests/CalcTests.swift"
echo 'struct OtherTests {}' >"$repo/SwiftTests/TranscriberTests/OtherTests.swift"
# Long enough for git's rename detection to pair it with its renamed copy below.
printf '%s\n' 'struct MovedTests {' '  // one' '  // two' '  // three' '  // four' '  // five' \
  '  // six' '  // seven' '}' >"$repo/SwiftTests/TranscriberTests/MovedTests.swift"
g add -A
g commit -qm base
g branch base

# fix: a production change plus a changed test file — the gate applies.
g checkout -q -b fix base
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a + b } }' >"$repo/TranscriberCore/Calc.swift"
echo 'struct CalcTests { /* asserts add(2, 2) == 4 */ }' >"$repo/SwiftTests/TranscriberTests/CalcTests.swift"
g commit -qam fix

# tests-only: no production change — the gate passes trivially.
g checkout -q -b tests-only base
echo 'struct CalcTests { /* characterization */ }' >"$repo/SwiftTests/TranscriberTests/CalcTests.swift"
g commit -qam tests-only

# exempt: a production change, and the only changed test file carries the marker.
g checkout -q -b exempt base
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a + b } }' >"$repo/TranscriberCore/Calc.swift"
printf '%s\n' '// RED-FIRST-EXEMPT: characterization of existing behaviour' 'struct CalcTests {}' \
  >"$repo/SwiftTests/TranscriberTests/CalcTests.swift"
g commit -qam exempt

# mixed: a production change, one gated test file, and one exempt test file.
g checkout -q -b mixed fix
printf '%s\n' '// RED-FIRST-EXEMPT: characterization of existing behaviour' 'struct OtherTests {}' \
  >"$repo/SwiftTests/TranscriberTests/OtherTests.swift"
g commit -qam mixed

# renamed: a production change, and a test file renamed AND modified (#297) — it is gated.
g checkout -q -b renamed base
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a + b } }' >"$repo/TranscriberCore/Calc.swift"
g mv SwiftTests/TranscriberTests/MovedTests.swift SwiftTests/TranscriberTests/MovedAgainTests.swift
sed 's|// four|// four: asserts add(2, 2) == 4|' "$repo/SwiftTests/TranscriberTests/MovedAgainTests.swift" >"$tmp/moved"
cat "$tmp/moved" >"$repo/SwiftTests/TranscriberTests/MovedAgainTests.swift"
g commit -qam renamed

# rewritten: a production change, and a test file renamed AND rewritten past git's rename detection
# (under 50 % similar): the diff shows it deleted and a new file added, which declares the same type.
g checkout -q -b rewritten base
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a + b } }' >"$repo/TranscriberCore/Calc.swift"
g rm -q SwiftTests/TranscriberTests/MovedTests.swift
printf '%s\n' 'struct MovedTests {' '  // asserts add(2, 2) == 4' '  // and add(0, 0) == 0' '}' \
  >"$repo/SwiftTests/TranscriberTests/RewrittenTests.swift"
g add -A
g commit -qm rewritten

# moved-and-fixed: a production change, a changed test file, and another test file renamed WITHOUT
# a change (a helper moved): the parent tree must hold the moved file under its new name.
g checkout -q -b moved-and-fixed fix
g mv SwiftTests/TranscriberTests/MovedTests.swift SwiftTests/TranscriberTests/MovedAgainTests.swift
g commit -qm moved-and-fixed

# moved: a production change, and a test file renamed WITHOUT a change — nothing new to gate.
g checkout -q -b moved base
echo 'enum Calc { static func add(_ a: Int, _ b: Int) -> Int { a + b } }' >"$repo/TranscriberCore/Calc.swift"
g mv SwiftTests/TranscriberTests/MovedTests.swift SwiftTests/TranscriberTests/MovedAgainTests.swift
g commit -qam moved

# --- canned logs -----------------------------------------------------------------------------------

ESC=$(printf '\033')
CHANGED="@TREE@/SwiftTests/TranscriberTests/CalcTests.swift"
UNCHANGED="@TREE@/SwiftTests/TranscriberTests/OtherTests.swift"

# The failure in #260: SwiftPM cannot check a dependency out of a damaged local cache.
LOG_CHECKOUT="Creating working copy for https://github.com/FluidInference/FluidAudio.git
error: 'fluidaudio': Couldn’t check out revision ‘0123456789abcdef0123456789abcdef01234567’:
    fatal: unable to read tree (0123456789abcdef0123456789abcdef01234567)"
LOG_CLONE="Fetching /nonexistent/dep.git
error: Failed to clone repository /nonexistent/dep.git:
    fatal: repository '/nonexistent/dep.git' does not exist"
LOG_PROD_ERROR="Building for debugging...
error: @TREE@/TranscriberCore/Calc.swift:1:76 expected expression after operator
error: SwiftDriver TranscriberCore normal arm64 com.apple.xcode.tools.swift.compiler failed with a nonzero exit code.
error: Build failed"
LOG_DEP_ERROR="Building for debugging...
@TREE@/.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/AsrManager.swift:10:5: error: cannot find type 'MLModel' in scope
error: fatalError"
# Newer toolchains colour the diagnostic even when the output is a file.
LOG_TEST_ERROR_COLOUR="Building for debugging...
error: SwiftCompile normal arm64 $CHANGED failed with a nonzero exit code.
$CHANGED:3:53: ${ESC}[1;31merror: ${ESC}[1;39mtype 'Calc' has no member 'mul'${ESC}[0;0m
error: Build failed"
LOG_TEST_ERROR_PLAIN="Building for debugging...
$CHANGED:3:53: error: type 'Calc' has no member 'mul'
error: fatalError"
LOG_TEST_ERROR_PREFIX="Building for debugging...
error: $CHANGED:3:53 expected expression after operator
error: Build failed"
LOG_TEST_ERROR_ELSEWHERE="Building for debugging...
error: SwiftCompile normal arm64 $UNCHANGED failed with a nonzero exit code.
$UNCHANGED:3:55: ${ESC}[1;31merror: ${ESC}[1;39mtype 'Calc' has no member 'gone'${ESC}[0;0m
Failed frontend command: swift-frontend -primary-file $UNCHANGED $CHANGED -o CalcTests.o
error: Build failed"
LOG_LINK="Building for debugging...
Undefined symbols for architecture arm64:
  \"_OBJC_CLASS_\$_SPUUpdater\", referenced from:
ld: symbol(s) not found for architecture arm64
clang: error: linker command failed with exit code 1 (use -v to see invocation)
error: Build failed"
LOG_RUN_FAILED="Build complete! (0.36 secs)
◇ Test run started.
✘ Test adds() recorded an issue at CalcTests.swift:3:40: Expectation failed: Calc.add(2, 2) == 4
✘ Test adds() failed after 0.001 seconds with 1 issue.
✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.
Note: Some test targets reported failures:
  - TranscriberTests (Swift Testing)"
LOG_RUN_FAILED_OLD="Build complete! (0.36 secs)
◇ Test run started.
✘ Test run with 3 tests failed after 0.001 seconds with 1 issue."
LOG_RUN_PASSED="Build complete! (0.31 secs)
◇ Test run started.
✔ Test adds() passed after 0.001 seconds.
✔ Test run with 1 test in 1 suite passed after 0.001 seconds."
LOG_RUN_ZERO="Build complete! (0.31 secs)
◇ Test run started.
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
LOG_RUN_CRASH="Build complete! (0.34 secs)
error: Process 'swiftpm-testing-helper --test-bundle-path @TREE@/.build/TranscriberTests.xctest' exited with unexpected signal code 5
◇ Test run started.
◇ Test adds() started.
TranscriberCore/Calc.swift:1: Fatal error: boom
Note: Some test targets reported failures:
  - TranscriberTests (Swift Testing)"

# --- harness ---------------------------------------------------------------------------------------

failures=0
out=""
status=0

scenario() { rm -rf "$fake"; mkdir -p "$fake"; : >"$fake/calls"; }
# given SIDE STEP EXIT_STATUS LOG
given() { printf '%s\n' "$4" >"$fake/$1.$2.log"; echo "$3" >"$fake/$1.$2.rc"; }
# The usual HEAD: everything builds, the tests run and pass.
head_green() { given head run 0 "$LOG_RUN_PASSED"; }
# The usual parent: the tests run and fail.
parent_red() { given parent run 1 "$LOG_RUN_FAILED"; }

run_gate() { # BRANCH
  g checkout -q "$1"
  status=0
  # A home of its own: without one the gate would make a real throwaway home, with a clone of the
  # model cache, for every scenario.
  out=$(cd "$repo" && CFFIXED_USER_HOME="$tmp/home" PATH="$bin:$PATH" FAKE_DIR="$fake" FAKE_HEAD="$repo" bash "$GATE" base 2>&1) || status=$?
}

fail() { failures=$((failures + 1)); echo "  FAIL: $1"; echo "----- gate output -----"; echo "$out"; echo "-----------------------"; }
check() { # NAME EXPECTED_STATUS MUST_CONTAIN [MUST_NOT_CONTAIN] [EXPECTED_CALLS]
  local name="$1" want="$2" must="$3" mustnot="${4:-}" calls="${5:-}" got
  if [ "$status" -ne "$want" ]; then fail "$name: exit $status, expected $want"; return; fi
  if ! grep -qF -- "$must" <<<"$out"; then fail "$name: output lacks '$must'"; return; fi
  if [ -n "$mustnot" ] && grep -qF -- "$mustnot" <<<"$out"; then fail "$name: output contains '$mustnot'"; return; fi
  if [ -n "$calls" ]; then
    got=$(paste -s -d ' ' - <"$fake/calls")
    if [ "$got" != "$calls" ]; then fail "$name: swift was run as '$got', expected '$calls'"; return; fi
  fi
  echo "  ok: $name"
}

BROKEN_PARENT="FAIL: could not build the parent — not RED."
BROKEN_HEAD="FAIL: could not build or run HEAD — not a verdict on the tests."
RED="OK: RED at parent"
PASSED="Red-first gate passed: RED at parent, GREEN at HEAD."
ALL_PARENT="parent.resolve parent.build parent.testbuild parent.run"
ALL_HEAD="head.resolve head.build head.testbuild head.run"

echo "parent: broken (never RED)"

scenario; given parent resolve 1 "$LOG_CHECKOUT"; head_green; run_gate fix
check "dependency checkout fails (#260)" 1 "$BROKEN_PARENT" "$RED" "parent.resolve"
check "  ... names the cause" 1 "package resolution or checkout failed"
check "  ... says how to repair the cache" 1 "swift package purge-cache"

scenario; given parent resolve 1 "$LOG_CLONE"; head_green; run_gate fix
check "dependency clone fails" 1 "$BROKEN_PARENT" "$RED" "parent.resolve"

scenario; given parent build 1 "$LOG_PROD_ERROR"; head_green; run_gate fix
check "production code does not compile" 1 "$BROKEN_PARENT" "$RED" "parent.resolve parent.build"

scenario; given parent build 1 "$LOG_DEP_ERROR"; head_green; run_gate fix
check "a dependency does not compile" 1 "$BROKEN_PARENT" "$RED" "parent.resolve parent.build"

scenario; given parent build 1 "$LOG_LINK"; head_green; run_gate fix
check "a production target does not link" 1 "$BROKEN_PARENT" "$RED" "parent.resolve parent.build"

scenario; given parent testbuild 1 "$LOG_TEST_ERROR_ELSEWHERE"; head_green; run_gate fix
check "compile error only in an UNCHANGED test file" 1 "$BROKEN_PARENT" "$RED" "parent.resolve parent.build parent.testbuild"
check "  ... names the cause" 1 "none in a changed test file"

scenario; given parent testbuild 1 "$LOG_LINK"; head_green; run_gate fix
check "the test bundle does not link" 1 "$BROKEN_PARENT" "$RED" "parent.resolve parent.build parent.testbuild"

scenario; given parent run 1 "$LOG_RUN_CRASH"; head_green; run_gate fix
check "the test process crashes, no summary" 1 "$BROKEN_PARENT" "$RED" "$ALL_PARENT"

scenario; given parent run 1 "$LOG_RUN_PASSED"; head_green; run_gate fix
check "non-zero exit although the tests passed" 1 "$BROKEN_PARENT" "$RED" "$ALL_PARENT"

scenario; given parent run 1 "$LOG_RUN_ZERO"; head_green; run_gate fix
check "non-zero exit with 0 tests executed" 1 "$BROKEN_PARENT" "$RED" "$ALL_PARENT"

scenario; given parent run 1 ""; head_green; run_gate fix
check "non-zero exit with no output at all" 1 "$BROKEN_PARENT" "$RED" "$ALL_PARENT"

echo "parent: RED"

scenario; given parent testbuild 1 "$LOG_TEST_ERROR_COLOUR"; head_green; run_gate fix
check "compile error in the changed test file (coloured)" 0 "$PASSED" "" "parent.resolve parent.build parent.testbuild $ALL_HEAD"
check "  ... says why it is RED" 0 "$RED (compile error in the changed test files"

scenario; given parent testbuild 1 "$LOG_TEST_ERROR_PLAIN"; head_green; run_gate fix
check "compile error in the changed test file (plain)" 0 "$PASSED"

# Far more compile errors than the gate prints (over a pipe buffer's worth, so a reader that
# stops after ten lines reliably breaks the pipe): printing only the first ten must not end the gate.
LOG_TEST_ERROR_MANY="Building for debugging..."
for i in $(seq 1 2000); do
  LOG_TEST_ERROR_MANY="$LOG_TEST_ERROR_MANY
$CHANGED:$i:5: error: type 'Calc' has no member 'f$i'"
done
scenario; given parent testbuild 1 "$LOG_TEST_ERROR_MANY"; head_green; run_gate fix
check "two thousand compile errors in the changed test file" 0 "$PASSED"

scenario; given parent testbuild 1 "$LOG_TEST_ERROR_PREFIX"; head_green; run_gate fix
check "compile error in the changed test file ('error: path' shape)" 0 "$PASSED"

scenario; parent_red; head_green; run_gate fix
check "the tests run and fail" 0 "$PASSED" "" "$ALL_PARENT $ALL_HEAD"
# The parent run saw the parent's production code under HEAD's test file; HEAD saw its own.
if grep -q 'a - b' "$fake/parent.seen-prod" && grep -q 'asserts add' "$fake/parent.seen-test" \
  && grep -q 'a + b' "$fake/head.seen-prod"; then
  echo "  ok:   ... against the parent's code with HEAD's test file overlaid"
else
  out="(overlay check)"; fail "the parent run did not see the parent's code under HEAD's test file"
fi

scenario; given parent run 1 "$LOG_RUN_FAILED_OLD"; head_green; run_gate fix
check "the tests run and fail (older summary line)" 0 "$PASSED"

scenario; given parent testbuild 1 "$LOG_TEST_ERROR_COLOUR"; head_green; run_gate mixed
check "compile error in the gated file, next to an exempt one" 0 "$PASSED" "only in RED-FIRST-EXEMPT"

# A renamed-and-modified test file is gated under its new name (#297), and the parent run sees it
# only under that name: the old copy would declare the same types twice and fail to compile — a
# false RED.
scenario; parent_red; head_green; run_gate renamed
check "a renamed and modified test file is gated" 0 "$PASSED" "" "$ALL_PARENT $ALL_HEAD"
check "  ... under its new name" 0 "gated files: SwiftTests/TranscriberTests/MovedAgainTests.swift"
seen=$(paste -s -d ' ' - 2>/dev/null <"$fake/parent.seen-files" || echo "(the parent's test target was never built)")
if grep -qx 'MovedAgainTests.swift' "$fake/parent.seen-files" 2>/dev/null \
  && ! grep -qx 'MovedTests.swift' "$fake/parent.seen-files"; then
  echo "  ok:   ... and the parent tree holds it under the new name only"
else
  out="parent tree: $seen"; fail "the parent tree does not hold the renamed file under its new name only"
fi

# The same, below git's rename threshold: the diff shows a delete and an add. The parent tree must
# not keep the deleted file either, or the type it declares is declared twice.
scenario; parent_red; head_green; run_gate rewritten
check "a test file renamed and rewritten (delete + add) is gated" 0 "$PASSED" "" "$ALL_PARENT $ALL_HEAD"
check "  ... under its new name" 0 "gated files: SwiftTests/TranscriberTests/RewrittenTests.swift"
seen=$(paste -s -d ' ' - 2>/dev/null <"$fake/parent.seen-files" || echo "(the parent's test target was never built)")
if grep -qx 'RewrittenTests.swift' "$fake/parent.seen-files" 2>/dev/null \
  && ! grep -qx 'MovedTests.swift' "$fake/parent.seen-files"; then
  echo "  ok:   ... and the parent tree does not keep the file the PR deleted"
else
  out="parent tree: $seen"; fail "the parent tree keeps the test file the PR deleted"
fi

# A file renamed without a change is not gated, but the parent tree still holds it, under its new
# name: dropping it would leave whatever uses it unable to compile (a false RED, or BROKEN).
scenario; parent_red; head_green; run_gate moved-and-fixed
check "a test file renamed without a change, next to a gated one" 0 "$PASSED" "MovedAgainTests" "$ALL_PARENT $ALL_HEAD"
seen=$(paste -s -d ' ' - 2>/dev/null <"$fake/parent.seen-files" || echo "(the parent's test target was never built)")
if grep -qx 'MovedAgainTests.swift' "$fake/parent.seen-files" 2>/dev/null \
  && ! grep -qx 'MovedTests.swift' "$fake/parent.seen-files"; then
  echo "  ok:   ... and the parent tree holds the moved file under its new name"
else
  out="parent tree: $seen"; fail "the parent tree does not hold the moved file under its new name"
fi

echo "parent: RED only from a gated file (#297)"

# OtherTests is changed and exempt on this branch; the gated CalcTests has no error. The gated
# suites never ran at the parent, so nothing shows they fail without the fix.
scenario; given parent testbuild 1 "$LOG_TEST_ERROR_ELSEWHERE"; head_green; run_gate mixed
check "compile error only in an EXEMPT changed test file: not RED" 1 "only in RED-FIRST-EXEMPT" "$RED" "parent.resolve parent.build parent.testbuild"
check "  ... says what to do" 1 "remove its marker"

echo "parent: not RED"

scenario; given parent run 0 "$LOG_RUN_PASSED"; head_green; run_gate fix
check "the tests pass at the parent" 1 "FAIL: the changed tests PASS at the parent commit." "$RED" "$ALL_PARENT"

scenario; given parent run 0 "$LOG_RUN_ZERO"; head_green; run_gate fix
check "0 tests executed at the parent" 1 "FAIL: the gated suites executed 0 tests at the parent commit" "$RED" "$ALL_PARENT"

echo "HEAD"

scenario; parent_red; given head resolve 1 "$LOG_CHECKOUT"; run_gate fix
check "dependency checkout fails" 1 "$BROKEN_HEAD" "do not pass at HEAD" "$ALL_PARENT head.resolve"

scenario; parent_red; given head build 1 "$LOG_LINK"; run_gate fix
check "a production target does not link" 1 "$BROKEN_HEAD" "do not pass at HEAD"

scenario; parent_red; given head build 1 "$LOG_DEP_ERROR"; run_gate fix
check "a dependency does not compile" 1 "$BROKEN_HEAD" "do not pass at HEAD"

scenario; parent_red; given head testbuild 1 "$LOG_LINK"; run_gate fix
check "the test bundle does not link" 1 "$BROKEN_HEAD" "do not pass at HEAD"

scenario; parent_red; given head run 1 "$LOG_RUN_CRASH"; run_gate fix
check "the test process crashes, no summary" 1 "$BROKEN_HEAD" "do not pass at HEAD" "$ALL_PARENT $ALL_HEAD"

scenario; parent_red; given head build 1 "$LOG_PROD_ERROR"; run_gate fix
check "production code does not compile" 1 "FAIL: the gated suites do not pass at HEAD (the production code does not compile" "$BROKEN_HEAD"

scenario; parent_red; given head testbuild 1 "$LOG_TEST_ERROR_COLOUR"; run_gate fix
check "the tests do not compile" 1 "FAIL: the gated suites do not pass at HEAD (the tests do not compile" "$BROKEN_HEAD"

scenario; parent_red; given head run 1 "$LOG_RUN_FAILED"; run_gate fix
check "the tests run and fail" 1 "FAIL: the gated suites do not pass at HEAD" "$BROKEN_HEAD" "$ALL_PARENT $ALL_HEAD"

scenario; parent_red; given head run 0 "$LOG_RUN_ZERO"; run_gate fix
check "0 tests executed" 1 "FAIL: the gated suites executed 0 tests at HEAD" "$BROKEN_HEAD"

echo "the throwaway home (#313)"

# A home the caller set is checked: the user's real one, or one that does not exist, runs nothing.
scenario; parent_red; head_green
g checkout -q fix
status=0
out=$(cd "$repo" && CFFIXED_USER_HOME="$HOME" PATH="$bin:$PATH" FAKE_DIR="$fake" FAKE_HEAD="$repo" bash "$GATE" base 2>&1) || status=$?
check "CFFIXED_USER_HOME is the real home" 1 "is the user's real home" "$PASSED"
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "the gate ran swift in the real home"; }
scenario; parent_red; head_green
status=0
out=$(cd "$repo" && CFFIXED_USER_HOME="$tmp/no-such-home" PATH="$bin:$PATH" FAKE_DIR="$fake" FAKE_HEAD="$repo" bash "$GATE" base 2>&1) || status=$?
check "CFFIXED_USER_HOME does not exist" 1 "is not an existing folder" "$PASSED"
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "the gate ran swift with a missing home"; }

# With no home from the caller the gate makes one per side; when it cannot, nothing runs. A copy of
# the gate next to a test-home.sh that fails, as one does on a full disk.
mkdir -p "$tmp/gate-copy"
cp "$GATE" "$tmp/gate-copy/verify-regression-tests.sh"
printf '%s\n' '#!/bin/bash' 'echo "cp: Library/Application Support/FluidAudio: No space left on device" >&2' 'exit 1' \
  >"$tmp/gate-copy/test-home.sh"
scenario; parent_red; head_green
g checkout -q fix
status=0
out=$(cd "$repo" && env -u CFFIXED_USER_HOME PATH="$bin:$PATH" FAKE_DIR="$fake" FAKE_HEAD="$repo" \
  bash "$tmp/gate-copy/verify-regression-tests.sh" base 2>&1) || status=$?
check "the throwaway home cannot be made" 1 "could not make a throwaway home for the parent run" "$PASSED"
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "the gate ran swift without a throwaway home"; }

echo "gate does not apply"

scenario; run_gate tests-only
check "tests-only change" 0 "PASS (trivially): no production code changed"
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "tests-only change ran swift"; }

scenario; run_gate moved
check "a test file renamed without a change" 0 "PASS (trivially): no test files changed."
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "a pure rename ran swift"; }

scenario; run_gate exempt
check "every changed test file is exempt" 0 "PASS (trivially): every changed test file is RED-FIRST-EXEMPT."
[ -s "$fake/calls" ] && { out=$(cat "$fake/calls"); fail "exempt change ran swift"; }

echo
if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "PASS"
