#!/bin/bash
#
# Toolchain report: which Swift and macOS this machine tests with, and how many tests that
# toolchain CANNOT run.
#
# WHY THIS EXISTS (#272)
#   A test can be "green" without running. Two ways that happens here, both tied to the toolchain:
#     1. `#if compiler(>=6.2)` around a test: an older compiler never sees it. It is not built,
#        not run and not counted, and the suite's total silently shrinks.
#     2. `guard #available(macOS 26.0, *) else { return }` (or the body wrapped in
#        `if #available`): on an older macOS the test is built, runs, returns at once and is
#        reported as PASSED without asserting anything.
#   For months CI ran an older Swift on an older macOS than development, so ten tests — the
#   SpeechAnalyzer engine's, one of them the "a transcription never downloads a missing model"
#   airgap test — never ran there while the check was green. This script makes that number
#   visible: it prints "N tests not run on this toolchain", and N must be 0 for a green run to
#   mean that every test ran.
#
# WHAT IT PRINTS (Markdown, on stdout; CI appends it to the job summary)
#   - the runner image (on GitHub Actions), `swift --version`, `sw_vers`, `xcode-select -p`, and
#     whether the Command Line Tools' Testing.framework is where the test command's `-F` flag
#     points;
#   - "**N tests not run on this toolchain**", split into "not compiled" and "skipped by a macOS
#     check", with the name of each;
#   - how many tests the suite should therefore report ("Test run with <M> tests").
#   On GitHub Actions a non-zero N also raises a warning annotation (on stderr, so it stays out
#   of the summary).
#
# HOW IT COUNTS (a line scanner, not a Swift parser — know its limits)
#   - A test is a line that starts with `@Test`. Its name is the first `func` after it.
#   - Not compiled: the `@Test` line sits inside an `#if compiler(>=X.Y)` / `#if compiler(<X.Y)`
#     (or `swift(...)`) branch this compiler does not take. `#else` and nesting are followed.
#   - Skipped by a macOS check: `#available(macOS N` with N newer than this macOS appears between
#     the test's `@Test` and the next declaration (`func`, `struct`, `class`, `enum`, `actor`,
#     `extension`, `@Suite`, `@Test`). A test is counted once, even with several checks.
#   - Anything it cannot attribute is LISTED, never dropped: a compound condition such as
#     `#if compiler(>=6.2) && os(macOS)`, an `@available(macOS N` attribute, `#unavailable`, or an
#     `#available` check that is not inside a test (a helper). Read those by hand.
#   - It does not know about tests that skip for other reasons (a missing fixture or model);
#     `PARLEY_REQUIRE_AMI_FIXTURE=1` turns those into failures in CI.
#
# USAGE
#   scripts/toolchain-report.sh [--swift X.Y[.Z]] [--macos N[.M]] [--tests DIR] [--swift-version]
#     --swift, --macos   report for THAT toolchain instead of this machine's, e.g.
#                        `--swift 6.1 --macos 15` shows what the old macos-15 runner did not run.
#     --tests DIR        scan DIR instead of SwiftTests (used by scripts/test-toolchain-report.sh).
#     --swift-version    print only this machine's Swift version (CI keys a cache on it) and exit.
#   Exit status: 0, whatever N is (the report informs; it is not a gate). 1 when the Swift or
#   macOS version cannot be determined — it must never print "0 tests not run" from ignorance.
#
# Compatible with the stock macOS bash 3.2 and the system awk.

set -euo pipefail

cd "$(dirname "$0")/.."

SWIFT_OVERRIDE=""
MACOS_OVERRIDE=""
TESTS_DIR="SwiftTests"
ONLY_SWIFT_VERSION=0

while [ $# -gt 0 ]; do
  case "$1" in
    --swift)         SWIFT_OVERRIDE="${2:?--swift needs a version}"; shift 2 ;;
    --macos)         MACOS_OVERRIDE="${2:?--macos needs a version}"; shift 2 ;;
    --tests)         TESTS_DIR="${2:?--tests needs a directory}"; shift 2 ;;
    --swift-version) ONLY_SWIFT_VERSION=1; shift ;;
    *) echo "toolchain-report: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# "Apple Swift version 6.3.3 (swiftlang-…)" -> "6.3.3". swift-driver may print its own version
# first on the same line, so anchor on "Swift version".
swift_banner=""
SWIFT_DETECTED=""
detect_swift() {
  swift_banner=$(swift --version 2>&1 || true)
  SWIFT_DETECTED=$(printf '%s\n' "$swift_banner" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
}

is_version() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.) return 1 ;;
    *) return 0 ;;
  esac
}

if [ "$ONLY_SWIFT_VERSION" = 1 ]; then
  detect_swift
  is_version "$SWIFT_DETECTED" || { echo "toolchain-report: could not read a version from 'swift --version'" >&2; exit 1; }
  echo "$SWIFT_DETECTED"
  exit 0
fi

if [ -n "$SWIFT_OVERRIDE" ]; then
  SWIFT_VERSION="$SWIFT_OVERRIDE"
else
  detect_swift
  SWIFT_VERSION="$SWIFT_DETECTED"
fi
if [ -n "$MACOS_OVERRIDE" ]; then
  MACOS_VERSION="$MACOS_OVERRIDE"
else
  MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || true)
fi

is_version "$SWIFT_VERSION" || { echo "toolchain-report: could not determine the Swift version ('$SWIFT_VERSION')" >&2; exit 1; }
is_version "$MACOS_VERSION" || { echo "toolchain-report: could not determine the macOS version ('$MACOS_VERSION')" >&2; exit 1; }
[ -d "$TESTS_DIR" ] || { echo "toolchain-report: no such directory: $TESTS_DIR" >&2; exit 1; }

# --- The toolchain --------------------------------------------------------------------------------

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

echo "### Toolchain"
echo
if [ -n "$SWIFT_OVERRIDE$MACOS_OVERRIDE" ]; then
  echo "- Reporting for Swift ${SWIFT_VERSION} on macOS ${MACOS_VERSION} (given on the command line), not for this machine."
else
  # ImageOS / ImageVersion are set by GitHub-hosted runners only.
  if [ -n "${ImageOS:-}" ]; then
    echo "- Runner image: \`${ImageOS}\` ${ImageVersion:-} ($(uname -m))"
  fi
  echo "- \`swift --version\`: $(printf '%s' "$swift_banner" | tr '\n' ' ')"
  echo "- \`sw_vers\`: $(sw_vers | tr -s '\t ' ' ' | tr '\n' ' ')"
  echo "- \`xcode-select -p\`: $(xcode-select -p 2>&1 || true)"
  if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    echo "- Command Line Tools \`Testing.framework\` (the test command's \`-F\` path): present"
  else
    echo "- Command Line Tools \`Testing.framework\` (the test command's \`-F\` path): **MISSING** at \`$CLT_FRAMEWORKS\`"
  fi
fi
echo

# --- The tests this toolchain cannot run ----------------------------------------------------------

# One record per line: "T" (a test), "C <where> <name> <reason>" (not compiled),
# "O <where> <name> <reason>" (skipped by a macOS check), "U <where> <text>" (not understood).
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose: $0 is awk's, not the shell's
scan=$(
  find "$TESTS_DIR" -name '*.swift' -type f -print0 | sort -z | xargs -0 awk \
    -v swift_version="$SWIFT_VERSION" -v macos_version="$MACOS_VERSION" '
    # "6.2" -> 6002000, "6.2.4" -> 6002004, "26" -> 26000000: comparable as numbers.
    function vernum(s,   p, n) {
      n = split(s, p, ".")
      return p[1] * 1000000 + (n > 1 ? p[2] : 0) * 1000 + (n > 2 ? p[3] : 0)
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # Is every enclosing #if branch one this compiler takes? Sets `why` to the first that is not.
    function compiled(   i) {
      for (i = 1; i <= depth; i++) if (!taken_now[i]) { why = label[i]; return 0 }
      return 1
    }
    # A simple `compiler(>=X.Y)` / `compiler(<X.Y)` / `swift(...)` condition: 1 taken, 0 not.
    # Anything else: -1 (unknown — assumed taken, and listed if it mentions the compiler).
    function evaluate(cond,   op, v) {
      if (cond !~ /^(compiler|swift)\((>=|<)[ \t]*[0-9][0-9.]*\)$/) return -1
      op = (cond ~ /\(>=/) ? ">=" : "<"
      v = cond; sub(/^[a-z]+\((>=|<)[ \t]*/, "", v); sub(/\)$/, "", v)
      if (op == ">=") return (vernum(swift_version) >= vernum(v)) ? 1 : 0
      return (vernum(swift_version) < vernum(v)) ? 1 : 0
    }
    function open_branch(cond,   r) {
      r = evaluate(cond)
      if (r < 0 && cond ~ /(compiler|swift)[ \t]*\(/) print "U " FILENAME ":" FNR " " trim($0)
      return r
    }
    # A not-compiled test is reported when its name is known, or here if no `func` ever followed.
    function end_test() {
      if (awaiting_func && !in_test) print "C " FILENAME ":" test_line " ? inside " pending_reason
      in_test = 0; awaiting_func = 0
    }

    FNR == 1 { if (NR > 1) end_test(); depth = 0; in_test = 0; awaiting_func = 0 }
    END { end_test() }

    {
      line = $0
      sub(/\/\/.*/, "", line)          # drop line comments (a "//" inside a string too: harmless here)
      t = trim(line)
    }

    t ~ /^#if[ \t]/ {
      cond = trim(substr(t, 4))
      depth++
      r = open_branch(cond)
      label[depth] = "#if " cond
      taken_now[depth] = (r != 0)      # unknown conditions are assumed taken
      taken_before[depth] = (r == 1)   # ...but only a KNOWN-taken branch rules out the #else
      next
    }
    t ~ /^#elseif[ \t]/ {
      if (depth > 0) {
        cond = trim(substr(t, 8))
        r = open_branch(cond)
        if (taken_before[depth]) { taken_now[depth] = 0; label[depth] = "the #elseif after " label[depth] }
        else { taken_now[depth] = (r != 0); label[depth] = "#elseif " cond; if (r == 1) taken_before[depth] = 1 }
      }
      next
    }
    t ~ /^#else/ {
      if (depth > 0) {
        if (taken_before[depth]) { taken_now[depth] = 0; label[depth] = "the #else of " label[depth] }
        else taken_now[depth] = 1
      }
      next
    }
    t ~ /^#endif/ { if (depth > 0) depth--; next }

    t ~ /^@Test/ {
      end_test()
      print "T"
      test_line = FNR; test_name = "?"; counted = 0; awaiting_func = 1
      if (compiled()) in_test = 1
      else { in_test = 0; pending_reason = why }
    }

    # The name: the first `func` at or after the @Test line. Any later declaration ends the test.
    t ~ /(^|[ \t(])func[ \t]/ {
      if (awaiting_func) {
        name = t; sub(/.*func[ \t]+/, "", name); sub(/[^A-Za-z0-9_`].*/, "", name)
        awaiting_func = 0
        if (in_test) test_name = name
        else print "C " FILENAME ":" test_line " " name " inside " pending_reason
      } else end_test()
    }
    t ~ /^(@Suite|((public|private|fileprivate|internal|final|@MainActor)[ \t]+)*(struct|class|enum|actor|extension)[ \t])/ { end_test() }

    {
      rest = t
      while (match(rest, /[#@](un)?available[ \t]*\([ \t]*macOS[ \t]+[0-9][0-9.]*/)) {
        hit = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        v = hit; sub(/.*macOS[ \t]+/, "", v)
        if (vernum(v) <= vernum(macos_version)) continue   # this macOS passes the check
        if (!compiled()) continue                           # the compiler never sees it
        if (hit ~ /^#available/ && in_test && !awaiting_func) {
          if (!counted) { print "O " FILENAME ":" test_line " " test_name " needs macOS " v; counted = 1 }
        } else print "U " FILENAME ":" FNR " " t
      }
    }
  '
)

total=$(printf '%s\n' "$scan" | grep -c '^T$' || true)
not_compiled=$(printf '%s\n' "$scan" | grep -c '^C ' || true)
os_skipped=$(printf '%s\n' "$scan" | grep -c '^O ' || true)
unknown=$(printf '%s\n' "$scan" | grep -c '^U ' || true)
not_run=$((not_compiled + os_skipped))

[ "$total" -gt 0 ] || { echo "toolchain-report: found no @Test under $TESTS_DIR — refusing to report 0 not run" >&2; exit 1; }

echo "**${not_run} tests not run on this toolchain** (Swift ${SWIFT_VERSION}, macOS ${MACOS_VERSION}; ${total} \`@Test\` functions under \`${TESTS_DIR}/\`)"
echo
if [ "$not_run" -gt 0 ]; then
  echo "- ${not_compiled} not compiled: inside an \`#if compiler(…)\` branch this Swift does not take. They are missing from the suite's total."
  echo "- ${os_skipped} compiled but skipped by a macOS check (\`#available\`): they return early and are reported as **passed** without asserting."
  echo
  echo "<details><summary>Which ones</summary>"
  echo
  # shellcheck disable=SC2016  # the backticks are Markdown, not a command substitution
  printf '%s\n' "$scan" | sed -n 's/^C \([^ ]*\) \([^ ]*\) \(.*\)$/- not compiled: `\2` (\1), \3/p'
  # shellcheck disable=SC2016
  printf '%s\n' "$scan" | sed -n 's/^O \([^ ]*\) \([^ ]*\) \(.*\)$/- skipped: `\2` (\1), \3/p'
  echo
  echo "</details>"
  echo
fi
if [ "$unknown" -gt 0 ]; then
  echo "${unknown} toolchain condition(s) this script could not attribute to a test — read them by hand, they are NOT in the count above:"
  echo
  # shellcheck disable=SC2016
  printf '%s\n' "$scan" | sed -n 's/^U \([^ ]*\) \(.*\)$/- \1: `\2`/p'
  echo
fi
echo "The suite should report \`Test run with $((total - not_compiled)) tests\` (every \`@Test\` this Swift compiles)."

if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ $((not_run + unknown)) -gt 0 ]; then
  echo "::warning title=Tests not run on this toolchain::${not_run} tests not run on this toolchain (Swift ${SWIFT_VERSION}, macOS ${MACOS_VERSION}): ${not_compiled} not compiled, ${os_skipped} skipped by a macOS check; ${unknown} condition(s) not attributed. See the job summary." >&2
fi
