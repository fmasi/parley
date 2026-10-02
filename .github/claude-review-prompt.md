# Review rubric: Parley

This file is read by BOTH the CI Claude review (fmasi/.github `claude-review.yml`) and the local
`/ci-review` command, so a branch that passes `/ci-review` should pass CI's review too.

Parley is a macOS menu-bar meeting recorder: a SwiftUI app (`TranscriberApp/`), an XPC audio-capture
service (`AudioCaptureHelper/XPC/`) and the logic library (`TranscriberCore/`). It records the mic and
the system (remote) audio as two separate streams, transcribes and diarizes them on the Mac, and
writes a transcript. Architecture, capture internals and conventions: `CLAUDE.md`, `ARCHITECTURE.md`,
`docs/pipeline.md`, `docs/gotchas.md`.

**What it protects.** A courtroom-grade record of a meeting that never leaves the Mac. The worst
failure is a *silent wrong answer*: a recording that looks healthy but lost one side of the call.
That is worse than a crash, because the user cannot know to distrust it (#220: 29 of 52 minutes of
remote audio recorded as digital silence, with one warning 50 seconds in and nothing after).

Review the change, not the whole codebase. Read the surrounding code when a hunk depends on it.
Report only material problems: no praise, no summary of what the code does, no style nits.

## What to check, in priority order

1. **The capture path and silent audio loss.** `SystemTapSession`, `MicCaptureSession`,
   `AudioOutputHandler`, `AudioCaptureService`, `WavFileWriter`, `AudioConverter`, `ChunkRotator`,
   and the detectors (`TrackLivenessMonitor`, `ExactZeroRunMonitor`, `FrameCountPlausibility`,
   rate drift, padding caps). Ask of every change: can audio now stop, turn to zeros, be padded
   over, be dropped or shift in time *without* an anomaly the user sees? Flag a detector that can
   fire once and go quiet, a restart or rebuild that reports success while nothing flows, a
   swallowed write or format error, a lost `restartInPlace`, and a channel mix-up (the archive is
   L = mic, R = system).
2. **Permissions (TCC).** Microphone, Screen & System Audio Recording, Calendar, Notifications
   (`SystemPermissionChecker`, `PermissionManager`, Setup). A missing, denied or revoked grant must
   stop or loudly warn, never record silence as if it were a quiet room: a tap without its System
   Audio Recording grant can keep "delivering" zeros (#220, #228). Also flag a TCC prompt moved to
   the moment of recording, and code that treats "not determined" as "granted".
3. **Concurrency in real-time audio.** Nothing on an audio callback or capture queue may block,
   take a contended lock, `await`, allocate per buffer, log per buffer or hop to the main actor.
   Nothing on the main thread may wait on a device, the HAL or XPC (#192, #197). Flag data races on
   writer or detector state, `@MainActor` / actor-isolation mistakes, `@unchecked Sendable` without
   a stated reason, continuations that can resume twice or never (`ResumeOnce`), and XPC
   reply/invalidation paths that can hang the recording.
4. **The airgap.** Meeting audio and transcript text leave the Mac only through the summary
   endpoint the user configured, and `SummaryDisclosure` stamps it in the transcript. Flag ANY new
   network call, SDK or dependency that phones home (telemetry, crash reporting, analytics), a
   model download at recording or transcription time (models download only in Setup or on Settings
   Save: gotcha 22), and a summary path that skips the disclosure stamp.
5. **Data safety and privacy.** `StorageManager` deletes only the oldest `.m4a` archives, never
   transcripts, and never an archive of a session that still has a session file in its folder (#230); source WAVs are deleted only after the AAC archive succeeded; crash recovery
   (`RecordingSentinel`, segment discovery and stitching) must not drop a segment. Log privacy
   (docs/pipeline.md "Log privacy conventions"): speaker names and transcript text `.private`,
   paths and filenames `.sensitive`, only counts and status `.public`. The summary API key lives
   in the Keychain only (`KeychainStore`), never in config.json, logs or tests.
6. **The updater and dependencies.** Sparkle: the feed URL, `SUPublicEDKey`, EdDSA verification
   (`VerifyEdSignatureCore`), `scripts/release.sh` / `publish.sh` and the appcast tooling. Any
   weakening is Critical. `Package.swift` / `Package.resolved` changes: say what moved (FluidAudio
   changes transcripts and model files; Sparkle installs code on users' Macs) and whether the PR
   shows a device test.
7. **Tests.** New or changed logic has Swift Testing tests in `SwiftTests/TranscriberTests/`
   covering the happy path, edge cases and invalid input; a bug fix has a test that fails without
   it (the `red-first` check enforces this). The test target links only `TranscriberCore` and
   `VerifyEdSignatureCore`, so decision logic added to `AudioCaptureHelper/` or `TranscriberApp/`
   is untested by construction: ask for it in Core behind a seam (as `RecordingCoordinator` and
   `TrackLivenessMonitor` were). Flag a `RED-FIRST-EXEMPT:` marker whose reason isn't a
   characterization test or the documented diarization-fixture gap, a test that can skip silently,
   and assertions that cannot fail. A change to capture or audio needs a device measurement in the
   PR description (docs/development-process.md §4); say so when it is missing.
8. **Consistency and docs.** Matches `CLAUDE.md`'s architecture and the surrounding code; no dead
   code or duplicate helpers. Behaviour changes update `CLAUDE.md`'s file map, `docs/parameters.md`
   (config keys and defaults), `docs/gotchas.md`, `scripts/test-checklist.md` and the README test
   count when they change.
9. **CI hygiene** (only when workflows, the justfile or lefthook.yml change). `test.yml`'s
   `--no-parallel`, timeouts, caches, conditional cancel and the `red-first` job are load-bearing
   (their comments say why): flag any loosening. Actions stay SHA-pinned; no `paths` filter on the
   review caller; `just ci` still mirrors CI.

## Out of scope

Don't review: `docs/superpowers/**` (plans and specs), `docs/research/**`, `docs/benchmarks/**`,
`stt-news-*.md`, `tools/system-tap-spike/**` (a throwaway spike). Mention a problem there only if
it is a leaked secret.

## How to rank

- **Critical**: one of these, on a path that can really happen. Must fix before merge.
  - audio can be lost, zeroed, padded over or misattributed without a visible anomaly, or a
    detector for that can be silenced;
  - a denied or revoked permission can produce a normal-looking recording;
  - meeting content can leave the Mac outside the configured summary endpoint, or a new
    phone-home appears;
  - transcripts, or audio outside the quota rules, can be deleted or corrupted;
  - a secret or personal data is leaked (committed, logged `.public`, in config.json);
  - Sparkle signature verification or the feed is weakened;
  - a data race or blocking call on the real-time audio path, or a hang of the main thread;
  - the build or the test suite breaks.

  One Critical makes the CI review end with `REVIEW-VERDICT: BLOCK` (label `claude-blocked`),
  which blocks the merge until a re-review passes. Don't inflate: a Critical is something the
  owner would roll back for.
- **Important**: a real bug on a likely path, missing error handling, new or changed behaviour
  without a test, logic in `AudioCaptureHelper/` or `TranscriberApp/` that belongs behind a Core
  seam, a capture change with no device measurement, or docs that are now wrong. Should fix before
  merge.
- **Minor**: worth fixing, safe to merge without.

The owner's process (docs/development-process.md §3) fixes a non-Critical finding only if it
reduces expected harm more than the code it adds. So prefer findings that can be shown with a test
that goes red, and say when the fix is a deletion.

## Output

One line per finding, most severe first:
`[Critical|Important|Minor] path/to/file:line: what is wrong, why it matters, the fix.`
If nothing material turns up, say so in one line.
