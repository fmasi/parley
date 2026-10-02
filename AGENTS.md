# parley: instructions for coding agents

Every coding agent reads this file: Claude Code (through `@AGENTS.md` in CLAUDE.md), Codex, Copilot,
Cursor and others. The owner doesn't read code. The checks below and the one Claude review on
GitHub are the safety net, so follow them exactly.

Parley is a macOS menu-bar meeting recorder (Swift: SwiftUI app, XPC audio-capture service,
`TranscriberCore` library). It records the mic and the system audio as separate streams and
transcribes and diarizes them on the Mac. It protects a courtroom-grade record of a meeting that
never leaves the Mac. The worst failure is a silent wrong answer, such as a recording that looks
healthy but lost one side of the call (#220). Architecture, capture internals and debugging are in
`CLAUDE.md` and `docs/`.

## How work lands here

The full process, and why each step exists: [docs/development-process.md](docs/development-process.md).

1. Branch from `main`. Never commit on `main`. Group related bugs and features into one PR; file a
   second, unrelated defect found mid-branch instead of bundling it.
2. Commit in small steps. The pre-commit hook (lefthook) runs gitleaks, shellcheck and actionlint.
   Once per clone: `lefthook install`.
3. `just ci` must pass before every push. The pre-push hook runs it (~10 minutes: the serial suite).
4. Push the branch and open a draft PR: `gh pr create --draft --fill`. CI does nothing on drafts.
5. Review locally before asking for the GitHub review: a code council over the full diff
   (development-process §2), then `/ci-review` in Claude Code. Fix what they find. A change to
   capture, audio or the pipeline is device-tested on a real Mac, with the measurement in the PR
   description or commit message.
6. Push, WAIT until the push has landed, then run `gh pr ready`. That runs CI once and the one
   Claude review. Marking ready in the same second as a push can review the previous commit.
7. The merge needs `test`, `red-first` and `review / review-gate` green. The gate is green while
   the PR has the label `claude-reviewed` and not `claude-blocked`. Only the review workflow (or
   the owner) sets those labels.
8. `claude-blocked` means the review found a Critical issue. Fix it, push, then ask for a re-review
   by removing and re-adding `ready-for-review`:
   `gh pr edit <N> --remove-label ready-for-review && gh pr edit <N> --add-label ready-for-review`.
   An `@claude review` comment gets an answer, not a verdict: it doesn't move the gate.
9. Release: decide PATCH vs MINOR deliberately (development-process §5), then follow
   `docs/release-checklist.md`.
10. The rules bind everyone, the owner included. Nobody bypasses them.

## Commands

`just --list` shows every recipe. The ones that matter:

- `just ci`: exactly what CI runs (workflow lint, the serial Swift suite, the release-tooling tests,
  the red-first gate), then the app-bundle build, which CI doesn't do.
- `just workflows`: actionlint + zizmor on `.github/workflows`, as the `test` job runs them.
- `just test`: fetch the AMI fixture, then the whole suite serially with the ground-truth guard armed.
- `just release-tools`: the stdlib tests of the release scripts (appcast, publish, feed verifier).
- `just red-first [base]`: the PR's changed tests must be RED at the merge base and GREEN at HEAD.
- `just build`: build the app bundle (app + XPC service) without installing it.
- `just secrets`: gitleaks on the staged changes (the pre-commit hook runs it).
- `just lint`: shellcheck the scripts (not part of CI).

Not recipes: `python3 scripts/dev.py` builds, installs to /Applications and relaunches the app
(`--debug` also tails the log); `scripts/release.sh` and `scripts/publish.sh` build, sign and publish
a release (see `docs/release-checklist.md`).

## Repo rules

- **Tests.** New or changed behaviour comes with Swift Testing tests in `SwiftTests/TranscriberTests/`
  (happy path, edge cases, invalid input). A bug fix comes with a test that fails without it: the
  `red-first` check runs the changed tests at the merge base and requires them RED there.
  `RED-FIRST-EXEMPT: <reason>` in a test file is only for characterization tests of existing
  behaviour and for the documented diarization-fixture gap.
- **Testable seams.** The test target links only `TranscriberCore` and `VerifyEdSignatureCore`.
  Decision logic (capture health, permission state, recording lifecycle) goes in `TranscriberCore`
  behind a protocol seam and is tested there with fakes; `AudioCaptureHelper/` and `TranscriberApp/`
  stay thin.
- **The test suite runs serially.** `--no-parallel`, the timeouts, the caches, the conditional
  cancel and the `red-first` job in `test.yml` are load-bearing (their comments say why). Don't
  loosen them. `PARLEY_REQUIRE_AMI_FIXTURE=1` makes a missing fixture a failure, never a skip.
- **No silent audio loss.** Every way capture can stop, turn to zeros or be padded over must
  surface as an anomaly the user sees, for as long as it lasts. A denied or revoked permission
  never produces a normal-looking recording.
- **Real-time audio.** Nothing on an audio callback or capture queue blocks, takes a contended
  lock, awaits, allocates or logs per buffer, or hops to the main actor. The main thread never
  waits on a device, the HAL or XPC.
- **Airgap.** Meeting audio and transcripts leave the Mac only through the user's configured
  summary endpoint, stamped by `SummaryDisclosure`. No telemetry, analytics or crash reporting.
  Models download only during Setup or on Settings Save, never at recording or transcription time.
- **Privacy and secrets.** Log privacy per docs/pipeline.md: names and transcript text `.private`,
  paths `.sensitive`, only counts and status `.public`. The summary API key lives in the Keychain
  only. Tests and fixtures use synthetic audio (`say`) or the public AMI corpus, never a real
  recording.
- **Data.** Transcripts are never deleted. `StorageManager` deletes only the oldest `.m4a`
  archives, within the configured quota, and never an archive of a session that still has a
  session file in its folder (`session.json`, `session-*.json`): for its chunks that is the only copy.
- **Updater.** Never weaken Sparkle's EdDSA verification, `SUPublicEDKey` or the feed URL.
- **Docs move with the code.** Update `CLAUDE.md`'s file map, `docs/parameters.md` (config keys,
  defaults), `docs/gotchas.md` (append new items), `scripts/test-checklist.md` and the README test
  count when they change.
- Follow the conventions in the existing code and in `.github/claude-review-prompt.md`, the rubric
  the Claude review applies.

## Never

- Never merge with `gh pr merge --admin`, and never try any other way around the ruleset.
- Never use `--no-verify` (on `git commit` or `git push`) to skip the hooks or `just ci`.
- Never add the `claude-reviewed` label yourself, and never remove `claude-blocked`. Only the review
  workflow and the owner do that.
- Never push to `main`. Every change goes through a PR.
- Never commit secrets, tokens, `.env` files, personal data, real recordings or transcripts.
