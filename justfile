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
test:
    bash scripts/fetch-diarization-fixtures.sh
    PARLEY_FETCH_MODELS=1 PARLEY_REQUIRE_AMI_FIXTURE=1 \
    swift test --no-parallel --filter TranscriberTests \
      -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/

# Stdlib only (system python3 + bash 3.2); the feed test builds verify-ed-signature itself.
# test.yml `test`, last step: the release-tooling tests that guard the Sparkle feed and appcast
release-tools:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    bash scripts/test-publish.sh
    bash scripts/test-verify-release-feed.sh

# CI passes the merge base with the PR's base branch, so this does too (not the raw base ref).
# test.yml `red-first`: changed tests must be RED at the merge base, GREEN at HEAD
red-first base="origin/main":
    PARLEY_FETCH_MODELS=1 bash scripts/verify-regression-tests.sh "$(git merge-base {{base}} HEAD)"

# Build ONLY: plain `dev.py` would also kill the running app and install to /Applications.
# The app bundle (TranscriberApp + XPC service); CI doesn't build it
build:
    python3 scripts/dev.py --build

# scan the staged changes for secrets (the pre-commit hook runs this)
secrets:
    gitleaks git --staged --redact --no-banner

# Not part of CI: shellcheck the scripts
lint:
    shellcheck scripts/*.sh package_app.sh

# act has no macOS backend, so test.yml (macos-15) can't run under it.
# Workflow parity: only proves every workflow parses
act:
    act -l
