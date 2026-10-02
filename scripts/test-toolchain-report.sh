#!/bin/bash
# Test for scripts/toolchain-report.sh, the "N tests not run on this toolchain" counter (#272).
#
# The counter's worst failure is a confident "0 tests not run" while tests are being skipped, so
# this runs it over a small fixture tree for several toolchains and checks every number. The
# fixture is written to a temp dir (never under SwiftTests/, where the real suite would build it).
# The last check runs it over the real tests for THIS machine's toolchain, which proves version
# detection works here.
#
# Compatible with the stock macOS bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

REPORT="scripts/toolchain-report.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/tests/Nested" "$TMP/empty"

# 9 tests. Per toolchain:            Swift 6.1 / macOS 15 | Swift 6.3 / macOS 26 | Swift 6.3 / macOS 15
#   always                           runs                 | runs                 | runs
#   gatedByCompiler                  not compiled         | runs                 | runs
#   gatedByBoth                      not compiled         | runs                 | skipped (macOS)
#   onlyOnOldCompilers (#else)       runs                 | not compiled         | not compiled
#   gatedByGuard                     skipped (macOS)      | runs                 | skipped (macOS)
#   gatedByIf, two checks            skipped once (macOS) | runs                 | skipped once (macOS)
#   alreadySatisfied (macOS 13)      runs                 | runs                 | runs
#   afterHelper                      runs                 | runs                 | runs
#   nestedGate (inside two #if)      not compiled         | runs                 | runs
cat > "$TMP/tests/Fixture.swift" <<'SWIFT'
import Testing

@Suite struct FixtureTests {
    @Test func always() { #expect(true) }

    // @Test func commentedOut() {}   <- not a test: the line does not start with @Test

    #if compiler(>=6.2)
    @Test func gatedByCompiler() { #expect(true) }

    @Test("with a display name")
    func gatedByBoth() async {
        guard #available(macOS 26.0, *) else { return }
        #expect(true)
    }
    #else
    @Test func onlyOnOldCompilers() { #expect(true) }
    #endif

    @Test func gatedByGuard() {
        guard #available(macOS 26.0, *) else { return }
        #expect(true)
    }

    @Test func gatedByIf() {
        if #available(macOS 26.0, *) { #expect(true) }
        if #available(macOS 26.1, *) { #expect(true) }
    }

    @Test func alreadySatisfied() {
        guard #available(macOS 13.0, *) else { return }
        #expect(true)
    }

    // A helper's check belongs to no test: listed as "could not attribute", never counted.
    func helper() -> Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    @Test func afterHelper() { #expect(helper() || true) }
}
SWIFT

cat > "$TMP/tests/Nested/Nested.swift" <<'SWIFT'
import Testing

#if canImport(Foundation)
#if compiler(>=6.2)
@Test func nestedGate() { #expect(true) }
#endif
#endif

// A compound condition is not evaluated: listed on every toolchain, its contents assumed compiled.
#if compiler(>=6.2) && os(macOS)
func notATest() {}
#endif
SWIFT

failures=0

# check LABEL SWIFT MACOS NOT_RUN NOT_COMPILED SKIPPED UNATTRIBUTED SUITE_TOTAL
check() {
  local label="$1" out
  out=$(bash "$REPORT" --tests "$TMP/tests" --swift "$2" --macos "$3")
  local ok=1
  printf '%s\n' "$out" | grep -q "^\*\*$4 tests not run on this toolchain\*\* " || ok=0
  if [ "$4" -gt 0 ]; then
    printf '%s\n' "$out" | grep -q "^- $5 not compiled: " || ok=0
    printf '%s\n' "$out" | grep -q "^- $6 compiled but skipped by a macOS check " || ok=0
  fi
  if [ "$7" -gt 0 ]; then
    printf '%s\n' "$out" | grep -q "^$7 toolchain condition(s) this script could not attribute" || ok=0
  else
    printf '%s\n' "$out" | grep -q "could not attribute" && ok=0
  fi
  printf '%s\n' "$out" | grep -q "Test run with $8 tests" || ok=0
  if [ "$ok" = 1 ]; then
    echo "  $label: PASS"
  else
    echo "  $label: FAIL — expected $4 not run ($5 not compiled, $6 skipped), $7 unattributed, suite total $8; got:"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  fi
}

# expect_text LABEL TEXT SWIFT MACOS: the report names the test (or line) it counted.
# (The report is captured first: `report | grep -q` under pipefail fails when grep exits early.)
expect_text() {
  local out
  out=$(bash "$REPORT" --tests "$TMP/tests" --swift "$3" --macos "$4")
  if printf '%s\n' "$out" | grep -qF -- "$2"; then
    echo "  $1: PASS"
  else
    echo "  $1: FAIL — '$2' is not in the report"
    failures=$((failures + 1))
  fi
}

# expect_refusal LABEL ARGS...: must exit non-zero, never print a count.
expect_refusal() {
  local label="$1"; shift
  if bash "$REPORT" "$@" >/dev/null 2>&1; then
    echo "  $label: FAIL — exited 0"
    failures=$((failures + 1))
  else
    echo "  $label: PASS"
  fi
}

echo "toolchain-report:"
# The helper's check and the compound #if are unattributed on macOS 15; only the compound #if on 26.
check "old compiler, old macOS (the macos-15 runner)" 6.1.2 15.7.9  5 3 2 2 6
check "new compiler, new macOS (nothing skipped)"     6.3.3 26.6.2  1 1 0 1 8
check "new compiler, old macOS"                       6.3   15      4 1 3 2 8
check "a patch release still satisfies >=6.2"         6.2.4 26.6    1 1 0 1 8
check "a macOS check newer than the runner's minor"   6.3   26.0    2 1 1 1 8
expect_text "names a test that is not compiled"       'nestedGate` ('  6.1 15
expect_text "names the #else branch it drops"         'onlyOnOldCompilers` (' 6.3 26
expect_text "names a test skipped by a macOS check"   'gatedByBoth` (' 6.3 15
expect_text "lists the compound condition"            'compiler(>=6.2) && os(macOS)' 6.3 26
expect_refusal "refuses a directory with no tests"    --tests "$TMP/empty" --swift 6.3 --macos 26
expect_refusal "refuses a version it cannot read"     --tests "$TMP/tests" --swift banana --macos 26
expect_refusal "refuses an unknown argument"          --frobnicate

# This machine, the real tests: version detection works and the report has its headline.
real=$(bash "$REPORT")
if printf '%s\n' "$real" | grep -q '^\*\*[0-9][0-9]* tests not run on this toolchain\*\* '; then
  echo "  this machine's toolchain, the real tests: PASS"
else
  echo "  this machine's toolchain, the real tests: FAIL — no headline"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "PASS"
