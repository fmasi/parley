#!/bin/bash
# A throwaway home folder for a test process (#313). Don't call this to run the tests: use
# scripts/swift-test.sh, which creates the home, checks it, and runs `swift test` in it.
#
#   test-home.sh            create a throwaway home and print its path. On any failure it prints
#                           nothing, removes what it created and exits non-zero.
#   test-home.sh --check D  exit 0 only if D is a usable throwaway home: non-empty, an existing
#                           folder, and not the user's real home.
#
# With CFFIXED_USER_HOME set to it, every home lookup in Foundation — NSHomeDirectory(),
# homeDirectoryForCurrentUser, the Application Support URL, `~` — resolves under it. A test that
# falls back to Config.default then writes there, never into the user's ~/Documents/Recordings or
# ~/Library/Application Support/Parley. An EMPTY CFFIXED_USER_HOME means the real home, so a caller
# must never pass this script's output on unchecked: `CFFIXED_USER_HOME="$(test-home.sh)" swift test`
# on one line runs the suite in the real home when this script fails (bash ignores the failure of a
# command substitution in a prefix assignment). The test bundle refuses to start in the real home
# anyway (SwiftTests/TestHomeGuard).
#
# The downloaded model cache (FluidAudio) is the one thing taken from the real home, so the suite
# does not download the models on every run. Locally it is an APFS clone (copy-on-write: instant,
# no extra space): a few tests hide the cache by renaming it, and through a link that would hide
# the real one — from the app, and from a suite running in another worktree. On CI (CI=true) it is
# a link, so the runner's cache of ~/Library/Application Support/FluidAudio/Models still fills on
# a miss (the folder is created).
set -euo pipefail
real_home=$(cd ~ && pwd -P)

if [ "${1:-}" = "--check" ]; then
  dir="${2:-}"
  if [ -z "$dir" ]; then
    echo "test-home.sh: the throwaway home is empty, which would mean the REAL home (#313)" >&2
    exit 1
  fi
  if [ ! -d "$dir" ]; then
    echo "test-home.sh: the throwaway home '$dir' is not an existing folder (#313)" >&2
    exit 1
  fi
  # The real home both as $HOME has it and as the user database has it: Foundation falls back to
  # the latter, and $HOME may have been changed.
  resolved=$(cd "$dir" && pwd -P)
  pw_home=$(/usr/bin/python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)
  pw_home=$( { [ -n "$pw_home" ] && cd "$pw_home" 2>/dev/null && pwd -P; } || true)
  if [ "$resolved" = "$real_home" ] || [ "$resolved" = "$pw_home" ]; then
    echo "test-home.sh: '$dir' is the user's real home, not a throwaway one (#313)" >&2
    exit 1
  fi
  exit 0
fi

# Homes from earlier runs: a day old is long finished.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'parley-test-home.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
fake=$(mktemp -d "${TMPDIR:-/tmp}/parley-test-home.XXXXXX")
# A failure below (a clone of the model cache hitting a busy file or a full disk) leaves no
# half-made home behind, and the path is printed only once the home is complete.
complete=0
trap '[ "$complete" = 1 ] || rm -rf "$fake"' EXIT
mkdir -p "$fake/Library/Application Support" "$fake/Documents"
models="$real_home/Library/Application Support/FluidAudio"
if [ "${CI:-}" = "true" ]; then
  mkdir -p "$models"
  ln -s "$models" "$fake/Library/Application Support/FluidAudio"
elif [ -d "$models" ]; then
  cp -cR "$models" "$fake/Library/Application Support/FluidAudio"
fi
complete=1
echo "$fake"
