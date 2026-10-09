# Local CI mirror (the local-first standard, ~/.claude/skills/ci-guidelines).
# `just ci` runs what .github/workflows/test.yml runs, in the same order, with the same flags and
# env, then builds the app bundle, which CI doesn't do. Run it before every push.
# CI also scans the PR's new commits with gitleaks first; locally the pre-commit hook scans each
# commit's staged changes (`just secrets`), so `just ci` doesn't repeat it.
set shell := ["bash", "-euo", "pipefail", "-c"]

default: ci

# test.yml's `test` (workflow lint, the toolchain report, the suite, the release tools) + `red-first` jobs, then the app-bundle build
ci: workflows toolchain test release-tools red-first build

# test.yml `test`, first step: actionlint + zizmor, the same commands CI runs (brew install actionlint zizmor)
workflows:
    @for t in actionlint zizmor; do command -v "$t" >/dev/null || { echo "$t missing: brew install $t" >&2; exit 1; }; done
    actionlint
    zizmor --min-severity high .github/workflows

# The report informs, it never fails on a count; only the counter's own test can fail this recipe.
# test.yml, both jobs: test the counter, then print this Mac's toolchain and "N tests not run on this toolchain"
toolchain:
    bash scripts/test-toolchain-report.sh
    bash scripts/toolchain-report.sh

# --no-parallel is load-bearing: the shared media-daemon wedge (see test.yml).
# test.yml `test`: fetch the AMI fixture, then the whole suite serially with the guard armed
# The suite runs with a throwaway home (scripts/test-home.sh), and the canary fails the recipe if the
# user's recordings or config changed anyway (#313: a test once ran the storage limit over them).
test:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/fetch-diarization-fixtures.sh
    snap=$(mktemp)
    bash scripts/test-canary.sh snapshot "$snap"
    trap 'bash scripts/test-canary.sh verify "$snap"' EXIT
    CFFIXED_USER_HOME="$(bash scripts/test-home.sh)" PARLEY_FETCH_MODELS=1 PARLEY_REQUIRE_AMI_FIXTURE=1 \
    swift test --no-parallel --filter TranscriberTests \
      -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/

# Stdlib only (system python3 + bash 3.2); the feed test builds verify-ed-signature itself.
# The last line tests the red-first gate's own classifier against a fake `swift` (a few seconds).
# test.yml `test`, last step: the release-tooling tests that guard the Sparkle feed and appcast
release-tools:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    bash scripts/test-publish.sh
    bash scripts/test-verify-release-feed.sh
    bash scripts/test-verify-regression-tests.sh

# CI passes the merge base with the PR's base branch, so this does too (not the raw base ref).
# test.yml `red-first`: changed tests must be RED at the merge base, GREEN at HEAD
red-first base="origin/main":
    PARLEY_FETCH_MODELS=1 bash scripts/verify-regression-tests.sh "$(git merge-base {{base}} HEAD)"

# Build ONLY: plain `dev.py` would also kill the running app and install to /Applications.
# A DEBUG build, unlike plain `dev.py` (release, #271): this step proves the app and the helper
# compile, and a debug build reuses what `just test` has just compiled (~15 s; a release build
# compiles the whole package again, ~1.5 min more on every push). Nothing is installed from it.
# The app bundle (TranscriberApp + XPC service); CI doesn't build it
build:
    python3 scripts/dev.py --build --debug-build

# scan the staged changes for secrets (the pre-commit hook runs this)
secrets:
    gitleaks git --staged --redact --no-banner

# Not part of CI: shellcheck the scripts
lint:
    shellcheck scripts/*.sh package_app.sh

# act has no macOS backend, so test.yml (macos-26) can't run under it.
# Workflow parity: only proves every workflow parses
act:
    act -l
