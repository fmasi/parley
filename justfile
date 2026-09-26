# Local CI mirror (the local-first standard, ~/.claude/skills/ci-guidelines).
# `just ci` runs what .github/workflows/test.yml runs, in the same order, with the same flags and
# env, then builds the app bundle, which CI doesn't do. Run it before every push.
set shell := ["bash", "-euo", "pipefail", "-c"]

default: ci

# test.yml's `test` + `red-first` jobs, then the app-bundle build
ci: test red-first build

# --no-parallel is load-bearing: the shared media-daemon wedge (see test.yml).
# test.yml `test`: fetch the AMI fixture, then the whole suite serially with the guard armed
test:
    bash scripts/fetch-diarization-fixtures.sh
    PARLEY_FETCH_MODELS=1 PARLEY_REQUIRE_AMI_FIXTURE=1 \
    swift test --no-parallel --filter TranscriberTests \
      -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/

# CI passes the merge base with the PR's base branch, so this does too (not the raw base ref).
# test.yml `red-first`: changed tests must be RED at the merge base, GREEN at HEAD
red-first base="origin/main":
    PARLEY_FETCH_MODELS=1 bash scripts/verify-regression-tests.sh "$(git merge-base {{base}} HEAD)"

# Build ONLY: plain `dev.py` would also kill the running app and install to /Applications.
# The app bundle (TranscriberApp + XPC service); CI doesn't build it
build:
    python3 scripts/dev.py --build

# Not part of CI: lint the workflows and the shell scripts
lint:
    actionlint
    shellcheck scripts/*.sh package_app.sh

# act has no macOS backend, so test.yml (macos-15) can't run under it.
# Workflow parity: only proves every workflow parses
act:
    act -l
