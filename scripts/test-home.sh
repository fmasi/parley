#!/bin/bash
# Prints a throwaway home folder for a test process (#313): run the tests with
# CFFIXED_USER_HOME="$(bash scripts/test-home.sh)" and every home lookup in Foundation —
# NSHomeDirectory(), homeDirectoryForCurrentUser, the Application Support URL, `~` — resolves
# under it. A test that falls back to Config.default then writes there, never into the user's
# ~/Documents/Recordings or ~/Library/Application Support/Parley.
#
# The downloaded model cache (FluidAudio) is the one thing taken from the real home, so the suite
# does not download the models on every run. Locally it is an APFS clone (copy-on-write: instant,
# no extra space): a few tests hide the cache by renaming it, and through a link that would hide
# the real one — from the app, and from a suite running in another worktree. On CI (CI=true) it is
# a link, so the runner's cache of ~/Library/Application Support/FluidAudio/Models still fills on
# a miss (the folder is created).
set -euo pipefail
real_home=$(cd ~ && pwd -P)
# Homes from earlier runs: a day old is long finished.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'parley-test-home.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
fake=$(mktemp -d "${TMPDIR:-/tmp}/parley-test-home.XXXXXX")
mkdir -p "$fake/Library/Application Support" "$fake/Documents"
models="$real_home/Library/Application Support/FluidAudio"
if [ "${CI:-}" = "true" ]; then
  mkdir -p "$models"
  ln -s "$models" "$fake/Library/Application Support/FluidAudio"
elif [ -d "$models" ]; then
  cp -cR "$models" "$fake/Library/Application Support/FluidAudio"
fi
echo "$fake"
