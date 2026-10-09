#!/bin/bash
# Prints a throwaway home folder for a test process (#313): run the tests with
# CFFIXED_USER_HOME="$(bash scripts/test-home.sh)" and every home lookup in Foundation —
# NSHomeDirectory(), homeDirectoryForCurrentUser, the Application Support URL, `~` — resolves
# under it. A test that falls back to Config.default then writes there, never into the user's
# ~/Documents/Recordings or ~/Library/Application Support/Parley.
#
# The one thing shared with the real home is the downloaded model cache (FluidAudio), linked
# read-write so the suite does not download the models again on every run — and so CI's cache of
# ~/Library/Application Support/FluidAudio/Models still fills on a miss (the folder is created).
set -euo pipefail
real_home=$(cd ~ && pwd -P)
fake=$(mktemp -d "${TMPDIR:-/tmp}/parley-test-home.XXXXXX")
mkdir -p "$fake/Library/Application Support" "$fake/Documents"
models="$real_home/Library/Application Support/FluidAudio"
mkdir -p "$models"
ln -s "$models" "$fake/Library/Application Support/FluidAudio"
echo "$fake"
