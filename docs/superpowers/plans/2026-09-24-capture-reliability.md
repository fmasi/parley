# Capture Reliability Overhaul Implementation Plan (v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Plan version:** v2 (2026-09-24). Supersedes v1 (commit `6a9966e`). v2 resolves every item of the preflight conflict scan (`.superpowers/sdd/2026-09-24-capture-reliability/preflight-scan.md`, sections A–D), folds in the owner's decisions of 2026-09-24 (spec §11), replaces the CI gate with local gates, and regroups the work into **parallel streams with disjoint file sets**. The mapping from every scan item to its change is in **Appendix A**; the mapping from v1 task ids to v2 task ids is the *Task index* under *Parallel streams*.

**Goal:** For each side of a recording, exactly one of "captured / healed within seconds / user told loudly and persistently" is always true, and the saved record states truthfully how much of each side was captured.

**Architecture:** Every decision becomes a pure, unit-tested type in `TranscriberCore` (the `TapPermissionGuard` / `CaptureReadiness` pattern): a per-track liveness monitor fed by heartbeats stamped at the top of each audio callback and gated on "some OTHER process is running output"; a tap recovery ladder; a helper-owned, app-pulled alarm registry; per-track coverage accounting into provenance; and pure lifecycle decisions (interruption arming, LaunchAgent health, relaunch, disk). The helper (`AudioCaptureHelperXPC`) and the app (`TranscriberApp`) stay thin shells, because neither target has unit tests.

**Tech Stack:** Swift 5.9 tools / Swift 6.x toolchain, Swift Testing (not XCTest), `@MainActor`, `os.Logger`, CoreAudio HAL property listeners, NSXPC. Build: `python3 scripts/dev.py --build`. Tests: see Global Constraints.

**Spec:** `docs/superpowers/specs/2026-09-24-capture-reliability-design.md` — the plan argues from it; read both. Section references below (§4.2, M-B, …) are into the spec. The spec was amended in v2 at §4.2, §7.2, §7.3, §8.3, §8.8, §8.10, §11 (each amendment says why; see Appendix A).

**Code base for every line number below:** commit `6a9966e` of `fix/capture-reliability` (= `fix/permission-readiness` `07610a4` + the v1 docs commit). Line numbers drift as streams merge; each task names the symbol next to the line so an implementer can re-find it with `grep -n`.

## Global Constraints

- macOS 15.0+, Apple Silicon. No Xcode on the dev machine for `swift test`; the app target only compiles through `python3 scripts/dev.py --build` (it expands SwiftUI macros). Every task that touches `TranscriberApp/` or `AudioCaptureHelper/` ends with that build.
- Tests use **Swift Testing** (`@Test`, `#expect`, `#require`, `Issue.record`) under `SwiftTests/TranscriberTests/` (never `Tests/`).
- Test command. Define the flags once per shell session so every task's `Run:` line is exact:
  ```bash
  export PARLEY_TEST="swift test --no-parallel -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/"
  $PARLEY_TEST --filter TranscriberTests                # the full suite (1220 tests / 138 suites at the base commit)
  $PARLEY_TEST --filter 'TrackLivenessMonitorTests'     # one suite (regex on the test id)
  ```
  `DiarizationMetamorphicTests` has a pre-existing flaky failure that also fails on `main`; it is not yours.
- **Red-first is a local gate** (`bash scripts/verify-regression-tests.sh <base-sha>`): every Added or Modified `.swift` file under `SwiftTests/TranscriberTests/` must make the gated suites FAIL when overlaid on `<base-sha>` (a compile error against a new symbol counts) and PASS at HEAD. Deleted test files are ignored by the script. A file whose only change is a deletion of tests, or a characterization test of existing behaviour, must carry the literal marker `// RED-FIRST-EXEMPT: <reason>` (the script greps for `RED-FIRST-EXEMPT:`). Each task states which of the two its test files are.
- **GitHub CI is DOWN (minutes exhausted).** Nothing is pushed unless the owner asks. Every former "push for CI" step is the **local gate** in *Parallel streams → Stream gate* below.
- App and helper ship together in one bundle: `AudioCaptureProtocol` additions are new methods (never signature changes of existing ones) and reverse-channel additions are `@objc optional`, matching `captureQualityAnomaly`.
- Airgap holds: no network, no telemetry. Log privacy: names/paths `.private`/`.sensitive`, never `.public`; enum states that carry a path (`LaunchAgentHealth.State.stalePath(found:)`) are logged `.private`.
- Rate band stays **0.95–1.05** (`RateDriftMonitor`); the audit's [0.9, 1.1] is refuted. Coverage uses deficit ≥ 15 s AND ≥ 10 % (§4.4).
- `SystemTapSession.stopAndFinalize`-on-disconnect stays (§8.3). No "helper keeps capturing after disconnect" until M-L1 is measured.
- Never propose SCK as a fix (§13). SCK code is only touched where a shared type forces it. SCK keeps the liveness watchdog and the alarms through the existing arrival stamp (`AudioOutputHandler.lastSystemBufferArrivalNanos()`), see H1.
- Product defaults (§11, owner decisions 2026-09-24): `Config.default.systemAudioSource` flips to `.coreAudioTap` for new installs (D1); `EngineID.default = .fluidAudio` and Apple Speech is LABELLED "not yet usable", never hidden (D2); the storage quota scope is out of scope (issue #224) — R5 still moves the quota call out of the archive `catch`.
- Commit after every task with an explicit `git add <files>` (never `-a`, never `-A`) and the message given. Do not push.
- Version: **MINOR** (§14).

## Review Focus

The five inputs the spec implies but no task's tests naturally exercise; each is pinned to a test in the owning task:

1. **Gate flapping at 1 Hz** (a call app toggling its output IO every second) — the monitor must report one gap per gate-open episode ≥ threshold, never one per flap. Pinned: C3 `gateFlapReportsAtMostOncePerEpisode`, `stallIsMeasuredFromGateOpenNotFromTheLastHeartbeat`.
2. **A helper newer than the app sends an unknown `AlarmKind`** — decoding must keep the known alarms, not drop the whole snapshot. Pinned: F2 `snapshotWithUnknownKindKeepsTheOthers`.
3. **A heartbeat timestamp newer than "now"** (two clocks read on different queues) — must read as healthy, never as a negative or huge gap. Pinned: C3 `heartbeatInTheFutureIsHealthy`.
4. **Two ladder triggers inside one backoff window** (an aggregate listener and a monitor verdict for the same stall), plus an off-ladder rebuild (output change) completing while a rung is in flight — one rung runs, results are matched by token. Pinned: C4 `secondTriggerWhileARungIsInFlightIsIgnored`, `anOffLadderRebuildResultDoesNotCompleteTheRung`.
5. **Coverage where the probe failed open** (`expectedSeconds == 0`, `deliveredSeconds > 0`) — status is `healthy`, never `neverDelivered` or `idle`. Pinned: C6 `deliveredWithNothingExpectedIsHealthyNotIdle`.

## File Structure

New pure cores (all `TranscriberCore/`, each with a matching `SwiftTests/TranscriberTests/<Name>Tests.swift`):

| File | Responsibility | Task |
|---|---|---|
| `CaptureAlarm.swift` | `AlarmKind`, `ActiveAlarm`, `CaptureAlarmRegistry`, `TrackHealthSnapshot`, `CaptureStatusSnapshot`, `AlarmRealarmPolicy` (§6) | F2 |
| `CaptureOptions.swift` | app→helper capture options (`tap_auto_start`, soft-alarm knob, debug frame drop) | F3 |
| `XPCInterruptionPolicy.swift` | crash-detection arming per capture generation (§8.1) | C1 |
| `LaunchAgentHealth.swift` | judge plist/launchctl state → repair action (§8.2) | C2 |
| `TrackLivenessMonitor.swift` | never-delivered / stalled / cleared / first-frames per track (§4.2); replaces `LivenessGapDetector.swift` | C3 |
| `OutputActivity.swift` | "any other process running output" (§4.3) | C3 |
| `TapRecoveryLadder.swift` | rungs, backoff, budget, slow retry, rung tokens (§5) | C4 |
| `MicHealPolicy.swift` | mic heal-then-alarm (§5, §6.1) | C5 |
| `TrackAccounting.swift` | per-track coverage and status (§7.1) | C6 |
| `RelaunchDecision.swift`, `BootSession.swift` | reattach / resume / salvage at launch; boot-session uuid (§8.3, §8.9) | C7 |
| `DiskSpaceCheck.swift` | bytes per chunk, start/rotation thresholds with hysteresis (§8.7) | C8 |
| `RecoveryMessages.swift` | `SalvageOutcome` + honest recovery texts (§7.4 P6) | C9 |
| `MonotonicWallClock.swift` | wall clock anchored to `ContinuousClock` (§8.12) | C10 |
| `LiveDiagnosticsLog.swift` | append-as-you-go anomaly log and merge (§8.11) | C11 |
| `EnginePreflight.swift`, `SyntheticWAV.swift` | 1 s synthetic WAV + engine smoke test (§11.2) | C12 |
| `Deadline.swift` | `withDeadline(seconds:_:)` on `ResumeOnce` for Core callers (§8.8) | C13 |

Modified cores: `CaptureDiagnostics.swift` (F1, E1, E2), `ChunkSession.swift`, `ChunkProcessor.swift`, `TranscriptionRunner.swift`, `TranscriptAssembler.swift`, `AudioArchiver.swift`, `AudioConcatenator.swift`, `SpeakerAssignment.swift`, `TranscriptRediarizer.swift`, `CaptureQualityNotice.swift`, `MeetingSummarizer.swift`, `SummaryPromptBuilder.swift`, `SummaryProvider.swift`, `RecordingCoordinator.swift`, `RecordingCaptureClient.swift`, `RecordingSentinel.swift`, `ChunkRotator.swift`, `AppState.swift`, `LaunchAgentManager.swift`, `PadRatioMonitor.swift`, `TapPermissionGuard.swift`, `ExactZeroRunMonitor.swift`, `WavFileWriter.swift`, `EngineID.swift`, `Config.swift`, `CrashRecoveryPlanner.swift`, `ChunkedSessionRecovery.swift`.

Thin shells: helper `AudioCaptureHelper/XPC/{OutputActivityProbe,TapHealer}.swift` (new), `SystemTapSession.swift`, `MicCaptureSession.swift`, `AudioCaptureService.swift`, `AudioOutputHandler.swift`, `LivenessWatchdogDriver.swift`, `main.swift`; protocol `AudioCaptureProtocol/AudioCaptureProtocol.swift`; app `TranscriberApp/Services/{CaptureAlarmWindowController,SystemEventObserver}.swift` (new), `AudioCaptureClient.swift`, `TranscriberApp.swift`, `Views/MenuView.swift`, `Views/CaptureAlarmView.swift` (new), `Views/RenameDialog.swift`, `Views/SettingsView.swift`, `Views/SetupView.swift`.

Deleted: `TranscriberCore/LivenessGapDetector.swift` + `LivenessGapDetectorTests.swift` (H1), the `PadRatioMonitorDeadTrackTests` suite and its extension (F1), `TranscriberApp.setupCrashHandler` / `recoverIfNeeded` (L4).

---

## Parallel streams

The owner wants maximum parallelism. The work is partitioned into **streams whose file sets are pairwise disjoint** among the streams that run concurrently, so several implementers can work at once in separate git worktrees off a common base and merge without conflicts. Two tasks that must touch the same file are in the same stream, in order.

### Integration branch and worktrees

- Integration branch: `fix/capture-reliability` (stacked on `fix/permission-readiness`, PR #222). Every stream branches from it and merges back into it. Nothing is pushed.
- Stream F is the **foundation**: its file set deliberately overlaps later streams', so **F merges before any other stream except C branches**. Stream C (pure cores) touches only NEW files and can branch at the base commit `6a9966e` at t=0, in parallel with F.
- Recipe per stream (`<s>` = f, c1…c13, h, e, r, l, d, x):
  ```bash
  cd /Users/fmasi/Git/wt-capture-reliability
  git worktree add ../wt-cr-<s> -b cr/<s> fix/capture-reliability     # after F merged (C: at 6a9966e is fine)
  # …work, commit per task…
  # before merging: rebase on the current integration head, then run the Stream gate below
  git -C ../wt-cr-<s> rebase fix/capture-reliability
  git merge --ff-only cr/<s>                                          # from the integration worktree
  git worktree remove ../wt-cr-<s>
  ```
- **Stream gate** (replaces "push for CI"; run in the stream's worktree, after the rebase):
  1. `$PARLEY_TEST --filter TranscriberTests` green (minus the metamorphic flake);
  2. `python3 scripts/dev.py --build` clean;
  3. `BASE=$(git merge-base fix/capture-reliability HEAD); bash scripts/verify-regression-tests.sh "$BASE"` exits 0 (the red-first gate over the whole stream diff);
  4. a local multi-reviewer **code council** over `git diff "$BASE"..HEAD` — per `docs/development-process.md` §2: distinct lenses (correctness, boundaries, silent failure, robustness/tests) plus skeptics who try to refute each finding; fix the must-list; re-run 1–3.
  Only then merge. Device items (Stream X) run once everything is merged.

### Streams, tasks, owned files

| Stream | Tasks (in order) | Owns (exclusively while it runs) | Starts | Waits for |
|---|---|---|---|---|
| **F** Foundation | F1 event kinds + L-N2 retirement · F2 `CaptureAlarm` · F3 `CaptureOptions` + config keys · F4 protocol/fake additions | `TranscriberCore/CaptureDiagnostics.swift`, `SwiftTests/…/CaptureDiagnosticsTests.swift`, `TranscriberCore/PadRatioMonitor.swift`, `SwiftTests/…/PadRatioMonitorTests.swift`, `AudioCaptureHelper/XPC/AudioOutputHandler.swift`, `TranscriberCore/CaptureAlarm.swift`, `SwiftTests/…/CaptureAlarmTests.swift`, `TranscriberCore/CaptureOptions.swift`, `SwiftTests/…/CaptureOptionsTests.swift`, `TranscriberCore/Config.swift`, `SwiftTests/…/ConfigTests.swift`, `AudioCaptureProtocol/AudioCaptureProtocol.swift`, `TranscriberCore/RecordingCaptureClient.swift`, `TranscriberApp/Services/AudioCaptureClient.swift`, `AudioCaptureHelper/XPC/AudioCaptureService.swift`, `AudioCaptureHelper/XPC/main.swift`, `TranscriberCore/RecordingCoordinator.swift` (one call-site line), `SwiftTests/…/RecordingCoordinatorTests.swift` (`FakeCaptureClient` only) | t=0 | — (merges FIRST; C may run concurrently because C's files are all new) |
| **C** Pure cores | C1…C13, each independent (see the C section); **one implementer per core is fine** | each Ci: exactly one new `TranscriberCore/<Name>.swift` (+ `BootSession.swift` in C7, `SyntheticWAV.swift` in C12) and one new `SwiftTests/…/<Name>Tests.swift`; C2 additionally owns `TranscriberCore/LaunchAgentManager.swift` + `SwiftTests/…/LaunchAgentManagerTests.swift` (nobody else touches them) | t=0 | C5 waits for C3 (uses `TrackLivenessMonitor.Verdict`) |
| **H** Helper | H1 liveness (v1 P0.3 helper) · H2 alarms in the helper (P0.4 helper) · H3 tap listeners, rungs, `tapAutoStart`, debug drop (P1.2 + P1.4 helper) · H4 `TapHealer` + `MicHealPolicy` wiring + permission guard (P1.3) · H5 `srst` (P1.5) · H6 coverage accumulation (P2.1 helper) · H7 power events (P3.5 helper) | `AudioCaptureHelper/XPC/*` (all files, incl. new `OutputActivityProbe.swift`, `TapHealer.swift`), `TranscriberCore/LivenessGapDetector.swift` (delete), `SwiftTests/…/LivenessGapDetectorTests.swift` (delete), `TranscriberCore/TapPermissionGuard.swift`, `SwiftTests/…/TapPermissionGuardTests.swift`, `SwiftTests/…/TapPermissionGuardSoftAlarmTests.swift` (new), `TranscriberCore/ExactZeroRunMonitor.swift`, `SwiftTests/…/ExactZeroRunMonitorTests.swift`, `TranscriberCore/WavFileWriter.swift`, `SwiftTests/…/WavFileWriterTests.swift` | after F | H1: C3 · H3: C4 · H4: C4, C5 · H6: C6 |
| **E** Evidence | E1 provenance coverage (P2.1 core) · E2 counters outside the ring (P3.6 core) | `TranscriberCore/CaptureDiagnostics.swift`, `SwiftTests/…/CaptureDiagnosticsTests.swift` | after F | E1: C6 |
| **R** Record | R0 runner/session seams for L · R1 metadata.capture + dual_stream + summary header (P2.1 record) · R2 `ChunkIssue` + chunk-index dedup + session-write hook (P2.2 + ChunkProcessor parts of P3.2/P3.3) · R3 abutting dedup (P2.4) · R4 archiver/concatenator (P2.3) · R5 honesty fixes (P2.7) · R6 re-detect (P2.6) · R7 filters keep text (P2.8, deferrable) | `TranscriberCore/{ChunkSession,ChunkProcessor,TranscriptionRunner,TranscriptAssembler,CaptureQualityNotice,StreamLabeling,DiarizationCleanup,AudioArchiver,AudioConcatenator,SpeakerAssignment,FluidAudioEngine,SpeechAnalyzerEngine,TranscriptRediarizer,CrashRecoveryPlanner,ChunkedSessionRecovery,SummaryProvider,OpenAISummaryProvider,LMStudioSummaryProvider,MeetingSummarizer,SummaryPromptBuilder,EchoDeduplicator,TranscriptMerger,TranscriptWriter,TranscriptRenamer}.swift`, `TranscriberApp/Views/RenameDialog.swift`, and their test files `SwiftTests/…/{ChunkSession,ChunkProcessor,TranscriptionRunner,TranscriptAssembler,CaptureQualityNotice,AudioArchiver,AudioConcatenator,SpeakerAssignment,SpeakerAssignmentVad,TranscriptRediarizer,OpenAISummaryProvider,LMStudioSummaryProvider,MeetingSummarizer,SummaryPromptBuilder,EchoDeduplicator,TranscriptWriter}Tests.swift`, `SwiftTests/…/RecoveryFixtures.swift` | after F | R1: E1 |
| **L** Lifecycle | L1 interruption policy wiring (P0.1) · L2 alarms in the app (P0.4 app) · L3 LaunchAgent wiring (P0.2) · L4 retry cap + coordinator owns launch recovery (P0.5) · L5 stop/start races (P3.2) · L6 salvage outcome (P2.5) · L7 honest relaunch (P3.1) · L8 disk (P3.3) · L9 deadlines + sentinel after finalize (P3.4) · L10 sleep/wake/quit (P3.5 app) · L11 evidence survives restarts (P3.6 wiring) · L12 completion notice counts (P2.2 coordinator part) | `TranscriberCore/{RecordingCoordinator,RecordingSentinel,ChunkRotator,AppState}.swift`, `SwiftTests/…/{RecordingCoordinator,RecordingSentinel,ChunkRotator,AppState}Tests.swift`, `TranscriberApp/TranscriberApp.swift`, `TranscriberApp/Views/MenuView.swift`, `TranscriberApp/Services/AudioCaptureClient.swift`, `TranscriberApp/Services/CaptureAlarmWindowController.swift` (new), `TranscriberApp/Views/CaptureAlarmView.swift` (new), `TranscriberApp/Services/SystemEventObserver.swift` (new) | after F | L1: C1 · L3: C2 · L5: C13, R0, R2 · L6: C9 · L7: C7, R0, R5 · L8: C8, R2 · L9: C13, R0 · L10: R0 · L11: C10, C11, E2 · L12: R2 |
| **D** Product defaults | D1 tap default + relabel (§11.1) · D2 engine default + label + preflight (§11.2, P2.9) | `TranscriberCore/Config.swift`, `SwiftTests/…/ConfigTests.swift`, `TranscriberCore/EngineID.swift`, `SwiftTests/…/EngineIDTests.swift`, `TranscriberApp/Views/SettingsView.swift`, `TranscriberApp/Views/SetupView.swift` | after F | D2: C12 |
| **X** Final docs | X1 checklist (P4.1) · X2 docs (P4.2) · X3 measurement decisions (P4.3) | `scripts/test-checklist.md`, `CLAUDE.md`, `README.md`, `docs/gotchas.md`, `docs/pipeline.md`, `docs/parameters.md`, `docs/app-store-blockers.md`, `docs/benchmarks/2026-09-capture-reliability.md` (new) | after ALL others merged | everything |

Disjointness check (files that appear in more than one row): `CaptureDiagnostics.swift`/`CaptureDiagnosticsTests.swift` (F then E — F merges first), `Config.swift`/`ConfigTests.swift` (F then D), `AudioCaptureClient.swift` (F then L), `AudioCaptureService.swift`, `main.swift`, `AudioOutputHandler.swift` (F then H), `RecordingCoordinator.swift`/`RecordingCoordinatorTests.swift` (F then L), `RecordingCaptureClient.swift` (F only), `PadRatioMonitor*.swift` (F only). Every overlap is with F, which is merged before the other stream branches. No two concurrent streams share a file, a test file, a doc, or the checklist.

### Dependency DAG and merge order

```
t=0:   F ──────────────────────────────▶ merge F           C1..C13 (parallel, new files only) ─▶ merge each Ci as it finishes
after F:  H (needs C3 by H1, C4 by H3, C5 by H4, C6 by H6)
          E (needs C6 by E1)
          R (needs E1 by R1)                 ← R0 first: it unblocks L7/L9/L10
          L (needs C1 by L1, C2 by L3, C13+R0+R2 by L5, C9 by L6, C7+R0+R5 by L7, C8+R2 by L8, C13+R0 by L9, R0 by L10, C10+C11+E2 by L11, R2 by L12)
          D (needs C12 by D2)
last:  X (after every stream is merged) → device protocol → X3 decisions
```

- Streams start in this order: **C and F at t=0**; **H, E, R, L, D the moment F merges**. Within each stream, a task that "waits for" a Ci/Ej/Rk must not start until that task has merged into the integration branch; rebase the stream on the integration head at that point (it is a fast-forward for everyone else's files).
- Merge order among the parallel streams does not matter (disjoint files), with one exception. Recommended: merge C-tasks as they finish (they unblock the most), then E1 early (unblocks R1), then R0 early (unblocks L7/L9/L10).
- *(X2 amendment, controller ruling during execution.)* **Stream H (with H2) merges before, or together with, stream L.** L2 removes the #220 sticky row, and until H2's helper alarms arrive nothing replaces it. No integration build is installed between the two merges. This is how it ran: `cr/h` merged at `dd8d3a4`, before `cr/l`.
- **Interim behaviour between merges** (state it, do not "fix" it ad hoc): between H2 and L3 merging, the SCK give-up sticky row is carried by either the old `noteSystemAudioLost` (before L3) or the helper's `remoteRecoveryFailed` alarm (after H2) — both are present only once both merged. *(X2 amendment: H merged before L, and L's tasks, L2 and L3 included, merged in one step. So the dangerous state, L2's app alarms without H2's helper alarms and therefore no sticky row at all, never existed on the integration branch.)* Between F4 and H2, `captureStatus` answers an empty snapshot (no alarms), which the app treats as "no helper alarms". Between H1 and H4, system-track liveness verdicts are recorded and alarmed directly (no ladder). All of these are on the feature branch only; nothing ships before X.

### Task index (v1 → v2)

| v1 | v2 | v1 | v2 |
|---|---|---|---|
| P0.1 | C1 (core) + L1 (wiring) | P2.1 | C6 (core) + E1 (provenance) + H6 (helper) + R1 (record) |
| P0.2 | C2 (core + `LaunchAgentManager`) + L3 (wiring) | P2.2 | R2 (+ L12 coordinator call site) |
| P0.3 | F1 (L-N2 retirement) + C3 (cores) + H1 (helper) | P2.3 | R4 |
| P0.4 | F2 (registry) + H2 (helper) + L2 (app) | P2.4 | R3 |
| P0.5 | L4 | P2.5 | C9 (core) + L6 (wiring) |
| P1.1 | C4 | P2.6 | R6 |
| P1.2 | H3 | P2.7 | R5 |
| P1.3 | C5 (core) + H4 (helper + guard) | P2.8 | R7 |
| P1.4 | F3 (options) + F4 (protocol) + H3 (tap init) | P2.9 | C12 (core) + D2 (wiring) |
| P1.5 | H5 | P3.1 | C7 (core) + R0 (seams) + L7 (wiring) |
| — | D1 (new: §11.1 default flip) | P3.2 | C13 (Deadline) + R2 (ChunkProcessor part) + R0 (runner seam) + L5 |
| — | R0 (new: seams) | P3.3 | C8 (core) + R2 (session-write hook) + L8 |
| P4.1 | X1 | P3.4 | R0 (finalize seam) + L9 |
| P4.2 | X2 | P3.5 | R0 (`CaptureGap`) + H7 (helper) + L10 (app) |
| P4.3 | X3 | P3.6 | C10 + C11 (cores) + E2 (counters) + L11 (wiring) |

---
# Stream F — Foundation (merges first)

F's file set overlaps the streams that come after it; that is allowed only because F merges before they branch. Keep F small and mechanical: vocabulary, shared value types, protocol surface, fakes.

### Task F1: Event vocabulary + retirement of the unreachable dead-track path (L-N2)

**Files:**
- Modify: `TranscriberCore/CaptureDiagnostics.swift:8-109` (`CaptureEventKind` cases), `:123-143` (`qualityCompromising`)
- Modify: `TranscriberCore/PadRatioMonitor.swift:31` (`neverDelivered` case), `:69-71` (`deadFrames`, `lastRate`), `:86-95` (guard block), `:117-123` (`finish()`), `:125-131` (`reset()` doc)
- Modify: `AudioCaptureHelper/XPC/AudioOutputHandler.swift:39` (`deadTrackReported`), `:148-149` (the two `noteDeadTrack` calls), `:722-741` (`noteDeadTrack`)
- Test: `SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift` (add one test; red-first: compile error on the new cases), `SwiftTests/TranscriberTests/PadRatioMonitorTests.swift:227-328` (delete the `PadRatioMonitorDeadTrackTests` suite AND its `extension` at 299-328; add `// RED-FIRST-EXEMPT: v2 F1 — this file's only change is the deletion of PadRatioMonitorDeadTrackTests (an unreachable path, L-N2); the remaining tests are unchanged characterization` as line 1)

**Interfaces:**
- Produces `CaptureEventKind` cases (severity class in parentheses; "qc" = member of `qualityCompromising`):
  `.helperIdleExit` (info) · `.neverDelivered` (anomaly, qc) · `.livenessRecovered` (info) · `.firstFrames` (info) · `.alarmRaised` (anomaly, NOT qc — the underlying kind already is) · `.alarmCleared` (info) · `.aggregateIOStopped` (warning) · `.tapRecoveryRung` (warning) · `.tapRecoveryGivenUp` (anomaly, qc) · `.recoveryStuck` (anomaly, qc) · `.serviceRestarted` (warning) · `.trackCoverage` (info) · `.captureGap` (anomaly, qc) · `.rotationFailed` (anomaly, qc) · `.sessionWriteFailed` (anomaly, NOT qc: the audio is intact) · `.diskLow` (warning) · `.xpcTimeout` (anomaly, NOT qc) · `.systemSleep` (info) · `.systemWake` (info).
- Removes `CaptureEventKind.trackNeverDelivered`, `PadRatioMonitor.Verdict.neverDelivered`, `PadRatioMonitor.finish()`, `AudioOutputHandler.noteDeadTrack`.

- [ ] **Step 1: Write the failing test**

Append to `struct CaptureDiagnosticsTests` in `SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift` (before its closing brace, line 225):
```swift
    /// v2 F1: the overhaul's event vocabulary lands first so every stream compiles against it.
    /// The severity CLASS is the contract: a kind in `qualityCompromising` changes the completion
    /// notice and the per-track status; the others are evidence only.
    @Test func overhaulEventKindsCarryTheirSeverityClass() {
        let compromising: [CaptureEventKind] = [.neverDelivered, .tapRecoveryGivenUp, .recoveryStuck, .captureGap, .rotationFailed]
        for k in compromising {
            #expect(CaptureEventKind.qualityCompromising.contains(k), "\(k.rawValue) must count against the record")
        }
        let evidenceOnly: [CaptureEventKind] = [
            .helperIdleExit, .livenessRecovered, .firstFrames, .alarmRaised, .alarmCleared, .aggregateIOStopped,
            .tapRecoveryRung, .serviceRestarted, .trackCoverage, .sessionWriteFailed, .diskLow, .xpcTimeout,
            .systemSleep, .systemWake,
        ]
        for k in evidenceOnly {
            #expect(!CaptureEventKind.qualityCompromising.contains(k), "\(k.rawValue) must not taint the record")
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `$PARLEY_TEST --filter 'CaptureDiagnosticsTests'`
Expected: compile error, `type 'CaptureEventKind' has no member 'neverDelivered'`.

- [ ] **Step 3: Add the cases, remove the dead path**

`CaptureDiagnostics.swift`: delete `case trackNeverDelivered` (line 43 and its doc comment 40-42) and the `.trackNeverDelivered,` entry at line 127; rewrite the comment at 133 to "A track full of exact-zero samples holds nothing usable, same as `neverDelivered`." Add after `case launchRecovery` (line 21):
```swift
    /// launchd idle-exited the helper while nothing was being captured (L-N1). Recorded into the
    /// app ring while idle — the next `resetSession()` wipes it, so it lives in the unified log and
    /// the live log, never in a later session's `.diag.jsonl`. Severity `.info`.
    case helperIdleExit
    /// A track that was EXPECTED to deliver (mic: always; tap: another process running output)
    /// produced no heartbeat within the first-frame threshold after capture start, a rebuild or a
    /// wake — Incident B's exact shape (46 min, 0 callbacks). Severity `.anomaly`.
    case neverDelivered
    /// A reported `neverDelivered`/`livenessGap` episode ended: the heartbeat is back. `.info`.
    case livenessRecovered
    /// First heartbeat of a generation (start / rebuild / wake). `.info`; drives the honest "Resumed".
    case firstFrames
    /// A sticky alarm was raised / cleared (§6). `alarmRaised` is `.anomaly` for the ring but NOT
    /// quality-compromising: the condition that raised it already is.
    case alarmRaised
    case alarmCleared
    /// An aggregate-device listener fired (`goin`→0, `stpd`, `diff`, `agrp`); detail `selector`. `.warning`.
    case aggregateIOStopped
    /// The healing ladder ran a rung; detail `rung`, `delay`, `total`. `.warning`.
    case tapRecoveryRung
    /// The ladder's fast budget is spent; the slow retry owns it now. `.anomaly`.
    case tapRecoveryGivenUp
    /// A rung has not returned within the stuck deadline (a HAL call blocking on a paused context). `.anomaly`.
    case recoveryStuck
    /// coreaudiod restarted (`srst`): every audio object id is dead. `.warning`.
    case serviceRestarted
    /// Per-track coverage counters at a rotation / at stop (§7.1). `.info`.
    case trackCoverage
    /// Time during which nothing was recorded although the recording was running (relaunch, sleep). `.anomaly`.
    case captureGap
    /// A chunk rotation threw. `.anomaly`.
    case rotationFailed
    /// `session.json` could not be written after a chunk. `.anomaly` (the audio is intact).
    case sessionWriteFailed
    /// Free space fell below one chunk at a rotation. `.warning`.
    case diskLow
    /// A helper call hit its deadline. `.anomaly`.
    case xpcTimeout
    /// `NSWorkspace.willSleep` / `didWake` while recording. `.info`; the interval becomes a `captureGap`.
    case systemSleep
    case systemWake
```
In `qualityCompromising` (line 123) add `.neverDelivered, .tapRecoveryGivenUp, .recoveryStuck, .captureGap, .rotationFailed,` (and nothing else).

`PadRatioMonitor.swift`: delete the `neverDelivered(seconds:)` case (31, with its doc), the `deadFrames`/`lastRate` fields (69-71), the `finish()` method (117-123); the guard block (86-95) becomes `guard hasDeliveredData else { return .notYet }`; trim the `reset()` doc (125-131) to: "Deliberately does NOT clear `hasDeliveredData`: a track that delivered in chunk 0 keeps its pad ratio judged in every later chunk."

`AudioOutputHandler.swift`: delete `private var deadTrackReported: Set<String> = []` (39), the two `noteDeadTrack(...)` calls (148-149, with the comment 145-147), and `noteDeadTrack` (722-741 with its doc comment). Keep the rest of `finalizeAll()` (H1 changes its line 166 later).

`PadRatioMonitorTests.swift`: delete lines 224-328 (the `// MARK`, the `PadRatioMonitorDeadTrackTests` suite and its `extension`); insert the `RED-FIRST-EXEMPT` marker as line 1.

- [ ] **Step 4: Run to verify it passes**

Run: `$PARLEY_TEST --filter 'CaptureDiagnosticsTests|PadRatioMonitorTests'`
Expected: pass; `PadRatioMonitorTests` reports 13 tests.

- [ ] **Step 5: Build (helper compiles without `noteDeadTrack`), full suite, commit**

Run: `python3 scripts/dev.py --build` then `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add TranscriberCore/CaptureDiagnostics.swift TranscriberCore/PadRatioMonitor.swift AudioCaptureHelper/XPC/AudioOutputHandler.swift SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift SwiftTests/TranscriberTests/PadRatioMonitorTests.swift
git commit -m "feat(diagnostics): capture-reliability event vocabulary; retire the unreachable trackNeverDelivered path (L-N2)"
```

---

### Task F2: `CaptureAlarm` — alarm state, snapshot, stale-helper rule, re-alarm policy

**Files:**
- Create: `TranscriberCore/CaptureAlarm.swift`
- Test: `SwiftTests/TranscriberTests/CaptureAlarmTests.swift` (new, red-first: compile error at parent)

**Interfaces:**
- Produces:
  ```swift
  public enum AlarmKind: String, Codable, CaseIterable, Sendable {
      case micNotDelivering, micDigitalSilence, remoteNotDelivering, remoteRecoveryFailed,
           remotePermissionDenied, remoteCantConfirm, diskWriteFailure,
           diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff,
           recordingResumedWithGap, recordingStopped, recordingFolderUnavailable
      public var isHelperOwned: Bool          // the first seven
      public var track: String?               // "mic" | "system" | nil
      public var isAcknowledgeable: Bool      // recordingResumedWithGap, recordingStopped
      public var outlivesRecording: Bool      // crashProtectionOff || isAcknowledgeable
  }
  public struct ActiveAlarm: Codable, Equatable, Sendable {
      public let kind: AlarmKind; public let raisedAt: Date; public var lastNotifiedAt: Date?
      public let message: String; public let episode: Int
      public init(kind:raisedAt:lastNotifiedAt:message:episode:)
  }
  public struct CaptureAlarmRegistry: Equatable, Sendable {
      public private(set) var alarms: [AlarmKind: ActiveAlarm]
      public private(set) var staleKinds: Set<AlarmKind>      // inherited from a replaced helper (§6.2)
      public private(set) var helperSessionId: String?
      public init()
      @discardableResult public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool
      @discardableResult public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm?
      public mutating func markNotified(_ kind: AlarmKind, now: Date)
      public mutating func apply(_ snapshot: CaptureStatusSnapshot)   // app side, see the doc comment
      public mutating func noteFirstFrames(track: String)             // clears stale kinds for that track (and track-less ones)
      public mutating func recordingEnded()                           // clears every kind that does not outlive the recording
      public var isEmpty: Bool
      public var sorted: [ActiveAlarm]                                // by raisedAt
  }
  public struct TrackHealthSnapshot: Codable, Equatable, Sendable { track: String; expected: Bool; heartbeatAgeSeconds: Double?; generation: Int }
  public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
      public let helperSessionId: String; public let isCapturing: Bool
      public let alarms: [ActiveAlarm]; public let tracks: [TrackHealthSnapshot]
      public init(helperSessionId:isCapturing:alarms:tracks:)
      public func encoded() -> Data
      public static func decode(_ data: Data) -> CaptureStatusSnapshot?   // tolerant of unknown kinds
  }
  public enum AlarmRealarmPolicy {
      public static let notifyInterval: TimeInterval = 120
      public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool
      public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool   // = CaptureReadiness.shouldPresentRepair
  }
  ```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/CaptureAlarmTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// H3/H9/L5 (§6): alarms are state, per track, sticky until the condition clears, re-notified
/// periodically. Incident A's watchdog fired once and stayed silent for 51 minutes.
@Suite struct CaptureAlarmTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func snapshot(_ id: String, _ alarms: [ActiveAlarm]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, isCapturing: true, alarms: alarms, tracks: [])
    }
    private func alarm(_ kind: AlarmKind, at: Date, episode: Int = 1) -> ActiveAlarm {
        ActiveAlarm(kind: kind, raisedAt: at, lastNotifiedAt: nil, message: kind.rawValue, episode: episode)
    }

    @Test func raiseIsIdempotentAndKeepsTheOriginalTimestamp() {
        var r = CaptureAlarmRegistry()
        #expect(r.raise(.remoteNotDelivering, message: "m", now: t0) == true)
        #expect(r.raise(.remoteNotDelivering, message: "m2", now: t0 + 10) == false)
        #expect(r.alarms[.remoteNotDelivering]?.raisedAt == t0)
        #expect(r.alarms[.remoteNotDelivering]?.message == "m")
    }

    @Test func clearReturnsTheAlarmAndEmptiesTheSlot() {
        var r = CaptureAlarmRegistry()
        r.raise(.micDigitalSilence, message: "m", now: t0)
        #expect(r.clear(.micDigitalSilence)?.kind == .micDigitalSilence)
        #expect(r.clear(.micDigitalSilence) == nil)
        #expect(r.isEmpty)
    }

    @Test func episodeCountsRaises() {
        var r = CaptureAlarmRegistry()
        r.raise(.micNotDelivering, message: "m", now: t0); _ = r.clear(.micNotDelivering)
        r.raise(.micNotDelivering, message: "m", now: t0 + 1)
        #expect(r.alarms[.micNotDelivering]?.episode == 2)
    }

    /// App side: helper-owned kinds follow the same helper's snapshot; app-owned ones are untouched.
    @Test func sameHelperSnapshotReplacesHelperOwnedAlarmsOnly() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0)]))
        r.apply(snapshot("h1", [alarm(.micDigitalSilence, at: t0 + 5)]))
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .micDigitalSilence])
        #expect(r.staleKinds.isEmpty)
    }

    /// Spec §6.3 (scan C7): the 5 s poll must not reset the 2-minute notify clock.
    @Test func pollingDoesNotResetTheNotifyClock() {
        var r = CaptureAlarmRegistry()
        let fromHelper = alarm(.remoteNotDelivering, at: t0)
        r.apply(snapshot("h1", [fromHelper]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot("h1", [fromHelper]))   // the next poll, same episode
        #expect(r.alarms[.remoteNotDelivering]?.lastNotifiedAt == t0 + 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(r.alarms[.remoteNotDelivering]!, now: t0 + 6) == false)
    }

    @Test func aNewEpisodeOfTheSameKindNotifiesAgain() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0, episode: 1)]))
        r.markNotified(.remoteNotDelivering, now: t0 + 1)
        r.apply(snapshot("h1", [alarm(.remoteNotDelivering, at: t0 + 30, episode: 2)]))
        #expect(r.alarms[.remoteNotDelivering]?.lastNotifiedAt == nil)
    }

    /// Spec §6.2 (scan C6): a restarted helper starts empty; the app keeps the old set until the
    /// new helper's first frames on that track prove the condition gone.
    @Test func aNewHelperKeepsTheOldAlarmsAsStaleUntilItsFirstFrames() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remotePermissionDenied, at: t0), alarm(.micDigitalSilence, at: t0)]))
        r.apply(snapshot("h2", []))   // crash restart: the new helper's registry is empty
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micDigitalSilence])
        #expect(r.staleKinds == [.remotePermissionDenied, .micDigitalSilence])
        r.apply(snapshot("h2", []))   // the next poll must not wipe them either
        #expect(Set(r.alarms.keys) == [.remotePermissionDenied, .micDigitalSilence])
        r.noteFirstFrames(track: "system")
        #expect(Set(r.alarms.keys) == [.micDigitalSilence], "mic frames have not arrived yet")
        r.noteFirstFrames(track: "mic")
        #expect(r.isEmpty)
    }

    @Test func aNewHelperReRaisingAKindMakesItCurrentAgain() {
        var r = CaptureAlarmRegistry()
        r.apply(snapshot("h1", [alarm(.remotePermissionDenied, at: t0)]))
        r.apply(snapshot("h2", [alarm(.remotePermissionDenied, at: t0 + 20)]))
        #expect(r.staleKinds.isEmpty)
        #expect(r.alarms[.remotePermissionDenied]?.raisedAt == t0 + 20)
    }

    @Test func recordingEndClearsPerRecordingKindsOnly() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.raise(.recordingStopped, message: "s", now: t0)
        r.raise(.diskLow, message: "d", now: t0)
        r.apply(snapshot("h1", [alarm(.micDigitalSilence, at: t0)]))
        r.recordingEnded()
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .recordingStopped])
    }

    @Test func snapshotRoundTrips() throws {
        var r = CaptureAlarmRegistry()
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        let s = CaptureStatusSnapshot(helperSessionId: "h1", isCapturing: true, alarms: r.sorted,
                                      tracks: [TrackHealthSnapshot(track: "system", expected: true, heartbeatAgeSeconds: 7.5, generation: 2)])
        let decoded = try #require(CaptureStatusSnapshot.decode(s.encoded()))
        #expect(decoded == s)
    }

    /// Review focus 2: a newer helper may send a kind this app does not know.
    @Test func snapshotWithUnknownKindKeepsTheOthers() throws {
        let json = """
        {"helperSessionId":"h","isCapturing":true,"tracks":[],
         "alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T16:00:00Z","message":"x","episode":1},
                   {"kind":"micDigitalSilence","raisedAt":"2026-09-24T16:00:00Z","message":"y","episode":1}]}
        """
        let decoded = try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))
        #expect(decoded.alarms.map(\.kind) == [.micDigitalSilence])
    }

    @Test func renotifyEveryTwoMinutesWhileActive() {
        var a = ActiveAlarm(kind: .remoteNotDelivering, raisedAt: t0, lastNotifiedAt: t0, message: "m", episode: 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 119) == false)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 120))
        a.lastNotifiedAt = nil
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0), "never notified: notify now")
    }

    @Test func windowReopensAfterTheSnooze() {
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: nil, now: t0))
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + 60) == false)
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + CaptureReadiness.repairSnooze))
    }

    @Test func kindsKnowTheirTrackAndOwner() {
        #expect(AlarmKind.micNotDelivering.track == "mic")
        #expect(AlarmKind.remotePermissionDenied.track == "system")
        #expect(AlarmKind.crashProtectionOff.track == nil)
        #expect(AlarmKind.micNotDelivering.isHelperOwned)
        #expect(AlarmKind.sessionWriteFailed.isHelperOwned == false)
        #expect(AlarmKind.recordingStopped.isAcknowledgeable)
        #expect(AlarmKind.recordingStopped.outlivesRecording && AlarmKind.crashProtectionOff.outlivesRecording)
        #expect(AlarmKind.diskLow.outlivesRecording == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'CaptureAlarmTests'` — Expected: compile error (`CaptureAlarmRegistry` not found).

- [ ] **Step 3: Implement `TranscriberCore/CaptureAlarm.swift`**

```swift
import Foundation

/// Alarm STATE (§6): per track, owned by the helper or the app, sticky until its condition
/// clears. Replaces the one-shot `captureQualityAnomaly` events + the single overwritable
/// `interruptionWarning` slot for anything that means "a side is not being recorded".
public enum AlarmKind: String, Codable, CaseIterable, Sendable {
    case micNotDelivering, micDigitalSilence
    case remoteNotDelivering, remoteRecoveryFailed, remotePermissionDenied, remoteCantConfirm
    case diskWriteFailure
    case diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff
    case recordingResumedWithGap, recordingStopped, recordingFolderUnavailable

    public var isHelperOwned: Bool {
        switch self {
        case .micNotDelivering, .micDigitalSilence, .remoteNotDelivering, .remoteRecoveryFailed,
             .remotePermissionDenied, .remoteCantConfirm, .diskWriteFailure: return true
        default: return false
        }
    }

    public var track: String? {
        switch self {
        case .micNotDelivering, .micDigitalSilence: return "mic"
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm: return "system"
        default: return nil
        }
    }

    /// Past events the user dismisses; everything else clears only when the condition clears.
    public var isAcknowledgeable: Bool { self == .recordingResumedWithGap || self == .recordingStopped }

    /// Survives the end of a recording: a machine-level condition, or a past event the user has
    /// not acknowledged yet ("the recording STOPPED at 16:02" must outlive the recording it is about).
    public var outlivesRecording: Bool { self == .crashProtectionOff || isAcknowledgeable }
}

public struct ActiveAlarm: Codable, Equatable, Sendable {
    public let kind: AlarmKind
    public let raisedAt: Date
    public var lastNotifiedAt: Date?
    public let message: String
    public let episode: Int

    public init(kind: AlarmKind, raisedAt: Date, lastNotifiedAt: Date?, message: String, episode: Int) {
        self.kind = kind; self.raisedAt = raisedAt; self.lastNotifiedAt = lastNotifiedAt
        self.message = message; self.episode = episode
    }
}

public struct CaptureAlarmRegistry: Equatable, Sendable {
    public private(set) var alarms: [AlarmKind: ActiveAlarm] = [:]
    private var episodes: [AlarmKind: Int] = [:]
    /// Helper-owned alarms inherited from a helper that has since been replaced (crash restart).
    /// Kept and shown until the new helper's first frames on that track prove the condition gone (§6.2).
    public private(set) var staleKinds: Set<AlarmKind> = []
    public private(set) var helperSessionId: String?

    public init() {}

    /// True when newly raised; a repeat keeps the original alarm untouched.
    @discardableResult
    public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool {
        guard alarms[kind] == nil else { return false }
        let episode = (episodes[kind] ?? 0) + 1
        episodes[kind] = episode
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: now, lastNotifiedAt: nil, message: message, episode: episode)
        return true
    }

    @discardableResult
    public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm? {
        staleKinds.remove(kind)
        return alarms.removeValue(forKey: kind)
    }

    public mutating func markNotified(_ kind: AlarmKind, now: Date) { alarms[kind]?.lastNotifiedAt = now }

    /// App side. SAME helper: its snapshot is the truth for helper-owned kinds; a kind still active
    /// in the same episode keeps its notify clock (scan C7). NEW helper (`helperSessionId` changed):
    /// the previous helper's alarms become stale but stay visible; the new helper's are adopted (§6.2).
    public mutating func apply(_ snapshot: CaptureStatusSnapshot) {
        let sameHelper = helperSessionId == nil || helperSessionId == snapshot.helperSessionId
        if sameHelper {
            for kind in AlarmKind.allCases where kind.isHelperOwned && !staleKinds.contains(kind) {
                if !snapshot.alarms.contains(where: { $0.kind == kind }) { alarms.removeValue(forKey: kind) }
            }
        } else {
            for kind in alarms.keys where kind.isHelperOwned { staleKinds.insert(kind) }
        }
        for incoming in snapshot.alarms where incoming.kind.isHelperOwned {
            var kept = incoming
            if let existing = alarms[incoming.kind], existing.episode == incoming.episode,
               !staleKinds.contains(incoming.kind) {
                kept.lastNotifiedAt = existing.lastNotifiedAt
            }
            alarms[incoming.kind] = kept
            staleKinds.remove(incoming.kind)
        }
        helperSessionId = snapshot.helperSessionId
    }

    /// First frames of `track` from the current helper: the previous helper's alarms on that track,
    /// and its track-less ones (`diskWriteFailure`), are proven stale. The new helper re-raises
    /// anything that is still true within seconds.
    public mutating func noteFirstFrames(track: String) {
        for kind in Array(staleKinds) where kind.track == track || kind.track == nil {
            alarms.removeValue(forKey: kind)
            staleKinds.remove(kind)
        }
    }

    /// The recording ended: everything scoped to it goes; machine-level and unacknowledged past
    /// events stay.
    public mutating func recordingEnded() {
        for kind in Array(alarms.keys) where !kind.outlivesRecording { _ = clear(kind) }
    }

    public var isEmpty: Bool { alarms.isEmpty }
    public var sorted: [ActiveAlarm] { alarms.values.sorted { $0.raisedAt < $1.raisedAt } }
}

public struct TrackHealthSnapshot: Codable, Equatable, Sendable {
    public let track: String
    public let expected: Bool
    public let heartbeatAgeSeconds: Double?
    public let generation: Int
    public init(track: String, expected: Bool, heartbeatAgeSeconds: Double?, generation: Int) {
        self.track = track; self.expected = expected; self.heartbeatAgeSeconds = heartbeatAgeSeconds; self.generation = generation
    }
}

/// What the app PULLS from the helper on connect, every 5 s while recording, and after any
/// restart — and what the helper PUSHES on every change. JSON over XPC.
public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
    public let helperSessionId: String
    public let isCapturing: Bool
    public let alarms: [ActiveAlarm]
    public let tracks: [TrackHealthSnapshot]

    public init(helperSessionId: String, isCapturing: Bool, alarms: [ActiveAlarm], tracks: [TrackHealthSnapshot]) {
        self.helperSessionId = helperSessionId; self.isCapturing = isCapturing; self.alarms = alarms; self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey { case helperSessionId, isCapturing, alarms, tracks }

    /// Tolerant: an alarm whose kind this build does not know is dropped, the rest survive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperSessionId = try c.decode(String.self, forKey: .helperSessionId)
        isCapturing = try c.decode(Bool.self, forKey: .isCapturing)
        tracks = try c.decodeIfPresent([TrackHealthSnapshot].self, forKey: .tracks) ?? []
        var raw = try c.nestedUnkeyedContainer(forKey: .alarms)
        var kept: [ActiveAlarm] = []
        while !raw.isAtEnd {
            if let a = try? raw.decode(ActiveAlarm.self) { kept.append(a) } else { _ = try? raw.decode(SkippedElement.self) }
        }
        alarms = kept
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }
    public func encoded() -> Data { (try? Self.coder().0.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> CaptureStatusSnapshot? { try? coder().1.decode(CaptureStatusSnapshot.self, from: data) }
}

/// Consumes one unknown array element while decoding (used by the tolerant snapshot decoder).
private struct SkippedElement: Decodable {
    private enum NoKeys: CodingKey {}
    init(from decoder: Decoder) throws { _ = try? decoder.container(keyedBy: NoKeys.self) }
}

public enum AlarmRealarmPolicy {
    public static let notifyInterval: TimeInterval = 120

    public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool {
        guard let last = alarm.lastNotifiedAt else { return true }
        return now.timeIntervalSince(last) >= notifyInterval
    }

    public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool {
        CaptureReadiness.shouldPresentRepair(lastDismissedAt: lastDismissedAt, now: now)
    }
}
```

- [ ] **Step 4: Run to verify they pass, commit**

Run: `$PARLEY_TEST --filter 'CaptureAlarmTests'` — Expected: 14 pass.
```bash
git add TranscriberCore/CaptureAlarm.swift SwiftTests/TranscriberTests/CaptureAlarmTests.swift
git commit -m "feat(alarms): CaptureAlarmRegistry — sticky per-track alarm state, stale-helper rule, snapshot transport, re-alarm policy (§6)"
```

---

### Task F3: `CaptureOptions` and the three capture knobs in `Config`

**Files:**
- Create: `TranscriberCore/CaptureOptions.swift`
- Modify: `TranscriberCore/Config.swift` (three optional fields; CodingKeys `tap_auto_start`, `remote_exact_zero_soft_alarm_seconds`, `debug_drop_tap_frames`; `decodeIfPresent`; `Config.default` passes `nil` for all three)
- Test: `SwiftTests/TranscriberTests/CaptureOptionsTests.swift` (new), `SwiftTests/TranscriberTests/ConfigTests.swift` (add one test) — both red-first (compile errors on the new members)

**Interfaces:**
```swift
public struct CaptureOptions: Codable, Equatable, Sendable {
    public var tapAutoStart: Bool                       // default true until M-B passes (§5)
    public var remoteExactZeroSoftAlarmSeconds: Int?    // nil = off (§10 M-A)
    public var debugDropTapFrames: Bool                 // diagnostic: helper drops tap buffers before the heartbeat (D-04)
    public init(tapAutoStart: Bool = true, remoteExactZeroSoftAlarmSeconds: Int? = nil, debugDropTapFrames: Bool = false)
    public init(config: Config)
    public func encoded() -> Data
    public static func decode(_ data: Data?) -> CaptureOptions   // nil / garbage → defaults
}
// Config: + tapAutoStart: Bool?, remoteExactZeroSoftAlarmSeconds: Int?, debugDropTapFrames: Bool?
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/CaptureOptionsTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// M-B: `TapAutoStart` decides whether "no callbacks" is ambiguous. It becomes a diagnostic knob
/// so the device test can A/B it without a rebuild; the default flips only on a measured pass.
@Suite struct CaptureOptionsTests {
    @Test func defaultsMatchTheShippedBehaviour() {
        let o = CaptureOptions()
        #expect(o.tapAutoStart == true)
        #expect(o.remoteExactZeroSoftAlarmSeconds == nil)
        #expect(o.debugDropTapFrames == false)
    }
    @Test func builtFromConfig() {
        var c = Config.default
        c.tapAutoStart = false
        c.remoteExactZeroSoftAlarmSeconds = 300
        c.debugDropTapFrames = true
        let o = CaptureOptions(config: c)
        #expect(o == CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 300, debugDropTapFrames: true))
        #expect(CaptureOptions(config: Config.default) == CaptureOptions())
    }
    @Test func roundTripsAndFailsSoft() {
        let o = CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 120, debugDropTapFrames: false)
        #expect(CaptureOptions.decode(o.encoded()) == o)
        #expect(CaptureOptions.decode(nil) == CaptureOptions())
        #expect(CaptureOptions.decode(Data("nope".utf8)) == CaptureOptions())
    }
}
```
Append to `ConfigTests.swift` (inside the existing suite):
```swift
    /// v2 F3: the three capture knobs are optional, snake_case, and absent by default.
    @Test func captureKnobsRoundTripAndDefaultToNil() throws {
        var c = Config.default
        #expect(c.tapAutoStart == nil && c.remoteExactZeroSoftAlarmSeconds == nil && c.debugDropTapFrames == nil)
        c.tapAutoStart = false
        c.remoteExactZeroSoftAlarmSeconds = 300
        c.debugDropTapFrames = true
        let data = try JSONEncoder().encode(c)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["tap_auto_start"] as? Bool == false)
        #expect(json["remote_exact_zero_soft_alarm_seconds"] as? Int == 300)
        #expect(json["debug_drop_tap_frames"] as? Bool == true)
        #expect(try JSONDecoder().decode(Config.self, from: data) == c)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'CaptureOptionsTests|ConfigTests'` → compile errors.

- [ ] **Step 3: Implement**

`Config.swift`: add `public var tapAutoStart: Bool?`, `public var remoteExactZeroSoftAlarmSeconds: Int?`, `public var debugDropTapFrames: Bool?` next to `preserveSourceWAV` (line 146); CodingKeys (265-292) `case tapAutoStart = "tap_auto_start"`, `case remoteExactZeroSoftAlarmSeconds = "remote_exact_zero_soft_alarm_seconds"`, `case debugDropTapFrames = "debug_drop_tap_frames"`; in `init(from:)` (294-322) `decodeIfPresent` for each; add the three to the memberwise `init` with `= nil` defaults and pass `nil` in `Config.default` (180-207).

`TranscriberCore/CaptureOptions.swift`:
```swift
import Foundation

/// What the app tells the helper before `startCapture` (§5, §10). JSON over `configureCapture`.
/// Every field has a default so an older helper (or a failed configure) records exactly as today.
public struct CaptureOptions: Codable, Equatable, Sendable {
    /// `kAudioAggregateDeviceTapAutoStartKey`. `true` = the shipped behaviour (gotcha #78); the
    /// default flips to `false` only if measurement M-B passes.
    public var tapAutoStart: Bool
    /// Seconds of exact-zero remote audio after which the helper says "can't confirm". `nil` = off,
    /// and it stays off unless the exact-zero census (M-A) shows no call app renders zeros when muted.
    public var remoteExactZeroSoftAlarmSeconds: Int?
    /// DIAGNOSTIC ONLY (device item D-04): the helper drops every tap buffer BEFORE stamping the
    /// heartbeat, reproducing Incident B's "expected but never delivered" deterministically.
    public var debugDropTapFrames: Bool

    public init(tapAutoStart: Bool = true, remoteExactZeroSoftAlarmSeconds: Int? = nil, debugDropTapFrames: Bool = false) {
        self.tapAutoStart = tapAutoStart
        self.remoteExactZeroSoftAlarmSeconds = remoteExactZeroSoftAlarmSeconds
        self.debugDropTapFrames = debugDropTapFrames
    }

    public init(config: Config) {
        self.init(tapAutoStart: config.tapAutoStart ?? true,
                  remoteExactZeroSoftAlarmSeconds: config.remoteExactZeroSoftAlarmSeconds,
                  debugDropTapFrames: config.debugDropTapFrames ?? false)
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> CaptureOptions {
        guard let data, let o = try? JSONDecoder().decode(CaptureOptions.self, from: data) else { return CaptureOptions() }
        return o
    }
}
```

- [ ] **Step 4: Run, full suite, commit**

Run: `$PARLEY_TEST --filter 'CaptureOptionsTests|ConfigTests'` → pass; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/CaptureOptions.swift TranscriberCore/Config.swift SwiftTests/TranscriberTests/CaptureOptionsTests.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat(config): CaptureOptions + tap_auto_start / remote_exact_zero_soft_alarm_seconds / debug_drop_tap_frames knobs (Q3b, Q4.6, M-A, M-B)"
```

---

### Task F4: The whole protocol surface at once — XPC, `RecordingCaptureClient`, fakes, stubs

Every later stream compiles against this surface; none of them edits `AudioCaptureProtocol.swift`, `RecordingCaptureClient.swift`, `main.swift` or `FakeCaptureClient` again.

**Files:**
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift:5-70` (`AudioCaptureProtocol`), `:76-94` (`AudioCaptureClientProtocol`)
- Modify: `TranscriberCore/RecordingCaptureClient.swift:22-58`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift` (`record` at 113 becomes internal; `start` at 206-241 gains `options:`; new `captureStatus()`, `systemPowerEvent(_:)`, `onFirstFrames`, `onAlarmsChanged`; `ReverseChannel` 386-424 gains two methods)
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (stubs: `captureStatus`, `configureCapture`, `systemPowerEvent`; `helperSessionId`; `pendingOptions`; `onFirstFrames`/`onAlarmsChanged` callbacks), `AudioCaptureHelper/XPC/main.swift:26-38` (wire the two new reverse-channel callbacks)
- Modify: `TranscriberCore/RecordingCoordinator.swift:283-288, 642-647` (pass `options:`)
- Test: `SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift:8-88` (`FakeCaptureClient`) + one new test (red-first: `StartCall.options` does not exist at parent)

**Interfaces:**
- `AudioCaptureProtocol` (new methods only):
  ```swift
  /// The helper's current alarm state + per-track health as JSON `CaptureStatusSnapshot` (§6.2).
  func captureStatus(reply: @escaping (Data?) -> Void)
  /// JSON `CaptureOptions`, applied to the NEXT `startCapture`. Reply false = not understood.
  func configureCapture(optionsJSON: Data, reply: @escaping (Bool) -> Void)
  /// "sleep" | "wake" from `NSWorkspace` (§8.10). Reply when applied.
  func systemPowerEvent(kind: String, reply: @escaping () -> Void)
  ```
- `AudioCaptureClientProtocol` (both `@objc optional`): `captureDidDeliverFirstFrames(track: String)`, `captureAlarmsChanged(snapshot: Data)`.
- `RecordingCaptureClient` (additions; `start` REPLACES the 4-argument form):
  ```swift
  var onBriefInterruption: (@Sendable () -> Void)? { get set }
  var onRestartInPlace: (@Sendable () -> Void)? { get set }
  var onFirstFrames: (@Sendable (String) -> Void)? { get set }
  var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)? { get set }
  /// `sessionId` is the chunk session id (`SessionState.sessionId`; the sanitized session name, stable
  /// across in-session restarts whose base names change). L11 resets the diagnostics ring only when it changes.
  func start(outputDirectory: URL, baseName: String, microphoneDeviceId: String?, systemAudioSource: SystemAudioSource, options: CaptureOptions, sessionId: String) async throws
  func captureStatus() async -> CaptureStatusSnapshot?
  func isCapturing() async -> Bool
  func recordLaunchRecovery(_ detail: [String: String])
  func systemPowerEvent(_ kind: String) async
  func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String])
  ```
- `AudioCaptureService`: `var onFirstFrames: ((String) -> Void)?`, `var onAlarmsChanged: ((Data) -> Void)?`, `let helperSessionId: String` (per process), `pendingOptions: CaptureOptions` under `stateLock`, read by `startCapture` as `let options = stateLock.sync { pendingOptions }` and recorded as `"tap_auto_start": "\(options.tapAutoStart)"` in the `.captureStart` detail.

- [ ] **Step 1: Write the failing test and extend the fake**

In `RecordingCoordinatorTests.swift`, `FakeCaptureClient` (lines 8-88):
- add stored closures `var onBriefInterruption: (@Sendable () -> Void)?`, `var onRestartInPlace: (@Sendable () -> Void)?`, `var onFirstFrames: (@Sendable (String) -> Void)?`, `var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?`;
- `StartCall` gains `let options: CaptureOptions` and `let sessionId: String`; `start(...)` gains `options: CaptureOptions, sessionId: String` and stores both;
- add `var statusSnapshot: CaptureStatusSnapshot?` and `func captureStatus() async -> CaptureStatusSnapshot? { statusSnapshot }`;
- add `var isCapturingResult = false` and `func isCapturing() async -> Bool { isCapturingResult }`;
- add `var launchRecoveries: [[String: String]] = []` and `func recordLaunchRecovery(_ detail: [String: String]) { launchRecoveries.append(detail) }`;
- add `var powerEvents: [String] = []` and `func systemPowerEvent(_ kind: String) async { powerEvents.append(kind) }`;
- add `var recordedEvents: [(kind: CaptureEventKind, severity: CaptureEvent.Severity, detail: [String: String])] = []` and `func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String]) { recordedEvents.append((kind, severity, detail)) }`.

Add to `RecordingCoordinatorLifecycleTests`:
```swift
    /// v2 F4: the coordinator hands the helper the capture options built from config, before start.
    @Test func startPassesTheConfiguredCaptureOptionsToTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.tapAutoStart = false; $0.debugDropTapFrames = true }
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        let call = try #require(h.client.startCalls.first)
        #expect(call.options == CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: nil, debugDropTapFrames: true))
        #expect(call.sessionId.hasSuffix("-Test") && call.baseName == call.sessionId + "-0", "the session id is the chunk base name (HHmmss-name) without the chunk index")
    }
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'RecordingCoordinatorLifecycleTests'` → compile error (`options` is not a member of `StartCall`; the fake no longer conforms).

- [ ] **Step 3: Protocol + Core**

`AudioCaptureProtocol.swift`: append the three methods to `AudioCaptureProtocol` (before line 70) and the two `@objc optional` methods to `AudioCaptureClientProtocol` (before line 94), with the doc comments from Interfaces.

`RecordingCaptureClient.swift`: add the members listed in Interfaces; replace the 4-argument `start` (37-42) with the 5-argument one.

`RecordingCoordinator.swift`: line 283-288 → add `options: CaptureOptions(config: config), sessionId: naming.chunkBaseName`; line 642-647 → add `options: CaptureOptions(config: configManager.config), sessionId: stripSegmentSuffix(sentinel.systemAudioPath)` (the same session-id derivation `CrashRecoveryPlanner.planRestart` uses at lines 76-96).

- [ ] **Step 4: App client**

`AudioCaptureClient.swift`:
- line 113: `private func record(` → `func record(` (the protocol needs it; nothing else changes).
- add next to `onQualityAnomaly` (49): `var onFirstFrames: (@Sendable (String) -> Void)?`, `var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?`.
- `start` (206): signature becomes `func start(outputDirectory: URL, baseName: String, microphoneDeviceId: String? = nil, systemAudioSource: SystemAudioSource = .screenCaptureKit, options: CaptureOptions = CaptureOptions(), sessionId: String = "") async throws` (the defaults keep `TranscriberApp.swift:366/430` compiling until L4 deletes them; `sessionId` is stored in `private(set) var currentSessionId: String?` for L11). After `let conn = try getConnection()` (218) insert `await configureCapture(options, on: conn)`, with:
```swift
    /// Best effort, 3 s: a helper that does not answer records with its defaults, which are today's behaviour.
    private func configureCapture(_ options: CaptureOptions, on conn: NSXPCConnection) async {
        let acknowledged = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(false) } as! AudioCaptureProtocol
            proxy.configureCapture(optionsJSON: options.encoded()) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(false) }
        }
        if !acknowledged { Logger.audio.warning("configureCapture not acknowledged — the helper records with default capture options") }
    }
```
- add (same shape as `systemAudioPermissionStatus()` at 317-327):
```swift
    func captureStatus() async -> CaptureStatusSnapshot? {
        guard let conn = try? getConnection() else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<CaptureStatusSnapshot?, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as! AudioCaptureProtocol
            proxy.captureStatus { once.resume($0.flatMap(CaptureStatusSnapshot.decode)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
    }

    func systemPowerEvent(_ kind: String) async {
        guard let conn = try? getConnection() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(()) } as! AudioCaptureProtocol
            proxy.systemPowerEvent(kind: kind) { once.resume(()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(()) }
        }
    }
```
- `ReverseChannel` (386-424): add
```swift
    func captureDidDeliverFirstFrames(track: String) {
        Task { @MainActor [weak client] in client?.onFirstFrames?(track) }
    }
    func captureAlarmsChanged(snapshot: Data) {
        guard let decoded = CaptureStatusSnapshot.decode(snapshot) else { return }
        Task { @MainActor [weak client] in client?.onAlarmsChanged?(decoded) }
    }
```

- [ ] **Step 5: Helper stubs and `main.swift`**

`AudioCaptureService.swift`:
- fields: `let helperSessionId = UUID().uuidString` (next to `isCapturing`, line 12), `private var pendingOptions = CaptureOptions()` (under `stateLock`, next to `tapSession` at 30), `var onFirstFrames: ((String) -> Void)?` and `var onAlarmsChanged: ((Data) -> Void)?` (next to `onQualityAnomaly`, 67).
- methods (next to `status(reply:)`, 313):
```swift
    /// F4 stub: the registry arrives in H2. Until then the snapshot carries no alarms and no tracks.
    func captureStatus(reply: @escaping (Data?) -> Void) {
        let capturing = stateLock.sync { isCapturing }
        reply(CaptureStatusSnapshot(helperSessionId: helperSessionId, isCapturing: capturing, alarms: [], tracks: []).encoded())
    }

    func configureCapture(optionsJSON: Data, reply: @escaping (Bool) -> Void) {
        let options = CaptureOptions.decode(optionsJSON)
        stateLock.sync { pendingOptions = options }
        Logger.audio.info("Capture options: tap_auto_start=\(options.tapAutoStart, privacy: .public) soft_alarm=\(options.remoteExactZeroSoftAlarmSeconds.map(String.init) ?? "off", privacy: .public) debug_drop=\(options.debugDropTapFrames, privacy: .public)")
        reply(true)
    }

    /// F4 stub: H7 pauses/re-arms the monitors here.
    func systemPowerEvent(kind: String, reply: @escaping () -> Void) {
        Logger.audio.info("System power event: \(kind, privacy: .public)")
        reply()
    }
```
- in `startCapture` (130-256): after `diagnostics.clear()` (165) add `let options = stateLock.sync { pendingOptions }` and include `"tap_auto_start": "\(options.tapAutoStart)"` in the `.captureStart` detail (the `record(.captureStart, …)` call in the same function). `options` is otherwise unused until H3 (`SystemTapSession(tapAutoStart:)`, debug drop) and H4 (soft alarm).

`main.swift` (after line 38):
```swift
        service.onFirstFrames = { track in
            DispatchQueue.global(qos: .utility).async { client?.captureDidDeliverFirstFrames?(track: track) }
        }
        service.onAlarmsChanged = { data in
            DispatchQueue.global(qos: .utility).async { client?.captureAlarmsChanged?(snapshot: data) }
        }
```

- [ ] **Step 6: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'RecordingCoordinatorLifecycleTests'` → pass; `python3 scripts/dev.py --build` → clean; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add AudioCaptureProtocol/AudioCaptureProtocol.swift TranscriberCore/RecordingCaptureClient.swift TranscriberCore/RecordingCoordinator.swift TranscriberApp/Services/AudioCaptureClient.swift AudioCaptureHelper/XPC/AudioCaptureService.swift AudioCaptureHelper/XPC/main.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "feat(xpc): capture-reliability protocol surface — captureStatus, configureCapture, systemPowerEvent, first-frames + alarm push; RecordingCaptureClient + fake extended (§6.2, §8.10)"
```

### F gate

Run the Stream gate (full suite, build, `verify-regression-tests.sh 6a9966e`, council over `git diff 6a9966e..HEAD`), then fast-forward `fix/capture-reliability` to `cr/f`. Every other stream except C branches from this point.

---
# Stream C — Pure cores (independent; any number of implementers; start at t=0)

Every C task creates exactly one new `TranscriberCore/<Name>.swift` (C7 and C12 create two) and one new test file, touches nothing else, and can branch from `6a9966e` directly. The only ordering inside C: C5 needs C3 merged (it consumes `TrackLivenessMonitor.Verdict`). Each task's tests are red-first by construction (the type does not exist at the parent). Each task ends with the Stream gate on its own diff (`BASE=$(git merge-base fix/capture-reliability HEAD)`).

### Task C1: `XPCInterruptionPolicy` — crash detection armed per capture generation

**Files:**
- Create: `TranscriberCore/XPCInterruptionPolicy.swift`
- Test: `SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift` (new, red-first: compile error at parent)

**Interfaces:**
- Consumes: `CrashClassification` (`TranscriberCore/CrashReportScanner.swift:5-8`: `.likelyCrash`, `.transientBlip`).
- Produces:
  ```swift
  public struct XPCInterruptionPolicy: Equatable, Sendable {
      public enum Decision: Equatable, Sendable { case ignoreIdle, verifyCapture, briefInterruption, crash }
      public private(set) var captureGeneration: Int
      public private(set) var expectingCapture: Bool
      public init()
      public mutating func captureStarted()
      public mutating func captureStopped()
      public mutating func onInterruption(classification: CrashClassification) -> Decision
      public mutating func onVerified(stillCapturing: Bool, generation: Int) -> Decision
      public mutating func onInvalidation() -> Decision
  }
  ```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// L-N1 (validated lifecycle §2.1): launchd idle-exits the helper ~10 min after the app goes
/// quiet. The client read that as a crash, latched "handled", and never ran recovery again for
/// the life of the process — the 2026-09-24 16:00 recording ran with crash detection disarmed.
@Suite struct XPCInterruptionPolicyTests {

    @Test func idleInterruptionIsIgnoredWithoutPingOrLatch() {
        var p = XPCInterruptionPolicy()
        #expect(p.onInterruption(classification: .transientBlip) == .ignoreIdle)
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.expectingCapture == false)
    }

    /// The exact incident shape: an idle-exit, then a recording starts, then a real crash.
    @Test func crashAfterAnIdleInterruptionStillFires() {
        var p = XPCInterruptionPolicy()
        _ = p.onInterruption(classification: .transientBlip)
        _ = p.onInvalidation()
        p.captureStarted()
        #expect(p.onInterruption(classification: .likelyCrash) == .crash)
    }

    @Test func blipVerifiesThenEscalatesOnceWhenTheHelperIsNotCapturing() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        #expect(p.onInterruption(classification: .transientBlip) == .verifyCapture)
        #expect(p.onVerified(stillCapturing: false, generation: gen) == .crash)
        // The trailing invalidation of the same dead connection must not fire a second recovery.
        #expect(p.onInvalidation() == .ignoreIdle)
    }

    @Test func blipWithTheHelperStillCapturingIsBrief() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        #expect(p.onVerified(stillCapturing: true, generation: gen) == .briefInterruption)
        // Still armed: a later real crash fires.
        #expect(p.onInvalidation() == .crash)
    }

    /// A restart bumped the generation while a verification ping from the old one was in flight.
    @Test func verificationFromAPreviousGenerationIsIgnored() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let old = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        p.captureStarted()
        #expect(p.onVerified(stillCapturing: false, generation: old) == .ignoreIdle)
    }

    @Test func stopDisarms() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        p.captureStopped()
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.onInterruption(classification: .likelyCrash) == .ignoreIdle)
    }

    @Test func aRestartReArmsAfterACrash() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        #expect(p.onInvalidation() == .crash)
        #expect(p.onInvalidation() == .ignoreIdle)   // one recovery per generation
        p.captureStarted()                           // the coordinator's restart
        #expect(p.onInvalidation() == .crash)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$PARLEY_TEST --filter 'XPCInterruptionPolicyTests'` — Expected: compile error, `cannot find 'XPCInterruptionPolicy' in scope`.

- [ ] **Step 3: Implement**

`TranscriberCore/XPCInterruptionPolicy.swift`:
```swift
import Foundation

/// Decides what an XPC interruption or invalidation means, armed per capture generation.
///
/// Why a generation and not a Bool (L-N1): launchd idle-exits the embedded helper ~10 min after
/// its last message. The client's old `crashHandlerFired` latch treated that as "crash handled"
/// and was reset only in `connect()`, which never ran again — so every later real crash was
/// ignored. Arming happens in `captureStarted()` and every decision fires at most once per
/// generation; outside a capture nothing is pinged, latched or spawned.
public struct XPCInterruptionPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Not capturing (an idle-exit), or this generation already escalated: do nothing.
        case ignoreIdle
        /// No crash report: ask the helper whether it is still capturing, then call `onVerified`.
        case verifyCapture
        /// The helper is still capturing — a connection blip, keep recording.
        case briefInterruption
        /// Run crash recovery. Fires at most once per generation.
        case crash
    }

    public private(set) var captureGeneration = 0
    public private(set) var expectingCapture = false
    private var firedGeneration: Int?

    public init() {}

    public mutating func captureStarted() {
        captureGeneration += 1
        expectingCapture = true
    }

    public mutating func captureStopped() {
        expectingCapture = false
    }

    private var alreadyFired: Bool { firedGeneration == captureGeneration }

    public mutating func onInterruption(classification: CrashClassification) -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        if classification == .likelyCrash {
            firedGeneration = captureGeneration
            return .crash
        }
        return .verifyCapture
    }

    public mutating func onVerified(stillCapturing: Bool, generation: Int) -> Decision {
        guard expectingCapture, generation == captureGeneration, !alreadyFired else { return .ignoreIdle }
        if stillCapturing { return .briefInterruption }
        firedGeneration = captureGeneration
        return .crash
    }

    public mutating func onInvalidation() -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        firedGeneration = captureGeneration
        return .crash
    }
}
```

- [ ] **Step 4: Run to verify it passes, commit**

Run: `$PARLEY_TEST --filter 'XPCInterruptionPolicyTests'` — Expected: 7 pass.
```bash
git add TranscriberCore/XPCInterruptionPolicy.swift SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift
git commit -m "feat(xpc): XPCInterruptionPolicy — crash detection armed per capture generation (L-N1)"
```

---

### Task C2: `LaunchAgentHealth` + `LaunchAgentManager` verify/repair

**Files:**
- Create: `TranscriberCore/LaunchAgentHealth.swift`
- Modify: `TranscriberCore/LaunchAgentManager.swift:62-81` (`install`: `bootstrap` instead of `load -w`), `:98-115` (`uninstall`: remove the plist FIRST, then `bootout`), add `programPath(inPlist:)`, `isLoaded(uid:)`, `verifyAndRepair(...)` after `generatePlist` (26-48)
- Test: `SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift` (new, red-first), `SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift` (add one test; red-first: `programPath(inPlist:)` does not exist)

Only C2 and nothing else touches `LaunchAgentManager*.swift`; L2 consumes the API from the app.

**Interfaces:**
```swift
public enum LaunchAgentHealth {
    public enum State: Equatable, Sendable { case healthy, missing, stalePath(found: String), notLoaded }
    public enum Action: Equatable, Sendable { case none, installAndBootstrap, rewriteAndBootstrap, bootstrap }
    public static func assess(plistProgramPath: String?, executablePath: String, loaded: Bool) -> State
    public static func action(for state: State) -> Action
    public static func userMessage(for state: State) -> String?
}
// LaunchAgentManager
public static func programPath(inPlist xml: String) -> String?
public static func isLoaded(uid: uid_t = getuid()) async -> Bool
public static func verifyAndRepair(executablePath: String? = nil, launchAgentsDir: URL? = nil, uid: uid_t = getuid()) async -> LaunchAgentHealth.State
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// L11: the plist existed (mtime Sep 17, path correct) but `launchctl print gui/501/eu.fmasi.parley`
/// said "Could not find service" — Quit's unload removed the job and left the file, and launch
/// only checked the file. Crash protection was off all day, including during the 16:00 recording.
@Suite struct LaunchAgentHealthTests {
    let exe = "/Applications/Parley.app/Contents/MacOS/Parley"

    @Test func loadedWithCurrentPathIsHealthy() {
        #expect(LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: true) == .healthy)
        #expect(LaunchAgentHealth.action(for: .healthy) == .none)
    }

    @Test func missingPlistInstallsAndBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: nil, executablePath: exe, loaded: false)
        #expect(s == .missing)
        #expect(LaunchAgentHealth.action(for: s) == .installAndBootstrap)
    }

    /// The incident: file present, job gone.
    @Test func presentButNotLoadedBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: false)
        #expect(s == .notLoaded)
        #expect(LaunchAgentHealth.action(for: s) == .bootstrap)
    }

    /// The app moved (a Sparkle update into a new path, or a dev build): a loaded job pointing at
    /// the old binary relaunches the wrong app or nothing.
    @Test func stalePathIsRewrittenEvenWhenLoaded() {
        let old = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        let s = LaunchAgentHealth.assess(plistProgramPath: old, executablePath: exe, loaded: true)
        #expect(s == .stalePath(found: old))
        #expect(LaunchAgentHealth.action(for: s) == .rewriteAndBootstrap)
    }

    @Test func onlyUnhealthyStatesHaveAUserMessage() {
        #expect(LaunchAgentHealth.userMessage(for: .healthy) == nil)
        #expect(LaunchAgentHealth.userMessage(for: .notLoaded)?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .stalePath(found: "/x"))?.contains("Crash protection") == true)
    }
}
```
Append to the suite in `LaunchAgentManagerTests.swift`:
```swift
    @Test func programPathIsParsedFromTheGeneratedPlist() {
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: plist) == "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: "<plist><dict></dict></plist>") == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'LaunchAgentHealthTests|LaunchAgentManagerTests'` — Expected: compile errors on `LaunchAgentHealth` and `programPath(inPlist:)`.

- [ ] **Step 3: Implement**

`TranscriberCore/LaunchAgentHealth.swift`:
```swift
import Foundation

/// Pure judgement of the crash-relaunch LaunchAgent (L11). `isInstalled()` used to mean "the plist
/// file exists"; launchd's opinion is what relaunches the app, so the job must be LOADED and must
/// point at the binary that is running.
public enum LaunchAgentHealth {
    public enum State: Equatable, Sendable {
        case healthy
        case missing
        case stalePath(found: String)
        case notLoaded
    }

    public enum Action: Equatable, Sendable {
        case none
        case installAndBootstrap
        case rewriteAndBootstrap
        case bootstrap
    }

    public static func assess(plistProgramPath: String?, executablePath: String, loaded: Bool) -> State {
        guard let plistProgramPath else { return .missing }
        if plistProgramPath != executablePath { return .stalePath(found: plistProgramPath) }
        return loaded ? .healthy : .notLoaded
    }

    public static func action(for state: State) -> Action {
        switch state {
        case .healthy: return .none
        case .missing: return .installAndBootstrap
        case .stalePath: return .rewriteAndBootstrap
        case .notLoaded: return .bootstrap
        }
    }

    /// The sticky row's text; nil when there is nothing to say.
    public static func userMessage(for state: State) -> String? {
        switch state {
        case .healthy: return nil
        case .missing, .notLoaded, .stalePath:
            return "Crash protection is off — if Parley crashes mid-recording it will not relaunch. Quit and reopen Parley to repair it."
        }
    }

    /// Log-safe name: `stalePath` carries a filesystem path, which is never logged `.public`.
    public static func logName(for state: State) -> String {
        switch state {
        case .healthy: return "healthy"
        case .missing: return "missing"
        case .stalePath: return "stalePath"
        case .notLoaded: return "notLoaded"
        }
    }
}
```

In `LaunchAgentManager.swift`, add after `generatePlist` (line 48):
```swift
    /// `ProgramArguments[0]` of a plist string, or nil if absent. Regex on the generated shape:
    /// this manager writes the only plist it ever reads.
    public static func programPath(inPlist xml: String) -> String? {
        let pattern = #"<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r = Range(m.range(at: 1), in: xml) else { return nil }
        return String(xml[r])
    }

    /// Whether launchd currently has the job (`launchctl print gui/<uid>/<label>` exits 0).
    public static func isLoaded(uid: uid_t = getuid()) async -> Bool {
        await runLaunchctl(args: ["print", "gui/\(uid)/\(label)"]) == 0
    }

    /// Judge, repair, and re-judge. Returns the state AFTER repair, so the caller shows the
    /// "crash protection is off" row only when repair failed.
    public static func verifyAndRepair(
        executablePath: String? = nil, launchAgentsDir: URL? = nil, uid: uid_t = getuid()
    ) async -> LaunchAgentHealth.State {
        let exePath = executablePath ?? Bundle.main.executablePath ?? Bundle.main.bundlePath
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)
        func currentPlistPath() -> String? {
            (try? String(contentsOf: plistURL, encoding: .utf8)).flatMap(programPath(inPlist:))
        }
        let state = LaunchAgentHealth.assess(plistProgramPath: currentPlistPath(), executablePath: exePath, loaded: await isLoaded(uid: uid))
        switch LaunchAgentHealth.action(for: state) {
        case .none:
            return state
        case .installAndBootstrap, .rewriteAndBootstrap:
            // A stale job must be booted out first or bootstrap fails with "already loaded".
            _ = await runLaunchctl(args: ["bootout", "gui/\(uid)/\(label)"])
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false)
            _ = await runLaunchctl(args: ["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootstrap:
            _ = await runLaunchctl(args: ["bootstrap", "gui/\(uid)", plistURL.path])
        }
        let after = LaunchAgentHealth.assess(plistProgramPath: currentPlistPath(), executablePath: exePath, loaded: await isLoaded(uid: uid))
        // `stalePath` carries a path: never `.public` (Global Constraints).
        Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → \(LaunchAgentHealth.logName(for: after), privacy: .public)")
        if case .stalePath(let found) = state {
            Logger.config.info("LaunchAgentManager: plist pointed at \(found, privacy: .private)")
        }
        return after
    }
```
- `install(...)` (62-81): replace `["load", "-w", plistURL.path]` (79) with `["bootstrap", "gui/\(getuid())", plistURL.path]`.
- `uninstall(...)` (98-115): remove the plist FIRST, then, if `unloadAgent`, `["bootout", "gui/\(getuid())/\(label)"]` (replaces `unload -w` at 106). Doc comment: "Order matters (gotcha #75): `unload` from a launchd-spawned instance SIGTERMs this process before the removal runs, so the file used to survive." Keep the `unloadAgent` parameter name.

- [ ] **Step 4: Run to verify they pass, commit**

Run: `$PARLEY_TEST --filter 'LaunchAgentHealthTests|LaunchAgentManagerTests'` — Expected: pass (the existing `installWritesPlistFile`/`uninstallRemovesPlistFile` tests use a temp dir and `loadAgent: false`/`unloadAgent: false`; unchanged).
```bash
git add TranscriberCore/LaunchAgentHealth.swift TranscriberCore/LaunchAgentManager.swift SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift
git commit -m "feat(launchagent): LaunchAgentHealth judgement + verifyAndRepair with bootstrap/bootout; plist removed before bootout (L11)"
```

---

### Task C3: `TrackLivenessMonitor` + `OutputActivity`

**Files:**
- Create: `TranscriberCore/TrackLivenessMonitor.swift`, `TranscriberCore/OutputActivity.swift`
- Test: `SwiftTests/TranscriberTests/TrackLivenessMonitorTests.swift`, `SwiftTests/TranscriberTests/OutputActivityTests.swift` (new, red-first)

(`LivenessGapDetector.swift` is deleted by H1, not here — the helper still uses it until H1.)

**Interfaces:**
```swift
public struct TrackLivenessMonitor: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }
    public enum Verdict: Equatable, Sendable {
        case healthy
        case firstFrames                       // first heartbeat after arm(); once per generation
        case neverDelivered(seconds: Double)   // once per episode
        case stalled(seconds: Double)          // once per episode; measured from max(last heartbeat, gate open)
        case cleared(ClearReason)              // the open episode ended
    }
    public let track: String
    public let firstFrameThresholdSeconds: Double   // default 5
    public let stallThresholdSeconds: Double        // default 3
    public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3)
    public mutating func arm(nowNanos: UInt64)      // start / rebuild / wake: a new generation
    public mutating func pause()                    // sleep: nothing judged until arm
    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict
    /// An accelerator reported a stall ahead of the threshold: open the episode so the next tick does
    /// not report the same stall again. Returns false (no-op) when nothing has been delivered this
    /// generation (the never-delivered path owns it) or the monitor is not armed.
    public mutating func openEpisodeExternally() -> Bool
    public var hasOpenEpisode: Bool { get }
}
public enum OutputActivity {
    public struct ProcessOutputState: Equatable, Sendable { public let pid: Int32; public let isRunningOutput: Bool; public let outputDevices: [UInt32]; public init(pid:isRunningOutput:outputDevices:) }
    public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TrackLivenessMonitorTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// H1 / L2 / L-N2: a track that NEVER delivers was invisible — `LivenessGapDetector` refused to
/// judge `lastArrivalNanos == 0`, `PadRatioMonitor.finish()` needed a rate it only learned from a
/// frame, and `trackNeverDelivered` could not fire in production. Incident B (2026-09-24, 46 min,
/// 0 callbacks while WebKit ran output) is the end-to-end proof.
@Suite struct TrackLivenessMonitorTests {
    private func ns(_ s: Double) -> UInt64 { UInt64(s * 1_000_000_000) }

    @Test func nothingIsJudgedBeforeArm() {
        var m = TrackLivenessMonitor(track: "system")
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
    }

    /// Incident B: armed, gate open (another process running output), no callback ever.
    @Test func expectedButNeverDeliveredFiresOnceAfterTheFirstFrameThreshold() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(10))
        #expect(m.check(nowNanos: ns(14), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(15), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
        #expect(m.check(nowNanos: ns(16), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)   // once
        #expect(m.hasOpenEpisode)
    }

    /// Gotcha #66: recording started before the call — nothing is expected until the gate opens,
    /// and the clock starts when it opens, not when capture started.
    @Test func gateClosedIsNeverAFaultAndTheClockStartsAtGateOpen() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(600), lastHeartbeatNanos: 0, gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(601), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(605), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(606), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func firstHeartbeatAfterArmIsReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true) == .firstFrames)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(1.9), gateOpen: true) == .healthy)
    }

    /// A heartbeat from BEFORE the arm is the previous generation's: a rebuild that never resumes
    /// is a never-delivered on the new generation, not a healthy track (the #86 false-success shape).
    @Test func heartbeatFromThePreviousGenerationDoesNotCount() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)   // delivering
        m.arm(nowNanos: ns(50))                                                       // rebuild
        #expect(m.check(nowNanos: ns(55), lastHeartbeatNanos: ns(49), gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func deliveredThenSilentIsAStallReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        var fired = 0
        for t in stride(from: 2.0, through: 30.0, by: 1.0) {
            if case .stalled = m.check(nowNanos: ns(t), lastHeartbeatNanos: ns(1), gateOpen: true) { fired += 1 }
        }
        #expect(fired == 1)
    }

    @Test func aHeartbeatClearsTheEpisodeAndReArmsIt() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 4))
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
        #expect(!m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(6), gateOpen: true) == .stalled(seconds: 4))
    }

    @Test func gateClosingClearsAnOpenEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true)   // neverDelivered
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: 0, gateOpen: false) == .cleared(.gateClosed))
    }

    /// Review focus 1: a call app toggling its output IO every second must not produce a report
    /// per flap. Only a gap that has been continuously open for the threshold is reported.
    @Test func gateFlapReportsAtMostOncePerEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0
        for t in 1...40 {
            let open = t % 2 == 0
            if case .neverDelivered = m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) { reports += 1 }
        }
        #expect(reports == 0, "the gate never stayed open for 5 s, so nothing was expected for 5 s")
    }

    /// Spec §4.2 (scan C5): "no heartbeat for stallThreshold WHILE THE GATE IS OPEN". Under
    /// tap_auto_start=true a call app resuming output after a minute of idle must not be judged
    /// stalled by 60 s on the first open tick: the stall clock starts at the gate opening.
    @Test func stallIsMeasuredFromGateOpenNotFromTheLastHeartbeat() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true) == .firstFrames)
        for t in 2...60 {
            #expect(m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy)
        }
        #expect(m.check(nowNanos: ns(61), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(63), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(64), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 3))
    }

    /// Spec §4.2 (scan C5): each gate-open period ≥ threshold over a still-dead track is one episode.
    @Test func aSlowGateFlapOverADeadTrackReportsOncePerOpenPeriod() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0, cleared = 0
        for t in 1...40 {
            let open = (t / 10) % 2 == 0   // 10 s open, 10 s closed, …
            switch m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) {
            case .neverDelivered: reports += 1
            case .cleared(.gateClosed): cleared += 1
            default: break
            }
        }
        #expect(reports == 2 && cleared == 2)
    }

    /// Review focus 3: heartbeats are stamped on the audio queue and read on the watchdog queue.
    @Test func heartbeatInTheFutureIsHealthy() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(2.5), gateOpen: true) == .healthy)
    }

    @Test func pauseSuspendsJudgementUntilTheNextArm() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        m.pause()
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        m.arm(nowNanos: ns(100))
        #expect(m.check(nowNanos: ns(105), lastHeartbeatNanos: ns(1), gateOpen: true) == .neverDelivered(seconds: 5))
    }

    /// Scan A26: an aggregate listener lets the driver report a stall 1 s after the event, before the
    /// 3 s threshold. That early report opens the episode, so the monitor's own tick two seconds
    /// later does not report the same stall a second time; the heartbeat still clears it.
    @Test func anExternallyOpenedEpisodeIsNotReportedAgainAndClearsOnHeartbeat() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        #expect(m.openEpisodeExternally())
        #expect(m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy, "already reported by the accelerator")
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
    }

    @Test func anExternalStallBeforeAnyHeartbeatIsRefused() {
        var m = TrackLivenessMonitor(track: "system")
        m.arm(nowNanos: ns(0))
        #expect(m.openEpisodeExternally() == false, "never-delivered owns a track that has not delivered")
        var unarmed = TrackLivenessMonitor(track: "system")
        #expect(unarmed.openEpisodeExternally() == false)
    }
}
```

`SwiftTests/TranscriberTests/OutputActivityTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// Q4.1 / H3b: the "is anything playing?" gate must be process-level and must exclude the helper
/// itself — the probe showed our own anchor-only aggregate reports `IsRunningOutput = 1`, and a
/// process on a non-default device is invisible to the old default-output check.
@Suite struct OutputActivityTests {
    typealias P = OutputActivity.ProcessOutputState

    @Test func nobodyRunningOutputIsClosed() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 10, isRunningOutput: false, outputDevices: [])], ownPid: 99) == false)
    }

    @Test func anotherProcessRunningOutputOpensTheGateWhateverTheDevice() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 2430, isRunningOutput: true, outputDevices: [84])], ownPid: 99))
    }

    /// run-own-aggregate.txt: pid 37097 (our probe) reported piro=1 outDevs=[84].
    @Test func ourOwnAggregateNeverOpensTheGate() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 99, isRunningOutput: true, outputDevices: [84])], ownPid: 99) == false)
    }

    @Test func emptyListIsClosed() {
        #expect(OutputActivity.othersRunningOutput([], ownPid: 99) == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'TrackLivenessMonitorTests|OutputActivityTests'` — Expected: compile errors.

- [ ] **Step 3: Implement the two cores**

`TranscriberCore/TrackLivenessMonitor.swift`:
```swift
import Foundation

/// Pure decision core of the 1 Hz off-audio-queue liveness watchdog, per track (§4.2).
///
/// Judges the HEARTBEAT (the OS calling our audio callback), not the content, from the moment
/// `arm()` says "expect frames from here": capture start, every tap/mic rebuild, every wake.
/// Unlike its predecessor it judges a track that has never delivered — that was Incident B.
/// Both thresholds count only time during which the gate was open (§4.2): the never-delivered clock
/// starts at max(arm, gate open); the stall clock at max(last heartbeat, gate open).
public struct TrackLivenessMonitor: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }

    public enum Verdict: Equatable, Sendable {
        case healthy
        case firstFrames
        case neverDelivered(seconds: Double)
        case stalled(seconds: Double)
        case cleared(ClearReason)
    }

    public let track: String
    public let firstFrameThresholdSeconds: Double
    public let stallThresholdSeconds: Double

    private var armedAtNanos: UInt64?
    /// When the gate was last seen opening. Tracks the GATE, not the generation: an arm() while the
    /// gate is already open must judge from the arm time, not from the next tick.
    private var gateOpenSinceNanos: UInt64?
    private var gateObservedThisGeneration = false
    private var heartbeatSeenThisGeneration = false
    private var firstFramesReported = false
    private var episodeOpen = false

    public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3) {
        self.track = track
        self.firstFrameThresholdSeconds = firstFrameThresholdSeconds
        self.stallThresholdSeconds = stallThresholdSeconds
    }

    public var hasOpenEpisode: Bool { episodeOpen }

    public mutating func arm(nowNanos: UInt64) {
        armedAtNanos = nowNanos
        gateObservedThisGeneration = false
        heartbeatSeenThisGeneration = false
        firstFramesReported = false
        episodeOpen = false
    }

    public mutating func pause() {
        armedAtNanos = nil
        episodeOpen = false
    }

    public mutating func openEpisodeExternally() -> Bool {
        guard armedAtNanos != nil, heartbeatSeenThisGeneration, !episodeOpen else { return false }
        episodeOpen = true
        return true
    }

    private static func seconds(from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / 1e9 : 0   // a stamp newer than "now" (two queues) is 0, never negative
    }

    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict {
        guard let armedAt = armedAtNanos else { return .healthy }
        guard gateOpen else {
            gateOpenSinceNanos = nil
            gateObservedThisGeneration = true
            if episodeOpen { episodeOpen = false; return .cleared(.gateClosed) }
            return .healthy
        }
        // First observation after an arm with the gate already open: it was open at the arm (the
        // tick is 1 Hz, so this is at most 1 s pessimistic). A closed→open transition starts now.
        if gateOpenSinceNanos == nil { gateOpenSinceNanos = gateObservedThisGeneration ? nowNanos : armedAt }
        gateObservedThisGeneration = true
        let gateOpenSince = gateOpenSinceNanos ?? armedAt

        if lastHeartbeatNanos > armedAt {
            // This generation has delivered.
            heartbeatSeenThisGeneration = true
            let sinceHeartbeat = Self.seconds(from: lastHeartbeatNanos, to: nowNanos)
            if episodeOpen, sinceHeartbeat < stallThresholdSeconds { episodeOpen = false; return .cleared(.heartbeat) }
            if !firstFramesReported { firstFramesReported = true; return .firstFrames }
            let silentWhileExpected = Self.seconds(from: max(lastHeartbeatNanos, gateOpenSince), to: nowNanos)
            if silentWhileExpected >= stallThresholdSeconds, !episodeOpen {
                episodeOpen = true
                return .stalled(seconds: silentWhileExpected)
            }
            return .healthy
        }

        let waited = Self.seconds(from: max(armedAt, gateOpenSince), to: nowNanos)
        if waited >= firstFrameThresholdSeconds, !episodeOpen {
            episodeOpen = true
            return .neverDelivered(seconds: waited)
        }
        return .healthy
    }
}
```

`TranscriberCore/OutputActivity.swift`:
```swift
import Foundation

/// "Is any OTHER process rendering output right now?" — the only "expected to produce" rule for
/// the tap (§4.3). Process-level, so it is route-independent and sees per-app output devices;
/// excludes our own pid because the helper's own aggregate reports itself as running output.
public enum OutputActivity {
    public struct ProcessOutputState: Equatable, Sendable {
        public let pid: Int32
        public let isRunningOutput: Bool
        public let outputDevices: [UInt32]
        public init(pid: Int32, isRunningOutput: Bool, outputDevices: [UInt32]) {
            self.pid = pid; self.isRunningOutput = isRunningOutput; self.outputDevices = outputDevices
        }
    }

    public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool {
        states.contains { $0.pid != ownPid && $0.isRunningOutput }
    }
}
```

- [ ] **Step 4: Run to verify they pass, commit**

Run: `$PARLEY_TEST --filter 'TrackLivenessMonitorTests|OutputActivityTests'` — Expected: 19 pass.
```bash
git add TranscriberCore/TrackLivenessMonitor.swift TranscriberCore/OutputActivity.swift SwiftTests/TranscriberTests/TrackLivenessMonitorTests.swift SwiftTests/TranscriberTests/OutputActivityTests.swift
git commit -m "feat(liveness): TrackLivenessMonitor (never-delivered, stall measured while the gate is open) + process-level OutputActivity gate (H1, L2, Q4.1, §4.2)"
```

---

### Task C4: `TapRecoveryLadder` — rungs, backoff, budget, slow retry, tokens, gate close

**Files:**
- Create: `TranscriberCore/TapRecoveryLadder.swift`
- Test: `SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift` (new, red-first)

**Interfaces:**
```swift
public struct TapRecoveryLadder: Equatable, Sendable {
    public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }
    public enum Trigger: Equatable, Sendable {
        case stalled, neverDelivered, listenerStopped, wake, rebuildFailed,
             serviceRestarted, permissionGrant, permissionInsurance
    }
    public enum Action: Equatable, Sendable {
        case none
        case run(Rung, token: Int, afterSeconds: Double)   // token identifies THIS run; results are matched on it
        case awaitHeartbeat(seconds: Double)
        case giveUp(retryAfterSeconds: Double)
    }
    public static let backoff: [Double]                // [0.25, 0.5, 1, 2] between ladder attempts
    public static let fastWindowSeconds: Double        // 15
    public static let heartbeatDeadlineSeconds: Double // 3
    public static let slowRetrySeconds: Double         // 60
    public static let rungBudget: Int                  // 2 per rung per episode
    public private(set) var inFlight: Rung?
    public private(set) var inFlightToken: Int?
    public private(set) var awaitingHeartbeat: Bool
    public private(set) var exhausted: Bool
    public private(set) var totalRebuilds: Int
    public init()
    public mutating func trigger(_ t: Trigger, now: Double) -> Action
    public mutating func rungCompleted(token: Int, succeeded: Bool, now: Double) -> Action   // a mismatched token → .none
    public mutating func noteExternalRebuild(now: Double) -> Action    // output-change / rate-drift rebuild: counts against the budget, completes nothing
    public mutating func heartbeatObserved() -> Action
    public mutating func heartbeatDeadlineMissed(now: Double) -> Action
    public mutating func slowRetryDue(now: Double) -> Action
    public mutating func gateClosed() -> Action                        // the track is no longer expected: episode over, un-exhaust
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// §5: a silent tap is rebuilt — aggregate first, then the whole tap — with backoff and a budget,
/// then alarmed, then retried slowly. Incident B had the rebuild code; nothing ever triggered it,
/// and one thrown rebuild was permanent (`onUnavailable`).
@Suite struct TapRecoveryLadderTests {
    typealias L = TapRecoveryLadder

    @Test func firstTriggerRunsAnAggregateRebuildImmediately() {
        var l = L()
        #expect(l.trigger(.stalled, now: 0) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
        #expect(l.inFlight == .rebuildAggregate && l.inFlightToken == 1)
    }

    /// Review focus 4: an aggregate listener and a monitor verdict describe the same stall.
    @Test func secondTriggerWhileARungIsInFlightIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.listenerStopped, now: 0.1) == .none)
        #expect(l.trigger(.neverDelivered, now: 0.2) == .none)
        #expect(l.totalRebuilds == 1)
    }

    @Test func aSuccessfulRungWaitsForAHeartbeat() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        #expect(l.trigger(.stalled, now: 1) == .none, "already waiting; a verdict must not start a second rebuild")
    }

    @Test func aHeartbeatClosesTheEpisode() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.4)
        #expect(l.heartbeatObserved() == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat && !l.exhausted)
        #expect(l.trigger(.stalled, now: 100) == .run(.rebuildAggregate, token: 2, afterSeconds: 0), "a later, separate stall starts a fresh episode")
    }

    @Test func missedHeartbeatBacksOffThenEscalatesToTheTapRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        #expect(l.heartbeatDeadlineMissed(now: 3.3) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
        _ = l.rungCompleted(token: 2, succeeded: true, now: 3.9)
        #expect(l.heartbeatDeadlineMissed(now: 6.9) == .run(.rebuildTap, token: 3, afterSeconds: 0.5))
        _ = l.rungCompleted(token: 3, succeeded: true, now: 7.6)
        #expect(l.heartbeatDeadlineMissed(now: 10.6) == .run(.rebuildTap, token: 4, afterSeconds: 1))
    }

    @Test func aThrownRungMovesOnAfterBackoff() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: false, now: 0.2) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
    }

    private func exhaust(_ l: inout L) {
        _ = l.trigger(.stalled, now: 0)
        for _ in 0..<4 {
            _ = l.rungCompleted(token: l.inFlightToken!, succeeded: true, now: 1)
            _ = l.heartbeatDeadlineMissed(now: 4)
        }
    }

    @Test func budgetExhaustedGivesUpWithASlowRetry() {
        var l = L()
        exhaust(&l)
        #expect(l.exhausted)
        #expect(l.trigger(.stalled, now: 5) == .none, "exhausted: the slow retry owns it")
        #expect(l.slowRetryDue(now: 65) == .run(.rebuildTap, token: 5, afterSeconds: 0))
        #expect(l.rungCompleted(token: 5, succeeded: false, now: 66) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
        #expect(l.exhausted)
    }

    @Test func giveUpActionCarriesTheSlowRetryInterval() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        var last: L.Action = .none
        for _ in 0..<4 {
            _ = l.rungCompleted(token: l.inFlightToken!, succeeded: true, now: 1)
            last = l.heartbeatDeadlineMissed(now: 4)
        }
        #expect(last == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    @Test func aFastWindowTimeoutGivesUpEvenWithBudgetLeft() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.5)
        #expect(l.heartbeatDeadlineMissed(now: 20) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// coreaudiod restart: every id is dead, nothing below a new tap can help.
    @Test func serviceRestartedJumpsStraightToANewTap() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.serviceRestarted, now: 0.1) == .run(.rebuildTap, token: 2, afterSeconds: 0))
    }

    /// The old rung's result arriving after a service restart must not complete the new rung.
    @Test func aStaleRungResultAfterAServiceRestartIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1
        _ = l.trigger(.serviceRestarted, now: 0.1)                        // token 2
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.3) == .none)
        #expect(l.inFlight == .rebuildTap && l.inFlightToken == 2)
    }

    /// Review focus 4 (scan A66/C9): an output-device rebuild completing while a ladder rung is in
    /// flight is NOT the rung's result — results are matched by token — but it does count against
    /// the episode's budget (§5: "their rebuilds report into the same ladder budget").
    @Test func anOffLadderRebuildResultDoesNotCompleteTheRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1 in flight
        #expect(l.rungCompleted(token: 0, succeeded: true, now: 0.2) == .none)
        #expect(l.inFlight == .rebuildAggregate, "still waiting for token 1")
        #expect(l.noteExternalRebuild(now: 0.2) == .none)
        #expect(l.totalRebuilds == 2)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        // The external rebuild used one of the two aggregate attempts: the next miss escalates to the tap rung.
        #expect(l.heartbeatDeadlineMissed(now: 3.4) == .run(.rebuildTap, token: 2, afterSeconds: 0.25))
    }

    @Test func anExternalRebuildOutsideAnEpisodeCostsNoBudget() {
        var l = L()
        _ = l.noteExternalRebuild(now: 0)
        #expect(l.totalRebuilds == 1)
        _ = l.trigger(.stalled, now: 10)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 10.3)
        #expect(l.heartbeatDeadlineMissed(now: 13.3) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25), "both aggregate attempts still available")
    }

    /// Spec §5 (scan C10): the slow retry runs only while the gate stays open; when the gate closes
    /// the episode ends, and a still-dead tap when it reopens gets a fresh fast episode, not a 60 s wait.
    @Test func gateClosedResetsAnExhaustedLadder() {
        var l = L()
        exhaust(&l)
        #expect(l.exhausted)
        #expect(l.gateClosed() == .none)
        #expect(!l.exhausted && l.inFlight == nil && !l.awaitingHeartbeat)
        #expect(l.trigger(.neverDelivered, now: 100) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    /// A grant reaches only a tap built after it: never budgeted, never delayed, even when exhausted.
    @Test func permissionGrantRunsEvenWhenExhausted() {
        var l = L()
        exhaust(&l)
        #expect(l.trigger(.permissionGrant, now: 5) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    /// The grey zone's insurance rebuild: once, only when nothing else is going on.
    @Test func permissionInsuranceRunsOnlyOnAQuietLadder() {
        var l = L()
        #expect(l.trigger(.permissionInsurance, now: 0) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        _ = l.heartbeatObserved()
        var busy = L()
        _ = busy.trigger(.stalled, now: 0)
        #expect(busy.trigger(.permissionInsurance, now: 0.1) == .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'TapRecoveryLadderTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/TapRecoveryLadder.swift`:
```swift
import Foundation

/// The tap's healing ladder (§5). Pure: fed triggers, rung results and heartbeat timing; answers
/// with the one thing to do next. The helper's `TapHealer` runs the rungs and the timers.
///
/// Every `.run` carries a token; `SystemTapSession.rebuild(rung:token:reason:)` echoes it back in
/// `onRebuildResult`, so a rebuild the ladder did not order (output-device change, rate drift —
/// token 0) can never be mistaken for a rung's result. Those still count against the budget through
/// `noteExternalRebuild`.
public struct TapRecoveryLadder: Equatable, Sendable {
    public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }

    public enum Trigger: Equatable, Sendable {
        case stalled, neverDelivered, listenerStopped, wake, rebuildFailed
        case serviceRestarted, permissionGrant, permissionInsurance
    }

    public enum Action: Equatable, Sendable {
        case none
        case run(Rung, token: Int, afterSeconds: Double)
        case awaitHeartbeat(seconds: Double)
        case giveUp(retryAfterSeconds: Double)
    }

    public static let backoff: [Double] = [0.25, 0.5, 1, 2]
    public static let fastWindowSeconds: Double = 15
    public static let heartbeatDeadlineSeconds: Double = 3
    public static let slowRetrySeconds: Double = 60
    public static let rungBudget = 2

    private var episodeStartedAt: Double?
    /// Attempts per rung this episode: ladder runs AND external rebuilds (the budget).
    private var attempts: [Rung: Int] = [:]
    /// Ladder runs this episode (the backoff index).
    private var ladderRuns = 0
    private var nextToken = 1
    public private(set) var inFlight: Rung?
    public private(set) var inFlightToken: Int?
    public private(set) var awaitingHeartbeat = false
    public private(set) var exhausted = false
    public private(set) var totalRebuilds = 0

    public init() {}

    public mutating func trigger(_ t: Trigger, now: Double) -> Action {
        switch t {
        case .serviceRestarted:
            reset()
            episodeStartedAt = now
            return start(.rebuildTap, delay: 0)
        case .permissionGrant:
            if inFlight != nil { return .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            awaitingHeartbeat = false
            return start(.rebuildAggregate, delay: 0)
        case .permissionInsurance:
            guard inFlight == nil, !awaitingHeartbeat, !exhausted, episodeStartedAt == nil else { return .none }
            episodeStartedAt = now
            return start(.rebuildAggregate, delay: 0)
        case .stalled, .neverDelivered, .listenerStopped, .wake, .rebuildFailed:
            if inFlight != nil || awaitingHeartbeat { return .none }
            if exhausted { return t == .rebuildFailed ? .giveUp(retryAfterSeconds: Self.slowRetrySeconds) : .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            return nextRung(now: now)
        }
    }

    public mutating func rungCompleted(token: Int, succeeded: Bool, now: Double) -> Action {
        guard let rung = inFlight, inFlightToken == token else { return .none }
        inFlight = nil
        inFlightToken = nil
        if succeeded {
            awaitingHeartbeat = true
            return .awaitHeartbeat(seconds: Self.heartbeatDeadlineSeconds)
        }
        _ = rung
        return trigger(.rebuildFailed, now: now)
    }

    /// A rebuild the ladder did not order finished (output-device change, rate drift, permission
    /// grant from the app). It reports into the same budget (§5) but never completes a rung.
    public mutating func noteExternalRebuild(now: Double) -> Action {
        totalRebuilds += 1
        if episodeStartedAt != nil { attempts[.rebuildAggregate, default: 0] += 1 }
        return .none
    }

    public mutating func heartbeatObserved() -> Action {
        reset()
        return .none
    }

    public mutating func heartbeatDeadlineMissed(now: Double) -> Action {
        guard awaitingHeartbeat else { return .none }
        awaitingHeartbeat = false
        return nextRung(now: now)
    }

    public mutating func slowRetryDue(now: Double) -> Action {
        guard exhausted, inFlight == nil else { return .none }
        inFlight = .rebuildTap
        inFlightToken = nextToken
        nextToken += 1
        totalRebuilds += 1
        return .run(.rebuildTap, token: inFlightToken!, afterSeconds: 0)
    }

    /// The track is no longer expected (§4.3): the episode ends. An exhausted ladder is
    /// un-exhausted so a still-dead tap gets a fresh fast episode when the gate reopens (scan C10).
    public mutating func gateClosed() -> Action {
        reset()
        return .none
    }

    private mutating func nextRung(now: Double) -> Action {
        if ladderRuns > 0, now - (episodeStartedAt ?? now) > Self.fastWindowSeconds { return giveUp() }
        let rung: Rung
        if (attempts[.rebuildAggregate] ?? 0) < Self.rungBudget { rung = .rebuildAggregate }
        else if (attempts[.rebuildTap] ?? 0) < Self.rungBudget { rung = .rebuildTap }
        else { return giveUp() }
        let delay = ladderRuns == 0 ? 0 : Self.backoff[min(ladderRuns - 1, Self.backoff.count - 1)]
        return start(rung, delay: delay)
    }

    private mutating func start(_ rung: Rung, delay: Double) -> Action {
        inFlight = rung
        inFlightToken = nextToken
        nextToken += 1
        attempts[rung, default: 0] += 1
        ladderRuns += 1
        totalRebuilds += 1
        return .run(rung, token: inFlightToken!, afterSeconds: delay)
    }

    private mutating func giveUp() -> Action {
        inFlight = nil
        inFlightToken = nil
        awaitingHeartbeat = false
        exhausted = true
        return .giveUp(retryAfterSeconds: Self.slowRetrySeconds)
    }

    private mutating func reset() {
        episodeStartedAt = nil
        attempts = [:]
        ladderRuns = 0
        inFlight = nil
        inFlightToken = nil
        awaitingHeartbeat = false
        exhausted = false
    }
}
```

- [ ] **Step 4: Run to verify it passes, commit**

Run: `$PARLEY_TEST --filter 'TapRecoveryLadderTests'` — Expected: 16 pass.
```bash
git add TranscriberCore/TapRecoveryLadder.swift SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift
git commit -m "feat(tap): TapRecoveryLadder — rungs, backoff, budget, slow retry, run tokens, gate-close reset (Q4.3, H5, §5)"
```

---

### Task C5: `MicHealPolicy` (after C3 merged)

**Files:**
- Create: `TranscriberCore/MicHealPolicy.swift`
- Test: `SwiftTests/TranscriberTests/MicHealPolicyTests.swift` (new, red-first)

**Interfaces:**
```swift
public struct MicHealPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, alarm, clear, none }
    public init()
    public mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict) -> Action
    public mutating func healFailed() -> Action     // MicCaptureSession.onUnavailable: no second verdict will come → .alarm
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/MicHealPolicyTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// H4 (mic side of §5): a silent mic is rebuilt first; the alarm comes only if that did not bring
/// frames back. `MicCaptureSession.attemptRecover()` has always existed; nothing called it for a
/// silent-but-not-errored session.
@Suite struct MicHealPolicyTests {
    @Test func firstSilenceHealsWithoutAlarming() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func silenceAfterAHealAttemptAlarmsAndHealsAgain() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .healAndAlarm)
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func framesClearTheEpisode() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.firstFrames) == .clear)
        #expect(p.onVerdict(.stalled(seconds: 3)) == .heal)
    }
    /// Scan C11: a heal whose restart budget is exhausted never re-arms the monitor, so no second
    /// verdict arrives — the alarm must come from the failure itself.
    @Test func aHealThatExhaustsItsBudgetAlarmsWithoutASecondVerdict() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.neverDelivered(seconds: 5))
        #expect(p.healFailed() == .alarm)
        #expect(p.onVerdict(.cleared(.heartbeat)) == .clear)
    }
    @Test func healthyIsNothing() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.healthy) == .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'MicHealPolicyTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/MicHealPolicy.swift`:
```swift
import Foundation

/// Mic side of "heal, then alarm" (§5, §6.1): the first silence verdict of an episode rebuilds the
/// AVCaptureSession; a second, still silent, alarms as well. A heal that reports its restart budget
/// exhausted alarms at once (no re-arm → no second verdict). Frames end the episode.
public struct MicHealPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, alarm, clear, none }
    private var healsThisEpisode = 0
    public init() {}

    public mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict) -> Action {
        switch v {
        case .neverDelivered, .stalled:
            healsThisEpisode += 1
            return healsThisEpisode == 2 ? .healAndAlarm : .heal
        case .cleared, .firstFrames:
            healsThisEpisode = 0
            return .clear
        case .healthy:
            return .none
        }
    }

    public mutating func healFailed() -> Action {
        healsThisEpisode = max(healsThisEpisode, 2)
        return .alarm
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'MicHealPolicyTests'` — Expected: 5 pass.
```bash
git add TranscriberCore/MicHealPolicy.swift SwiftTests/TranscriberTests/MicHealPolicyTests.swift
git commit -m "feat(mic): MicHealPolicy — heal first, alarm on the second silent verdict or an exhausted heal (H4, §6.1)"
```

---

### Task C6: `TrackAccounting` — per-track coverage and status

**Files:**
- Create: `TranscriberCore/TrackAccounting.swift`
- Test: `SwiftTests/TranscriberTests/TrackAccountingTests.swift` (new, red-first)

**Interfaces:**
```swift
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }
    public var expectedSeconds: Double, heartbeatCallbacks: Int, deliveredSeconds: Double, exactZeroSeconds: Double,
               paddedSeconds: Double, longestGapSeconds: Double, gapCount: Int, rebuilds: Int
    public init()
    public static let minimumDeficitSeconds: Double   // 15
    public static let deficitRatio: Double            // 0.10
    public func status(isTap: Bool, contentAnomalies: Int) -> Status
    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting)
    public func asDetail(prefix: String) -> [String: String]     // "remote_expected_seconds": "12.3", …
    public init?(detail: [String: String], prefix: String)
    public func asMetadataDictionary(status: Status) -> [String: Any]  // snake_case + "status"
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TrackAccountingTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// §7.1: the record says per side how much was expected and delivered. Incident B's provenance
/// said `system_delivered_seconds 0, anomaly_count 0` and nothing about 2736 s of expected output.
@Suite struct TrackAccountingTests {
    @Test func nothingExpectedNothingDeliveredIsIdleForTheTap() {
        var a = TrackAccounting()
        a.expectedSeconds = 0.4
        #expect(a.status(isTap: true, contentAnomalies: 0) == .idle)
        #expect(a.status(isTap: false, contentAnomalies: 0) == .healthy, "the mic is always expected; a 0.4 s session is just short")
    }

    /// Incident B.
    @Test func expectedButNeverDeliveredIsNeverDelivered() {
        var a = TrackAccounting()
        a.expectedSeconds = 2736
        #expect(a.status(isTap: true, contentAnomalies: 0) == .neverDelivered)
    }

    @Test func aDeficitOfTenPercentAndFifteenSecondsIsCompromised() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 84
        #expect(a.status(isTap: true, contentAnomalies: 0) == .compromised)
        a.deliveredSeconds = 91
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "9 % short: within tolerance")
        a.expectedSeconds = 60; a.deliveredSeconds = 50
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "10 s short: under the 15 s floor")
    }

    @Test func aContentAnomalyIsCompromisedRegardlessOfCoverage() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 100
        #expect(a.status(isTap: false, contentAnomalies: 1) == .compromised)
    }

    /// Review focus 5: the probe failed open / TapAutoStart=false zeros — frames without a gate.
    @Test func deliveredWithNothingExpectedIsHealthyNotIdle() {
        var a = TrackAccounting()
        a.deliveredSeconds = 30
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy)
    }

    @Test func detailRoundTripsAndSums() throws {
        var a = TrackAccounting()
        a.expectedSeconds = 10; a.deliveredSeconds = 9.5; a.exactZeroSeconds = 1; a.paddedSeconds = 0.5
        a.longestGapSeconds = 3; a.gapCount = 1; a.rebuilds = 2; a.heartbeatCallbacks = 940
        let back = try #require(TrackAccounting(detail: a.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(back == a)
        var sum = a; sum += back
        #expect(sum.expectedSeconds == 20 && sum.rebuilds == 4 && sum.longestGapSeconds == 3)
        #expect(TrackAccounting(detail: [:], prefix: "remote") == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'TrackAccountingTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/TrackAccounting.swift`:
```swift
import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }

    public var expectedSeconds: Double = 0
    public var heartbeatCallbacks: Int = 0
    public var deliveredSeconds: Double = 0
    public var exactZeroSeconds: Double = 0
    public var paddedSeconds: Double = 0
    public var longestGapSeconds: Double = 0
    public var gapCount: Int = 0
    public var rebuilds: Int = 0

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    /// `contentAnomalies` is the count of CONTENT-compromising events on this track (rate drift,
    /// exact-zero mic, permission denied, converter failure, write failure, sustained format drop) —
    /// never healed liveness events (scan C12); `makeProvenance` (E1) computes it.
    public func status(isTap: Bool, contentAnomalies: Int) -> Status {
        if contentAnomalies > 0 { return .compromised }
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 5, deliveredSeconds == 0 { return .neverDelivered }
        let deficit = expectedSeconds - deliveredSeconds
        if expectedSeconds > 0, deficit >= Self.minimumDeficitSeconds, deficit / expectedSeconds >= Self.deficitRatio {
            return .compromised
        }
        return .healthy
    }

    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting) {
        lhs.expectedSeconds += rhs.expectedSeconds
        lhs.heartbeatCallbacks += rhs.heartbeatCallbacks
        lhs.deliveredSeconds += rhs.deliveredSeconds
        lhs.exactZeroSeconds += rhs.exactZeroSeconds
        lhs.paddedSeconds += rhs.paddedSeconds
        lhs.longestGapSeconds = max(lhs.longestGapSeconds, rhs.longestGapSeconds)
        lhs.gapCount += rhs.gapCount
        lhs.rebuilds += rhs.rebuilds
    }

    private static let keys = ["expected_seconds", "heartbeat_callbacks", "delivered_seconds", "exact_zero_seconds",
                               "padded_seconds", "longest_gap_seconds", "gap_count", "rebuilds"]

    public func asDetail(prefix: String) -> [String: String] {
        let values: [String] = [String(format: "%.1f", expectedSeconds), "\(heartbeatCallbacks)", String(format: "%.1f", deliveredSeconds),
                                String(format: "%.1f", exactZeroSeconds), String(format: "%.1f", paddedSeconds),
                                String(format: "%.1f", longestGapSeconds), "\(gapCount)", "\(rebuilds)"]
        return Dictionary(uniqueKeysWithValues: zip(Self.keys.map { "\(prefix)_\($0)" }, values))
    }

    public init?(detail: [String: String], prefix: String) {
        guard let e = detail["\(prefix)_expected_seconds"].flatMap(Double.init) else { return nil }
        expectedSeconds = e
        heartbeatCallbacks = detail["\(prefix)_heartbeat_callbacks"].flatMap(Int.init) ?? 0
        deliveredSeconds = detail["\(prefix)_delivered_seconds"].flatMap(Double.init) ?? 0
        exactZeroSeconds = detail["\(prefix)_exact_zero_seconds"].flatMap(Double.init) ?? 0
        paddedSeconds = detail["\(prefix)_padded_seconds"].flatMap(Double.init) ?? 0
        longestGapSeconds = detail["\(prefix)_longest_gap_seconds"].flatMap(Double.init) ?? 0
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
    }

    public func asMetadataDictionary(status: Status) -> [String: Any] {
        ["status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
         "exact_zero_seconds": exactZeroSeconds, "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds,
         "gap_count": gapCount, "rebuilds": rebuilds, "heartbeat_callbacks": heartbeatCallbacks]
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'TrackAccountingTests'` — Expected: 6 pass.
```bash
git add TranscriberCore/TrackAccounting.swift SwiftTests/TranscriberTests/TrackAccountingTests.swift
git commit -m "feat(provenance): TrackAccounting — per-track coverage counters and status (§7.1)"
```

---

### Task C7: `RelaunchDecision` + `BootSession`

**Files:**
- Create: `TranscriberCore/RelaunchDecision.swift`, `TranscriberCore/BootSession.swift`
- Test: `SwiftTests/TranscriberTests/RelaunchDecisionTests.swift` (new, red-first; includes one `BootSession` test)

**Interfaces:**
```swift
public enum BootSession { public static func currentUUID() -> String? }   // sysctl kern.bootsessionuuid
public enum RelaunchDecision: Equatable, Sendable {
    case reattach                                   // helper still capturing
    case resumeSameSession(gapStart: Date)          // helper dead, sentinel fresh (≤ resumeWindow)
    case salvageAndStop(reason: Reason)             // helper dead: sentinel old / no liveness / was stopping
    case salvageStale                               // from a previous boot session
    case waitForFolder                              // recording folder unreachable
    public enum Reason: Equatable, Sendable { case tooOld(seconds: TimeInterval), noLiveness, wasStopping }
    public static let resumeWindow: TimeInterval    // 180
    public static func decide(lastAliveAt: Date?, bootSessionUUID: String?, wasStopping: Bool, now: Date,
                              helperCapturing: Bool, currentBootSessionUUID: String?, folderReachable: Bool) -> RelaunchDecision
}
```
Primitive inputs on purpose: the sentinel fields (`lastAliveAt`, `bootSessionUUID`, `stopping`) are added by L7 to `RecordingSentinel` (an L file); this core has no dependency on it.

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/RelaunchDecisionTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L1/L3 (§8.3): an app crash mid-meeting used to end the recording silently (the helper stops
/// on disconnect; Flow B salvaged and showed a rename dialog). A stale-sentinel check based on
/// `systemUptime` judged 7.2 h of sleep as "before the last boot".
@Suite struct RelaunchDecisionTests {
    let now = Date(timeIntervalSince1970: 10_000)

    private func decide(alive: TimeInterval?, boot: String? = "B1", stopping: Bool = false,
                        helper: Bool = false, current: String? = "B1", folder: Bool = true) -> RelaunchDecision {
        RelaunchDecision.decide(lastAliveAt: alive.map { now.addingTimeInterval(-$0) }, bootSessionUUID: boot,
                                wasStopping: stopping, now: now, helperCapturing: helper,
                                currentBootSessionUUID: current, folderReachable: folder)
    }

    @Test func helperStillCapturingReattaches() {
        #expect(decide(alive: 30, helper: true) == .reattach)
    }
    @Test func freshSentinelAndDeadHelperResumesTheSameSession() {
        #expect(decide(alive: 30) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
    }
    @Test func theWindowEdgeStillResumes() {
        #expect(decide(alive: RelaunchDecision.resumeWindow) == .resumeSameSession(gapStart: now.addingTimeInterval(-RelaunchDecision.resumeWindow)))
    }
    @Test func oldSentinelSalvagesAndStops() {
        #expect(decide(alive: 600) == .salvageAndStop(reason: .tooOld(seconds: 600)))
    }
    @Test func aSentinelWithoutLivenessSalvages() {
        #expect(decide(alive: nil) == .salvageAndStop(reason: .noLiveness))
    }
    /// Spec §8.3/§8.8 (scan A163/C16): a crash during post-Stop finalize must not resume a recording
    /// the user stopped; the sentinel is marked `stopping` before finalize and that wins over freshness.
    @Test func aSentinelMarkedStoppingIsSalvagedNeverResumed() {
        #expect(decide(alive: 5, stopping: true) == .salvageAndStop(reason: .wasStopping))
    }
    @Test func aDifferentBootSessionIsStaleEvenIfRecent() {
        #expect(decide(alive: 30, boot: "B0") == .salvageStale)
    }
    @Test func unreachableFolderWaitsAndNeverDeletes() {
        #expect(decide(alive: 30, folder: false) == .waitForFolder)
    }
    @Test func unknownBootSessionIsNotStale() {
        #expect(decide(alive: 30, boot: nil) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
        #expect(decide(alive: 30, current: nil) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
    }
    @Test func thisMachineReportsABootSessionUUID() {
        let uuid = BootSession.currentUUID()
        #expect(uuid?.isEmpty == false)
        #expect(BootSession.currentUUID() == uuid, "stable within one boot")
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'RelaunchDecisionTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/BootSession.swift`:
```swift
import Foundation

/// `kern.bootsessionuuid`: changes on every boot, immune to sleep and to wall-clock changes
/// (gotcha #76: `ProcessInfo.systemUptime` excludes sleep — 7.2 h short on this Mac).
public enum BootSession {
    public static func currentUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
```

`TranscriberCore/RelaunchDecision.swift`:
```swift
import Foundation

/// What to do with a recording sentinel at launch (§8.3, §8.9). Pure; the coordinator supplies the
/// facts and applies the decision.
public enum RelaunchDecision: Equatable, Sendable {
    case reattach
    case resumeSameSession(gapStart: Date)
    case salvageAndStop(reason: Reason)
    case salvageStale
    case waitForFolder

    public enum Reason: Equatable, Sendable { case tooOld(seconds: TimeInterval), noLiveness, wasStopping }

    /// The sentinel's `lastAliveAt` is refreshed every 60 s and at every rotation; a relaunch within
    /// this window resumes the SAME session (the gap is recorded), later ones salvage and say STOPPED.
    public static let resumeWindow: TimeInterval = 180

    public static func decide(lastAliveAt: Date?, bootSessionUUID: String?, wasStopping: Bool, now: Date,
                              helperCapturing: Bool, currentBootSessionUUID: String?, folderReachable: Bool) -> RelaunchDecision {
        if helperCapturing { return .reattach }
        if !folderReachable { return .waitForFolder }
        if let recorded = bootSessionUUID, let current = currentBootSessionUUID, recorded != current { return .salvageStale }
        if wasStopping { return .salvageAndStop(reason: .wasStopping) }
        guard let lastAliveAt else { return .salvageAndStop(reason: .noLiveness) }
        let age = now.timeIntervalSince(lastAliveAt)
        if age <= resumeWindow { return .resumeSameSession(gapStart: lastAliveAt) }
        return .salvageAndStop(reason: .tooOld(seconds: age))
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'RelaunchDecisionTests'` — Expected: 10 pass.
```bash
git add TranscriberCore/RelaunchDecision.swift TranscriberCore/BootSession.swift SwiftTests/TranscriberTests/RelaunchDecisionTests.swift
git commit -m "feat(relaunch): RelaunchDecision (reattach / resume / salvage, stopping wins) + kern.bootsessionuuid (L1, L3, §8.3)"
```

---

### Task C8: `DiskSpaceCheck` with hysteresis

**Files:**
- Create: `TranscriberCore/DiskSpaceCheck.swift`
- Test: `SwiftTests/TranscriberTests/DiskSpaceCheckTests.swift` (new, red-first)

**Interfaces:**
```swift
public enum DiskSpaceCheck {
    public static let headroomBytes = 200_000_000
    public static func bytesPerChunk(chunkMinutes: Int) -> Int          // minutes × 60 × 2 tracks × 96 000 B/s
    public static func canStart(freeBytes: Int, chunkMinutes: Int) -> Bool   // ≥ 2 chunks + headroom
    public enum RotationVerdict: Equatable, Sendable { case ok, low }
    /// `.low` below 1 chunk; once low, stays low until ≥ 2 chunks (§6.1 diskLow: "cleared when free ≥ 2 chunks").
    public static func rotationVerdict(freeBytes: Int, chunkMinutes: Int, currentlyLow: Bool) -> RotationVerdict
    public static func freeBytes(at url: URL) -> Int?                  // volumeAvailableCapacityForImportantUsage
    public static func message(freeBytes: Int, chunkMinutes: Int) -> String
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/DiskSpaceCheckTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L10 (§8.7): disk is checked before start and at every rotation; the diskLow alarm has hysteresis
/// so a rotation right at the threshold does not flap (scan C17).
@Suite struct DiskSpaceCheckTests {
    @Test func bytesPerChunkIsTwoTracksAt96KBps() {
        #expect(DiskSpaceCheck.bytesPerChunk(chunkMinutes: 10) == 10 * 60 * 2 * 96_000)
    }
    @Test func startNeedsTwoChunksPlusHeadroom() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.canStart(freeBytes: 2 * one + 200_000_000, chunkMinutes: 30))
        #expect(!DiskSpaceCheck.canStart(freeBytes: 2 * one + 199_000_000, chunkMinutes: 30))
    }
    @Test func rotationWarnsBelowOneChunk() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one - 1, chunkMinutes: 30, currentlyLow: false) == .low)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: 2 * one, chunkMinutes: 30, currentlyLow: false) == .ok)
    }
    @Test func diskLowClearsOnlyAtTwoChunks() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one + 1, chunkMinutes: 30, currentlyLow: true) == .low, "between 1 and 2 chunks: still low")
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: 2 * one, chunkMinutes: 30, currentlyLow: true) == .ok)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one + 1, chunkMinutes: 30, currentlyLow: false) == .ok, "not yet low: 1–2 chunks is fine")
    }
    @Test func theRealVolumeAnswers() {
        #expect((DiskSpaceCheck.freeBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
    @Test func messageNamesTheNumbers() {
        let m = DiskSpaceCheck.message(freeBytes: 100_000_000, chunkMinutes: 10)
        #expect(m.contains("100 MB") && m.contains("10-minute"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'DiskSpaceCheckTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/DiskSpaceCheck.swift`:
```swift
import Foundation

/// Disk thresholds for a recording (§8.7). Two 48 kHz mono Int16 WAVs = 2 × 96 000 B/s.
public enum DiskSpaceCheck {
    public static let headroomBytes = 200_000_000
    private static let bytesPerSecondPerTrack = 96_000

    public static func bytesPerChunk(chunkMinutes: Int) -> Int { chunkMinutes * 60 * 2 * bytesPerSecondPerTrack }

    public static func canStart(freeBytes: Int, chunkMinutes: Int) -> Bool {
        freeBytes >= 2 * bytesPerChunk(chunkMinutes: chunkMinutes) + headroomBytes
    }

    public enum RotationVerdict: Equatable, Sendable { case ok, low }

    public static func rotationVerdict(freeBytes: Int, chunkMinutes: Int, currentlyLow: Bool) -> RotationVerdict {
        let one = bytesPerChunk(chunkMinutes: chunkMinutes)
        if freeBytes < one { return .low }
        if currentlyLow, freeBytes < 2 * one { return .low }
        return .ok
    }

    public static func freeBytes(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    public static func message(freeBytes: Int, chunkMinutes: Int) -> String {
        let needed = 2 * bytesPerChunk(chunkMinutes: chunkMinutes) + headroomBytes
        return "Only \(freeBytes / 1_000_000) MB free — Parley needs at least \(needed / 1_000_000) MB to record \(chunkMinutes)-minute chunks."
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'DiskSpaceCheckTests'` — Expected: 6 pass.
```bash
git add TranscriberCore/DiskSpaceCheck.swift SwiftTests/TranscriberTests/DiskSpaceCheckTests.swift
git commit -m "feat(disk): DiskSpaceCheck — start threshold, rotation verdict with hysteresis (L10, §8.7)"
```

---

### Task C9: `RecoveryMessages` + `SalvageOutcome`

**Files:**
- Create: `TranscriberCore/RecoveryMessages.swift`
- Test: `SwiftTests/TranscriberTests/RecoveryMessagesTests.swift` (new, red-first)

**Interfaces:**
```swift
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind; public let chunkCount: Int
    public init(kind: Kind, chunkCount: Int)
}
public enum RecoveryMessages {
    public static func recordingFailed(after outcome: SalvageOutcome) -> String
    public static func stopFailed(after outcome: SalvageOutcome, error: String) -> String
    public static func relaunchStopped(at: Date, outcome: SalvageOutcome) -> String
    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String
    public static func clock(_ date: Date) -> String    // "HH:mm:ss", current locale's calendar, local time zone
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/RecoveryMessagesTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// P6: "The portion recorded before the failure has been transcribed" was said even when no
/// transcript existed and finalize had thrown.
@Suite struct RecoveryMessagesTests {
    let url = URL(fileURLWithPath: "/tmp/m.json")

    @Test func writtenTranscriptIsNamed() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3))
        #expect(m.contains("m.json") && m.contains("3 chunks"))
    }
    @Test func nothingWrittenSaysSo() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(m.contains("No transcript could be written") && !m.contains("has been transcribed"))
    }
    @Test func finalizeFailureKeepsTheAudioAndSaysWhy() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 2))
        #expect(m.contains("disk full") && m.contains("kept on disk"))
    }
    @Test func stopFailureCarriesTheErrorAndTheOutcome() {
        let m = RecoveryMessages.stopFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1), error: "helper gone")
        #expect(m.contains("helper gone") && m.contains("m.json"))
    }
    @Test func relaunchStoppedNamesTheClockTime() {
        let at = Date(timeIntervalSince1970: 0)
        let m = RecoveryMessages.relaunchStopped(at: at, outcome: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(m.hasPrefix("Recording STOPPED at \(RecoveryMessages.clock(at))"))
    }
    @Test func resumedMessageNamesTheGap() {
        let crashed = Date(timeIntervalSince1970: 100), resumed = Date(timeIntervalSince1970: 104)
        let m = RecoveryMessages.resumedAfterCrash(crashedAt: crashed, resumedAt: resumed)
        #expect(m == "Parley crashed at \(RecoveryMessages.clock(crashed)) and resumed at \(RecoveryMessages.clock(resumed)) — 4 s not recorded.")
    }
    @Test func singularChunkGrammar() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1))
        #expect(m.contains("1 chunk ") || m.contains("1 chunk)"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'RecoveryMessagesTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/RecoveryMessages.swift`:
```swift
import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind
    public let chunkCount: Int
    public init(kind: Kind, chunkCount: Int) { self.kind = kind; self.chunkCount = chunkCount }
}

public enum RecoveryMessages {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    public static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    private static func chunks(_ n: Int) -> String { n == 1 ? "1 chunk" : "\(n) chunks" }

    private static func describe(_ outcome: SalvageOutcome) -> String {
        switch outcome.kind {
        case .transcriptWritten(let url):
            return "The \(chunks(outcome.chunkCount)) recorded before it were transcribed to \(url.lastPathComponent)."
        case .nothingToSalvage:
            return "No transcript could be written: nothing had been recorded yet."
        case .finalizeFailed(let why):
            return "The \(chunks(outcome.chunkCount)) recorded before it are kept on disk but could not be transcribed: \(why)."
        }
    }

    public static func recordingFailed(after outcome: SalvageOutcome) -> String {
        "Capture failed and could not be restarted. " + describe(outcome)
    }

    public static func stopFailed(after outcome: SalvageOutcome, error: String) -> String {
        "Stopping the recording failed (\(error)). " + describe(outcome)
    }

    public static func relaunchStopped(at: Date, outcome: SalvageOutcome) -> String {
        "Recording STOPPED at \(clock(at)) — Parley crashed and could not resume it. " + describe(outcome)
    }

    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String {
        let gap = Int(resumedAt.timeIntervalSince(crashedAt).rounded())
        return "Parley crashed at \(clock(crashedAt)) and resumed at \(clock(resumedAt)) — \(gap) s not recorded."
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'RecoveryMessagesTests'` — Expected: 7 pass.
```bash
git add TranscriberCore/RecoveryMessages.swift SwiftTests/TranscriberTests/RecoveryMessagesTests.swift
git commit -m "feat(recovery): SalvageOutcome + RecoveryMessages — honest salvage / stop / relaunch texts (P6, §8.3)"
```

---

### Task C10: `MonotonicWallClock`

**Files:**
- Create: `TranscriberCore/MonotonicWallClock.swift`
- Test: `SwiftTests/TranscriberTests/MonotonicWallClockTests.swift` (new, red-first)

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L15 (§8.12): chunk start times come from the monotonic clock anchored once to the wall clock,
/// so an NTP step mid-recording cannot shift the transcript's timeline.
@Suite struct MonotonicWallClockTests {
    @Test func advancesWithTheMonotonicClockNotTheWallClock() {
        let t = ContinuousClock.now
        let c = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: t)
        #expect(c.now(monotonic: t.advanced(by: .seconds(60))) == Date(timeIntervalSince1970: 60))
        #expect(c.now(monotonic: t.advanced(by: .milliseconds(1500))).timeIntervalSince1970 == 1.5)
    }
    @Test func startAnchorsToTheGivenWallTime() {
        let wall = Date(timeIntervalSince1970: 1_000)
        let c = MonotonicWallClock.start(now: wall)
        let later = c.now()
        #expect(later >= wall && later.timeIntervalSince(wall) < 5)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'MonotonicWallClockTests'` → compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Wall-clock time derived from the monotonic clock: anchored once, then advanced by
/// `ContinuousClock` elapsed time (§8.12). Display uses the wall clock; timelines use this.
public struct MonotonicWallClock: Sendable {
    public let anchorWall: Date
    public let anchorMonotonic: ContinuousClock.Instant

    public init(anchorWall: Date, anchorMonotonic: ContinuousClock.Instant) {
        self.anchorWall = anchorWall
        self.anchorMonotonic = anchorMonotonic
    }

    public static func start(now: Date = Date()) -> MonotonicWallClock {
        MonotonicWallClock(anchorWall: now, anchorMonotonic: .now)
    }

    public func now(monotonic: ContinuousClock.Instant = .now) -> Date {
        let d = anchorMonotonic.duration(to: monotonic).components
        return anchorWall.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'MonotonicWallClockTests'` — Expected: 2 pass.
```bash
git add TranscriberCore/MonotonicWallClock.swift SwiftTests/TranscriberTests/MonotonicWallClockTests.swift
git commit -m "feat(clock): MonotonicWallClock — wall time anchored to ContinuousClock (L15, §8.12)"
```

---

### Task C11: `LiveDiagnosticsLog`

**Files:**
- Create: `TranscriberCore/LiveDiagnosticsLog.swift`
- Test: `SwiftTests/TranscriberTests/LiveDiagnosticsLogTests.swift` (new, red-first)

**Interfaces:**
```swift
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL                                      // <directory>/<sessionId>.diag.live.jsonl
    public init(directory: URL, sessionId: String)
    public func append(_ event: CaptureEvent)                // .warning/.anomaly only; one JSON line; never throws (logs)
    public func events() -> [CaptureEvent]                   // corrupt lines skipped
    public func merged(into ring: CaptureDiagnostics) -> CaptureDiagnostics   // union, deduplicated by (timestamp, origin, kind, detail)
    public func delete()
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L4/L14 (§8.11): the diagnostics ring is in memory and is lost with the process. Anomalies are
/// appended to disk as they happen, and finalize merges the file back without duplicates.
@Suite struct LiveDiagnosticsLogTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func retry(at seconds: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSince1970: seconds), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"])
    }

    @Test func appendsAnomaliesAsTheyHappenAndMergesWithoutDuplicates() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
        var ring = CaptureDiagnostics()
        ring.record(retry(at: 1))
        ring.record(retry(at: 2))
        let merged = log.merged(into: ring)
        #expect(merged.events.count == 2, "the event both on disk and in the ring is one event")
    }

    @Test func informationalEventsAreNotWritten() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(CaptureEvent(timestamp: Date(), origin: .app, kind: .captureStart, severity: .info))
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }

    @Test func aCorruptLineIsSkippedAndTheRestSurvive() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{not json\n".utf8)); try handle.close()
        log.append(retry(at: 3))
        #expect(log.events().map(\.timestamp.timeIntervalSince1970) == [1, 3])
    }

    @Test func deleteRemovesTheFile() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        log.delete()
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'LiveDiagnosticsLogTests'` → compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation
import os

/// Append-as-you-go anomaly log (§8.11): `<session>.diag.live.jsonl` next to the recording. Written
/// line by line so a crash loses at most the line in flight; merged into the ring at finalize.
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public init(directory: URL, sessionId: String) {
        url = directory.appendingPathComponent("\(sessionId).diag.live.jsonl")
    }

    public func append(_ event: CaptureEvent) {
        guard event.severity != .info else { return }
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else if (try? line.write(to: url, options: .atomic)) == nil {
            Logger.files.error("LiveDiagnosticsLog: could not write \(self.url.lastPathComponent, privacy: .sensitive)")
        }
    }

    public func events() -> [CaptureEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(CaptureEvent.self, from: $0) }
    }

    public func merged(into ring: CaptureDiagnostics) -> CaptureDiagnostics {
        var seen = Set<String>()
        func key(_ e: CaptureEvent) -> String {
            "\(e.timestamp.timeIntervalSinceReferenceDate)|\(e.origin.rawValue)|\(e.kind.rawValue)|\(e.detail.sorted { $0.key < $1.key })"
        }
        var result = ring
        var extra: [CaptureEvent] = []
        for e in ring.events { seen.insert(key(e)) }
        for e in events() where seen.insert(key(e)).inserted { extra.append(e) }
        result.merge(extra)
        return result
    }

    public func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
```
(`CaptureDiagnostics.merge(_:)` exists at `CaptureDiagnostics.swift:347`; E2 changes its counter handling but not its signature.)

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'LiveDiagnosticsLogTests'` — Expected: 4 pass.
```bash
git add TranscriberCore/LiveDiagnosticsLog.swift SwiftTests/TranscriberTests/LiveDiagnosticsLogTests.swift
git commit -m "feat(evidence): LiveDiagnosticsLog — anomalies appended as they happen, merged at finalize (L4, L14, §8.11)"
```

---

### Task C12: `EnginePreflight` + `SyntheticWAV`

**Files:**
- Create: `TranscriberCore/EnginePreflight.swift`, `TranscriberCore/SyntheticWAV.swift`
- Test: `SwiftTests/TranscriberTests/EnginePreflightTests.swift` (new, red-first)

`SyntheticWAV` is a COPY of the test fixture writer's shape (`RecoveryFixtures.writeFakeWav`, which stays where it is — scan A122/A133: copy, never move). The test file declares its own throwing engine (`PreflightThrowingEngine`) so it cannot collide with R2's `ThrowingEngine`.

**Interfaces:**
```swift
public enum SyntheticWAV {
    /// 16-bit PCM mono WAV holding a 440 Hz tone at −20 dBFS.
    public static func write(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws
}
public enum EnginePreflight {
    public enum Failure: Error, Equatable { case engineThrew(String) }
    /// Writes a 1 s synthetic WAV, calls `transcribe(audioPath:language: nil, audioSource: .system)`, rethrows as `.engineThrew`.
    public static func run(engine: any TranscriptionEngine, scratchDirectory: URL = FileManager.default.temporaryDirectory) async throws
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// P1 / §11.2: a fresh install on macOS 26 produced empty transcripts because the live chunk path
/// threw `languageRequired` on every chunk and swallowed it. Setup Continue and Settings Save now
/// run the chosen engine on one synthetic second and refuse on throw.
private struct PreflightThrowingEngine: TranscriptionEngine {
    let name = "PreflightThrowing"
    struct Boom: Error {}
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

@Suite struct EnginePreflightTests {
    @Test func aThrowingEngineFailsPreflightWithItsError() async {
        await #expect(throws: EnginePreflight.Failure.self) {
            try await EnginePreflight.run(engine: PreflightThrowingEngine())
        }
    }

    @Test func aWorkingEnginePassesOnASyntheticSecond() async throws {
        try await EnginePreflight.run(engine: FakeEngine())   // FakeEngine: ChunkedSessionRecoveryTests.swift:11
    }

    @Test func theSyntheticWavIsOneSecondOf16kHzMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticWAV.write(to: url, seconds: 1)
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        #expect(file.length == 16_000)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'EnginePreflightTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/SyntheticWAV.swift`:
```swift
import Foundation

/// A tiny real WAV for smoke tests (engine preflight). Same header layout as the test fixture
/// writer, but with a tone instead of zeros so an engine has something to decode.
public enum SyntheticWAV {
    public static func write(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let ch = 1, bits = 16
        let frames = Int(seconds * Double(sampleRate))
        let dataBytes = frames * ch * bits / 8
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data()
        h.append("RIFF".data(using: .ascii)!); h.append(le(UInt32(36 + dataBytes))); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); h.append(le(UInt32(16))); h.append(le(UInt16(1))); h.append(le(UInt16(ch)))
        h.append(le(UInt32(sampleRate))); h.append(le(UInt32(sampleRate * ch * bits / 8))); h.append(le(UInt16(ch * bits / 8))); h.append(le(UInt16(bits)))
        h.append("data".data(using: .ascii)!); h.append(le(UInt32(dataBytes)))
        var samples = Data(capacity: dataBytes)
        let amplitude = 3276.0   // −20 dBFS
        for i in 0..<frames {
            let v = Int16(amplitude * sin(2 * .pi * 440 * Double(i) / Double(sampleRate)))
            samples.append(le(v))
        }
        h.append(samples)
        try h.write(to: url)
    }
}
```

`TranscriberCore/EnginePreflight.swift`:
```swift
import Foundation

/// Run the chosen engine on one synthetic second before trusting it with a meeting (§11.2).
public enum EnginePreflight {
    public enum Failure: Error, Equatable { case engineThrew(String) }

    public static func run(engine: any TranscriptionEngine, scratchDirectory: URL = FileManager.default.temporaryDirectory) async throws {
        let url = scratchDirectory.appendingPathComponent("parley-preflight-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticWAV.write(to: url, seconds: 1)
        do {
            _ = try await engine.transcribe(audioPath: url, language: nil, audioSource: .system)
        } catch {
            throw Failure.engineThrew("\(error)")
        }
    }
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'EnginePreflightTests'` — Expected: 3 pass.
```bash
git add TranscriberCore/EnginePreflight.swift TranscriberCore/SyntheticWAV.swift SwiftTests/TranscriberTests/EnginePreflightTests.swift
git commit -m "feat(engine): EnginePreflight on a synthetic second (P1 mitigation, §11.2)"
```

---

### Task C13: `withDeadline` for Core callers

**Files:**
- Create: `TranscriberCore/Deadline.swift`
- Test: `SwiftTests/TranscriberTests/DeadlineTests.swift` (new, red-first)

The only `withDeadline` today is `private static` in `TranscriberApp/Services/PermissionRepairWindowController.swift:201` (non-throwing, app target). The coordinator (Core) needs one (scan A169/D6); the app client reuses it in L9.

**Interfaces:**
```swift
public enum DeadlineError: Error, Equatable { case timedOut(String) }
/// Waits at most `seconds` for `body`; the body keeps running after a timeout (it cannot be cancelled
/// safely — an XPC continuation must still be resumed by ResumeOnce). Throws `DeadlineError.timedOut(label)`.
public func withDeadline<T: Sendable>(seconds: Double, label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L13 (§8.8): every helper call gets a deadline. `ResumeOnce` already guarantees a continuation is
/// resumed once; this adds "and not later than N seconds".
@Suite struct DeadlineTests {
    @Test func aFastBodyReturnsItsValue() async throws {
        let v = try await withDeadline(seconds: 1, label: "fast") { 42 }
        #expect(v == 42)
    }
    @Test func aSlowBodyThrowsTimedOutWithItsLabel() async {
        await #expect(throws: DeadlineError.timedOut("stop")) {
            try await withDeadline(seconds: 0.05, label: "stop") { try await Task.sleep(for: .seconds(10)); return 1 }
        }
    }
    @Test func aThrowingBodyRethrowsItsOwnError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withDeadline(seconds: 1, label: "boom") { throw Boom() }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'DeadlineTests'` → compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/Deadline.swift`:
```swift
import Foundation

public enum DeadlineError: Error, Equatable {
    case timedOut(String)
}

public func withDeadline<T: Sendable>(seconds: Double, label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let outcome: Result<T, any Error> = await withCheckedContinuation { cont in
        let once = ResumeOnce(cont)
        Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(DeadlineError.timedOut(label)))
        }
    }
    return try outcome.get()
}
```

- [ ] **Step 4: Run, commit**

Run: `$PARLEY_TEST --filter 'DeadlineTests'` — Expected: 3 pass.
```bash
git add TranscriberCore/Deadline.swift SwiftTests/TranscriberTests/DeadlineTests.swift
git commit -m "feat(core): withDeadline(seconds:label:) on ResumeOnce for Core callers (L13, §8.8)"
```

---
# Stream H — Helper: liveness, alarms, healing, coverage, power events

One implementer, serial. Branch after F merged. The helper target has no unit tests: every task here ends with `python3 scripts/dev.py --build` and is exercised on device in X1. The three Core files H owns (`TapPermissionGuard.swift`, `ExactZeroRunMonitor.swift`, `WavFileWriter.swift`) get red-first tests in their own suites.

### Task H1: Heartbeats, probe, driver, verdict handling (v1 P0.3 helper part) — needs C3 merged

**Files:**
- Delete: `TranscriberCore/LivenessGapDetector.swift`, `SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift`
- Create: `AudioCaptureHelper/XPC/OutputActivityProbe.swift`
- Modify: `AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift` (whole file), `AudioCaptureHelper/XPC/SystemTapSession.swift:37-43` (callbacks), `:345-361` (generation bump, `onGenerationChanged`), `:439-443` (heartbeat stamp), `:683-694` (delete `isOutputDeviceRunningSomewhere`), `AudioCaptureHelper/XPC/MicCaptureSession.swift:35-41` (callbacks), `:194-203` (generation bump), `:407-413` (heartbeat stamp), `AudioCaptureHelper/XPC/AudioCaptureService.swift:113-128` (`startLivenessWatchdog`), `:230-239` (call site), `:440-459` (tapGuard timer gate source), `:593-623` (`startMicSession` returns the session)
- Test: none new in Core (C3 covers the decisions). Deleting `LivenessGapDetectorTests.swift` needs no marker (the red-first script ignores deleted files).

**Interfaces:**
- `OutputActivityProbe` (helper): `func snapshot() -> [OutputActivity.ProcessOutputState]?`, `func othersRunningOutput() -> Bool` (fails OPEN), `func start()`, `func stop()`, `var onChange: (() -> Void)?`.
- `SystemTapSession`: `func lastHeartbeatNanos() -> UInt64`, `func generationValue() -> Int`, `var onGenerationChanged: (() -> Void)?`.
- `MicCaptureSession`: `func lastHeartbeatNanos() -> UInt64`, `func generationValue() -> Int`, `var onGenerationChanged: (() -> Void)?`.
- `LivenessWatchdogDriver`: `var lastMicHeartbeatNanos: (() -> UInt64)?`, `var lastSystemHeartbeatNanos: (() -> UInt64)?`, `func arm(track:)`, `func pause()`, `func accelerate(track:)`, `func othersRunningOutput() -> Bool`, `var onVerdict: ((String, TrackLivenessMonitor.Verdict) -> Void)?`, `var onGate: ((Bool, UInt64) -> Void)?`.
- `AudioCaptureService`: `private func startLivenessWatchdog(handler:mic:tap:)`, `private func handleLiveness(track:verdict:)`; `startMicSession` returns `(session: MicCaptureSession, deviceId: String?)`.

- [ ] **Step 1: Retire the detector**

`git rm TranscriberCore/LivenessGapDetector.swift SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift`

- [ ] **Step 2: The probe**

`AudioCaptureHelper/XPC/OutputActivityProbe.swift` (new):
```swift
import CoreAudio
import Foundation
import os
import TranscriberCore

/// Reads Core Audio's process objects and answers "is any OTHER process running output?" (§4.3).
/// Fails OPEN on any read failure. Registers `kAudioHardwarePropertyProcessObjectList` so a
/// process appearing/leaving triggers an immediate re-check (`onChange`).
final class OutputActivityProbe {
    private let queue = DispatchQueue(label: "audio-capture.output-activity")
    private var listener: AudioObjectPropertyListenerBlock?
    var onChange: (() -> Void)?

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0; var size = UInt32(4); var a = address(sel)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var a = address(sel, scope); var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard size == 0 || AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
        return out
    }

    /// nil = unreadable (caller fails open).
    func snapshot() -> [OutputActivity.ProcessOutputState]? {
        guard let procs = Self.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
        return procs.map { p in
            OutputActivity.ProcessOutputState(
                pid: Int32(bitPattern: Self.u32(p, kAudioProcessPropertyPID) ?? 0),
                isRunningOutput: Self.u32(p, kAudioProcessPropertyIsRunningOutput) == 1,
                outputDevices: Self.ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput) ?? []
            )
        }
    }

    func othersRunningOutput() -> Bool {
        guard let states = snapshot() else {
            Logger.audio.error("Output activity: process list unreadable — assuming output is running")
            return true
        }
        return OutputActivity.othersRunningOutput(states, ownPid: getpid())
    }

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        var a = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block) == noErr {
            listener = block
        }
    }

    func stop() {
        guard let block = listener else { return }
        var a = Self.address(kAudioHardwarePropertyProcessObjectList)
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        listener = nil
    }

    /// coreaudiod restarted: the listener registration died with it (H5).
    func restart() { stop(); start() }
}
```

- [ ] **Step 3: Heartbeats and generations in the two sessions**

`SystemTapSession.swift`:
- next to `onBuilt` (43): `var onGenerationChanged: (() -> Void)?`; fields `private let heartbeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)` and `private var generation = 0` (under `stateLock`); accessors `func lastHeartbeatNanos() -> UInt64 { heartbeat.withLock { $0 } }`, `func generationValue() -> Int { stateLock.sync { generation } }`.
- in `handleTapBuffers` (439): insert `heartbeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }` as the FIRST statement, before the `stateLock.sync` read at 442 (a heartbeat means "the OS called us", whatever the guards say next).
- in `buildAggregateAndStart`: after the `stateLock.sync { aggregateID = agg; procID = proc }` commit (345-348) add `stateLock.sync { generation += 1 }`; after `onBuilt?()` (361) add `onGenerationChanged?()`.
- delete `isOutputDeviceRunningSomewhere()` (683-694 with its doc comment). Its two callers go away in this task (driver rewrite below; service timer below).

`MicCaptureSession.swift`:
- next to `onUnavailable` (39): `var onGenerationChanged: (() -> Void)?`; the same `heartbeat` lock + `generation` (under `stateLock`) + the two accessors.
- `captureOutput` (407-413): insert `heartbeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }` before `onSampleBuffer(sampleBuffer)` (412).
- `buildAndStart` (135-204): after the raced check (194-201) and before the "Mic capture started" log (203): `stateLock.sync { generation += 1 }; onGenerationChanged?()`.

- [ ] **Step 4: The driver**

Replace `AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift` with:
```swift
import Foundation
import TranscriberCore

/// Off-audio-queue 1 Hz driver for the per-track `TrackLivenessMonitor`s (§4.2). Owns the timer
/// on its OWN serial queue — a callback that stopped cannot notice its own silence.
///
/// The system track's heartbeat source is whatever captures system audio (the tap's callback, or
/// the SCK arrival stamp): SCK inherits the liveness watchdog and its alarms for free (§13).
final class LivenessWatchdogDriver {
    let queue = DispatchQueue(label: "audio-capture.liveness-watchdog")
    private var timer: DispatchSourceTimer?
    private var monitors: [String: TrackLivenessMonitor] = [
        "mic": TrackLivenessMonitor(track: "mic"),
        "system": TrackLivenessMonitor(track: "system"),
    ]
    private let outputActivity = OutputActivityProbe()

    var lastMicHeartbeatNanos: (() -> UInt64)?
    var lastSystemHeartbeatNanos: (() -> UInt64)?
    /// Every non-healthy verdict, on `queue`: (track, verdict).
    var onVerdict: ((String, TrackLivenessMonitor.Verdict) -> Void)?
    /// The gate state on every tick (for coverage accounting, H6): (gateOpen, nowNanos).
    var onGate: ((Bool, UInt64) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.monitors = ["mic": TrackLivenessMonitor(track: "mic"), "system": TrackLivenessMonitor(track: "system")]
            self.outputActivity.onChange = { [weak self] in self?.queue.async { self?.tick() } }
            self.outputActivity.start()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    /// Start / rebuild / wake of one track: judge from now, expect first frames within 5 s.
    func arm(track: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in self?.monitors[track]?.arm(nowNanos: now) }
    }

    /// Sleep: nothing is judged until the next arm.
    func pause() { queue.async { [weak self] in self?.monitors.keys.forEach { self?.monitors[$0]?.pause() } } }

    /// Synchronous read of the process-level gate (also used by the tap guard timer and by `accelerate`).
    func othersRunningOutput() -> Bool { outputActivity.othersRunningOutput() }

    /// coreaudiod restarted (H5): re-register the process-list listener.
    func serviceRestarted() { queue.async { [weak self] in self?.outputActivity.restart() } }

    /// An aggregate listener (`goin`→0, `stpd`, `diff`) said IO may have stopped. Accelerators never
    /// rebuild blindly (§5): one second later, if no heartbeat has arrived since the event and the
    /// track is expected, report a stall now instead of waiting for the 3 s threshold. The monitor's
    /// episode is opened so its own tick does not report the same stall again (scan A26).
    func accelerate(track: String) {
        let eventNanos = DispatchTime.now().uptimeNanoseconds
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let heartbeat = (track == "mic" ? self.lastMicHeartbeatNanos : self.lastSystemHeartbeatNanos)?() ?? 0
            let expected = track == "mic" || self.outputActivity.othersRunningOutput()
            guard heartbeat <= eventNanos, expected else { return }
            guard var m = self.monitors[track], m.openEpisodeExternally() else { return }
            self.monitors[track] = m
            self.onVerdict?(track, .stalled(seconds: 1))
        }
    }

    private func stopLocked() {
        timer?.cancel(); timer = nil
        outputActivity.stop()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gateOpen = outputActivity.othersRunningOutput()
        onGate?(gateOpen, now)
        if let hb = lastMicHeartbeatNanos, var m = monitors["mic"] {
            let v = m.check(nowNanos: now, lastHeartbeatNanos: hb(), gateOpen: true)
            monitors["mic"] = m
            if v != .healthy { onVerdict?("mic", v) }
        }
        if let hb = lastSystemHeartbeatNanos, var m = monitors["system"] {
            let v = m.check(nowNanos: now, lastHeartbeatNanos: hb(), gateOpen: gateOpen)
            monitors["system"] = m
            if v != .healthy { onVerdict?("system", v) }
        }
    }
}
```

- [ ] **Step 5: The service**

`AudioCaptureService.swift`:
- `startMicSession` (593-623): change the signature to `private func startMicSession(handler: AudioOutputHandler, microphoneDeviceId: String?) throws -> (session: MicCaptureSession, deviceId: String?)` and return `(mic, resolvedId)` where it returned `resolvedId`; update its caller in `startCapture` (the `let resolvedMicId = try self.startMicSession(...)` form becomes `let (micSession, resolvedMicId) = try self.startMicSession(...)`), keeping `@discardableResult` off.
- replace `startLivenessWatchdog` (113-128) with:
```swift
    private func startLivenessWatchdog(handler: AudioOutputHandler, mic: MicCaptureSession, tap: SystemTapSession?) {
        livenessWatchdog.lastMicHeartbeatNanos = { [weak mic] in mic?.lastHeartbeatNanos() ?? 0 }
        // Tap: the callback's own heartbeat. SCK: the arrival stamp (gotcha #63) — SCK keeps the watchdog (§13).
        livenessWatchdog.lastSystemHeartbeatNanos = tap.map { tap in { [weak tap] in tap?.lastHeartbeatNanos() ?? 0 } }
            ?? { [weak handler] in handler?.lastSystemBufferArrivalNanos() ?? 0 }
        livenessWatchdog.onVerdict = { [weak self] track, verdict in self?.handleLiveness(track: track, verdict: verdict) }
        mic.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: "mic") }
        tap?.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: "system") }
        livenessWatchdog.start()
        livenessWatchdog.arm(track: "mic")
        livenessWatchdog.arm(track: "system")
    }

    /// Verdicts arrive on the watchdog queue. H1: record + transient banner; H2 adds the alarm
    /// registry; H4 routes the system track into the ladder and the mic into MicHealPolicy.
    private func handleLiveness(track: String, verdict: TrackLivenessMonitor.Verdict) {
        switch verdict {
        case .firstFrames:
            record(.firstFrames, .info, ["track": track])
            onFirstFrames?(track)
        case .neverDelivered(let s):
            record(.neverDelivered, .anomaly, ["track": track, "seconds": "\(Int(s))"])
            onQualityAnomaly?(CaptureEventKind.neverDelivered.rawValue, track == "mic"
                ? "The microphone isn’t delivering any audio." : "The other side of the call isn’t reaching Parley although audio is playing.")
        case .stalled(let s):
            record(.livenessGap, .anomaly, ["track": track, "seconds": "\(Int(s))"])
            onQualityAnomaly?(CaptureEventKind.livenessGap.rawValue, track == "mic"
                ? "The microphone stopped delivering audio \(Int(s))s ago." : "System audio stopped delivering \(Int(s))s ago.")
        case .cleared(let reason):
            record(.livenessRecovered, .info, ["track": track, "reason": "\(reason)"])
        case .healthy:
            break
        }
    }
```
- call site (237): `self.startLivenessWatchdog(handler: outputHandler, mic: micSession, tap: self.stateLock.sync { self.tapSession })`.
- tapGuard timer (452-453): `let outputRunning = self.tapGuard.wantsOutputState ? self.livenessWatchdog.othersRunningOutput() : nil` (H4 removes `wantsOutputState`/`outputRunning` altogether).
- The `.deliveryGap` wiring (121-126) is gone with the old `startLivenessWatchdog`; `TapPermissionGuard.deliveryGap` stays unused until H4 deletes it.

- [ ] **Step 6: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green (`LivenessGapDetectorTests` is gone).
```bash
git add -u TranscriberCore/LivenessGapDetector.swift SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift
git add AudioCaptureHelper/XPC/OutputActivityProbe.swift AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift AudioCaptureHelper/XPC/SystemTapSession.swift AudioCaptureHelper/XPC/MicCaptureSession.swift AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat(liveness): heartbeat-stamped TrackLivenessMonitor driver with the process-level output gate; SCK keeps liveness via its arrival stamp; never-delivered is caught in 5 s (H1, L2, Q4.1, H3b)"
```

---

### Task H2: Alarms in the helper — registry, raise/clear sites, push, real `captureStatus` (v1 P0.4 helper part)

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (`captureStatus` stub from F4 → real; `raiseAlarm`/`clearAlarm`; sites), `AudioCaptureHelper/XPC/AudioOutputHandler.swift:593-608` (`onMicAudioResumed`)
- Modify: `TranscriberCore/ExactZeroRunMonitor.swift:17-23, 44-52` (`Verdict.resumed`), `TranscriberCore/WavFileWriter.swift:29-41, 77-82, 93-98` (`onWriteRecovered`; `noteWriteFailure` internal)
- Test: `SwiftTests/TranscriberTests/ExactZeroRunMonitorTests.swift` (add; red-first: `.resumed` does not exist), `SwiftTests/TranscriberTests/WavFileWriterTests.swift` (add; red-first: `onWriteRecovered` does not exist)

**Interfaces:**
- `ExactZeroRunMonitor.Verdict` gains `case resumed` — the first non-zero batch after a reported run (once per run).
- `WavFileWriter.onWriteRecovered: (() -> Void)?` — first successful write after `onWriteFailure` fired; `func noteWriteFailure(_ message: String)` becomes internal (test seam).
- `AudioOutputHandler.onMicAudioResumed: (() -> Void)?`.
- `AudioCaptureService`: `private func raiseAlarm(_ kind: AlarmKind, _ message: String)`, `clearAlarm(_:)`; `captureStatus` returns the registry (tracks are filled by H6).

- [ ] **Step 1: Write the failing tests**

Append to `ExactZeroRunMonitorTests`:
```swift
    /// §6.1: `micDigitalSilence` clears on the first non-zero mic sample — the monitor says so once.
    @Test func silentRunThenAudioReportsResumedOnce() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        let zeros = [Int16](repeating: 0, count: 4800)
        let audio = [Int16](repeating: 0, count: 4799) + [1]
        for _ in 0..<130 { _ = m.record(samples: zeros, rate: rate) }
        #expect(m.record(samples: audio, rate: rate) == .resumed)
        #expect(m.record(samples: audio, rate: rate) == .notYet, "once per run")
    }

    @Test func audioWithoutAReportedRunIsNotAResume() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        let audio = [Int16](repeating: 0, count: 4799) + [1]
        #expect(m.record(samples: audio, rate: rate) == .notYet)
    }
```
Append to `struct WavFileWriterTests` in `WavFileWriterTests.swift` (same shape as `writingBeforeSampleRateIsSetUsesTheDocumentedFallback` at line 26):
```swift
    /// §6.1: diskWriteFailure clears on the next successful write on that writer — reported once.
    @Test func aSuccessfulWriteAfterAFailureReportsRecoveryOnce() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString).wav").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = try WavFileWriter(path: path)
        var failures = 0, recoveries = 0
        writer.onWriteFailure = { _ in failures += 1 }
        writer.onWriteRecovered = { recoveries += 1 }
        writer.noteWriteFailure(CocoaError(.fileWriteNoPermission), context: "test")   // internal seam (was private)
        let samples = [Int16](repeating: 0, count: 480)
        samples.withUnsafeBufferPointer { writer.appendInt16($0) }
        samples.withUnsafeBufferPointer { writer.appendInt16($0) }
        writer.finalize()
        #expect(failures == 1 && recoveries == 1)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'ExactZeroRunMonitorTests|WavFileWriterTests'` → compile errors.

- [ ] **Step 3: Core changes**

`ExactZeroRunMonitor.swift`: add `case resumed` to `Verdict` (17-23); in `record(samples:rate:)` (44-52) the "any non-zero batch re-arms" branch returns `.resumed` when a run had been reported (`reported == true` before re-arming), else `.notYet`.

`WavFileWriter.swift`: add `public var onWriteRecovered: (() -> Void)?` next to `onWriteFailure` (29); make `noteWriteFailure(_ error: Error, context: String)` internal (drop `private`, line 32 — the test seam); after the successful `try fileHandle.write(contentsOf:)` + `dataByteCount += …` in `append` (77-82) and `appendInt16` (93-98): `if writeFailureReported { writeFailureReported = false; onWriteRecovered?() }`.

- [ ] **Step 4: Run to verify they pass** — `$PARLEY_TEST --filter 'ExactZeroRunMonitorTests|WavFileWriterTests'` → pass.

- [ ] **Step 5: The helper registry and its sites**

`AudioCaptureOutputHandler.swift` (the file is `AudioOutputHandler.swift`): add `var onMicAudioResumed: (() -> Void)?` next to `onLiveAnomaly` (80); in `appendAlignedMic` (593-594) the verdict switch handles `.resumed` → `onMicAudioResumed?()`.

`AudioCaptureService.swift`:
- fields: `private let alarms = OSAllocatedUnfairLock(initialState: CaptureAlarmRegistry())`.
- replace the F4 `captureStatus` stub body with `reply(snapshot().encoded())` and add:
```swift
    private func snapshot() -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(
            helperSessionId: helperSessionId,
            isCapturing: stateLock.sync { isCapturing },
            alarms: alarms.withLock { $0.sorted },
            tracks: trackHealth())   // H6 fills this from the coverage counters; until then []
    }
    private func trackHealth() -> [TrackHealthSnapshot] { [] }
    private func raiseAlarm(_ kind: AlarmKind, _ message: String) {
        let changed = alarms.withLock { $0.raise(kind, message: message, now: Date()) }
        guard changed else { return }
        record(.alarmRaised, .anomaly, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot().encoded())
    }
    private func clearAlarm(_ kind: AlarmKind) {
        guard alarms.withLock({ $0.clear(kind) }) != nil else { return }
        record(.alarmCleared, .info, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot().encoded())
    }
```
- sites:
  - `handleLiveness` (H1): `.neverDelivered`/`.stalled` on `mic` → `raiseAlarm(.micNotDelivering, message)`; on `system` → `raiseAlarm(.remoteNotDelivering, message)` (interim, direct — H4 gates both behind healing); `.cleared` → `clearAlarm(track == "mic" ? .micNotDelivering : .remoteNotDelivering)`; `.firstFrames` → `clearAlarm(track == "mic" ? .micNotDelivering : .remoteNotDelivering)` and, for `system`, also `clearAlarm(.remoteRecoveryFailed)` (only the NotDelivering/RecoveryFailed kinds — never the permission or digital-silence kinds, scan B P0.4(4)).
  - mic exact zero: where `outputHandler.onLiveAnomaly` is wired (189-191) add `if kind == .exactZeroMic { self?.raiseAlarm(.micDigitalSilence, message) }`; wire `outputHandler.onMicAudioResumed = { [weak self] in self?.clearAlarm(.micDigitalSilence) }`.
  - `apply(_:)` (481-518): `.reportDenied(let status)` → after the existing `onQualityAnomaly` call add `raiseAlarm(status == nil ? .remoteCantConfirm : .remotePermissionDenied, message)`; `.reportRestored` → `clearAlarm(.remotePermissionDenied); clearAlarm(.remoteCantConfirm)`.
  - `wireWriteFailure` (104-109): add `raiseAlarm(.diskWriteFailure, message)` in the failure closure and `writer.onWriteRecovered = { [weak self] in self?.clearAlarm(.diskWriteFailure) }`.
  - `tap.onUnavailable` (646-650): add `self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.")` (H3 moves this to the rebuild-result path).
  - SCK give-up `handleSystemStreamUnrecoverable()` (878-894): after `onSystemAudioUnrecoverable?(…)` add `raiseAlarm(.remoteRecoveryFailed, "Remote audio couldn’t be recovered — only your microphone is recording.")` — this is what replaces the app's `noteSystemAudioLost` (scan D2) once L3 merges.
  - `stopCapture` (258-311), `stopAndFinalize` (520-561), `cleanupAfterFailure` (563-585): `alarms.withLock { $0 = CaptureAlarmRegistry() }` next to `livenessWatchdog.stop()`.

- [ ] **Step 6: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add AudioCaptureHelper/XPC/AudioCaptureService.swift AudioCaptureHelper/XPC/AudioOutputHandler.swift TranscriberCore/ExactZeroRunMonitor.swift TranscriberCore/WavFileWriter.swift SwiftTests/TranscriberTests/ExactZeroRunMonitorTests.swift SwiftTests/TranscriberTests/WavFileWriterTests.swift
git commit -m "feat(alarms): helper-owned alarm registry raised/cleared at every live anomaly site, pushed on change, served by captureStatus (H3, H9, L5, §6)"
```

---

### Task H3: `SystemTapSession` — aggregate listeners, rungs with tokens, `tapAutoStart`, diagnostic frame drop (v1 P1.2 + P1.4 helper) — needs C4 merged

**Files:**
- Modify: `AudioCaptureHelper/XPC/SystemTapSession.swift:37-43` (callbacks), `:106-109` (init), `:235-247` (`aggDesc`, line 241), `:345-361` (listeners), `:391-420` (`teardownIO`), `:439-443` (frame drop), `:639-661` (rebuild API), `:699-756` (rate-drift call at 755)
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (`startSystemTap` 631-661: init arguments, `onUnavailable` → `onRebuildResult`; `apply(.rebuildTap)` 495-498)

**Interfaces:**
- `SystemTapSession.init(deliveryQueue:tapAutoStart:dropFramesForDiagnostics:onSamples:)`.
- `var onAggregateEvent: ((String) -> Void)?` — fourcc: `"goin"` (value 0 only), `"stpd"`, `"diff"`, `"agrp"`; on `monitorQueue`.
- `var onRebuildResult: ((TapRecoveryLadder.Rung, Int, Bool, String) -> Void)?` — (rung, token, succeeded, reason); on `configQueue`. Token 0 = a rebuild the ladder did not order.
- `func rebuild(rung: TapRecoveryLadder.Rung, token: Int, reason: String)` — async on `configQueue`.
- Removes: `onUnavailable`, `rebuild(reason:)`.

- [ ] **Step 1: Init parameters and the diagnostic drop**

`init` (106-109) → `init(deliveryQueue: DispatchQueue, tapAutoStart: Bool = true, dropFramesForDiagnostics: Bool = false, onSamples: @escaping ([Int16], CMTime) -> Void)`; store both. Line 241: `kAudioAggregateDeviceTapAutoStartKey as String: tapAutoStart,`. In `handleTapBuffers` (439), BEFORE the heartbeat stamp H1 inserted: `if dropFramesForDiagnostics { return }` with the comment "D-04: reproduce Incident B (no callbacks at all) on demand — the heartbeat is never stamped, so never-delivered fires and the ladder runs against a tap this code keeps silent".

- [ ] **Step 2: Aggregate listeners**

Fields: `private var aggregateListenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []` (under `stateLock`), `var onAggregateEvent: ((String) -> Void)?`.

At the end of `buildAggregateAndStart`, after the commit at 345-348 (and H1's generation bump), before the format log: `registerAggregateListeners(on: agg)`, with:
```swift
    private static let aggregateSelectors: [(AudioObjectPropertySelector, String)] = [
        (kAudioDevicePropertyDeviceIsRunning, "goin"),
        (kAudioDevicePropertyIOStoppedAbnormally, "stpd"),
        (kAudioDevicePropertyDeviceHasChanged, "diff"),
        (kAudioAggregateDevicePropertyActiveSubDeviceList, "agrp"),
    ]

    /// Accelerators only (§5): they force an immediate heartbeat check in the driver; the
    /// heartbeat decides. Registered per aggregate generation, removed in `teardownIO`.
    private func registerAggregateListeners(on agg: AudioObjectID) {
        var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for (selector, name) in Self.aggregateSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if name == "goin" {
                    var running: UInt32 = 1; var size = UInt32(4)
                    var a = addr
                    if AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &running) == noErr, running != 0 { return }
                }
                Logger.audio.warning("System tap aggregate event '\(name, privacy: .public)'")
                self.onEvent?(.aggregateIOStopped, .warning, ["source": "system-tap", "selector": name])
                self.onAggregateEvent?(name)
            }
            if AudioObjectAddPropertyListenerBlock(agg, &addr, monitorQueue, block) == noErr {
                registered.append((addr, block))
            }
        }
        stateLock.sync { aggregateListenerBlocks = registered }
    }
```
In `teardownIO` (391-420), before `AudioDeviceStop`: read-and-clear `aggregateListenerBlocks` under `stateLock`, then `AudioObjectRemovePropertyListenerBlock(agg, &addr, monitorQueue, block)` for each.

- [ ] **Step 3: Rungs and results**

Replace `rebuild(reason:)` (639-641) and `rebuildForOutputChange` (645-661) with:
```swift
    /// Run one healing rung on `configQueue`. The result goes to `onRebuildResult` with the caller's
    /// token (0 = not ordered by the ladder); the healer decides what happens next. A stop that raced
    /// in makes this a no-op.
    func rebuild(rung: TapRecoveryLadder.Rung, token: Int, reason: String) {
        if stateLock.sync(execute: { isStopping }) { return }
        configQueue.async { [weak self] in
            guard let self else { return }
            if self.stateLock.sync(execute: { self.isStopping }) { return }
            self.teardownIO()
            do {
                if rung == .rebuildTap {
                    self.destroyTap()
                    try self.createTap()
                }
                try self.buildAggregateAndStart()
                Logger.audio.info("System tap \(rung.rawValue, privacy: .public) done (\(reason, privacy: .public))")
                self.onEvent?(.restartInPlace, .warning, ["source": "system-tap", "reason": reason, "rung": rung.rawValue])
                self.onRebuildResult?(rung, token, true, reason)
            } catch {
                Logger.audio.error("System tap \(rung.rawValue, privacy: .public) failed (\(reason, privacy: .public)): \(error, privacy: .public)")
                self.onEvent?(.restartFailed, .anomaly, ["source": "system-tap", "reason": "\(rung.rawValue) failed: \(reason)", "error": "\(error)"])
                self.onRebuildResult?(rung, token, false, reason)
            }
        }
    }

    /// Output-device change (HAL listener): the same aggregate rebuild, reported into the ladder as external.
    private func rebuildForOutputChange() { rebuild(rung: .rebuildAggregate, token: 0, reason: "output device changed") }
```
`checkRateDrift` line 755: `rebuild(rung: .rebuildAggregate, token: 0, reason: "rate drift remediation")`. Delete `var onUnavailable` (40) and its call (was 658).

- [ ] **Step 4: Service side (interim until H4)**

`startSystemTap` (631-661): construct `SystemTapSession(deliveryQueue: audioQueue, tapAutoStart: options.tapAutoStart, dropFramesForDiagnostics: options.debugDropTapFrames) { … }` where `options` is the `pendingOptions` value read in `startCapture` (F4) — pass it into `startSystemTap(handler:options:)`. Replace the `tap.onUnavailable = …` block (646-650) with:
```swift
        tap.onRebuildResult = { [weak self] rung, _, succeeded, reason in
            guard let self else { return }
            if succeeded { self.clearAlarm(.remoteRecoveryFailed) }
            else { self.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture (\(rung.rawValue)). The other side may not be recorded.") }
            _ = reason
        }
```
(§6.1: `remoteRecoveryFailed` raised when a rung threw, cleared by the next successful rung — scan C8. H4 keeps these two lines inside `TapHealer.rebuildResult`.) `apply(.rebuildTap)` (495-498): `tap?.rebuild(rung: .rebuildAggregate, token: 0, reason: "system audio permission")`.

- [ ] **Step 5: Build, commit**

Run: `python3 scripts/dev.py --build`. Expected: clean.
```bash
git add AudioCaptureHelper/XPC/SystemTapSession.swift AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat(tap): aggregate goin/stpd/diff/agrp listeners, tokened rungs with results instead of a permanent onUnavailable, tap_auto_start + diagnostic frame drop (Q1, Q2b, Q4.2, Q3b)"
```

---

### Task H4: `TapHealer` + `MicHealPolicy` wiring; the permission guard keeps permission logic only (v1 P1.3) — needs C4, C5 merged

**Files:**
- Create: `AudioCaptureHelper/XPC/TapHealer.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (`handleLiveness`, `startSystemTap`, `apply(_:)`, `startTapGuardTimer` 440-459, `startMicSession` 593-623 for `onUnavailable`, stop paths), `AudioCaptureHelper/XPC/MicCaptureSession.swift:338` (`heal()`)
- Modify: `TranscriberCore/TapPermissionGuard.swift:24-32` (`Evidence`), `:34-43` (`Action.rebuildTap(reason:)`), `:52` (`noBuffersAfterRebuild`), `:79-82` (init), `:101-125` (`samples`), `:127-147` (`deliveryGap`, `tick`, `wantsOutputState`), `:158-192` (`permissionChecked`)
- Test: `SwiftTests/TranscriberTests/TapPermissionGuardTests.swift` (changed assertions — red-first, NO exemption marker: `.rebuildTap` gains a payload, so the file fails to compile at the parent), `SwiftTests/TranscriberTests/TapPermissionGuardSoftAlarmTests.swift` (new, red-first)

**Interfaces:**
- `TapPermissionGuard`: `enum RebuildReason: Equatable, Sendable { case grant, insurance }`; `Action.rebuildTap(reason: RebuildReason)`; `init(zeroThresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds, softAlarmSeconds: Double? = nil)`; `tick(now:)` (single parameter); `Evidence` loses `.deliveryGap`; removed: `deliveryGap(now:)`, `noBuffersAfterRebuild`, `wantsOutputState`.
- `TapHealer` (helper): `init()`, `weak var tap: SystemTapSession?`, `func trigger(_:)`, `func heartbeatObserved()`, `func gateClosed()`, `func rebuildResult(rung:token:succeeded:)`, `func cancelAll()`, `var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?`, `var onGiveUp: (() -> Void)?`, `var onRecovered: (() -> Void)?`, `var onStuck: (() -> Void)?`, `var onRungFailed: ((TapRecoveryLadder.Rung) -> Void)?`, `var onRungSucceeded: (() -> Void)?`, `var totalRebuilds: Int`.
- `MicCaptureSession.heal()`.

- [ ] **Step 1: Change the guard tests and add the soft-alarm suite**

`TapPermissionGuardTests.swift`:
- delete `deliveryGapTriggersACheck` (154-161), `deliveryGapWithAnUnverifiableStatusReports` (181-188) and `noBuffersAfterAGrantRebuildWhileOutputPlaysIsEvidence` (229-241) — their paths are retired (the ladder owns delivery gaps);
- in `noConcurrentChecks` replace line 86 (`#expect(g.deliveryGap(now: 11) == [])`) with `#expect(feedZeros(&g, seconds: 13, from: 11).isEmpty)   // the first check hasn't answered yet`;
- every `== [.rebuildTap]` assertion names the branch it exercises: the grant branch (`permissionChecked` line 167) returns `.rebuildTap(reason: .grant)` — lines 29, 69, 106, 206; the insurance branch (line 174) returns `.rebuildTap(reason: .insurance)` — lines 143, 150, 220. (Verify each against the guard's branch before editing; the test names say which.)

`SwiftTests/TranscriberTests/TapPermissionGuardSoftAlarmTests.swift` (new):
```swift
import Testing
@testable import TranscriberCore

/// §9 / M-A: exact zeros with the permission authorized are the muted-remote shape and never alarm
/// on their own. A "can't confirm" after a long run ships OFF (nil) until the exact-zero census
/// shows no call app renders zeros when muted. Time is continuous across feeds (scan B P1.3).
@Suite struct TapPermissionGuardSoftAlarmTests {
    private let zeros = [Int16](repeating: 0, count: 4_800)

    /// Feeds 0.1 s batches of zeros from `from` for `seconds`; returns the actions and the end time.
    private func feed(_ g: inout TapPermissionGuard, seconds: Double, from: Double) -> (actions: [TapPermissionGuard.Action], end: Double) {
        var actions: [TapPermissionGuard.Action] = []
        var t = from
        for _ in 0..<Int(seconds * 10) {
            actions += g.samples(zeros, rate: 48_000, now: t)
            actions += g.tick(now: t)
            t += 0.1
        }
        return (actions, t)
    }

    /// The grey zone end to end: check once, one insurance rebuild, then nothing for ten minutes.
    @Test func offByDefaultTenMinutesOfZerosNeverAlarms() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        let first = feed(&g, seconds: 13, from: 0)
        #expect(first.actions.filter { $0 == .checkPermission(.exactZeroRun) }.count == 1)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: first.end) == [.rebuildTap(reason: .insurance)])
        _ = g.tapBuilt(status: .authorized, now: first.end)
        let rest = feed(&g, seconds: 600, from: first.end)
        #expect(!rest.actions.contains { if case .reportDenied = $0 { return true }; return false })
        #expect(!rest.actions.contains { if case .rebuildTap = $0 { return true }; return false }, "one insurance rebuild per episode")
    }

    @Test func whenEnabledItSaysCantConfirmOnceAfterTheWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        let before = feed(&g, seconds: 299, from: 0)
        #expect(!before.actions.contains(.reportDenied(nil)))
        let after = feed(&g, seconds: 2, from: before.end)
        #expect(after.actions.filter { $0 == .reportDenied(nil) }.count == 1)
    }

    @Test func realAudioResetsTheSoftWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        let first = feed(&g, seconds: 200, from: 0)
        _ = g.samples([Int16](repeating: 0, count: 4_799) + [1], rate: 48_000, now: first.end)
        let second = feed(&g, seconds: 200, from: first.end + 0.1)
        #expect(!second.actions.contains(.reportDenied(nil)), "400 s of zeros in total, but only 200 s since real audio")
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'TapPermissionGuardTests|TapPermissionGuardSoftAlarmTests'` → compile errors (`.rebuildTap(reason:)`, `softAlarmSeconds:`).

- [ ] **Step 3: The guard**

`TapPermissionGuard.swift`:
- `Evidence` (24-32): delete `.deliveryGap`. `Action` (34-43): `case rebuildTap(reason: RebuildReason)` with `public enum RebuildReason: Equatable, Sendable { case grant, insurance }`.
- delete `noBuffersAfterRebuild` (50-52), `deliveryGap(now:)` (127-130), `wantsOutputState` (146-147); `tick` (135-144) becomes `public mutating func tick(now: Double) -> [Action]` without the first `if awaitingAudio, outputRunning == true …` block (136-140), and with this new first statement:
```swift
        if let soft = softAlarmSeconds, let since = zeroRunStartedAt, now - since >= soft, !problemReported {
            return report(nil, now: now)
        }
```
- fields: `private let softAlarmSeconds: Double?`, `private var zeroRunStartedAt: Double?`; init (79-82): `public init(zeroThresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds, softAlarmSeconds: Double? = nil)`.
- `samples` (101-125): in the `allZero` branch `if zeroRunStartedAt == nil { zeroRunStartedAt = now }`; in the real-audio branch `zeroRunStartedAt = nil`.
- `permissionChecked` (158-192): line 167 → `return [.rebuildTap(reason: .grant)]`; line 174 → `return [.rebuildTap(reason: .insurance)]`.

- [ ] **Step 4: Run to verify they pass** — `$PARLEY_TEST --filter 'TapPermissionGuardTests|TapPermissionGuardSoftAlarmTests'` → pass.

- [ ] **Step 5: `TapHealer`**

`AudioCaptureHelper/XPC/TapHealer.swift`:
```swift
import Foundation
import os
import TranscriberCore

/// Runs `TapRecoveryLadder`'s actions: dispatches rungs to `SystemTapSession` with their token, arms
/// the heartbeat deadline, the stuck watchdog and the slow retry. Single serial queue; no decisions
/// of its own.
final class TapHealer {
    private let queue = DispatchQueue(label: "audio-capture.tap-healer")
    private var ladder = TapRecoveryLadder()
    private let epoch = DispatchTime.now().uptimeNanoseconds
    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - epoch) / 1e9 }
    private var heartbeatDeadline: DispatchWorkItem?
    private var stuckWatchdog: DispatchWorkItem?
    private var slowRetry: DispatchWorkItem?
    static let stuckSeconds: Double = 5

    weak var tap: SystemTapSession?
    var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?
    var onGiveUp: (() -> Void)?
    var onRecovered: (() -> Void)?
    var onStuck: (() -> Void)?
    var onRungFailed: ((TapRecoveryLadder.Rung) -> Void)?
    var onRungSucceeded: (() -> Void)?
    var totalRebuilds: Int { queue.sync { ladder.totalRebuilds } }

    func trigger(_ t: TapRecoveryLadder.Trigger) {
        queue.async { self.apply(self.ladder.trigger(t, now: self.now)) }
    }

    func heartbeatObserved() {
        queue.async {
            let wasHealing = self.ladder.inFlight != nil || self.ladder.awaitingHeartbeat || self.ladder.exhausted
            self.heartbeatDeadline?.cancel(); self.slowRetry?.cancel()
            _ = self.ladder.heartbeatObserved()
            if wasHealing { self.onRecovered?() }
        }
    }

    /// The track is no longer expected: end the episode, stop the slow retry (§5, scan C10).
    func gateClosed() {
        queue.async {
            self.heartbeatDeadline?.cancel(); self.slowRetry?.cancel()
            _ = self.ladder.gateClosed()
        }
    }

    func rebuildResult(rung: TapRecoveryLadder.Rung, token: Int, succeeded: Bool) {
        queue.async {
            if succeeded { self.onRungSucceeded?() } else { self.onRungFailed?(rung) }
            if token == 0 {
                self.apply(self.ladder.noteExternalRebuild(now: self.now))
                return
            }
            self.stuckWatchdog?.cancel()
            self.apply(self.ladder.rungCompleted(token: token, succeeded: succeeded, now: self.now))
        }
    }

    func cancelAll() {
        queue.async { [self] in heartbeatDeadline?.cancel(); stuckWatchdog?.cancel(); slowRetry?.cancel() }
    }

    private func apply(_ action: TapRecoveryLadder.Action) {
        switch action {
        case .none:
            break
        case .run(let rung, let token, let delay):
            onEvent?(.tapRecoveryRung, .warning, ["rung": rung.rawValue, "token": "\(token)", "delay": "\(delay)", "total": "\(ladder.totalRebuilds)"])
            let stuck = DispatchWorkItem { [weak self] in
                self?.onEvent?(.recoveryStuck, .anomaly, ["rung": rung.rawValue, "token": "\(token)"])
                self?.onStuck?()
            }
            stuckWatchdog = stuck
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + Self.stuckSeconds, execute: stuck)
                self.tap?.rebuild(rung: rung, token: token, reason: "healing ladder")
            }
        case .awaitHeartbeat(let seconds):
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply(self.ladder.heartbeatDeadlineMissed(now: self.now))
            }
            heartbeatDeadline = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        case .giveUp(let retryAfter):
            onEvent?(.tapRecoveryGivenUp, .anomaly, ["rebuilds": "\(ladder.totalRebuilds)"])
            onGiveUp?()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply(self.ladder.slowRetryDue(now: self.now))
            }
            slowRetry = item
            queue.asyncAfter(deadline: .now() + retryAfter, execute: item)
        }
    }
}
```

- [ ] **Step 6: Service wiring**

`AudioCaptureService.swift`:
- fields: `private let tapHealer = TapHealer()`, `private var micHealPolicy = MicHealPolicy()` (touched on the watchdog queue only).
- `startSystemTap`: `tapHealer.tap = tap`; replace H3's interim `tap.onRebuildResult` closure with `tap.onRebuildResult = { [weak self] rung, token, ok, _ in self?.tapHealer.rebuildResult(rung: rung, token: token, succeeded: ok) }`; `tap.onAggregateEvent = { [weak self] _ in self?.livenessWatchdog.accelerate(track: "system") }`; `tapHealer.onEvent = { [weak self] k, s, d in self?.record(k, s, d) }`; `tapHealer.onGiveUp = { [weak self] in self?.raiseAlarm(.remoteNotDelivering, "The other side of the call isn’t reaching Parley although audio is playing. Parley keeps retrying; if this persists, check the output device in the call app.") }`; `tapHealer.onRecovered = { [weak self] in self?.clearAlarm(.remoteNotDelivering) }`; `tapHealer.onStuck = { [weak self] in self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.") }`; `tapHealer.onRungFailed = { [weak self] rung in self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture (\(rung.rawValue)). The other side may not be recorded.") }`; `tapHealer.onRungSucceeded = { [weak self] in self?.clearAlarm(.remoteRecoveryFailed) }`.
- `handleLiveness`: system track — `.neverDelivered`: record + `tapHealer.trigger(.neverDelivered)` (no direct alarm any more); `.stalled`: record + `tapHealer.trigger(.stalled)`; `.firstFrames`: record + `onFirstFrames?(track)` + `tapHealer.heartbeatObserved()`; `.cleared(.heartbeat)`: record + `tapHealer.heartbeatObserved()`; `.cleared(.gateClosed)`: record + `tapHealer.gateClosed()` + `clearAlarm(.remoteNotDelivering)`. Mic track — `switch micHealPolicy.onVerdict(verdict)`: `.heal` → `stateLock.sync { micSession }?.heal()`; `.healAndAlarm` → heal + `raiseAlarm(.micNotDelivering, "The microphone isn’t delivering any audio. Try another microphone from the menu.")`; `.alarm` → raise only; `.clear` → `clearAlarm(.micNotDelivering)`; `.none` → nothing. `.firstFrames` on mic also records and calls `onFirstFrames?("mic")`.
- `startMicSession` `mic.onUnavailable` (606-611): keep the `.restartFailed` record and add `self?.livenessWatchdog.queue.async { guard let self else { return }; if self.micHealPolicy.healFailed() == .alarm { self.raiseAlarm(.micNotDelivering, "The microphone stopped delivering audio and could not be reopened. Try another microphone from the menu.") } }` (scan C11).
- `apply(_:)` (495-498): `case .rebuildTap(let reason): tapHealer.trigger(reason == .grant ? .permissionGrant : .permissionInsurance)`.
- `startTapGuardTimer` handler (449-455): `self.apply(self.tapGuard.tick(now: self.guardNow()))` (no HAL read).
- `startSystemTap`: `tapGuard = TapPermissionGuard(softAlarmSeconds: options.remoteExactZeroSoftAlarmSeconds.map(Double.init))`.
- `stopCapture`/`stopAndFinalize`/`cleanupAfterFailure`: `tapHealer.cancelAll()`.

`MicCaptureSession.swift`: next to `attemptRecover()` (338): `/// Silent-but-not-errored session; the liveness verdict is the only caller (H4). func heal() { attemptRecover() }`.

- [ ] **Step 7: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add AudioCaptureHelper/XPC/TapHealer.swift AudioCaptureHelper/XPC/AudioCaptureService.swift AudioCaptureHelper/XPC/MicCaptureSession.swift TranscriberCore/TapPermissionGuard.swift SwiftTests/TranscriberTests/TapPermissionGuardTests.swift SwiftTests/TranscriberTests/TapPermissionGuardSoftAlarmTests.swift
git commit -m "feat(healing): TapHealer runs the ladder from liveness verdicts (tokened results, gate-close reset); mic heals before alarming; permission guard keeps permission logic only (H3, H4, H5, Q4.4)"
```

---

### Task H5: coreaudiod restart (`srst`) and listener re-registration (v1 P1.5)

**Files:**
- Modify: `AudioCaptureHelper/XPC/SystemTapSession.swift:505-540` (`startDeviceMonitoring`), `:591-621` (`stopDeviceMonitoring`), the `rebuild(rung:token:reason:)` from H3 (re-register after `createTap()`), `AudioCaptureHelper/XPC/AudioCaptureService.swift` (`startSystemTap`)

- [ ] **Step 1: Implement**

`SystemTapSession`: `var onServiceRestarted: (() -> Void)?`; in `startDeviceMonitoring` register a third system-object listener for `kAudioHardwarePropertyServiceRestarted` on `monitorQueue` whose block logs, emits `onEvent?(.serviceRestarted, .warning, ["source": "system-tap"])` and calls `onServiceRestarted?()`; `stopDeviceMonitoring` removes it. Add `private func reregisterSystemListeners() { stopDeviceMonitoring(); startDeviceMonitoring() }` and call it inside `rebuild(rung:token:reason:)` right after `try self.createTap()` in the `.rebuildTap` branch (the header says client state must be re-established after `srst`).

`AudioCaptureService.startSystemTap`: `tap.onServiceRestarted = { [weak self] in guard let self else { return }; self.livenessWatchdog.serviceRestarted(); self.tapHealer.trigger(.serviceRestarted); self.stateLock.sync { self.micSession }?.heal() }`.

- [ ] **Step 2: Build, commit**

Run: `python3 scripts/dev.py --build`. Expected: clean.
```bash
git add AudioCaptureHelper/XPC/SystemTapSession.swift AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat(tap): coreaudiod restart → new tap + listeners re-registered, mic re-opened, probe re-armed (Q1g, Q3c)"
```

---

### Task H6: Coverage accumulation and `TrackHealthSnapshot` (v1 P2.1 helper part) — needs C6 merged

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (coverage lock; `onGate`; `coverageFacts()` replaces `tapTrackFacts()` at 432-438; `.trackCoverage` at rotation; `trackHealth()`), `AudioCaptureHelper/XPC/AudioOutputHandler.swift:24-60` (counters), `:142-172` (`finalizeAll` gate at 166), `:382-413` (`appendSystemSamples`), `:574-595` (`appendAlignedMic`), `AudioCaptureHelper/XPC/SystemTapSession.swift` / `MicCaptureSession.swift` (heartbeat count)

**Interfaces:**
- `AudioOutputHandler`: `func trackTotals() -> (micDelivered: Int64, micPad: Int64, micZero: Int64, sysDelivered: Int64, sysPad: Int64)` (read via `audioQueue.sync` from an XPC thread, as `tapTrackFacts` did); `var systemExpectedSeconds: (() -> Double)?`.
- `SystemTapSession`/`MicCaptureSession`: `func heartbeatCount() -> Int` (the heartbeat lock becomes `OSAllocatedUnfairLock<(nanos: UInt64, count: Int)>`).
- `AudioCaptureService.coverageFacts() -> [String: String]` = `asDetail(prefix: "remote") + asDetail(prefix: "local")`, in `captureStop` and in `.trackCoverage` at every rotation.

- [ ] **Step 1: Implement**

`AudioOutputHandler`: add `totalSystemPadFrames`, `totalMicPadFrames`, `micExactZeroFrames` (count all-zero batches in `appendAlignedMic`, next to the existing `micExactZeroMonitor.record` at 593), `trackTotals()`, `var systemExpectedSeconds: (() -> Double)?`; line 166 becomes `if !(isUsingSystemTap && (systemExpectedSeconds?() ?? 0) < 1)` (Q4.5: skip the finalize check only when the tap was never expected to deliver).

`SystemTapSession`/`MicCaptureSession`: the heartbeat lock becomes `OSAllocatedUnfairLock<(nanos: UInt64, count: Int)>`; the stamp does `$0 = (now, $0.count + 1)`; `heartbeatCount()`.

`AudioCaptureService`:
- `private let coverage = OSAllocatedUnfairLock(initialState: ["mic": TrackAccounting(), "system": TrackAccounting()])`, `private let lastGateTickNanos = OSAllocatedUnfairLock<UInt64>(initialState: 0)`.
- in `startLivenessWatchdog` (H1): `livenessWatchdog.onGate = { [weak self] open, now in self?.accountGate(open: open, nowNanos: now) }`, with
```swift
    /// Expected seconds accumulate by ELAPSED time between gate observations (capped at 2 s), never
    /// "+1 per call": the driver also ticks on process-list changes (scan A26).
    private func accountGate(open: Bool, nowNanos: UInt64) {
        let previous = lastGateTickNanos.withLock { p in defer { p = nowNanos }; return p }
        guard previous != 0, nowNanos > previous else { return }
        let dt = min(2.0, Double(nowNanos - previous) / 1e9)
        coverage.withLock { c in
            c["mic"]!.expectedSeconds += dt
            if open { c["system"]!.expectedSeconds += dt }
        }
    }
```
  reset `lastGateTickNanos` to 0 and `coverage` to fresh accountings in `startCapture`.
- `handleLiveness`: `.stalled(s)`/`.neverDelivered(s)` → `coverage.withLock { c in c[track]!.gapCount += 1; c[track]!.longestGapSeconds = max(c[track]!.longestGapSeconds, s) }` (the accelerator's synthetic stall opens the monitor's episode, so it is counted once — C3/H1).
- `tapHealer.onEvent` `.tapRecoveryRung` → `coverage["system"].rebuilds += 1`; the tap's external rebuilds (`onRebuildResult` token 0, succeeded) → `rebuilds += 1` as well.
- `coverageFacts()` (replaces `tapTrackFacts()`, 432-438; both `record(.captureStop, …)` calls at 277 and 531 switch to it): on an XPC thread, `let totals = audioQueue.sync { handler.trackTotals() }`, `let zeros = audioQueue.sync { tapGuard.exactZeroFrames }`, heartbeat counts from the sessions; merge into copies of the two accountings (`deliveredSeconds = Double(delivered) / 48_000`, `paddedSeconds`, `exactZeroSeconds`, `heartbeatCallbacks`) and return `remote.asDetail(prefix: "remote").merging(local.asDetail(prefix: "local")) { a, _ in a }`.
- `rotateChunk` (347-388): after the swap, `record(.trackCoverage, .info, ["chunk": newBaseName].merging(coverageFacts()) { a, _ in a })` — from the XPC thread, never inside `audioQueue.sync`.
- `trackHealth()` (H2 stub): `[TrackHealthSnapshot(track: "mic", expected: true, heartbeatAgeSeconds: age(mic), generation: mic.generationValue()), TrackHealthSnapshot(track: "system", expected: livenessWatchdog.othersRunningOutput(), heartbeatAgeSeconds: age(tap or handler stamp), generation: tap?.generationValue() ?? 0)]` where `age` = `(now − stamp) / 1e9`, nil when the stamp is 0.
- `outputHandler.systemExpectedSeconds = { [weak self] in self?.coverage.withLock { $0["system"]!.expectedSeconds } ?? 0 }` where the handler is created in `startCapture`.

- [ ] **Step 2: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add AudioCaptureHelper/XPC/AudioCaptureService.swift AudioCaptureHelper/XPC/AudioOutputHandler.swift AudioCaptureHelper/XPC/SystemTapSession.swift AudioCaptureHelper/XPC/MicCaptureSession.swift
git commit -m "feat(provenance): per-track coverage accumulated in the helper (elapsed-time gate accounting), emitted at rotation and stop, served in captureStatus tracks (B7/B8, Q4.5)"
```

---

### Task H7: Power events in the helper (v1 P3.5 helper part)

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (the F4 `systemPowerEvent` stub)

- [ ] **Step 1: Implement**

```swift
    func systemPowerEvent(kind: String, reply: @escaping () -> Void) {
        defer { reply() }
        guard stateLock.sync(execute: { isCapturing }) else { return }
        switch kind {
        case "sleep":
            Logger.audio.info("System sleep: liveness paused")
            livenessWatchdog.pause()
            tapHealer.cancelAll()
        case "wake":
            Logger.audio.info("System wake: re-arming both tracks, healing the tap and the mic")
            livenessWatchdog.arm(track: "mic")
            livenessWatchdog.arm(track: "system")
            tapHealer.trigger(.wake)
            stateLock.sync { micSession }?.heal()
        default:
            Logger.audio.warning("Unknown power event \(kind, privacy: .public)")
        }
    }
```

- [ ] **Step 2: Build, commit**

Run: `python3 scripts/dev.py --build`. Expected: clean.
```bash
git add AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat(lifecycle): helper pauses liveness on sleep and re-arms + heals both tracks on wake (L12, §8.10)"
```

### H gate

Stream gate over `git diff $(git merge-base fix/capture-reliability HEAD)..HEAD` (council lens: HAL calls that can block on `configQueue`; every rung reports a result with its token; no rebuild without a trigger; no alarm before the fast budget is spent; nothing raised on a closed gate). Merge.

---
# Stream E — Evidence: `CaptureDiagnostics` provenance and counters

One implementer, two tasks, serial. Branch after F merged. Owns `TranscriberCore/CaptureDiagnostics.swift` and `SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift` exclusively.

### Task E1: Per-track coverage in provenance; `compromised` from content kinds only (v1 P2.1 core) — needs C6 merged

**Files:**
- Modify: `TranscriberCore/CaptureDiagnostics.swift:123-143` (add `contentCompromising`), `:175-284` (`CaptureProvenance` fields, CodingKeys, decode, `asMetadataDictionary`), `:399-425` (`makeProvenance`, `tapTrackSeconds`)
- Test: `SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift` (add; red-first: `remoteCoverage` does not exist)

**Interfaces:**
```swift
// CaptureEventKind
public static let contentCompromising: Set<CaptureEventKind>   // rateDrift, exactZeroMic, systemAudioPermissionDenied, converterFailure, writeFailure, sustainedFormatDrop (§7.1)
// CaptureProvenance: + localCoverage: TrackAccounting?, remoteCoverage: TrackAccounting?, localStatus: String?, remoteStatus: String?
//   keys local_coverage / remote_coverage / local_status / remote_status; asMetadataDictionary emits the two coverage dicts (asMetadataDictionary(status:)) when present
// CaptureDiagnostics
public func contentAnomalyCount(track: String) -> Int           // "mic" | "system"
```

- [ ] **Step 1: Write the failing tests**

Append to `struct CaptureDiagnosticsTests`:
```swift
    /// A crash-recovered recording has several helper sessions, each with its own captureStop.
    @Test func provenanceSumsCoverageAcrossHelperSessions() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 100
        var b = TrackAccounting(); b.expectedSeconds = 50; b.deliveredSeconds = 0
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info, detail: b.asDetail(prefix: "remote")))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteCoverage?.expectedSeconds == 150)
        #expect(p.remoteCoverage?.deliveredSeconds == 100)
        #expect(p.remoteStatus == "compromised")
        #expect(p.systemDeliveredSeconds == 100, "legacy field derived from coverage")
        #expect(p.localCoverage == nil && p.localStatus == nil)
        let meta = p.asMetadataDictionary()
        #expect((meta["remote_coverage"] as? [String: Any])?["status"] as? String == "compromised")
        #expect(meta["local_coverage"] == nil)
    }

    /// Spec §7.1 (scan C12): only CONTENT-compromising kinds mark a side compromised. A stall that
    /// healed is evidence in the ring, not a verdict on the record.
    @Test func aHealedStallDoesNotCompromiseTheTrackButRateDriftDoes() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 99
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .livenessGap, severity: .anomaly, detail: ["track": "system", "seconds": "3"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .livenessRecovered, severity: .info, detail: ["track": "system"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(2), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "healthy")
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(3), origin: .helper, kind: .rateDrift, severity: .anomaly, detail: ["source": "system-tap"]))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "compromised")
        #expect(d.contentAnomalyCount(track: "mic") == 0)
    }

    @Test func micContentKindsCountForTheLocalSideOnly() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 60; a.deliveredSeconds = 60
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .exactZeroMic, severity: .anomaly))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info,
                              detail: a.asDetail(prefix: "local").merging(a.asDetail(prefix: "remote")) { x, _ in x }))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.localStatus == "compromised" && p.remoteStatus == "healthy")
    }

    @Test func coverageRoundTripsThroughCodable() throws {
        var a = TrackAccounting(); a.expectedSeconds = 10; a.deliveredSeconds = 9
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, remoteCoverage: a, remoteStatus: "healthy")
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(back.remoteCoverage == a && back.remoteStatus == "healthy" && back.localCoverage == nil)
    }
```
The existing `provenanceCarriesTapTrackExactZeroSeconds` (86-98) stays unchanged: the legacy `system_*` keys remain a fallback when no coverage keys are present.

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'CaptureDiagnosticsTests'` → compile error.

- [ ] **Step 3: Implement**

`CaptureDiagnostics.swift`:
- next to `qualityCompromising` (123-143):
```swift
    /// The kinds that mean a side's CONTENT is wrong (§7.1) — what turns a track's status into
    /// `compromised`. Healed liveness episodes (`livenessGap`, `neverDelivered`) and recovery events
    /// stay evidence: they are already counted in the coverage deficit if they cost audio.
    public static let contentCompromising: Set<CaptureEventKind> = [
        .rateDrift, .exactZeroMic, .systemAudioPermissionDenied, .converterFailure, .writeFailure, .sustainedFormatDrop,
    ]
```
- `CaptureProvenance`: four new optional fields (init parameters with `= nil` defaults appended after `systemExactZeroSeconds`), CodingKeys `local_coverage`, `remote_coverage`, `local_status`, `remote_status`, `decodeIfPresent`; `asMetadataDictionary` (267-283): when `remoteCoverage` is set, `d["remote_coverage"] = remoteCoverage.asMetadataDictionary(status: TrackAccounting.Status(rawValue: remoteStatus ?? "healthy") ?? .healthy)`; same for `local_coverage`.
- `CaptureDiagnostics`:
```swift
    /// Which side an event is about: its `track`/`source` detail, else the kind's own side.
    private static func side(of e: CaptureEvent) -> String? {
        if let t = e.detail["track"] ?? e.detail["source"] {
            if t == "mic" { return "mic" }
            if ["system", "system-tap", "tap"].contains(t) { return "system" }
        }
        switch e.kind {
        case .exactZeroMic: return "mic"
        case .systemAudioPermissionDenied, .rateDrift, .sustainedFormatDrop: return "system"
        default: return nil
        }
    }

    public func contentAnomalyCount(track: String) -> Int {
        events.filter { CaptureEventKind.contentCompromising.contains($0.kind) && Self.side(of: $0) == track }.count
    }

    private func coverage(prefix: String) -> TrackAccounting? {
        let parts = events.filter { $0.kind == .captureStop }.compactMap { TrackAccounting(detail: $0.detail, prefix: prefix) }
        guard var total = parts.first else { return nil }
        for p in parts.dropFirst() { total += p }
        return total
    }
```
  `makeProvenance` (399-419): `let remote = coverage(prefix: "remote")`, `let local = coverage(prefix: "local")`; pass `systemDeliveredSeconds: remote.map { Int($0.deliveredSeconds.rounded()) } ?? tapTrackSeconds("system_delivered_seconds")`, `systemExactZeroSeconds: remote.map { Int($0.exactZeroSeconds.rounded()) } ?? tapTrackSeconds("system_exact_zero_seconds")`, `localCoverage: local`, `remoteCoverage: remote`, `localStatus: local.map { $0.status(isTap: false, contentAnomalies: contentAnomalyCount(track: "mic")).rawValue }`, `remoteStatus: remote.map { $0.status(isTap: true, contentAnomalies: contentAnomalyCount(track: "system")).rawValue }`. Keep `tapTrackSeconds` (421-425) as the legacy fallback.

- [ ] **Step 4: Run, full suite, commit**

Run: `$PARLEY_TEST --filter 'CaptureDiagnosticsTests'` → pass; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/CaptureDiagnostics.swift SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift
git commit -m "feat(provenance): local/remote coverage + status in CaptureProvenance; compromised only from content kinds (B7/B8, H8, §7.1)"
```

---

### Task E2: Counters outside the ring; `resetSession()`; `events_dropped`; merge without double counting (v1 P3.6 core)

**Files:**
- Modify: `TranscriberCore/CaptureDiagnostics.swift:291-360` (`CaptureDiagnostics` stored counters, `record`, `evict`, `clear`, `merge`, `resetSession`), `:175-284` (`CaptureProvenance.eventsDropped`, key `events_dropped`), `:399-419` (`makeProvenance`)
- Test: `SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift` — `clearThenProvenanceReflectsOnlyNewEvents` (180-203) changes (red-first: its assertions invert), plus three new tests

**Interfaces:**
```swift
// CaptureDiagnostics
public private(set) var retryCount: Int          // stored, survives eviction and clear()
public private(set) var launchRecoveries: Int    // stored, survives eviction and clear()
public private(set) var droppedCount: Int        // existing; now survives clear()
public mutating func clear()                     // events only (an in-session restart)
public mutating func resetSession()              // events AND counters (a new session id)
// CaptureProvenance: + eventsDropped: Int (key events_dropped, default 0)
```

- [ ] **Step 1: Change the enshrined test and add the new ones**

Replace `clearThenProvenanceReflectsOnlyNewEvents` (lines 180-203) with:
```swift
    // #101 per-session reset, restated for v2 (L4/L14): `clear()` is an IN-SESSION restart and keeps the
    // counters that live outside the ring; `resetSession()` is the new-session reset that zeroes them.
    @Test func clearKeepsTheOutOfRingCountersAndResetSessionZeroesThem() {
        var d = CaptureDiagnostics()
        d.record(event(.restartInPlace, .warning, at: 0))
        d.record(event(.restartInPlace, .warning, at: 1))
        d.record(event(.retry, .warning, at: 2))
        d.record(event(.launchRecovery, .warning, at: 3))
        d.record(event(.streamStopError, .anomaly, at: 4))
        let dirty = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(dirty.routeChanges == 2 && dirty.anomalyCount == 1 && dirty.retries == 1 && dirty.recovered)

        d.clear()
        d.record(event(.captureStart, .info, at: 10))
        let restarted = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(restarted.routeChanges == 0 && restarted.anomalyCount == 0 && restarted.systemAudioUnrecovered == false)
        #expect(restarted.retries == 1 && restarted.recovered == true, "the restart is part of this session's story")

        d.resetSession()
        d.record(event(.captureStart, .info, at: 20))
        let fresh = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(fresh.retries == 0 && fresh.recovered == false && fresh.eventsDropped == 0)
    }

    @Test func countersSurviveEvictionAndClear() {
        var d = CaptureDiagnostics(maxEvents: 2)
        d.record(event(.retry, .warning, at: 0))
        d.record(event(.retry, .warning, at: 1))
        d.record(event(.retry, .warning, at: 2))
        #expect(d.events.count == 2 && d.droppedCount == 1)
        #expect(d.retryCount == 3, "the evicted retry still counts")
        d.clear()
        #expect(d.retryCount == 3 && d.droppedCount == 1)
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).eventsDropped == 1)
    }

    /// Scan B P3.6(2): `merge()` re-records the ring's own events; that must not count them twice.
    @Test func mergeDoesNotDoubleCountTheCounters() {
        var d = CaptureDiagnostics()
        d.record(event(.retry, .warning, at: 0))
        d.merge([event(.retry, .warning, at: 1, origin: .helper)])
        #expect(d.events.count == 2 && d.retryCount == 2)
        d.merge([])
        #expect(d.retryCount == 2)
    }

    @Test func eventsDroppedRoundTripsInProvenance() throws {
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, eventsDropped: 7)
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(back.eventsDropped == 7 && p.asMetadataDictionary()["events_dropped"] as? Int == 7)
        let legacy = Data(#"{"engine":"e","route_changes":0,"retries":0,"recovered":false,"anomaly_count":0}"#.utf8)
        #expect(try JSONDecoder().decode(CaptureProvenance.self, from: legacy).eventsDropped == 0)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'CaptureDiagnosticsTests'` → compile errors (`retryCount` is computed today and `resetSession`/`eventsDropped` do not exist); the changed test's `retries == 1` after `clear()` would fail.

- [ ] **Step 3: Implement**

`CaptureDiagnostics`:
- replace the computed `retryCount` (358) and `didRecover` (359) with stored `public private(set) var retryCount = 0`, `public private(set) var launchRecoveries = 0`; `didRecover` becomes `launchRecoveries > 0`.
- `record(_:)` (322-328) → `record(event); count(event)` where `private mutating func count(_ e: CaptureEvent) { if e.kind == .retry { retryCount += 1 }; if e.kind == .launchRecovery { launchRecoveries += 1 } }` and the append/evict body moves to `private mutating func store(_ event: CaptureEvent)`.
- `clear()` (339-344): removes events, byteCosts, totalBytes only — NOT `droppedCount`, `retryCount`, `launchRecoveries`.
- `resetSession()`: `clear()` + zero the three counters.
- `merge(_ other:)` (347-351): `let combined = (events + other).sorted { … }; clear(); for e in combined { store(e) }; for e in other { count(e) }` — the ring's own events were counted when first recorded.
- `CaptureProvenance`: `public let eventsDropped: Int` (init parameter `eventsDropped: Int = 0` appended, key `events_dropped`, `decodeIfPresent ?? 0`, always emitted by `asMetadataDictionary`). `makeProvenance` passes `eventsDropped: droppedCount`.

- [ ] **Step 4: Run, full suite, commit**

Run: `$PARLEY_TEST --filter 'CaptureDiagnosticsTests'` → pass; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/CaptureDiagnostics.swift SwiftTests/TranscriberTests/CaptureDiagnosticsTests.swift
git commit -m "fix(evidence): retry/launch-recovery/dropped counters live outside the ring; clear() is in-session, resetSession() is per session; merge counts once (L4, L14, H7)"
```

### E gate

Stream gate; merge. E1 unblocks R1; E2 unblocks L11.

---
# Stream R — Record: the honest transcript and post-capture data loss

One implementer, serial. Branch after F merged. R0 first: it is what L7/L9/L10 wait for.

### Task R0: Runner and session seams for the lifecycle stream

**Files:**
- Modify: `TranscriberCore/ChunkSession.swift:112-207` (`CaptureGap`, `SessionState.gaps`, explicit Codable), `TranscriberCore/ChunkProcessor.swift:26-41` (`StateStore.appendGap`), `:90` (`appendGap`), `TranscriberCore/TranscriptionRunner.swift:335-339` (`finalizeDelayForTesting`), `:442-454` (`assemble(captureGaps:)`), `:512-547` (`setupChunkedPipeline(seededState:)`, `failSetupForTesting`, `recordCaptureGap`), `TranscriberCore/TranscriptAssembler.swift:7-18` (`captureGaps:`)
- Test: `SwiftTests/TranscriberTests/ChunkSessionTests.swift`, `TranscriptAssemblerTests.swift`, `TranscriptionRunnerTests.swift` (add; red-first: new members)

**Interfaces:**
```swift
public struct CaptureGap: Codable, Equatable, Sendable {
    public let start: Date; public let end: Date; public let reason: String   // "app relaunch" | "sleep"
    public var seconds: Double { end.timeIntervalSince(start) }
    public init(start: Date, end: Date, reason: String)
}
// SessionState: + gaps: [CaptureGap] (default [], decodeIfPresent)
// ChunkProcessor: func appendGap(_ gap: CaptureGap) async     // persists session.json
// TranscriptionRunner
public func setupChunkedPipeline(captureClient:outputDirectory:sessionBaseName:config:seededState: SessionState? = nil) throws
public func recordCaptureGap(_ gap: CaptureGap)                  // → chunkProcessor.appendGap, fire-and-forget
var failSetupForTesting = false                                   // internal seam: setupChunkedPipeline throws before creating the processor
var finalizeDelayForTesting: Duration? = nil                      // internal seam: finalize sleeps first
// TranscriptAssembler.assemble(..., captureGaps: [CaptureGap] = [])   → metadata.capture.gaps (creates metadata.capture when absent)
```

- [ ] **Step 1: Write the failing tests**

`ChunkSessionTests.swift` (inside the suite; `makeSession(chunks:)` and `makeTempDir()` exist at lines 38 and 10):
```swift
    @Test("sessionStateGapsDefaultToEmptyAndRoundTrip")
    func sessionStateGapsDefaultToEmptyAndRoundTrip() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var state = makeSession(chunks: [])
        try SessionState.write(state, directory: dir)
        #expect(SessionState.read(directory: dir)?.gaps == [])
        let gap = CaptureGap(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 220), reason: "sleep")
        state.gaps.append(gap)
        try SessionState.write(state, directory: dir)
        let back = try #require(SessionState.read(directory: dir))
        #expect(back.gaps.count == 1 && back.gaps[0].reason == "sleep" && back.gaps[0].seconds == 120)
    }
```
`TranscriptAssemblerTests.swift`:
```swift
    /// Scan A113: gaps must land in metadata.capture even when no coverage was stamped (a fake or an
    /// old helper); the `capture` dictionary is created on demand.
    @Test func captureGapsLandInMetadataCaptureEvenWithoutCoverage() throws {
        let gap = CaptureGap(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 14), reason: "app relaunch")
        let json = TranscriptAssembler.assemble(
            segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
            diarization: false, dualStream: false, captureGaps: [gap])
        let capture = try #require((json["metadata"] as? [String: Any])?["capture"] as? [String: Any])
        let gaps = try #require(capture["gaps"] as? [[String: Any]])
        #expect(gaps.count == 1 && gaps[0]["reason"] as? String == "app relaunch" && gaps[0]["seconds"] as? Double == 4)
        #expect(gaps[0]["start"] as? String == "1970-01-01T00:00:10Z")
    }
```
`TranscriptionRunnerTests.swift` (new suite at the end of the file):
```swift
@MainActor
@Suite struct TranscriptionRunnerPipelineSeamTests {
    private final class NoopRotationClient: ChunkRotationClient {
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            ("\(outputDirectory)/\(newBaseName).wav", "\(outputDirectory)/\(newBaseName)_mic.wav")
        }
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runner-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L7: a relaunch seeds the pipeline with the persisted session so completed chunks are not re-done.
    @Test func seededStateIsUsedByTheChunkPipeline() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                                   segments: [], speakerDatabase: [:])
        let seeded = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default, seededState: seeded)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.chunks.map(\.index) == [0] && state.sessionId == "m")
        runner.teardownChunkedPipeline()
    }

    @Test func recordCaptureGapPersistsIntoSessionJson() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default)
        let processor = try #require(runner.chunkProcessor)
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
        #expect(SessionState.read(directory: dir)?.gaps.map(\.reason) == ["sleep"])
        runner.teardownChunkedPipeline()
    }

    @Test func failSetupForTestingThrowsBeforeCreatingTheProcessor() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        runner.failSetupForTesting = true
        #expect(throws: (any Error).self) {
            try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default)
        }
        #expect(runner.chunkProcessor == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'ChunkSessionTests|TranscriptAssemblerTests|TranscriptionRunnerPipelineSeamTests'` → compile errors.

- [ ] **Step 3: Implement**

`ChunkSession.swift`: add `CaptureGap` (before `SessionState`); `SessionState` gains `public var gaps: [CaptureGap]` (init parameter `gaps: [CaptureGap] = []`), and — since its Codable is synthesized today — an explicit `CodingKeys` (`sessionId, meetingStart, engine, chunkDurationMinutes, chunks, provenance, gaps`) with `init(from:)` using `decodeIfPresent` for `provenance` and `gaps ?? []` (R2 adds `issues` the same way).

`ChunkProcessor.swift`: `StateStore` (26-41) gains `func appendGap(_ gap: CaptureGap) -> SessionState { sessionState.gaps.append(gap); return sessionState }`; the class gains
```swift
    /// A period during which nothing was recorded (relaunch, sleep). Persisted with the session so a
    /// later relaunch and the final transcript both see it (§7.2 metadata.capture.gaps).
    public nonisolated func appendGap(_ gap: CaptureGap) async {
        let snapshot = await stateStore.appendGap(gap)
        do { try SessionState.write(snapshot, directory: outputDirectory) }
        catch { Logger.state.error("Failed to write session.json after a capture gap: \(error, privacy: .public)") }
    }
```
`TranscriptionRunner.swift`: `setupChunkedPipeline` (512-547): parameter `seededState: SessionState? = nil`; `if failSetupForTesting { throw SetupFailure.forTesting }` (a private `enum SetupFailure: Error { case forTesting }`) as the first statement; `let sessionState = seededState ?? SessionState(...)`. Add `public func recordCaptureGap(_ gap: CaptureGap) { let p = chunkProcessor; Task { await p?.appendGap(gap) } }`, `var failSetupForTesting = false`, `var finalizeDelayForTesting: Duration?`; `finalize` (335-339) starts with `if let d = finalizeDelayForTesting { try await Task.sleep(for: d) }`; the `assemble` call (442-454) passes `captureGaps: sessionState.gaps`.

`TranscriptAssembler.assemble` (7-18): parameter `captureGaps: [CaptureGap] = []`; after the provenance block: `if !captureGaps.isEmpty { var capture = metadata["capture"] as? [String: Any] ?? [:]; capture["gaps"] = captureGaps.map { ["start": iso8601($0.start), "end": iso8601($0.end), "seconds": $0.seconds, "reason": $0.reason] }; metadata["capture"] = capture }` (use the same ISO8601 formatter as `recorded_at`).

- [ ] **Step 4: Run, full suite, commit**

Run: `$PARLEY_TEST --filter 'ChunkSessionTests|TranscriptAssemblerTests|TranscriptionRunnerPipelineSeamTests'` → pass; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/ChunkSession.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/TranscriptionRunner.swift TranscriberCore/TranscriptAssembler.swift SwiftTests/TranscriberTests/ChunkSessionTests.swift SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift
git commit -m "feat(record): CaptureGap in the session and metadata.capture.gaps; seeded chunk pipeline; runner test seams (§7.2, L1, L12)"
```

---

### Task R1: `metadata.capture`, `dual_stream` from capture, summary header (v1 P2.1 record part) — needs E1 merged

**Files:**
- Modify: `TranscriberCore/TranscriptAssembler.swift` (coverage into `metadata.capture`), `TranscriberCore/TranscriptionRunner.swift:397` (`isDualStream`), `TranscriberCore/MeetingSummarizer.swift:174-217` (`parseTranscript`), `TranscriberCore/SummaryProvider.swift:19-36` (`CaptureSideNote`, `SummaryMetadata.remoteCapture/localCapture`), `TranscriberCore/SummaryPromptBuilder.swift:17-30, 55-95`
- Test: `TranscriptAssemblerTests.swift`, `TranscriptionRunnerTests.swift`, `SummaryPromptBuilderTests.swift`, `MeetingSummarizerTests.swift` (add; red-first)

**Interfaces:**
```swift
public struct CaptureSideNote: Equatable, Sendable { public let status: String; public let deliveredSeconds: Double; public let expectedSeconds: Double; public init(status:deliveredSeconds:expectedSeconds:) }
// SummaryMetadata init: + remoteCapture: CaptureSideNote? = nil, localCapture: CaptureSideNote? = nil
// MeetingSummarizer: static func parseTranscriptForTesting(at: URL) throws -> ([SummarySegment], SummaryMetadata)
// SummaryPromptBuilder: static func captureLine(_ metadata: SummaryMetadata) -> String?
```

- [ ] **Step 1: Write the failing tests**

`TranscriptAssemblerTests.swift`:
```swift
    @Test func coverageLandsInMetadataCapture() throws {
        var remote = TrackAccounting(); remote.expectedSeconds = 2736; remote.deliveredSeconds = 0
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, remoteCoverage: remote, remoteStatus: "neverDelivered")
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                diarization: false, dualStream: false, provenance: p)
        let capture = try #require((json["metadata"] as? [String: Any])?["capture"] as? [String: Any])
        let r = try #require(capture["remote"] as? [String: Any])
        #expect(r["status"] as? String == "neverDelivered" && r["expected_seconds"] as? Double == 2736)
        #expect(capture["local"] == nil)
    }
```
`TranscriptionRunnerTests.swift` (in `TranscriptionRunnerPipelineSeamTests` from R0):
```swift
    /// P8: `dual_stream` is the capture-time flag the writer persisted, not "did a local segment survive".
    @Test func finalizeStampsDualStreamFromTheChunkFlags() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 5, text: "hi", speaker: "Remote Speaker 1", source: "remote")],
            speakerDatabase: ["Remote Speaker 1": [1, 0, 0]], localSpeakerDatabase: [:], isDualStream: true)
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
        #expect((json?["metadata"] as? [String: Any])?["dual_stream"] as? Bool == true)
    }
```
`SummaryPromptBuilderTests.swift`:
```swift
    @Test func headerNamesAnUncapturedRemoteSide() {
        let m = SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["Frederic"],
                                dualStream: true, echoSegmentsRemoved: 0,
                                remoteCapture: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 2736))
        let msg = SummaryPromptBuilder.userMessage(metadata: m, segments: [])
        #expect(msg.contains("Remote audio: not captured (0 s delivered of 2736 s expected)"))
        #expect(SummaryPromptBuilder.captureLine(SummaryMetadata(sessionName: "s", date: Date(), durationSeconds: 1, speakers: [])) == nil)
        #expect(SummaryPromptBuilder.systemPrompt.contains("state that in the Summary section"))
    }
```
`MeetingSummarizerTests.swift`:
```swift
    @Test func parsesCaptureCoverageFromMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["capture": ["remote": ["status": "neverDelivered", "delivered_seconds": 0.0, "expected_seconds": 2736.0]]],
            "segments": [] as [Any],
        ]).write(to: url)
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(meta.remoteCapture == CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 2736))
        #expect(meta.localCapture == nil)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'TranscriptAssemblerTests|TranscriptionRunnerPipelineSeamTests|SummaryPromptBuilderTests|MeetingSummarizerTests'` → compile errors.

- [ ] **Step 3: Implement**

`TranscriptAssembler.assemble`: when `provenance?.remoteCoverage` / `localCoverage` is set, merge `["remote": …asMetadataDictionary(status:)]` / `["local": …]` into `metadata["capture"]` (created on demand, alongside R0's `gaps`).

`TranscriptionRunner.finalize` line 397: `let isDualStream = chunksAreDualStream` (the variable already computed at 354).

`SummaryProvider.swift`: `CaptureSideNote`; `SummaryMetadata` gains `public let remoteCapture: CaptureSideNote?`, `localCapture: CaptureSideNote?` (init defaults nil).

`MeetingSummarizer.parseTranscript` (174-217): read `metadata.capture.remote` / `.local` (`status: String`, `delivered_seconds: Double`, `expected_seconds: Double`) into the notes; add `static func parseTranscriptForTesting(at url: URL) throws -> ([SummarySegment], SummaryMetadata) { try parseTranscript(at: url) }` (internal).

`SummaryPromptBuilder`: `static func captureLine(_ metadata: SummaryMetadata) -> String?` — `"Remote audio: not captured (0 s delivered of 2736 s expected)"` for `neverDelivered`, `"Remote audio: partly captured (X s delivered of Y s expected)"` for `compromised`, `"Remote audio: nothing was playing on this Mac (no remote side)"` for `idle`, nothing for `healthy`; same for local with the prefix "Your microphone"; both lines joined with "\n" when both apply. `userMessage` (17-30) inserts it after the `Participants:` line (23). `systemPrompt` (55) gains the rule `- If a "Remote audio" or "Your microphone" line says a side was not captured, state that in the Summary section before anything else.`

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/TranscriptAssembler.swift TranscriberCore/TranscriptionRunner.swift TranscriberCore/MeetingSummarizer.swift TranscriberCore/SummaryProvider.swift TranscriberCore/SummaryPromptBuilder.swift SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift SwiftTests/TranscriberTests/SummaryPromptBuilderTests.swift SwiftTests/TranscriberTests/MeetingSummarizerTests.swift
git commit -m "feat(record): metadata.capture coverage, dual_stream from the chunk flags, summary states an uncaptured side (H8, P8, Inv 4)"
```

---

### Task R2: `ChunkIssue` — nothing swallowed inside a chunk stays silent; chunk-index dedup; session-write hook (v1 P2.2 + the ChunkProcessor parts of P3.2/P3.3)

**Files:**
- Modify: `TranscriberCore/ChunkSession.swift` (`ChunkIssue`, `ProcessedChunk.issues`, `SessionState.issues`), `TranscriberCore/ChunkProcessor.swift:23` (index tracking), `:64-79` (`processChunk`/`processLastChunk` guards), `:96-248` (`processChunkAsync`: issues, ASR-failed keeps WAVs, session-write hook), `:251-331` (`StreamResult.issues`, `transcribeStream` sites), `TranscriberCore/TranscriptionRunner.swift:440-454` (issues → assemble), `TranscriberCore/TranscriptAssembler.swift` (`processingIssues:`), `TranscriberCore/CaptureQualityNotice.swift` (new overloads; old ones kept), `TranscriberCore/StreamLabeling.swift:20-30` (returns `absorbed`), `TranscriberCore/DiarizationCleanup.swift:54-57` (`absorbMinorityClustersCounting`)
- Test: `ChunkProcessorTests.swift`, `ChunkSessionTests.swift`, `CaptureQualityNoticeTests.swift`, `TranscriptAssemblerTests.swift` (add; red-first)

**Interfaces:**
```swift
public struct ChunkIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case asrFailed = "asr_failed", diarizationFailed = "diarization_failed", vadUnavailable = "vad_unavailable",
             streamEmpty = "stream_empty", archiveFailed = "archive_failed", sessionWriteFailed = "session_write_failed",
             duplicatesDropped = "duplicates_dropped", segmentsFiltered = "segments_filtered",
             clustersAbsorbed = "clusters_absorbed", echoFlagged = "echo_flagged"
    }
    public let code: Code; public let track: String?; public let count: Int?
    public init(code: Code, track: String?, count: Int?)
    /// asrFailed, diarizationFailed, archiveFailed, sessionWriteFailed. NOT streamEmpty (an idle side is not a problem, §7.1/§9 — scan C13).
    public var affectsContent: Bool
}
public struct SessionIssue: Codable, Equatable, Sendable { public let chunk: Int; public let issue: ChunkIssue }
// ProcessedChunk.issues: [ChunkIssue] (default [])   SessionState.issues: [SessionIssue] (default [])
// ChunkProcessor: var onSessionWriteFailure: ((Int) -> Void)?   // L8 raises sessionWriteFailed
// TranscriptAssembler.assemble(..., processingIssues: [[String: Any]] = [])   → metadata.processing_issues, processing_issue_count (content-affecting), processing_problem_chunks (distinct chunks with a content-affecting issue)
// CaptureQualityNotice
public static func completionTitle(anomalyCount: Int, problemChunkCount: Int, segmentCount: Int) -> String
public static func completionBody(fileName: String, anomalyCount: Int, problemChunkCount: Int, segmentCount: Int) -> String
public static func problemChunkCount(inTranscriptAt: URL) -> Int
public static func segmentCount(inTranscriptAt: URL) -> Int
// the existing completionTitle(anomalyCount:) / completionBody(fileName:anomalyCount:) STAY and delegate with problemChunkCount: 0, segmentCount: 1
```
Title precedence (spec §7.3, amended): `segmentCount == 0` → "Transcription Complete — no speech was transcribed"; else `anomalyCount > 0` → "Transcription Complete — capture anomalies"; else `problemChunkCount > 0` → "Transcription Complete — N chunk(s) had processing problems"; else "Transcription Complete". The body names every count that is non-zero.

- [ ] **Step 1: Write the failing tests**

`ChunkProcessorTests.swift` — add at FILE scope (after the imports, before the suite; scan A122):
```swift
/// An engine whose transcribe() always throws (ASR failure path).
struct ThrowingEngine: TranscriptionEngine {
    let name = "Throwing"
    struct Boom: Error {}
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}
```
and inside `ChunkProcessorTests` (the `makeTempDir()`, `FakeEngine`, `FakeDiarizer`, `RecoveryFixtures.writeFakeWav(at:seconds:)` fixtures exist):
```swift
    private func makeProcessor(dir: URL, engine: any TranscriptionEngine) -> ChunkProcessor {
        ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
            transcriber: engine, diarizer: FakeDiarizer())
    }
    private func chunk0(in dir: URL) -> ChunkRotator.FinalizedChunk {
        ChunkRotator.FinalizedChunk(index: 0, systemPath: dir.appendingPathComponent("meeting-0.wav").path,
                                    micPath: dir.appendingPathComponent("meeting-0_mic.wav").path, startTime: Date(timeIntervalSince1970: 0))
    }

    /// P3: an ASR failure used to become an empty chunk and "Transcription Complete".
    @Test func anAsrFailureIsRecordedAsAChunkIssueAndKeepsTheWav() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sysURL = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sysURL, seconds: 1)
        let processor = makeProcessor(dir: dir, engine: ThrowingEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .asrFailed, track: "remote", count: nil)))
        #expect(FileManager.default.fileExists(atPath: sysURL.path), "the WAV of an ASR-failed chunk is kept for re-transcription")
    }

    /// §7.1/§9 (scan C13): an empty side is recorded, but it is not a "processing problem".
    @Test func anEmptyStreamIsRecordedButDoesNotAffectContent() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 0)   // 44-byte header
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        let issue = try #require(chunk.issues.first { $0.code == .streamEmpty })
        #expect(issue.track == "remote" && issue.affectsContent == false)
    }

    /// L6/L7 (scan B P3.2): the orphan re-ingested by the crash path and the same index arriving again
    /// from the rotator must not produce two chunks.
    @Test func processingTheSameChunkIndexTwiceAppendsOnce() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        await processor.processLastChunk(chunk0(in: dir))
        await processor.processLastChunk(chunk0(in: dir))
        processor.processChunk(chunk0(in: dir))
        await processor.awaitAllProcessed()
        #expect(await processor.getSessionState().chunks.map(\.index) == [0])
    }

    /// L10: a session.json that cannot be written is reported to the coordinator hook and recorded.
    @Test func aSessionWriteFailureIsReportedAndRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        final class Sink { var indices: [Int] = [] }
        let reported = Sink()
        processor.onSessionWriteFailure = { reported.indices.append($0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)   // no new files in dir
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        await processor.processLastChunk(chunk0(in: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(reported.indices == [0])
        #expect(await processor.getSessionState().issues.contains(SessionIssue(chunk: 0, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))))
    }
```
(The archive step in that last test also fails under 0o500 — that is fine: it records `.archiveFailed` and keeps the WAV; the assertion is on the session-write hook.)

`ChunkSessionTests.swift`:
```swift
    @Test("processedChunkIssuesDefaultToEmptyAndDecode")
    func processedChunkIssuesDefaultToEmptyAndDecode() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bare = Data(#"{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","segments":[],"speakerDatabase":{}}"#.utf8)
        #expect(try decoder.decode(ProcessedChunk.self, from: bare).issues == [])
        let withIssue = Data(#"{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","segments":[],"speakerDatabase":{},"issues":[{"code":"asr_failed","track":"remote"}]}"#.utf8)
        #expect(try decoder.decode(ProcessedChunk.self, from: withIssue).issues == [ChunkIssue(code: .asrFailed, track: "remote", count: nil)])
    }
```
`CaptureQualityNoticeTests.swift`:
```swift
    /// §7.3 precedence: no speech > capture anomalies > processing problems > complete.
    @Test func processingIssuesGetTheirOwnTitleWithPrecedence() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 2, segmentCount: 40) == "Transcription Complete — 2 chunks had processing problems")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 1, segmentCount: 40) == "Transcription Complete — 1 chunk had processing problems")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 0) == "Transcription Complete — no speech was transcribed")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1, problemChunkCount: 1, segmentCount: 40) == "Transcription Complete — capture anomalies")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 40) == "Transcription Complete")
        let body = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1, problemChunkCount: 2, segmentCount: 40)
        #expect(body.contains("1 capture anomaly") && body.contains("2 chunks had processing problems"))
    }

    @Test func problemChunkCountReadsDistinctChunksWithContentIssues() throws {
        let url = try writeTranscript(["metadata": ["processing_issues": [
            ["chunk": 0, "code": "asr_failed", "track": "remote"],
            ["chunk": 0, "code": "diarization_failed", "track": "local"],
            ["chunk": 3, "code": "stream_empty", "track": "remote"],
        ], "processing_problem_chunks": 1], "segments": [["start": 0, "end": 1, "text": "x", "speaker": "S"]]])
        #expect(CaptureQualityNotice.problemChunkCount(inTranscriptAt: url) == 1)
        #expect(CaptureQualityNotice.segmentCount(inTranscriptAt: url) == 1)
    }
```
`TranscriptAssemblerTests.swift`:
```swift
    @Test func processingIssuesLandInMetadataWithCounts() throws {
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
            diarization: false, dualStream: false,
            processingIssues: [["chunk": 0, "code": "asr_failed", "track": "remote"], ["chunk": 0, "code": "stream_empty", "track": "local"], ["chunk": 2, "code": "asr_failed", "track": "remote"]])
        let m = try #require(json["metadata"] as? [String: Any])
        #expect((m["processing_issues"] as? [[String: Any]])?.count == 3)
        #expect(m["processing_issue_count"] as? Int == 2, "stream_empty does not affect content")
        #expect(m["processing_problem_chunks"] as? Int == 2)
    }
```

- [ ] **Step 2: Run to verify they fail** → compile errors (`issues`, `ChunkIssue`, `onSessionWriteFailure`, new overloads).

- [ ] **Step 3: Implement**

`ChunkSession.swift`: `ChunkIssue` (with `affectsContent` = code ∈ {asrFailed, diarizationFailed, archiveFailed, sessionWriteFailed}), `SessionIssue`; `ProcessedChunk.issues` (init default `[]`, CodingKey `issues`, `decodeIfPresent ?? []` in the custom init at 89-105); `SessionState.issues` (default `[]`, `decodeIfPresent` in R0's `init(from:)`).

`ChunkProcessor.swift`:
- index dedup: `private var settledIndices: Set<Int> = []` (main actor) and `private nonisolated let inFlightIndices = OSAllocatedUnfairLock<Set<Int>>(initialState: [])`; `processChunk` (64) and `processLastChunk` (77) first `guard inFlightIndices.withLock({ $0.insert(chunk.index).inserted })` and skip if the store already holds the index (`await stateStore.getSessionState().chunks.contains { $0.index == chunk.index }`); on completion the index stays in the set (a settled chunk is never re-done). Log the skip at `.info`.
- `StreamResult` (251-254) gains `issues: [ChunkIssue]`; `transcribeStream` (264-331): empty stream (276-280) → `issues: [ChunkIssue(code: .streamEmpty, track: source, count: nil)]`; ASR catch (287-290) → `.asrFailed`; VAD nil with a diarizer (301) → `.vadUnavailable`; diarization catch (312-320) → `.diarizationFailed`; `StreamLabeling.withDiarization` returns `absorbed: Int` → `.clustersAbsorbed(count)` when > 0.
- `processChunkAsync` (96-248): `var issues = systemResult.issues + micResult.issues`; echo dedup (141-152) → `.echoFlagged(count: removedCount)` when > 0; archive `catch` (209-221) → `.archiveFailed`; an ASR-failed chunk archives with `preserveSourceWAV: true` (both WAVs stay next to the `.m4a`); `ProcessedChunk(... issues: issues)`; session write catch (240-242) → `let snapshot2 = await stateStore.noteSessionWriteFailure(chunkIndex: chunk.index)` (appends `SessionIssue(chunk:, issue: .sessionWriteFailed)` to the in-memory state so the next successful write persists it) and `await MainActor.run { onSessionWriteFailure?(chunk.index) }`; `@MainActor public var onSessionWriteFailure: ((Int) -> Void)?`.

`StreamLabeling.withDiarization` (20-30): return type gains `absorbed: Int` from `DiarizationCleanup.absorbMinorityClustersCounting(_:minShare:) -> (DiarizationResult, absorbed: Int)`; the old `absorbMinorityClusters` wraps it.

`TranscriptionRunner.finalize` (440-454): `let processingIssues = sortedChunks.flatMap { c in c.issues.map { ["chunk": c.index, "code": $0.code.rawValue, "track": $0.track as Any, "count": $0.count as Any] } } + sessionState.issues.map { ["chunk": $0.chunk, "code": $0.issue.code.rawValue] }`; `diarization: diarizer != nil && !processingIssues.contains { $0["code"] as? String == "diarization_failed" }` (the `diarization: true` literal at 448 goes); pass `processingIssues:`.

`TranscriptAssembler.assemble`: parameter `processingIssues: [[String: Any]] = []` → `metadata["processing_issues"]`, `processing_issue_count` (issues whose code is content-affecting per `ChunkIssue.Code(rawValue:)`), `processing_problem_chunks` (distinct `chunk` values among those).

`CaptureQualityNotice`: the four new statics per Interfaces; `problemChunkCount(inTranscriptAt:)` reads `metadata.processing_problem_chunks`; `segmentCount(inTranscriptAt:)` reads `segments.count`; the old overloads delegate.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/ChunkSession.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/TranscriptionRunner.swift TranscriberCore/TranscriptAssembler.swift TranscriberCore/CaptureQualityNotice.swift TranscriberCore/StreamLabeling.swift TranscriberCore/DiarizationCleanup.swift SwiftTests/TranscriberTests/ChunkProcessorTests.swift SwiftTests/TranscriberTests/ChunkSessionTests.swift SwiftTests/TranscriberTests/CaptureQualityNoticeTests.swift SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift
git commit -m "feat(record): ProcessedChunk.issues → metadata.processing_issues; completion notice names processing problems; ASR-failed chunks keep their WAV; chunk index processed once; session-write hook (P3, P7, L7, L10)"
```

---

### Task R3: Text dedup only for abutting repeats, counted (v1 P2.4)

**Files:**
- Modify: `TranscriberCore/SpeakerAssignment.swift:70-85`, `TranscriberCore/FluidAudioEngine.swift:123`, `TranscriberCore/SpeechAnalyzerEngine.swift:141`, `TranscriberCore/ChunkProcessor.swift:285-290`, `TranscriberCore/TranscriptionRunner.swift:696`
- Test: `SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift:9-48` (replace the four `deduplicate` tests; red-first: `.segments`/`.dropped` do not exist)

- [ ] **Step 1: Replace the tests at lines 9-48 with**

```swift
    /// P2: "Yes." … "Yes." minutes apart are two answers. 20 same-stream repeats 0.6–80 s apart
    /// survived in real transcripts only because the case differed.
    @Test func aRepeatFarApartSurvives() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "Yes.", language: nil), TranscriptSegment(start: 11, end: 12, text: "Yes.", language: nil)]
        let r = SpeakerAssignment.deduplicate(segs)
        #expect(r.segments.count == 2 && r.dropped == 0)
    }
    @Test func anAbuttingRepeatIsDroppedAndCounted() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "Yes.", language: nil), TranscriptSegment(start: 1.1, end: 2, text: " yes. ", language: nil)]
        let r = SpeakerAssignment.deduplicate(segs)
        #expect(r.segments.count == 1 && r.dropped == 1)
    }
    @Test func zeroDurationIsStillDropped() {
        let r = SpeakerAssignment.deduplicate([TranscriptSegment(start: 5, end: 5, text: "x", language: nil)])
        #expect(r.segments.isEmpty && r.dropped == 1)
    }
    @Test func nonConsecutiveRepeatsAreKept() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "hello", language: nil), TranscriptSegment(start: 1, end: 2, text: "world", language: nil),
                    TranscriptSegment(start: 2, end: 3, text: "hello", language: nil)]
        #expect(SpeakerAssignment.deduplicate(segs).segments.count == 3)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'SpeakerAssignmentTests'` → compile error.

- [ ] **Step 3: Implement**

`SpeakerAssignment.swift` (70-85):
```swift
    /// Remove zero-duration segments and a repeat that ABUTS the previous segment (a decoder
    /// stutter). A repeat further away is a real repeated answer and is kept (P2).
    public static func deduplicate(_ segments: [TranscriptSegment], maxGapSeconds: Double = 0.25)
        -> (segments: [TranscriptSegment], dropped: Int) {
        var cleaned: [TranscriptSegment] = []
        var dropped = 0
        for seg in segments {
            if seg.start == seg.end { dropped += 1; continue }
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces).lowercased()
            if let prev = cleaned.last,
               prev.text.trimmingCharacters(in: .whitespaces).lowercased() == trimmed,
               seg.start <= prev.end + maxGapSeconds {
                dropped += 1
                continue
            }
            cleaned.append(seg)
        }
        return (cleaned, dropped)
    }
```
`FluidAudioEngine.swift:123` and `SpeechAnalyzerEngine.swift:141`: `return segments` (the engines no longer dedup). `ChunkProcessor.transcribeStream` (after the `transcribe` call at 286): `let dedup = SpeakerAssignment.deduplicate(segments); segments = dedup.segments; if dedup.dropped > 0 { issues.append(ChunkIssue(code: .duplicatesDropped, track: source, count: dedup.dropped)) }`. `TranscriptionRunner.transcribeStream` (the CLI/`run()` path, line 696): the same call; the count is logged at `.info` (that path has no chunk issues; the CLI `run()` semantics are a non-goal, §13).

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/SpeakerAssignment.swift TranscriberCore/FluidAudioEngine.swift TranscriberCore/SpeechAnalyzerEngine.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/TranscriptionRunner.swift SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift
git commit -m "fix(asr): dedup drops only abutting repeats; moved out of the engines and counted per chunk (P2)"
```

---

### Task R4: Archiver mirror branch; concatenator that never deletes a lossless source (v1 P2.3)

**Files:**
- Modify: `TranscriberCore/AudioArchiver.swift:65-106`, `TranscriberCore/AudioConcatenator.swift` (whole), `TranscriberCore/TranscriptionRunner.swift:408-429` (`concatenate(chunks:)`), `TranscriberCore/TranscriptAssembler.swift` (`mergedAudio:`)
- Test: `SwiftTests/TranscriberTests/AudioArchiverTests.swift`, `AudioConcatenatorTests.swift`, `RecoveryFixtures.swift` (`writeFakeWav` gains `sampleRate:`) — red-first (new error case / new parameter)

**Interfaces:**
```swift
public struct ChunkAudio: Sendable { public let url: URL; public let startTime: Date?; public init(url: URL, startTime: Date?) }
public enum AudioConcatenatorError { noSources, cannotLoadTrack(String), exportFailed(String), mixedSources([String]) }
public struct AudioConcatenationResult { outputPath: URL; usedPassthrough: Bool; gapsInsertedSeconds: Double }
public static func concatenate(chunks: [ChunkAudio], outputDirectory: URL, outputName: String, deleteSources: Bool) async throws -> AudioConcatenationResult
public static func concatenate(sources: [URL], outputDirectory: URL, outputName: String) async throws -> AudioConcatenationResult   // wraps: startTime nil, deleteSources true
// RecoveryFixtures.writeFakeWav(at:seconds:sampleRate: Int = 48_000)
```

- [ ] **Step 1: Write the failing tests**

`RecoveryFixtures.swift:17`: `static func writeFakeWav(at url: URL, seconds: Double, sampleRate: Int = 48_000) throws` (replace the hardcoded `48_000` in `sr` and `frames`).

`AudioArchiverTests.swift` (inside the suite; `createTestWav(at:frequency:durationSeconds:sampleRate:)` is at line 19):
```swift
    private func channelRMS(_ url: URL, from: Double, to: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let start = AVAudioFramePosition(from * format.sampleRate), count = AVAudioFrameCount((to - from) * format.sampleRate)
        file.framePosition = start
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        return (0..<Int(format.channelCount)).map { ch in
            let p = buffer.floatChannelData![ch]
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += p[i] * p[i] }
            return (sum / Float(max(1, buffer.frameLength))).squareRoot()
        }
    }

    /// P4 mirror of #183: a mic that delivered zero frames for a whole chunk left a 16 kHz header;
    /// the rate guard refused, the chunk fell back to its WAV, and the concatenator re-encoded the
    /// mono system WAV into BOTH channels (probe: RMS L=0.259 R=0.259) and deleted it.
    @Test func micEmptyHeaderWithSystemAudioArchivesAsSystemOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archiver-micempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("m-0.wav"), mic = dir.appendingPathComponent("m-0_mic.wav")
        try Self.createTestWav(at: sys, frequency: 440, durationSeconds: 1, sampleRate: 48_000)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 0, sampleRate: 16_000)   // header only, 16 kHz — the real #183 shape
        let result = try await AudioArchiver.archive(systemAudio: sys, micAudio: mic, outputDirectory: dir, bitrateKbps: 64)
        #expect(result.archivePath.lastPathComponent == "m-0.m4a")
        let rms = try channelRMS(result.archivePath, from: 0.2, to: 0.8)
        #expect(rms[1] > 0.05 && rms[0] < 0.01, "system audio on the RIGHT channel, left silent")
        #expect(!FileManager.default.fileExists(atPath: mic.path))
        #expect(!FileManager.default.fileExists(atPath: sys.path))
    }
```
`AudioConcatenatorTests.swift` (inside the suite; `createTestM4a(at:durationSeconds:frequency:)` is at line 23):
```swift
    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("concat-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func mixedWavAndM4aSourcesAreRefusedAndNothingIsDeleted() async throws {
        let dir = try tempDir("mixed"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.wav")
        try await Self.createTestM4a(at: a); try RecoveryFixtures.writeFakeWav(at: b, seconds: 1)
        await #expect(throws: AudioConcatenatorError.self) {
            _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: true)
        }
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func preserveKeepsTheSources() async throws {
        let dir = try tempDir("preserve"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a); try await Self.createTestM4a(at: b)
        _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: false)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    /// P9: a crash restart leaves a gap between chunk 0's end and chunk 1's start; the merged audio
    /// must keep the transcript's wall-clock timeline.
    @Test func gapsBetweenChunksAreFilledWithSilence() async throws {
        let dir = try tempDir("gaps"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a, durationSeconds: 1); try await Self.createTestM4a(at: b, durationSeconds: 1)
        let t0 = Date(timeIntervalSince1970: 0)
        let r = try await AudioConcatenator.concatenate(
            chunks: [ChunkAudio(url: a, startTime: t0), ChunkAudio(url: b, startTime: t0.addingTimeInterval(3))],
            outputDirectory: dir, outputName: "c", deleteSources: true)
        let d = try await AVURLAsset(url: r.outputPath).load(.duration).seconds
        #expect(abs(d - 4) < 0.3)
        #expect(abs(r.gapsInsertedSeconds - 2) < 0.1)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'AudioArchiverTests|AudioConcatenatorTests'` → compile errors (`ChunkAudio`, `sampleRate:`); the archiver test alone would throw the rate mismatch at 99-106.

- [ ] **Step 3: Implement**

`AudioArchiver.archive`: after the existing `sysFile.length == 0, micFile.length > 0` branch (65-81) and before the "both empty" guard (82), add the mirror:
```swift
        if micFile.length == 0, sysFile.length > 0 {
            Logger.files.info("AudioArchiver: mic track is empty — archiving '\(baseName, privacy: .sensitive)' as system-only")
            let result = try await archiveSystemOnly(systemAudio: systemAudio, outputDirectory: outputDirectory,
                                                     bitrateKbps: bitrateKbps, preserveSourceWAV: preserveSourceWAV)
            if !preserveSourceWAV { try? FileManager.default.removeItem(at: micAudio) }
            return result
        }
```
(`archiveSystemOnly` at 159-164 writes the system track to the RIGHT channel as `archive` does — verify by the RMS assertion; if it writes mono, extend it with the same L-silent/R-system layout `archive` uses.)

`AudioConcatenator`: new `concatenate(chunks:outputDirectory:outputName:deleteSources:)`: refuse if `Set(chunks.map { $0.url.pathExtension.lowercased() }).count > 1` or any non-`m4a` (`throw .mixedSources(names)`); build the composition inserting `compositionTrack.insertEmptyTimeRange(CMTimeRange(start: insertTime, duration: gap))` when `chunk.startTime − previousEnd > 1 s` (previousEnd = previous startTime + previous duration), summing `gapsInsertedSeconds`; after export verify `|duration − (Σ durations + gaps)| ≤ 0.25 + 0.05 × chunks.count` else `throw .exportFailed("duration mismatch …")` and keep sources; delete sources only when `deleteSources` and every source is `.m4a`. Keep the `sources:` overload (39-43) delegating with `startTime: nil, deleteSources: true`.

`TranscriptionRunner.finalize` (410-429): `concatenate(chunks: sortedChunks.map { ChunkAudio(url: outputDirectory.appendingPathComponent($0.audioPath), startTime: $0.startTime) }, outputDirectory:, outputName:, deleteSources: !(config.preserveSourceWAV ?? false))`; stamp `metadata["merged_audio"] = ["passthrough": r.usedPassthrough, "gaps_inserted_seconds": r.gapsInsertedSeconds]` through a new `mergedAudio: [String: Any]? = nil` parameter on `assemble`.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/AudioArchiver.swift TranscriberCore/AudioConcatenator.swift TranscriberCore/TranscriptionRunner.swift TranscriberCore/TranscriptAssembler.swift SwiftTests/TranscriberTests/AudioArchiverTests.swift SwiftTests/TranscriberTests/AudioConcatenatorTests.swift SwiftTests/TranscriberTests/RecoveryFixtures.swift
git commit -m "fix(archive): mic-empty mirror branch; concatenator refuses mixed sources, honours preserve, verifies duration, fills gaps from chunk start times (P4, P9)"
```

---

### Task R5: Small honesty fixes — session id, quota placement, summary truncation, absorption hint (v1 P2.7)

**Files:**
- Modify: `TranscriberCore/ChunkSession.swift:181-193` (`read(directory:sessionId:)`), `TranscriberCore/CrashRecoveryPlanner.swift:29, 42`, `TranscriberCore/ChunkedSessionRecovery.swift:12`, `TranscriberCore/ChunkProcessor.swift:202-221` (quota after the catch), `TranscriberCore/SummaryProvider.swift:38-40` (`SummaryResponse`, `summarizeDetailed`), `TranscriberCore/OpenAISummaryProvider.swift:199-216` (`finish_reason == "length"`), `TranscriberCore/LMStudioSummaryProvider.swift:81-100` (`isLikelyTruncated` → `truncated`), `TranscriberCore/MeetingSummarizer.swift:22-49` (banner), `TranscriberApp/Views/RenameDialog.swift` (hint when `clusters_absorbed` present)
- Test: `ChunkSessionTests.swift`, `OpenAISummaryProviderTests.swift`, `MeetingSummarizerTests.swift` (add; red-first)

**Interfaces:**
```swift
// SessionState
public static func read(directory: URL, sessionId: String) -> SessionState?   // nil on id mismatch; read(directory:) stays (legacy)
// SummaryProvider
public struct SummaryResponse: Equatable, Sendable { public let markdown: String; public let truncated: Bool; public init(markdown:truncated:) }
public protocol SummaryProvider { func summarize(...) -> String; func summarizeDetailed(segments:metadata:) async throws -> SummaryResponse }   // extension default wraps summarize(...) with truncated: false
```

- [ ] **Step 1: Write the failing tests**

`ChunkSessionTests.swift`:
```swift
    @Test("readWithMismatchedSessionIdReturnsNil")
    func readWithMismatchedSessionIdReturnsNil() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(makeSession(chunks: []), directory: dir)   // makeSession's sessionId is the fixture's
        let id = try #require(SessionState.read(directory: dir)?.sessionId)
        #expect(SessionState.read(directory: dir, sessionId: id) != nil)
        #expect(SessionState.read(directory: dir, sessionId: id + "-other") == nil)
    }
```
`OpenAISummaryProviderTests.swift` (in `OpenAISummaryProviderRetryTests`, which has `makeProvider()` and `MockURLProtocol`):
```swift
    @Test func finishReasonLengthMarksTheResponseTruncated() async throws {
        MockURLProtocol.reset()
        let body = #"{"choices":[{"message":{"role":"assistant","content":"# Summary\ncut"},"finish_reason":"length"}]}"#
        MockURLProtocol.responses = [(200, [:], Data(body.utf8))]
        let r = try await makeProvider().summarizeDetailed(segments: [], metadata: SummaryMetadata(sessionName: "s", date: Date(), durationSeconds: 1, speakers: []))
        #expect(r.truncated && r.markdown.contains("cut"))
    }
```
`MeetingSummarizerTests.swift` (file scope, next to `CapturingProvider` at line 427):
```swift
private struct TruncatingProvider: SummaryProvider {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String { "# Summary\ncut" }
    func summarizeDetailed(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> SummaryResponse {
        SummaryResponse(markdown: "# Summary\ncut", truncated: true)
    }
}
```
and inside the suite (same transcript fixture style as `summarizeWritesMarkdownFile`):
```swift
    @Test func truncatedSummaryGetsABannerFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("m.json")
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "A"]]]).write(to: transcript)
        try await MeetingSummarizer.summarize(transcriptPath: transcript, provider: TruncatingProvider(), endpoint: "http://localhost")
        let md = try String(contentsOf: dir.appendingPathComponent("m-summary.md"), encoding: .utf8)
        #expect(md.hasPrefix("> ⚠️ This summary may be incomplete"))
        #expect(md.contains("# Summary\ncut"))
    }
```

- [ ] **Step 2: Run to verify they fail** → compile errors (`read(directory:sessionId:)`, `summarizeDetailed`, `SummaryResponse`).

- [ ] **Step 3: Implement**

`SessionState.read(directory:sessionId:)`: calls `read(directory:)`, returns nil (with a `.warning` log, id `.sensitive`) when `state.sessionId != sessionId`. `CrashRecoveryPlanner.swift:29` and `:42` pass `sessionId:` (both functions already have a `sessionId` parameter); `ChunkedSessionRecovery.swift:12` likewise.

`ChunkProcessor` (202-221): move `StorageManager.enforceQuota(...)` out of the archive `do` into its own `do { … } catch { Logger.files.error(…) }` after it, guarded by `if let archivePath` (an archive failure means no quota pass); the scope stays the day folder (§11.3, issue #224).

`SummaryProvider.swift`: `SummaryResponse`; `func summarizeDetailed(segments:metadata:) async throws -> SummaryResponse` with a protocol-extension default `SummaryResponse(markdown: try await summarize(segments: segments, metadata: metadata), truncated: false)`. `OpenAISummaryProvider`: `static func parseDetailedResponse(_ data: Data) throws -> SummaryResponse` reading `choices[0].finish_reason == "length"`; `summarizeDetailed` uses it (`summarize` keeps `parseResponse`). `LMStudioSummaryProvider` (81-100): `summarizeDetailed` returns `truncated: isLikelyTruncated(...)` (the warning stays). `MeetingSummarizer.summarize` (22-49): call `summarizeDetailed`; prepend `"> ⚠️ This summary may be incomplete: the model reached its output limit.\n\n"` when truncated.

`RenameDialog.swift`: when the transcript's `metadata.processing_issues` contains a `clusters_absorbed` entry for the channel, show under the count stepper: "1 quiet voice was merged into the main speaker — set a count and Re-detect to undo" (plural by count).

- [ ] **Step 4: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'ChunkSessionTests|OpenAISummaryProviderRetryTests|MeetingSummarizerTests'` → pass; `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/ChunkSession.swift TranscriberCore/CrashRecoveryPlanner.swift TranscriberCore/ChunkedSessionRecovery.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/SummaryProvider.swift TranscriberCore/OpenAISummaryProvider.swift TranscriberCore/LMStudioSummaryProvider.swift TranscriberCore/MeetingSummarizer.swift TranscriberApp/Views/RenameDialog.swift SwiftTests/TranscriberTests/ChunkSessionTests.swift SwiftTests/TranscriberTests/OpenAISummaryProviderTests.swift SwiftTests/TranscriberTests/MeetingSummarizerTests.swift
git commit -m "fix(record): session id check on read, quota outside the archive catch, truncated-summary banner, absorption hint (P7, P12, P13, P14)"
```

---

### Task R6: Re-detect that cannot shift the timeline or lose text (v1 P2.6)

**Files:**
- Modify: `TranscriberCore/TranscriptRediarizer.swift:137-141` (`RediarizeError`), `:213-238` (VAD), `:284-309` (backup before write), `:357-431` (`decodeChannelAudio`), `TranscriberApp/Views/RenameDialog.swift:251-318` (show the `Outcome`)
- Test: `SwiftTests/TranscriberTests/TranscriptRediarizerTests.swift` (new suite; red-first)

- [ ] **Step 1: Write the failing tests** (append to `TranscriptRediarizerTests.swift`; `AVFoundation` is already imported)

```swift
@Suite(.serialized)
struct TranscriptRediarizerTimelineTests {
    /// Counts the samples the diarizer received, so timeline padding is observable.
    final class CountingDiarizer: DiarizationProvider, @unchecked Sendable {
        private(set) var samplesSeen = 0
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await FakeDiarizer().diarize(audioPath: audioPath, numSpeakers: numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            samplesSeen = audio.count
            return try await FakeDiarizer().diarize(audio: audio, numSpeakers: numSpeakers, progress: progress)
        }
    }

    private func writeSilentWav(at url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Chunk 0 = mic-only WAV (`.skip` for the remote channel, 10 s); chunk 1 = system-only WAV (1 s).
    private func makeTwoChunkRecording(withDurations: Bool = true) throws -> (transcript: URL, chunk1: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic0 = dir.appendingPathComponent("call-0_mic.wav"), sys1 = dir.appendingPathComponent("call-1.wav")
        try writeSilentWav(at: mic0, seconds: 10); try writeSilentWav(at: sys1, seconds: 1)
        var metadata: [String: Any] = ["audio_paths": [mic0.path, sys1.path]]
        if withDurations { metadata["chunk_durations"] = [10.0, 1.0] }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": metadata,
            "segments": [["start": 10.2, "end": 10.8, "text": "hi", "speaker": "Remote Speaker 1", "source": "remote"]],
        ]).write(to: transcript)
        return (transcript, sys1, { try? FileManager.default.removeItem(at: dir) })
    }

    /// P5: a `.skip` chunk contributed nothing and every later chunk's timeline shifted by its length.
    @Test func skipChunksArePaddedWithTheirDuration() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    @Test func aSkipChunkWithUnknownDurationIsRefused() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(withDurations: false); defer { cleanup() }
        do {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
            Issue.record("expected chunkDurationUnknown")
        } catch TranscriptRediarizer.RediarizeError.chunkDurationUnknown(let name) {
            #expect(name == "call-0_mic.wav")
        }
    }

    @Test func aMissingListedChunkIsRefused() async throws {
        let (t, chunk1, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try FileManager.default.removeItem(at: chunk1)
        do {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
            Issue.record("expected chunkMissing")
        } catch TranscriptRediarizer.RediarizeError.chunkMissing(let name) {
            #expect(name == "call-1.wav")
        }
    }

    @Test func aBackupIsWrittenBeforeOverwriting() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let before = try Data(contentsOf: t)
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        let backup = t.deletingPathExtension().appendingPathExtension("rediarize-backup.json")
        #expect(try Data(contentsOf: backup) == before)
        #expect(try Data(contentsOf: t) != before)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'TranscriptRediarizerTimelineTests'` → compile error on `chunkMissing`/`chunkDurationUnknown`; the padding test would see 16 000 samples.

- [ ] **Step 3: Implement**

`RediarizeError` (137-141) gains `chunkMissing(String)` ("Chunk <name> is missing — re-detect cannot rebuild the timeline without it.") and `chunkDurationUnknown(String)`. `decodeChannelAudio` (357-431): read `metadata.chunk_durations` (threaded in as a new parameter from `rediarize`); if a listed chunk does not exist → `throw .chunkMissing(<lastPathComponent>)` (no silent filtering); `.skip` → `combined.append(contentsOf: [Float](repeating: 0, count: Int(duration * 16_000)))` with `duration = chunkDurations[index]`, else `throw .chunkDurationUnknown(name)`. `rediarize` (213-238): `speechMap = nil` in both branches (the segments already passed the gate once; the second VAD pass filtered text). Before the atomic write (306): copy the transcript to `url.deletingPathExtension().appendingPathExtension("rediarize-backup.json")` (overwrite). `RenameDialog.rediarize` (251-318): keep the `Outcome` (line 262 `let outcome = try await …`) and show `"\(outcome.speakerCount) speaker(s) found · \(outcome.segmentsRelabeled) lines relabeled"` under the stepper.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberCore/TranscriptRediarizer.swift TranscriberApp/Views/RenameDialog.swift SwiftTests/TranscriberTests/TranscriptRediarizerTests.swift
git commit -m "fix(rediarize): refuse missing chunks, pad skipped ones, no second VAD pass, backup before overwrite, outcome shown (P5)"
```

---

### Task R7 (deferrable): Filters keep the text — `filtered` and `echo` flags instead of deletion (v1 P2.8)

**Files:**
- Modify: `TranscriberCore/SpeakerAssignment.swift:42-60` (`LabeledSegment.filtered/echo`), `:638-668` (keep the filtered segment), `TranscriberCore/EchoDeduplicator.swift:97-100, 139-173`, `TranscriberCore/ChunkSession.swift` (`ProcessedChunk.Segment.filtered/echo`), `TranscriberCore/ChunkProcessor.swift:141-152` (`.echoFlagged` count source — R2 already records it; this task only switches the count to `flaggedCount`, scan A121), `TranscriberCore/TranscriptMerger.swift:12-41`, `TranscriberCore/TranscriptAssembler.swift`, `TranscriberCore/TranscriptWriter.swift:23-56`, `TranscriberCore/MeetingSummarizer.swift:174-217`, `TranscriberCore/TranscriptRenamer.swift:68, 99` (`collectSpeakerSamples` skips flagged)
- Test: `SpeakerAssignmentVadTests.swift:39` (change), `EchoDeduplicatorTests.swift:150-152` (change), `TranscriptWriterTests.swift`, `MeetingSummarizerTests.swift` (add) — all red-first (assertion inversions / new members)

**Interfaces:**
```swift
// LabeledSegment: + var filtered = false, echo = false
// EchoDeduplicator.DeduplicationResult: + flaggedCount: Int   (removedCount stays as an alias returning the same number for one release)
// ProcessedChunk.Segment / MergedSegment: + filtered, echo (Codable default false)
// TranscriptAssembler writes "filtered": true / "echo": true only when set
// TranscriptWriter.formatTXT/SRT skip flagged; MeetingSummarizer.parseTranscript skips flagged; TranscriptRenamer skips flagged samples
```

- [ ] **Step 1: Change and add tests**

`EchoDeduplicatorTests.swift:150-152` (in `removesEchoWhenAllThreeSignalsMatch`) becomes:
```swift
        #expect(result.segments.count == 2, "nothing is deleted any more")
        #expect(result.segments.filter { !$0.echo }.map(\.source) == ["remote"])
        #expect(result.segments.first { $0.source == "local" }?.echo == true)
        #expect(result.flaggedCount == 1)
```
`SpeakerAssignmentVadTests.swift:39` (`lowSpeechLowQualityFiltered`): replace its `result.count == 1` / `result[0].text == "real speech"` assertions with:
```swift
        #expect(result.count == 2, "filtered text is kept, flagged")
        let flagged = try #require(result.first { $0.filtered })
        #expect(flagged.speaker == "Unknown")
        #expect(result.first { !$0.filtered }?.text == "real speech")
```
(make the test `throws`). `TranscriptWriterTests.swift` (uses `tempDir()`/`createJSON(in:metadata:segments:)` at 87+):
```swift
    @Test func flaggedSegmentsAreHiddenInTxtAndSrt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "Hello"],
            ["start": 2.0, "end": 3.0, "speaker": "Unknown", "text": "noise", "filtered": true],
            ["start": 3.0, "end": 4.0, "speaker": "Bob", "text": "Hello", "echo": true],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)
        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        let srt = try String(contentsOf: dir.appendingPathComponent("test.srt"), encoding: .utf8)
        #expect(srt.contains("Alice: Hello") && !srt.contains("noise") && !srt.contains("Bob"))
        let txt = TranscriptWriter.formatTXT(segments: segments)
        #expect(txt.contains("Alice") && !txt.contains("noise") && !txt.contains("Bob"))
    }
```
`MeetingSummarizerTests.swift`:
```swift
    @Test func flaggedSegmentsAreExcludedFromTheSummaryInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [
            ["start": 0.0, "end": 1.0, "text": "keep", "speaker": "A"],
            ["start": 1.0, "end": 2.0, "text": "drop", "speaker": "B", "echo": true],
            ["start": 2.0, "end": 3.0, "text": "drop", "speaker": "Unknown", "filtered": true],
        ]]).write(to: url)
        let (segments, _) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(segments.map(\.text) == ["keep"])
    }
```

- [ ] **Step 2: Run to verify they fail** → compile errors on `.echo`/`.filtered`/`flaggedCount`.

- [ ] **Step 3: Implement**

`LabeledSegment.filtered = false, echo = false`; `SpeakerAssignment.assign` (638-668) keeps the `!shouldInclude` segment with `filtered: true, speaker: unknownSpeaker`; `EchoDeduplicator.deduplicate` returns every input with `echo: true` on matches, `DeduplicationResult.flaggedCount` (`removedCount` kept as an alias); `ProcessedChunk.Segment` + `MergedSegment` carry both flags (Codable default false); `TranscriptAssembler` writes `"filtered": true` / `"echo": true` only when set; `TranscriptWriter.formatTXT/SRT` skip flagged; `MeetingSummarizer.parseTranscript` skips flagged; `TranscriptRenamer.collectSpeakerSamples` skips flagged; `ChunkProcessor` (141-152) reads `flaggedCount` for the `.echoFlagged` issue R2 already records (no second issue); metadata key `echo_segments_removed` keeps its value (count of flagged) for readers.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/SpeakerAssignment.swift TranscriberCore/EchoDeduplicator.swift TranscriberCore/ChunkSession.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/TranscriptMerger.swift TranscriberCore/TranscriptAssembler.swift TranscriberCore/TranscriptWriter.swift TranscriberCore/MeetingSummarizer.swift TranscriberCore/TranscriptRenamer.swift SwiftTests/TranscriberTests/SpeakerAssignmentVadTests.swift SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift SwiftTests/TranscriberTests/TranscriptWriterTests.swift SwiftTests/TranscriberTests/MeetingSummarizerTests.swift
git commit -m "feat(record): VAD/quality gate and echo dedup flag segments instead of deleting them; TXT/SRT/summary hide them (P10, P11)"
```

### R gate

Stream gate (council lens: any path that still deletes a lossless source; every `try?` in ChunkProcessor/TranscriptionRunner accounted for as an issue; metadata keys documented in X2). Merge. R0 unblocks L7/L9/L10; R2 unblocks L5/L8/L12; R5 unblocks L7.

---
# Stream L — Lifecycle: coordinator and app shell

One implementer, serial, in this order: L1 → L2 → L3 → L4 → L5 → L6 → L7 → L8 → L9 → L10 → L11 → L12. Branch after F merged. Every task that touches `TranscriberApp/` ends with `python3 scripts/dev.py --build`. All coordinator tests use the `Harness` at `RecordingCoordinatorTests.swift:94-152` and the `FakeCaptureClient` F4 extended.

### Task L1: Wire `XPCInterruptionPolicy` into the app client (v1 P0.1 wiring) — needs C1 merged

**Files:**
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:12` (`crashHandlerFired`), `:52` (its reset), `:63-107` (both handlers), `:214` (`start`), `:243` (`stop`)
- Test: none (app target; the decisions are C1's). The device item is D-01.

- [ ] **Step 1: Implement**

- Replace `private var crashHandlerFired = false` (12) with `private var interruptionPolicy = XPCInterruptionPolicy()`; delete `crashHandlerFired = false` (52).
- Replace the interruption handler body (63-95) with:
```swift
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let boundConnection = self.connection
                let classification = CrashReportScanner.classifyLive()
                switch self.interruptionPolicy.onInterruption(classification: classification) {
                case .ignoreIdle:
                    // Not capturing: launchd idle-exited the helper. No ping (a ping would spawn a
                    // throwaway helper), no latch. Lands in the unified log and the live log only;
                    // the next resetSession() wipes it from the app ring (it belongs to no session).
                    self.record(.helperIdleExit, .info)
                    Logger.audio.info("XPC interrupted while idle — helper idle-exit, ignored")
                case .crash:
                    self.record(.xpcInterruption, .anomaly, ["classification": "crash"])
                    Logger.audio.warning("XPC interrupted — crash report present, treating as crash")
                    self.onServiceCrash?()
                case .verifyCapture:
                    self.record(.xpcInterruption, .warning, ["classification": "blip"])
                    let generation = self.interruptionPolicy.captureGeneration
                    Logger.audio.warning("XPC interrupted — no crash report; verifying capture is alive")
                    let stillCapturing = await self.isCapturing()
                    guard self.connection === boundConnection else { return }
                    switch self.interruptionPolicy.onVerified(stillCapturing: stillCapturing, generation: generation) {
                    case .briefInterruption: self.onBriefInterruption?()
                    case .crash:
                        Logger.audio.warning("XPC interrupted — helper not capturing, escalating to crash recovery")
                        self.onServiceCrash?()
                    case .ignoreIdle, .verifyCapture: break
                    }
                case .briefInterruption:
                    break   // onInterruption never returns this; onVerified does
                }
            }
        }
```
- Replace the invalidation handler body (96-107) with:
```swift
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.connection = nil
                switch self.interruptionPolicy.onInvalidation() {
                case .crash:
                    Logger.audio.warning("XPC connection invalidated during capture")
                    self.record(.xpcInvalidation, .anomaly)
                    self.onServiceCrash?()
                default:
                    Logger.audio.info("XPC connection invalidated while idle")
                    self.record(.xpcInvalidation, .info)
                }
            }
        }
```
- In `start` add `interruptionPolicy.captureStarted()` as the statement right after `diagnostics.clear()` (214) — unconditional; L11 replaces `diagnostics.clear()` but keeps this line. In `stop()` (243) add `interruptionPolicy.captureStopped()` as the first statement.

- [ ] **Step 2: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "fix(xpc): arm crash detection per capture generation — an idle-exit no longer disarms recovery (L-N1)"
```

---

### Task L2: Alarms in the app — `AppState.activeAlarms`, pull/push, presenter, rows (v1 P0.4 app part)

**Files:**
- Create: `TranscriberApp/Services/CaptureAlarmWindowController.swift`, `TranscriberApp/Views/CaptureAlarmView.swift`
- Modify: `TranscriberCore/AppState.swift` (14-22 `phase`, 35-37 storage, 59-88 `noteQualityAnomaly`/`noteSystemAudioLost`/`clearRemoteAudioProblem`, 93-96 `hasMenuAlerts`, 113-123 `menuBarIcon`), `TranscriberCore/RecordingCoordinator.swift:68-92` (init: `presentAlarmsUI`), `:222-267` (→ `wireCaptureCallbacks()`), `:254-259` (`noteSystemAudioLost` call), `:298` (poll start), `:638-666` (`wireCaptureCallbacks()` before the restart; delete 661), `TranscriberApp/TranscriberApp.swift:479-484` (`noteSystemAudioLost` call), `TranscriberApp/Views/MenuView.swift:68-88` (init closure), `:233-262` (`alertBanners`), `TranscriberApp/Services/AudioCaptureClient.swift:108` (pull on connect)
- Test: `SwiftTests/TranscriberTests/AppStateTests.swift:239-326` (replace the eight #220 tests; red-first: new members), `SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift:349-425` (replace the six #220 tests; red-first)

**Interfaces:**
```swift
// AppState
public private(set) var alarms: CaptureAlarmRegistry
public var activeAlarms: [AlarmKind: ActiveAlarm] { get }
public func applyHelperSnapshot(_ snapshot: CaptureStatusSnapshot)
@discardableResult public func raiseAppAlarm(_ kind: AlarmKind, message: String, now: Date = Date()) -> Bool
public func clearAppAlarm(_ kind: AlarmKind)
public func acknowledge(_ kind: AlarmKind)
public func markNotified(_ kind: AlarmKind, now: Date = Date())
public func noteFirstFrames(track: String)                 // stale helper alarms on that track go
public var remoteAudioNotCaptured: Bool { get }            // any active alarm on the "system" track
public var crashProtectionOff: Bool { get }                // activeAlarms[.crashProtectionOff] != nil
// noteQualityAnomaly(kind:message:) -> Bool: sets interruptionWarning; returns true only for the permission kinds (repair)
// RecordingCoordinator
public init(..., presentAlarmsUI: @escaping @MainActor ([ActiveAlarm], [AlarmKind]) -> Void = { _, _ in }, ...)
var statusPollInterval: Duration = .seconds(5)
func pollHelperStatus() async
func presentAlarms(now: Date = Date())
func noteFirstFrames(track: String)                        // L2: alarm clearing; L4 extends the SAME method with the recovery confirmation
private func wireCaptureCallbacks()                        // every captureClient closure (the ones at 222-267 + onAlarmsChanged + onFirstFrames)
```

- [ ] **Step 1: Replace the tests**

`AppStateTests.swift`: delete lines 239-326 (from `// MARK: - #220` to the end of the struct) and append:
```swift
    // MARK: - Alarms (§6)

    private func snapshot(_ id: String, _ kinds: [AlarmKind]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, isCapturing: true,
                              alarms: kinds.map { ActiveAlarm(kind: $0, raisedAt: Date(), lastNotifiedAt: nil, message: $0.rawValue, episode: 1) }, tracks: [])
    }

    @Test func helperSnapshotPopulatesActiveAlarmsAndTheStickyRemoteFlag() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("h", [.remotePermissionDenied]))
        #expect(state.activeAlarms[.remotePermissionDenied] != nil)
        #expect(state.remoteAudioNotCaptured)
        #expect(state.hasMenuAlerts)
        #expect(state.menuBarIcon == "exclamationmark.bubble")
    }

    @Test func aSnapshotWithoutTheKindClearsIt() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("h", [.remotePermissionDenied]))
        state.applyHelperSnapshot(snapshot("h", []))
        #expect(!state.remoteAudioNotCaptured && state.activeAlarms.isEmpty)
    }

    /// The single-slot banner can be dismissed or overwritten by any later notice; the alarm cannot.
    @Test func benignNoticeNeverTouchesAnAlarm() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.rotationFailed, message: "rotation failed")
        #expect(!state.noteQualityAnomaly(kind: CaptureEventKind.livenessGap.rawValue, message: "mic gap"))
        state.interruptionWarning = nil   // user dismissed the banner
        #expect(state.activeAlarms[.rotationFailed] != nil)
        #expect(state.hasMenuAlerts)
    }

    @Test func onlyPermissionKindsAskForRepair() {
        let state = AppState()
        state.phase = .recording(since: Date())
        #expect(state.noteQualityAnomaly(kind: CaptureEventKind.systemAudioPermissionDenied.rawValue, message: "denied"))
        #expect(state.interruptionWarning == "denied")
        #expect(!state.noteQualityAnomaly(kind: CaptureEventKind.systemAudioPermissionRestored.rawValue, message: "back"))
        #expect(state.interruptionWarning == "back")
    }

    @Test func recordingEndClearsPerRecordingAlarmsButNotCrashProtection() {
        let state = AppState()
        state.raiseAppAlarm(.crashProtectionOff, message: "off")
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.diskLow, message: "low")
        state.applyHelperSnapshot(snapshot("h", [.micDigitalSilence]))
        state.phase = .idle
        #expect(state.activeAlarms[.diskLow] == nil && state.activeAlarms[.micDigitalSilence] == nil)
        #expect(state.activeAlarms[.crashProtectionOff] != nil)
        #expect(state.crashProtectionOff && state.hasMenuAlerts)
        #expect(state.menuBarIcon == "exclamationmark.triangle")
    }

    @Test func acknowledgeClearsOnlyAcknowledgeableKinds() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.recordingResumedWithGap, message: "gap")
        state.raiseAppAlarm(.diskLow, message: "low")
        state.acknowledge(.recordingResumedWithGap)
        state.acknowledge(.diskLow)
        #expect(state.activeAlarms[.recordingResumedWithGap] == nil)
        #expect(state.activeAlarms[.diskLow] != nil)
    }

    /// §6.2: a restarted helper's empty snapshot keeps the old alarms until its first frames.
    @Test func aNewHelperKeepsAlarmsUntilFirstFramesOnThatTrack() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("h1", [.remoteRecoveryFailed, .micDigitalSilence]))
        state.applyHelperSnapshot(snapshot("h2", []))
        #expect(state.remoteAudioNotCaptured)
        state.noteFirstFrames(track: "system")
        #expect(!state.remoteAudioNotCaptured && state.activeAlarms[.micDigitalSilence] != nil)
    }

    @Test func noAlertsWhenNothingIsWrong() {
        #expect(!AppState().hasMenuAlerts)
    }

    @Test func aBannerAloneStillCountsAsAnAlert() {
        let state = AppState()
        state.interruptionWarning = "device changed"
        #expect(state.hasMenuAlerts)
    }
}
```

`RecordingCoordinatorTests.swift`: delete lines 349-425 (the `// MARK: - #220` block through `crashRestartClearsTheStickyState`) and insert:
```swift
    // MARK: - Alarms (§6)

    private func snapshot(_ id: String, _ kinds: [AlarmKind]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, isCapturing: true,
                              alarms: kinds.map { ActiveAlarm(kind: $0, raisedAt: Date(), lastNotifiedAt: nil, message: $0.rawValue, episode: 1) }, tracks: [])
    }

    /// The tap running without its permission: the helper's alarm reaches the app, sticks, and opens repair.
    @Test func helperPermissionAlarmSticksAndOpensRepair() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onAlarmsChanged?(snapshot("h1", [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.activeAlarms[.remotePermissionDenied] != nil)
        #expect(h.appState.remoteAudioNotCaptured)
        #expect(h.repairRequests.value == 1)
        h.client.onAlarmsChanged?(snapshot("h1", [.remotePermissionDenied]))   // the next poll: no second repair window
        for _ in 0..<50 { await Task.yield() }
        #expect(h.repairRequests.value == 1)
    }

    @Test func unrelatedAnomalyIsATransientNoticeOnly() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onQualityAnomaly?("exactZeroMic", "mic silent")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.interruptionWarning == "mic silent")
        #expect(!h.appState.remoteAudioNotCaptured && h.repairRequests.value == 0)
    }

    @Test func aSnapshotWithoutTheKindClearsTheAlarm() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onAlarmsChanged?(snapshot("h1", [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        h.client.onAlarmsChanged?(snapshot("h1", []))
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.appState.remoteAudioNotCaptured)
    }

    /// The SCK give-up used to be `noteSystemAudioLost`; the sticky part is now the helper's alarm
    /// (`remoteRecoveryFailed`, H2) and the app keeps only the transient notice (scan D2).
    @Test func systemAudioUnrecoverableIsATransientNoticeAndTheHelperAlarmIsSticky() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onSystemAudioUnrecoverable?("tap rebuild failed")
        h.client.onAlarmsChanged?(snapshot("h1", [.remoteRecoveryFailed]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.interruptionWarning?.contains("only your microphone") == true)
        #expect(h.appState.remoteAudioNotCaptured)
    }

    @Test func staleSnapshotAfterTheRecordingEndedIsIgnored() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.appState.phase = .idle
        h.client.onAlarmsChanged?(snapshot("h1", [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.activeAlarms.isEmpty && h.repairRequests.value == 0)
    }

    /// §6.2 (scan C6): a crash-restarted helper starts with an empty registry; the app keeps the old
    /// helper's alarms until the new helper's first frames on that track. The restart re-wires the
    /// callbacks (scan B P0.4(5)).
    @Test func crashRestartKeepsTheStickyStateUntilFramesArrive() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.appState.applyHelperSnapshot(snapshot("h1", [.remotePermissionDenied]))

        await h.coordinator.handleXPCCrash()
        #expect(h.client.startCalls.count == 1)
        #expect(h.appState.remoteAudioNotCaptured, "still true after the restart")

        h.client.onAlarmsChanged?(snapshot("h2", []))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.remoteAudioNotCaptured, "the new helper's empty registry proves nothing yet")

        h.client.onFirstFrames?("system")
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.appState.remoteAudioNotCaptured)
    }

    @Test func threeMissedPollsRaiseHelperUnresponsiveAndAnAnswerClearsIt() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.statusSnapshot = nil
        await h.coordinator.pollHelperStatus(); await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] == nil)
        await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] != nil)
        h.client.statusSnapshot = snapshot("h1", [])
        await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] == nil)
    }

    @Test func presentAlarmsNotifiesNewKindsAndRenotifiesEveryTwoMinutes() async throws {
        let h = try Harness()
        let shown = Harness.Box<[(alarms: [ActiveAlarm], new: [AlarmKind])]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { alarms, new in shown.value.append((alarms, new)) }, recordingMicrophone: h.recordingMic)
        h.appState.phase = .recording(since: Date())
        let t0 = Date()
        h.appState.raiseAppAlarm(.diskLow, message: "low", now: t0)
        coordinator.presentAlarms(now: t0)
        #expect(shown.value.count == 1 && shown.value[0].new == [.diskLow])
        coordinator.presentAlarms(now: t0 + 60)
        #expect(shown.value.count == 1, "nothing new, not due")
        coordinator.presentAlarms(now: t0 + 121)
        #expect(shown.value.count == 2 && shown.value[1].new.isEmpty, "re-notify: same alarm, no new kinds")
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'AppStateTests|RecordingCoordinatorLifecycleTests'` → compile errors.

- [ ] **Step 3: `AppState`**

Replace lines 35-37 (`remoteAudioNotCaptured`, `remoteAudioProblem`) with:
```swift
    /// Sticky alarms (§6). Helper-owned kinds mirror the helper's snapshot; app-owned kinds are
    /// raised here. Nothing benign can overwrite them; `interruptionWarning` stays the transient slot.
    public private(set) var alarms = CaptureAlarmRegistry()
    public var activeAlarms: [AlarmKind: ActiveAlarm] { alarms.alarms }

    public func applyHelperSnapshot(_ snapshot: CaptureStatusSnapshot) { alarms.apply(snapshot) }
    @discardableResult
    public func raiseAppAlarm(_ kind: AlarmKind, message: String, now: Date = Date()) -> Bool { alarms.raise(kind, message: message, now: now) }
    public func clearAppAlarm(_ kind: AlarmKind) { _ = alarms.clear(kind) }
    public func acknowledge(_ kind: AlarmKind) { guard kind.isAcknowledgeable else { return }; _ = alarms.clear(kind) }
    public func markNotified(_ kind: AlarmKind, now: Date = Date()) { alarms.markNotified(kind, now: now) }
    public func noteFirstFrames(track: String) { alarms.noteFirstFrames(track: track) }

    /// The other side is not being captured, for whatever reason the helper reported.
    public var remoteAudioNotCaptured: Bool { alarms.alarms.keys.contains { $0.track == "system" } }
    public var crashProtectionOff: Bool { alarms.alarms[.crashProtectionOff] != nil }
```
`phase.didSet` (20): `if !isRecording { alarms.recordingEnded() }`. `noteQualityAnomaly` (59-73): `interruptionWarning = message; return kind == CaptureEventKind.systemAudioPermissionDenied.rawValue`. Delete `noteSystemAudioLost` (77-81) and `clearRemoteAudioProblem` (85-88). `hasMenuAlerts` (93-96): `criticalError != nil || interruptionWarning != nil || truncatedErrorMessage != nil || !alarms.isEmpty`. `menuBarIcon` (113-123): `.recording` → `"exclamationmark.bubble"` when `!alarms.isEmpty || interruptionWarning != nil`; `.idle` → `"exclamationmark.triangle"` when `!alarms.isEmpty` (only kinds that outlive a recording can be there), else `"mic"`.

- [ ] **Step 4: Coordinator**

- init (68-92): add `presentAlarmsUI: @escaping @MainActor ([ActiveAlarm], [AlarmKind]) -> Void = { _, _ in }` before `recordingMicrophone`; store it.
- `wireCaptureCallbacks()` (new, private): the five closures now at 222-267, with two changes — `onSystemAudioUnrecoverable` (254-259) sets `self.appState.interruptionWarning = message` (the sticky state is the helper's `remoteRecoveryFailed`, H2); `onQualityAnomaly` (260-267) becomes `self.appState.noteQualityAnomaly(kind: kind, message: message)` with no repair call (repair opens from `presentAlarms`) — plus:
```swift
        captureClient.onAlarmsChanged = { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.appState.applyHelperSnapshot(snapshot)
                self.presentAlarms()
            }
        }
        captureClient.onFirstFrames = { [weak self] track in
            Task { @MainActor in self?.noteFirstFrames(track: track) }
        }
```
  `startRecording` calls `wireCaptureCallbacks()` where the closures were (222). `handleXPCCrash` calls `wireCaptureCallbacks()` right before `try await captureClient.start(...)` (642): the restarted helper must report into the same closures. Delete `appState.clearRemoteAudioProblem()` (661).
- status poll + presenter:
```swift
    private let presentAlarmsUI: @MainActor ([ActiveAlarm], [AlarmKind]) -> Void
    var statusPollInterval: Duration = .seconds(5)   // tests shorten it
    private var statusPoll: Task<Void, Never>?
    private var missedPolls = 0
    private var presentedKinds: Set<AlarmKind> = []

    private func startStatusPoll() {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while let self, !Task.isCancelled, self.appState.isRecording {
                try? await Task.sleep(for: self.statusPollInterval)
                await self.pollHelperStatus()
            }
        }
    }

    private func stopStatusPoll() { statusPoll?.cancel(); statusPoll = nil; missedPolls = 0 }

    func pollHelperStatus() async {
        if let s = await captureClient.captureStatus() {
            missedPolls = 0
            appState.clearAppAlarm(.helperUnresponsive)
            appState.applyHelperSnapshot(s)
        } else {
            missedPolls += 1
            if missedPolls >= 3 {
                appState.raiseAppAlarm(.helperUnresponsive, message: "The capture helper stopped answering. The recording may have stopped — check the audio files after you stop.")
            }
        }
        presentAlarms()
    }

    /// New kinds and due re-notifications go to the UI; the permission kinds also open the repair window (once per raise).
    func presentAlarms(now: Date = Date()) {
        let active = appState.alarms.sorted
        let newKinds = active.map(\.kind).filter { !presentedKinds.contains($0) }
        presentedKinds = Set(active.map(\.kind))
        let due = active.filter { AlarmRealarmPolicy.shouldRenotify($0, now: now) }
        for a in due { appState.markNotified(a.kind, now: now) }
        if !newKinds.isEmpty || !due.isEmpty { presentAlarmsUI(active, newKinds) }
        if newKinds.contains(.remotePermissionDenied) || newKinds.contains(.remoteCantConfirm) { onSystemAudioPermissionDenied() }
    }

    /// L2: the new helper's frames clear the previous helper's alarms on that track. L4 extends this
    /// same method with the recovery confirmation ("Recording Resumed").
    func noteFirstFrames(track: String) {
        guard appState.isRecording else { return }
        appState.noteFirstFrames(track: track)
        presentAlarms()
    }
```
  `startStatusPoll()` after `appState.phase = .recording(since: Date())` (298); `stopStatusPoll()` at the top of `stopRecording` (after the guards, 424) and in every `appState.phase = .idle` path of `handleXPCCrash`.

`TranscriberApp.swift:479-484`: the `onSystemAudioUnrecoverable` closure body becomes `appState.interruptionWarning = message` (with `{ message in`). (L4 deletes the whole function.)

- [ ] **Step 5: App shell**

`AudioCaptureClient.connect()` after `conn.resume()` (108): `Task { @MainActor [weak self] in guard let self, let s = await self.captureStatus() else { return }; self.onAlarmsChanged?(s) }`.

`TranscriberApp/Services/CaptureAlarmWindowController.swift` (new, `@MainActor final class`, `static let shared`): `func present(_ alarms: [ActiveAlarm], newlyRaised: [AlarmKind], appState: AppState)` — if `newlyRaised` is non-empty, or `AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: lastDismissedAt, now: Date())`: open/refresh an `NSPanel` (`[.titled, .closable, .utilityWindow]`, `level = .floating`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, NO `NSApp.activate`) hosting `CaptureAlarmView`; post `MenuView.postNotification(title: "Parley isn’t recording everything", body: <the first message>)` (default `.timeSensitive` + `.default` sound) once per call when `newlyRaised` is non-empty or a re-notify is due (the coordinator only calls when one of the two holds); "Later" sets `lastDismissedAt = Date()` and closes; `windowWillClose` counts as Later. Skip the `.remotePermissionDenied` / `.remoteCantConfirm` rows when `PermissionRepairWindowController.shared` has its panel open (it keeps its own window, §6.3).

`TranscriberApp/Views/CaptureAlarmView.swift` (new): `struct CaptureAlarmView: View` taking `alarms: [ActiveAlarm]`, `onLater: () -> Void`, `onAcknowledge: (AlarmKind) -> Void`: one row per alarm (SF Symbol by track: `speaker.slash.fill` system, `mic.slash.fill` mic, `shield.slash` crashProtectionOff, `externaldrive.badge.exclamationmark` disk kinds, `exclamationmark.triangle` otherwise; the message; an **Acknowledge** button for `isAcknowledgeable` kinds; **Open System Settings** (`PrivacyPane.systemAudioRecording.open()`, `DesignSystem.swift:198`) for `remotePermissionDenied`), and a **Later** button.

`MenuView.swift`:
- `alertBanners` (233-262): replace the sticky row block (236-245) with `ForEach(appState.alarms.sorted, id: \.kind) { alarm in MenuActionRow(icon: icon(for: alarm.kind), title: title(for: alarm.kind), subtitle: alarm.message) { dismissPanel(); if alarm.kind.track == "system" { Task { await PermissionRepairWindowController.shared.verify(trigger: .userRequest) } } else { CaptureAlarmWindowController.shared.present(appState.alarms.sorted, newlyRaised: [], appState: appState) } } }` (rows are not dismissible; `icon(for:)`/`title(for:)` are small private helpers: e.g. `.crashProtectionOff` → "Crash protection is off", `.micNotDelivering` → "Your microphone isn’t being recorded", `.remoteNotDelivering`/`.remoteRecoveryFailed`/`.remotePermissionDenied`/`.remoteCantConfirm` → "The other side may not be recorded", `.diskLow`/`.diskWriteFailure`/`.rotationFailed`/`.sessionWriteFailed` → "Recording to disk is in trouble", `.helperUnresponsive` → "The capture helper stopped answering", `.recordingResumedWithGap` → "Recording resumed after a crash", `.recordingStopped` → "Recording STOPPED", `.recordingFolderUnavailable` → "Recording folder unavailable").
- init (68-88): pass `presentAlarmsUI: { alarms, new in CaptureAlarmWindowController.shared.present(alarms, newlyRaised: new, appState: appState) }` to the coordinator (L4 moves this construction to `TranscriberApp`).

- [ ] **Step 6: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'AppStateTests|RecordingCoordinatorLifecycleTests'` → pass; `python3 scripts/dev.py --build` → clean; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/AppState.swift TranscriberCore/RecordingCoordinator.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift TranscriberApp/Services/AudioCaptureClient.swift TranscriberApp/Services/CaptureAlarmWindowController.swift TranscriberApp/Views/CaptureAlarmView.swift SwiftTests/TranscriberTests/AppStateTests.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "feat(alarms): app pulls the helper's alarm state every 5 s and on connect, keeps it across helper restarts until first frames; loud, sticky rows + floating window, re-notified every 2 min (H3, H9, L5, §6)"
```

---

### Task L3: LaunchAgent verified and repaired at every launch (v1 P0.2 wiring) — needs C2 merged

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift:222-232`
- Test: none (app target; the judgement is C2's; the alarm rendering is L2's). Device item D-02.

- [ ] **Step 1: Implement**

Replace lines 222-232 with:
```swift
        // L11: launchd's opinion is what relaunches us; verify and repair, and say so when it fails.
        let stateForAgent = appState
        Task(priority: .utility) {
            let health = await LaunchAgentManager.verifyAndRepair()
            await MainActor.run {
                if let message = LaunchAgentHealth.userMessage(for: health) {
                    stateForAgent.raiseAppAlarm(.crashProtectionOff, message: message)
                    MenuView.postNotification(title: "Crash protection is off", body: message)
                } else {
                    stateForAgent.clearAppAlarm(.crashProtectionOff)
                }
            }
        }
```
(`verifyAndRepair` returns the state AFTER repair, so the row appears only when repair failed — scan A18.)

- [ ] **Step 2: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected: clean; green.
```bash
git add TranscriberApp/TranscriberApp.swift
git commit -m "fix(launchagent): verify + bootstrap crash protection at every launch; sticky crashProtectionOff alarm when repair fails (L11)"
```

---

### Task L4: Retry cap on confirmed frames; coordinator owns launch recovery (v1 P0.5)

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:68-92` (init: `engineFactory`), `:564-680` (`handleXPCCrash`: 658, 662-666), new `recoverAtLaunch()`, `confirmRecoveryHealthy(now:)`, `noteFirstFrames` (extend), `TranscriberApp/TranscriberApp.swift:116-133` (own the coordinator), `:173-178` (recovery task), `:259-506` (delete `recoverIfNeeded`, `setupCrashHandler`), `:508-534` (`MenuView(coordinator:…)`), `TranscriberApp/Views/MenuView.swift:33-89` (take the coordinator)
- Test: `RecordingCoordinatorTests.swift:793-796` and `:844` (change; red-first: assertions invert), plus new tests

**Interfaces:**
```swift
// RecordingCoordinator
public init(..., engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))? = nil, ...)
    // nil → transcriptionRunner.prepareEngine(config:); the Harness injects { _ in (FakeEngine(), FakeDiarizer()) }
public var recoveryConfirmationSeconds: TimeInterval   // default 60; tests set 0
func confirmRecoveryHealthy(now: Date = Date())        // resets xpcRetryCount after the window of confirmed frames with no crash AND no mic alarm since
public func recoverAtLaunch() async                    // the former TranscriberApp.recoverIfNeeded, behaviour-neutral in L4 (L7 changes the decisions)
```

- [ ] **Step 1: Change the enshrined tests and add the new ones**

In `crashWithNoLivePipelineRestartsInChunkIndexNamespace` replace lines 793-796 (`interruptionWarning`, `notified`, `xpcRetryCount == 0`, `recoveryInFlight`) with:
```swift
        // L9: `start()` returning proves nothing (the helper replies before its first frame, and a
        // first-sample crash comes back as another interruption). The streak resets only after
        // confirmed frames — see retryStreakResetsOnlyAfterConfirmedFrames.
        #expect(h.coordinator.xpcRetryCount == 1)
        // Honest "Resumed" (L2): nothing is announced until frames arrive.
        #expect(h.notified.value.isEmpty)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
        #expect(h.coordinator.recoveryInFlight == false)
```
In `crashAfterDecayIntervalStartsAFreshStreak` replace line 844 (`notified … == ["Recording Resumed"]`) with `#expect(h.notified.value.isEmpty && h.appState.interruptionWarning == "Recording restarted — waiting for audio…")`.

Add to `RecordingCoordinatorLifecycleTests`:
```swift
    @Test func retryStreakResetsOnlyAfterConfirmedFrames() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryConfirmationSeconds = 60
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 1)

        let t0 = Date()
        h.coordinator.noteFirstFrames(track: "mic", now: t0)
        #expect(h.notified.value.map(\.title) == ["Recording Resumed"])
        h.coordinator.confirmRecoveryHealthy(now: t0 + 30)
        #expect(h.coordinator.xpcRetryCount == 1, "30 s of frames is not yet confirmation")
        h.coordinator.confirmRecoveryHealthy(now: t0 + 60)
        #expect(h.coordinator.xpcRetryCount == 0)
    }

    /// Spec §8.5 (scan C15): "60 s of CONFIRMED frames" — a mic NotDelivering alarm inside the window
    /// means the frames were not confirmed; the streak stays.
    @Test func aMicAlarmDuringTheConfirmationWindowKeepsTheStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        let t0 = Date()
        h.coordinator.noteFirstFrames(track: "mic", now: t0)
        h.client.onAlarmsChanged?(CaptureStatusSnapshot(helperSessionId: "h2", isCapturing: true,
            alarms: [ActiveAlarm(kind: .micNotDelivering, raisedAt: t0 + 10, lastNotifiedAt: nil, message: "m", episode: 1)], tracks: []))
        for _ in 0..<50 { await Task.yield() }
        h.coordinator.confirmRecoveryHealthy(now: t0 + 61)
        #expect(h.coordinator.xpcRetryCount == 1)
    }

    /// Gotcha #50 / L9: a helper that crashes on its first sample never delivers frames, so the
    /// streak never resets and the third crash inside the window gives up.
    @Test func firstSampleCrashLoopGivesUpAtTheCap() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 2)
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle)
        #expect(h.criticals.value.map(\.title) == ["Recording Failed"])
    }

    @Test func firstFramesOutsideARecoveryDoNotAnnounceResumed() async throws {
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.coordinator.noteFirstFrames(track: "mic")
        #expect(h.notified.value.isEmpty)
    }

    /// Flow A at launch: the helper is still capturing → re-attach, restore its alarm state, no salvage.
    @Test func recoverAtLaunchReattachesToACapturingHelper() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.isCapturingResult = true
        h.client.statusSnapshot = CaptureStatusSnapshot(helperSessionId: "h1", isCapturing: true,
            alarms: [ActiveAlarm(kind: .micDigitalSilence, raisedAt: Date(), lastNotifiedAt: nil, message: "m", episode: 1)], tracks: [])
        await h.coordinator.recoverAtLaunch()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.isRecording && h.client.startCalls.isEmpty)
        #expect(h.client.launchRecoveries.first?["flow"] == "A")
        #expect(h.appState.activeAlarms[.micDigitalSilence] != nil)
        #expect(RecordingSentinel.read(directory: h.tmp) != nil)
    }
```
`Harness.init` gains `engineFactory: { _ in (FakeEngine(), FakeDiarizer()) }` (passed to the coordinator) so `recoverAtLaunch`'s Flow-B branches never touch a real engine.

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'RecordingCoordinatorLifecycleTests'` → compile errors (`recoveryConfirmationSeconds`, `confirmRecoveryHealthy`, `recoverAtLaunch`, `engineFactory`); the two changed assertions would fail (`xpcRetryCount == 0`, `["Recording Resumed"]` today).

- [ ] **Step 3: Coordinator**

- State: `public var recoveryConfirmationSeconds: TimeInterval = 60`, `private var awaitingRecoveryFrames = false`, `private var recoveryFramesAt: Date?`, `private var lastMicAlarmAt: Date?`; `private let engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))?` (init parameter, default nil, placed right after `presentAlarmsUI:`; L8's `freeBytesProvider:` goes after `recordingMicrophone:` — every one of these has a default, so existing call sites are unchanged).
- `handleXPCCrash`: delete `xpcRetryCount = 0` (658); replace the notify (662-666) with `awaitingRecoveryFrames = true; recoveryFramesAt = nil; appState.interruptionWarning = "Recording restarted — waiting for audio…"`.
- In L2's `onAlarmsChanged` closure add, after `applyHelperSnapshot`: `if snapshot.alarms.contains(where: { $0.kind == .micNotDelivering }) { self.lastMicAlarmAt = Date() }`.
- Extend `noteFirstFrames(track:)` (L2) to `func noteFirstFrames(track: String, now: Date = Date())`:
```swift
    func noteFirstFrames(track: String, now: Date = Date()) {
        guard appState.isRecording else { return }
        appState.noteFirstFrames(track: track)
        presentAlarms(now: now)
        guard track == "mic", awaitingRecoveryFrames else { return }
        awaitingRecoveryFrames = false
        recoveryFramesAt = now
        lastMicAlarmAt = nil
        appState.interruptionWarning = "Recording briefly interrupted. Resumed."
        notify("Recording Resumed", "Recording was briefly interrupted and has been restarted.")
        let window = recoveryConfirmationSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.confirmRecoveryHealthy()
        }
    }

    /// L9 / §8.5: the streak resets only after `recoveryConfirmationSeconds` of frames since the
    /// restart's first frame, with no newer crash and no mic NotDelivering alarm in that window.
    func confirmRecoveryHealthy(now: Date = Date()) {
        guard appState.isRecording, let since = recoveryFramesAt,
              now.timeIntervalSince(since) >= recoveryConfirmationSeconds,
              lastCrashAt.map({ $0 <= since }) ?? true,
              lastMicAlarmAt.map({ $0 <= since }) ?? true else { return }
        xpcRetryCount = 0
        recoveryFramesAt = nil
    }
```
- `recoverAtLaunch()`: move `TranscriberApp.recoverIfNeeded` (259-404) into the coordinator: `captureClient` is `self.captureClient` (the protocol now has `isCapturing()` and `recordLaunchRecovery(_:)` — F4); `RecordingSentinel.read()`/`.delete()`/`.write(_:)` use `directory: sentinelDirectory`; `RenameWindowController.shared.show + autoSummarize` (331-334) → `presentTranscript(url, config)`; `CriticalAlertController.shared.show` (340-343, 395-398) → `notifyCritical`; the `UNUserNotificationCenter` block (380-390) → `notify("Recording Resumed", …)` — but only after frames: set `awaitingRecoveryFrames = true` and `appState.interruptionWarning = "Recording restarted — waiting for audio…"` instead; `transcriptionRunner.prepareEngine(config:)` (302) → `engineFactory?(config) ?? transcriptionRunner.prepareEngine(config: config)`; `ConfigManager.shared.config` → `configManager.config`; `RecordingMicrophone.shared.set/clear` → `setHelperMic`/`clearHelperMic`; `setupCrashHandler(...)` (285, 377) → `wireCaptureCallbacks(); startStatusPoll()`; the Flow-A branch (280-287) also `Task { await pollHelperStatus() }` so the helper's alarms are restored on re-attach; `mirrorMicSwitches` is not needed (the wired `onMicDeviceChanged` covers it). Keep the `systemUptime` stale check (270-276) as is — L7 replaces it. `captureClient.start(...)` calls pass `options: CaptureOptions(config: configManager.config), sessionId: stripSegmentSuffix(sentinel.systemAudioPath)`.

- [ ] **Step 4: App wiring**

`TranscriberApp.swift`: add `private let coordinator: RecordingCoordinator` (next to `captureClient`, 119), constructed in `init()` right after `captureClient` (136-137) with the closures now in `MenuView.init` (73-87) moved here verbatim plus `presentAlarmsUI: { alarms, new in CaptureAlarmWindowController.shared.present(alarms, newlyRaised: new, appState: state) }`; replace the `recoverIfNeeded` Task (173-178) with `let c = coordinator; Task { @MainActor in await c.recoverAtLaunch() }`; delete `recoverIfNeeded` (259-404) and `setupCrashHandler` (406-506); `MenuView(...)` (511-519) gains `coordinator: coordinator`. `MenuView.swift`: `let coordinator: RecordingCoordinator` replaces `@State private var coordinator` (45) and the construction in `init` (66-88); `init` takes `coordinator:`.

- [ ] **Step 5: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'RecordingCoordinatorLifecycleTests'` → pass; `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/RecordingCoordinator.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(recovery): retry streak resets on 60 s of confirmed frames (no crash, no mic alarm), honest Resumed, coordinator owns launch recovery (L9, L2)"
```

---

### Task L5: Stop vs crash, double start, post-start failure (v1 P3.2) — needs C13, R0, R2 merged

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:184-309` (`startRecording`: `startInFlight`, post-start bounded stop), `:411-559` (`stopRecording` catch), `:564-680` (`handleXPCCrash` guards), `TranscriberApp/Views/MenuView.swift:306-327` (Record disabled while `isStartInFlight`)
- Test: `RecordingCoordinatorTests.swift` (add; red-first)

- [ ] **Step 1: Write the failing tests**

```swift
    /// L6: the trailing invalidation of a stop lands mid-stop; the stop path owns the teardown.
    @Test func aCrashDuringStopIsIgnoredByTheCrashHandler() async throws {
        let h = try Harness(); _ = try h.writeSentinel(); h.appState.phase = .recording(since: Date())
        h.client.stopError = FakeCaptureError()
        h.client.onStop = { await h.coordinator.handleXPCCrash() }
        await h.coordinator.stopRecording()
        #expect(h.client.startCalls.isEmpty, "the stop path owns the teardown; no restart")
        #expect(h.appState.isIdle)
    }

    /// L7: a second Start while the first is still setting up is ignored, not queued.
    @Test func aSecondStartWhileOneIsInFlightIsIgnored() async throws {
        let h = try Harness()
        h.client.onStart = { Task { await h.coordinator.startRecording(sessionName: "b", microphoneDeviceId: nil) } }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.client.startCalls.count == 1)
        #expect(RecordingSentinel.read(directory: h.tmp)?.sessionName == "a")
        #expect(!h.coordinator.isStartInFlight)
    }

    /// L8: any failure after a successful helper start runs a bounded stop before reporting.
    @Test func aFailureAfterAStartedHelperStopsTheHelper() async throws {
        let h = try Harness()
        h.runner.failSetupForTesting = true   // R0 seam: setupChunkedPipeline throws
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.stopCalls == 1)
        #expect(h.appState.isIdle)
        #expect(h.notified.value.map(\.title) == ["Recording Failed"])
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }
```

- [ ] **Step 2: Run to verify they fail** → compile error on `isStartInFlight`; the other two would fail (a restart happens; `stopCalls == 0`).

- [ ] **Step 3: Implement**

- `startRecording`: `public private(set) var isStartInFlight = false`; after the clamshell hop (207) `guard appState.isIdle, !isStartInFlight else { return }; isStartInFlight = true; defer { isStartInFlight = false }`; `var captureStarted = false` set `true` right after `try await captureClient.start(...)` (283-288); in the `catch` (303-308): `if captureStarted { _ = try? await withDeadline(seconds: 20, label: "stop after failed start") { try await self.captureClient.stop() } }` before `clearHelperMic()` (the helper must let go of the mic before the marker is released, #192).
- `stopRecording`: `stopInFlight` already exists (46, set at 424); in `handleXPCCrash` add `guard !stopInFlight else { Logger.state.info("Crash handler yielding to a stop in flight"); return }` as the first statement, and `guard appState.isRecording, !stopInFlight else { return }` after every `await` (the orphan re-ingest at 621 is synchronous; the `await captureClient.start` at 642 is the one that matters). The `stopRecording` catch (532-558): `finalizeAbandonedSession(sentinel:, reingestOrphan: true)` (the orphan is re-ingested once — R2's index dedup makes a second attempt a no-op).
- `MenuView.recordButton` (306-327): `.disabled(appState.isTranscribing || coordinator.isStartInFlight)`.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift TranscriberApp/Views/MenuView.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(lifecycle): crash handler yields to a stop in flight, orphan re-ingested once, double start ignored, post-start failure stops the helper (L6, L7, L8)"
```

---

### Task L6: Salvage says what it did; Flow B is presented, not silent (v1 P2.5 wiring) — needs C9 merged

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:596-610` (give-up message), `:667-679` (restart-failed message), `:532-558` (stop-failed message), `:686-726` (`finalizeAbandonedSession`/`salvageAbandonedSession` → `SalvageOutcome`), `recoverAtLaunch` Flow B chunked branch (from L4)
- Test: `RecordingCoordinatorTests.swift:983-1026` (`RecordingCoordinatorSalvageTests`: assert the outcome; red-first: `salvageAbandonedSession` gains a return value the tests bind)

- [ ] **Step 1: Change the tests**

In `salvageEmptySessionTearsDownWithoutTranscript` (983): `let outcome = await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: …)` and add `#expect(outcome == SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))`. In `salvageNonEmptySessionStampsProvenanceBeforeFinalizing` (1000): bind the outcome and add
```swift
        // One chunk → no concatenation; finalize assembles the JSON from the chunk's segments and writes it
        // (TranscriptionRunner.finalize:335-460 reads no audio for a single chunk), so this fixture's
        // non-existent .m4a is fine: the transcript IS written.
        #expect(outcome.chunkCount == 1)
        #expect(outcome.kind == .transcriptWritten(outDir.appendingPathComponent("sess.json")))
        #expect(h.appState.lastJsonPath == outDir.appendingPathComponent("sess.json").path)
```
Add:
```swift
    @Test func aFinalizeFailureIsReportedNotSwallowed() async throws {
        let h = try Harness()
        let outDir = h.tmp.appendingPathComponent("nowrite")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path) }
        let state = SessionState(sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
                                 chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: "sess-0.m4a", segments: [], speakerDatabase: [:])])
        let outcome = await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: outDir)
        guard case .finalizeFailed = outcome.kind else { Issue.record("expected finalizeFailed, got \(outcome.kind)"); return }
        #expect(h.appState.lastJsonPath == nil)
    }
```
Also: `grep -n "has been transcribed" SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift` — any assertion on the old wording (in `crashLoopWithinDecayWindowGivesUp` at 816 or `crashRestartFailureEscalatesCritically` at 801) changes to `contains("No transcript could be written")` (the harness has no chunks). If the grep finds nothing, nothing changes.

- [ ] **Step 2: Run to verify they fail** → compile errors / the outcome assertions fail.

- [ ] **Step 3: Implement**

`salvageAbandonedSession` (707-726) returns `SalvageOutcome`: `nothingToSalvage` on empty (chunkCount 0); on success `transcriptWritten(result.jsonPath)`; on a thrown `finalize` → `finalizeFailed("\(error.localizedDescription)")` (a real `catch`, no `try?`), chunkCount = `sessionState.chunks.count`; `finalizeAbandonedSession` (686-701) returns it too (`nothingToSalvage` when there is no processor — and calls `teardownChunkedPipeline()` on that path, closing the guard gap at 690). The three message sites: give-up (605-608) → `RecoveryMessages.recordingFailed(after: outcome)`; restart failed (675-678) → the same; stop failed (553-556) → `RecoveryMessages.stopFailed(after: outcome, error: error.localizedDescription)`. `recoverAtLaunch` Flow B chunked (from L4): on a result → `await presentCompletedTranscription(result)` (posts the completion notice + rename), then `notifyCritical("Recording STOPPED", RecoveryMessages.relaunchStopped(at: sentinel.startedAt, outcome:))` and `appState.raiseAppAlarm(.recordingStopped, message:)`; on nil → the `nothingToSalvage` message, same alarm.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(recovery): salvage reports what it wrote; relaunch salvage is presented and says the recording STOPPED (P6)"
```

---

### Task L7: Honest relaunch — `RelaunchDecision`, sentinel liveness and `stopping`, resume the same session (v1 P3.1 wiring) — needs C7, R0, R5 merged

**Files:**
- Modify: `TranscriberCore/RecordingSentinel.swift:7-23` (fields), `:35-44` (decode), `TranscriberCore/RecordingCoordinator.swift` (`recoverAtLaunch` decisions; alive timer; `refreshSentinelLiveness(now:)`; `markSentinelStopping()` in `stopRecording`; `resumeSameSession`), `TranscriberCore/ChunkRotator.swift:93-120` (`onRotated`)
- Test: `RecordingSentinelTests.swift` (add), `RecordingCoordinatorTests.swift` (new suite `RecordingCoordinatorRelaunchTests`), `ChunkRotatorTests.swift` (add) — red-first

**Interfaces:**
```swift
// RecordingSentinel: + lastAliveAt: Date?, bootSessionUUID: String?, stopping: Bool (all decodeIfPresent; stopping defaults false)
// RecordingCoordinator
var aliveRefreshInterval: Duration = .seconds(60)
func refreshSentinelLiveness(now: Date = Date())
func markSentinelStopping()                                  // called by stopRecording BEFORE captureClient.stop()
// ChunkRotator: var onRotated: (@MainActor () -> Void)?    // after onChunkFinalized, every successful rotation
```

- [ ] **Step 1: Write the failing tests**

`RecordingSentinelTests.swift` (inside the suite; `makeTempDir`/`cleanup`/`makeSentinel` exist):
```swift
    @Test func livenessBootSessionAndStoppingRoundTripAndDefault() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        var s = makeSentinel(startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try RecordingSentinel.write(s, directory: dir)
        let bare = try #require(RecordingSentinel.read(directory: dir))
        #expect(bare.lastAliveAt == nil && bare.bootSessionUUID == nil && bare.stopping == false)
        s.lastAliveAt = Date(timeIntervalSinceReferenceDate: 800_000_060)
        s.bootSessionUUID = "B1"
        s.stopping = true
        try RecordingSentinel.write(s, directory: dir)
        let full = try #require(RecordingSentinel.read(directory: dir))
        #expect(full.lastAliveAt?.timeIntervalSinceReferenceDate == 800_000_060 && full.bootSessionUUID == "B1" && full.stopping)
    }
```
`ChunkRotatorTests.swift` (the file has `makeRotator(startTime:)`; add a rotator whose `onRotated` is observable — `rotateNow()` arrives in L8, so this test drives `recoverFromCrash` which does not rotate; use the timer seam instead):
```swift
    @Test func onRotatedFiresAfterEverySuccessfulRotation() async throws {
        let fired = Box(0)
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        rotator.onRotated = { fired.value += 1 }
        rotator.start()
        let timer = try #require(rotator.activeTimerForTesting)
        timer.fire()                                    // one rotation, synchronously scheduled
        for _ in 0..<50 { await Task.yield() }
        rotator.stop()
        #expect(fired.value == 1 && rotator.currentChunkInfo.index == 1)
    }
```
(`Box` is a tiny `final class Box<T> { var value: T; init(_ v: T) { value = v } }` added at file scope in `ChunkRotatorTests.swift`; `activeTimerForTesting` is at `ChunkRotator.swift:47`.)

`RecordingCoordinatorTests.swift` — new suite:
```swift
@MainActor
@Suite struct RecordingCoordinatorRelaunchTests {
    private func writeSentinel(_ h: Harness, alive: TimeInterval?, boot: String? = BootSession.currentUUID(), stopping: Bool = false) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = alive.map { Date().addingTimeInterval(-$0) }
        s.bootSessionUUID = boot
        s.stopping = stopping
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }

    /// L1 (§8.3): the app died 30 s ago; the helper is gone; resume the SAME session and say so.
    @Test func freshSentinelResumesTheSameSessionAndRecordsTheGap() async throws {
        let h = try Harness()
        let s = try writeSentinel(h, alive: 30)
        try RecoveryFixtures.writeSessionJSON(dir: URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent(), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1 && h.client.startCalls[0].baseName == "sess-1")
        #expect(h.appState.isRecording)
        #expect(h.appState.activeAlarms[.recordingResumedWithGap]?.message.contains("resumed at") == true)
        #expect(h.client.launchRecoveries.first?["flow"] == "resume")
        #expect(h.client.recordedEvents.contains { $0.kind == .captureGap && $0.detail["reason"] == "app relaunch" })
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt != nil)
        let state = try #require(await h.runner.chunkProcessor?.getSessionState())
        #expect(state.chunks.map(\.index) == [0], "seeded from session.json")
        #expect(state.gaps.map(\.reason) == ["app relaunch"])
    }

    @Test func oldSentinelSalvagesAndStopsLoudly() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 600)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
        #expect(h.criticals.value.first?.body.hasPrefix("Recording STOPPED at") == true)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "deleted only after the salvage ran")
    }

    /// Scan A163/C16: a crash during post-Stop finalize must not restart a recording the user stopped.
    @Test func aStoppingSentinelIsSalvagedNeverResumed() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 5, stopping: true)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    @Test func aSentinelFromAnotherBootIsSalvagedNotDeleted() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 10, boot: "not-this-boot")
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.activeAlarms[.recordingStopped] != nil)
    }

    @Test func stopMarksTheSentinelStoppingBeforeAskingTheHelper() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let seen = Harness.Box<Bool?>(nil)
        h.client.onStop = { seen.value = RecordingSentinel.read(directory: h.tmp)?.stopping }
        h.client.stopError = FakeCaptureError()
        await h.coordinator.stopRecording()
        #expect(seen.value == true)
    }

    @Test func refreshSentinelLivenessRewritesLastAliveAt() throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 30)
        let now = Date(timeIntervalSince1970: 5_000)
        h.coordinator.refreshSentinelLiveness(now: now)
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt == now)
    }
}
```

- [ ] **Step 2: Run to verify they fail** → compile errors.

- [ ] **Step 3: Implement**

`RecordingSentinel`: `public var lastAliveAt: Date?`, `public var bootSessionUUID: String?`, `public var stopping: Bool = false` (init parameters with defaults; `decodeIfPresent` in `init(from:)` at 35-44, `stopping ?? false`). `startRecording` writes `lastAliveAt: Date(), bootSessionUUID: BootSession.currentUUID()`.

`RecordingCoordinator`:
- `markSentinelStopping()`: read, set `stopping = true`, write; called in `stopRecording` right after `let sentinel = RecordingSentinel.read(...)` (428) and before `captureClient.stop()` (429).
- `refreshSentinelLiveness(now:)`: read, set `lastAliveAt = now`, write. Alive timer: `private var aliveTimer: Task<Void, Never>?` started with the status poll (every `aliveRefreshInterval`), cancelled with it; `transcriptionRunner.chunkRotator?.onRotated = { [weak self] in self?.refreshSentinelLiveness() }` after `setupChunkedPipeline` (and after the resume's setup).
- `recoverAtLaunch()`: replace the `systemUptime` block and the Flow A/B branches with
```swift
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let folderReachable = FileManager.default.isWritableFile(atPath: outputDir.path)
        let helperCapturing = await captureClient.isCapturing()
        switch RelaunchDecision.decide(lastAliveAt: sentinel.lastAliveAt, bootSessionUUID: sentinel.bootSessionUUID, wasStopping: sentinel.stopping,
                                       now: Date(), helperCapturing: helperCapturing, currentBootSessionUUID: BootSession.currentUUID(),
                                       folderReachable: folderReachable) {
        case .reattach:                 // the L4 Flow-A branch, unchanged, + the alive timer
        case .resumeSameSession(let gapStart): await resumeSameSession(sentinel: sentinel, outputDir: outputDir, gapStart: gapStart)
        case .salvageAndStop, .salvageStale: await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)   // the L6 Flow-B chunked branch (chunked or legacy), then delete the sentinel
        case .waitForFolder:
            appState.raiseAppAlarm(.recordingFolderUnavailable, message: "The recording folder isn’t reachable — Parley will keep the recording data and retry.")
            Task { [weak self] in try? await Task.sleep(for: .seconds(30)); await self?.recoverAtLaunch() }
        }
```
  with `resumeSameSession`: `let plan = CrashRecoveryPlanner.planRestart(sentinel: sentinel, outputDirectory: outputDir)`; `wireCaptureCallbacks()`; `setHelperMic(sentinel.micDeviceUID)`; `try await captureClient.start(outputDirectory: outputDir, baseName: plan.baseName, microphoneDeviceId: sentinel.micDeviceUID, systemAudioSource: configManager.config.systemAudioSource, options: CaptureOptions(config: configManager.config), sessionId: sessionId)` where `sessionId = stripSegmentSuffix(sentinel.systemAudioPath)`; write `plan.newSentinel` with `lastAliveAt = now`, `bootSessionUUID`, `stopping = false`; `try transcriptionRunner.setupChunkedPipeline(captureClient:, outputDirectory:, sessionBaseName: sessionId, config:, seededState: SessionState.read(directory: outputDir, sessionId: sessionId))` (R0 + R5), `startChunkRotation()`, `onRotated` hook; re-ingest orphans: `for orphan in CrashRecoveryPlanner.orphanChunks(outputDirectory:sessionId:completedIndices:) { processor.processChunk(FinalizedChunk(index:systemPath:micPath:startTime:)) }` (R2 makes a duplicate index a no-op); `appState.phase = .recording(since: sentinel.startedAt)`; `let now = Date()`; `captureClient.recordLaunchRecovery(["flow": "resume", "gap_seconds": "\(Int(now.timeIntervalSince(gapStart)))"])`; `captureClient.record(.captureGap, .anomaly, ["start": ISO8601(gapStart), "end": ISO8601(now), "reason": "app relaunch"])`; `transcriptionRunner.recordCaptureGap(CaptureGap(start: gapStart, end: now, reason: "app relaunch"))`; `appState.raiseAppAlarm(.recordingResumedWithGap, message: RecoveryMessages.resumedAfterCrash(crashedAt: gapStart, resumedAt: now))`; `notifyCritical("Recording resumed after a crash", <same message>)`; `awaitingRecoveryFrames = true; appState.interruptionWarning = "Recording restarted — waiting for audio…"`; `startStatusPoll()` + alive timer. If `start` throws → `salvageAtLaunch` path.

`ChunkRotator.rotate()` (93-120): after `self.onChunkFinalized(finalized)` (115) add `self.onRotated?()`; `public var onRotated: (@MainActor () -> Void)?`.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberCore/RecordingSentinel.swift TranscriberCore/RecordingCoordinator.swift TranscriberCore/ChunkRotator.swift SwiftTests/TranscriberTests/RecordingSentinelTests.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift SwiftTests/TranscriberTests/ChunkRotatorTests.swift
git commit -m "feat(relaunch): resume the same session after an app crash (gap recorded in the session and the record), honest STOPPED otherwise, stopping sentinel never resumes, boot-session stale check, sentinel never deleted before salvage (L1, L3)"
```

---

### Task L8: Disk — check before start and at every rotation; rotation failures become alarms (v1 P3.3 wiring) — needs C8, R2 merged

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:68-92` (init: `freeBytesProvider`), `startRecording` (refusal), rotation hook (`onRotated` → disk verdict), `TranscriberCore/ChunkRotator.swift:93-120` (`onRotationFailed`, `rotateNow()`)
- Test: `RecordingCoordinatorTests.swift`, `ChunkRotatorTests.swift` (add; red-first)

**Interfaces:**
```swift
// RecordingCoordinator init: + freeBytesProvider: @escaping (URL) -> Int? = { DiskSpaceCheck.freeBytes(at: $0) }
// ChunkRotator: var onRotationFailed: (@MainActor (Error) -> Void)?; public func rotateNow()   // an immediate rotation (wake, tests)
```

- [ ] **Step 1: Write the failing tests**

`RecordingCoordinatorTests.swift`:
```swift
    @Test func startIsRefusedWhenTheDiskIsFull() async throws {
        let h = try Harness()
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic, freeBytesProvider: { _ in 1_000_000 })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        #expect(h.notified.value.first?.title == "Recording not started")
        #expect(h.notified.value.first?.body.contains("MB free") == true)
    }

    @Test func aRotationFailureRaisesTheAlarmAndADeadCaptureBecomesACrash() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
        h.client.rotateError = FakeCaptureError()
        h.runner.chunkRotator?.rotateNow()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.activeAlarms[.rotationFailed] != nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .rotationFailed })
        h.client.rotateError = NoCaptureError()
        h.runner.chunkRotator?.rotateNow()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.startCalls.count == 2, "\"No capture in progress\" means the capture is dead: the crash path restarts it")
    }
```
with, at file scope, `private struct NoCaptureError: Error, LocalizedError { var errorDescription: String? { "No capture in progress" } }` and `FakeCaptureClient` gaining `var rotateError: Error?` (thrown by `rotateChunk`) and `var rotateCalls = 0`.

`ChunkRotatorTests.swift`:
```swift
private final class ThrowingRotationClient: ChunkRotationClient {
    struct Boom: Error {}
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) { throw Boom() }
}
    @Test func aThrowingRotateInvokesOnRotationFailedAndKeepsTheIndex() async throws {
        let failures = Box(0)
        let rotator = ChunkRotator(captureClient: ThrowingRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        rotator.onRotationFailed = { _ in failures.value += 1 }
        rotator.rotateNow()
        for _ in 0..<50 { await Task.yield() }
        #expect(failures.value == 1 && rotator.currentChunkInfo.index == 0)
    }
```

- [ ] **Step 2: Run to verify they fail** → compile errors (`freeBytesProvider`, `rotateNow`, `onRotationFailed`, `rotateError`).

- [ ] **Step 3: Implement**

`ChunkRotator`: `public var onRotationFailed: (@MainActor (Error) -> Void)?`; in the `catch` (116-118) call it after the log; `public func rotateNow() { rotate() }`.

`RecordingCoordinator`: `private let freeBytesProvider: (URL) -> Int?` (init parameter, default `{ DiskSpaceCheck.freeBytes(at: $0) }`); in `startRecording` before writing the sentinel (270): `let free = freeBytesProvider(URL(fileURLWithPath: config.recordingDirectory)) ?? .max; guard DiskSpaceCheck.canStart(freeBytes: free, chunkMinutes: config.validatedChunkDuration) else { notify("Recording not started", DiskSpaceCheck.message(freeBytes: free, chunkMinutes: config.validatedChunkDuration)); return }`. After `setupChunkedPipeline`: `rotator.onRotationFailed = { [weak self] error in … }` → `captureClient.record(.rotationFailed, .anomaly, ["error": "\(error)"])`, `appState.raiseAppAlarm(.rotationFailed, message: "A chunk rotation failed — the current chunk keeps recording, but the file may not rotate again.")`, and if `"\(error.localizedDescription)".contains("No capture in progress")` → `Task { await self.handleXPCCrash() }`. In the `onRotated` hook (L7) also: `let verdict = DiskSpaceCheck.rotationVerdict(freeBytes: free, chunkMinutes:, currentlyLow: appState.activeAlarms[.diskLow] != nil)`; `.low` → `raiseAppAlarm(.diskLow, message: "Less than one chunk of free space — Parley keeps recording, but free some space now.")` + `record(.diskLow, .warning, ["free_mb": …])`; `.ok` → `clearAppAlarm(.diskLow)` and `clearAppAlarm(.rotationFailed)`. `transcriptionRunner.chunkProcessor?.onSessionWriteFailure = { [weak self] index in self?.appState.raiseAppAlarm(.sessionWriteFailed, message: "Parley could not save its progress file — if it is interrupted now, the last chunk may not be recovered."); self?.captureClient.record(.sessionWriteFailed, .anomaly, ["chunk": "\(index)"]) }` (R2's hook).

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift TranscriberCore/ChunkRotator.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift SwiftTests/TranscriberTests/ChunkRotatorTests.swift
git commit -m "fix(disk): free-space check before start and at rotation (diskLow with hysteresis); rotation and session-write failures are alarms; a dead capture on rotate is a crash (L10)"
```

---

### Task L9: Deadlines on every helper call; the sentinel outlives finalize (v1 P3.4) — needs C13, R0 merged

**Files:**
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:151-163` (`drainHelperDiagnostics`), `:206-241` (`start`), `:243-265` (`stop`), `:267-289` (`rotateChunk`), `:291-310` (`updateMicrophone`), `:364-373` (`pingStatus`), `:433-449` (`CaptureError.timedOut`), `TranscriberCore/RecordingCoordinator.swift:431` (sentinel delete → after `presentCompletedTranscription`), `:521-528` (fallback branch), `:546` (catch)
- Test: `RecordingCoordinatorTests.swift` (add; red-first: the sentinel is deleted at 431 today)

- [ ] **Step 1: Write the failing test**

```swift
    /// L13 / #194 / #195: a crash during transcription must still find the sentinel.
    @Test func stopKeepsTheSentinelUntilTheTranscriptExists() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        let mic = call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1); try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
        h.runner.finalizeDelayForTesting = .milliseconds(400)   // R0 seam

        let stopping = Task { await h.coordinator.stopRecording() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(RecordingSentinel.read(directory: h.tmp) != nil, "still there while finalize runs")
        await stopping.value
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.presented.value.count == 1)
    }
```

- [ ] **Step 2: Run to verify it fails** → `finalizeDelayForTesting` exists (R0); the first sentinel assertion fails today (deleted at 431).

- [ ] **Step 3: Implement**

`AudioCaptureClient`: add `case timedOut(String)` to `CaptureError` (433-449); wrap each call's `withCheckedThrowingContinuation` in `try await withDeadline(seconds: N, label: "<call>") { … }` (C13: `start` 15, `stop` 20, `rotateChunk` 10, `updateMicrophone` 10, `drainHelperDiagnostics` 3, `pingStatus` 3; `captureStatus`/`configureCapture`/`systemPowerEvent` already carry 3 s via `ResumeOnce`); on `DeadlineError.timedOut(let label)` → `record(.xpcTimeout, .anomaly, ["call": label])` and rethrow as `CaptureError.timedOut(label)` (for `drainHelperDiagnostics` and `pingStatus`, which do not throw: log + record, return `()` / `false`). Because a timed-out continuation may still be resumed later by the proxy, every wrapped continuation uses `ResumeOnce` (`systemAudioPermissionStatus()` at 317-327 is the pattern).

`RecordingCoordinator`: move `RecordingSentinel.delete(directory: sentinelDirectory)` from 431 to right after `await presentCompletedTranscription(result)` (465) and after the fallback branch's presentation (521-528); in the catch (546) delete only after `finalizeAbandonedSession` returned (it already is, at 546 — keep); `markSentinelStopping()` (L7) stays before `captureClient.stop()`.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberApp/Services/AudioCaptureClient.swift TranscriberCore/RecordingCoordinator.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(xpc): deadlines on every helper call; the sentinel is deleted only once the transcript exists (L13, #194, #195)"
```

---

### Task L10: Sleep, wake, logout/shutdown, quit-while-recording; gaps in the record (v1 P3.5 app part) — needs R0 merged

**Files:**
- Create: `TranscriberApp/Services/SystemEventObserver.swift`
- Modify: `TranscriberCore/RecordingCoordinator.swift` (`systemWillSleep(at:)`, `systemDidWake(at:)`, `systemWillPowerOff()`, `prepareForQuit(confirm:)`, idle-sleep assertion), `TranscriberApp/TranscriberApp.swift` (install the observer), `TranscriberApp/Views/MenuView.swift:17-31` (`quitAfterUninstallingLaunchAgent(coordinator:)`)
- Test: `RecordingCoordinatorTests.swift` (add; red-first)

**Interfaces:**
```swift
// RecordingCoordinator
func systemWillSleep(at: Date = Date())
func systemDidWake(at: Date = Date())
func systemWillPowerOff() async               // logout / shutdown / restart: bounded stop
/// Quit: idle → true. Recording → `confirm()`; true → bounded stop (30 s) then true; false → false (stay).
func prepareForQuit(confirm: () async -> Bool) async -> Bool
```
Spec §8.10 (amended, scan C18): `NSWorkspace.sessionDidResignActiveNotification` is fast user switching — the recording continues, nothing to do; logout, shutdown and restart all arrive as `willPowerOffNotification`.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func sleepAndWakeAreRecordedAsAGapAndForceARotation() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_000)
        h.coordinator.systemWillSleep(at: t0)
        h.coordinator.systemDidWake(at: t0 + 120)
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        #expect(h.client.recordedEvents.map(\.kind).filter { $0 == .systemSleep || $0 == .systemWake } == [.systemSleep, .systemWake])
        #expect(h.client.rotateCalls == 1, "wake forces a rotation")
        let gaps = try #require(await h.runner.chunkProcessor?.getSessionState().gaps)
        #expect(gaps.count == 1 && gaps[0].reason == "sleep" && gaps[0].seconds == 120)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
    }

    @Test func quitWhileRecordingStopsFirstOnlyWhenConfirmed() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(await h.coordinator.prepareForQuit(confirm: { false }) == false)
        #expect(h.client.stopCalls == 0 && h.appState.isRecording)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }) == true)
        #expect(h.client.stopCalls == 1)
        let idle = try Harness()
        #expect(await idle.coordinator.prepareForQuit(confirm: { false }) == true, "idle: nothing to confirm")
    }
```

- [ ] **Step 2: Run to verify they fail** → compile errors.

- [ ] **Step 3: Implement**

`SystemEventObserver` (app, `@MainActor final class`): observes `NSWorkspace.shared.notificationCenter` for `willSleepNotification`, `didWakeNotification`, `willPowerOffNotification` and forwards to `coordinator.systemWillSleep()`, `systemDidWake()`, `Task { await coordinator.systemWillPowerOff() }`. Installed in `TranscriberApp.init` next to the coordinator.

`RecordingCoordinator`:
- `private var sleptAt: Date?`; `private var sleepAssertion: NSObjectProtocol?` — `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Recording")` when the phase becomes `.recording` (in `startRecording`, the reattach and the resume paths) and `endActivity` on every path to idle (lid close is the user's call: recorded, not fought).
- `systemWillSleep(at:)`: `guard appState.isRecording`; `sleptAt = at`; `captureClient.record(.systemSleep, .info, [:])`; `stopStatusPoll()`; `Task { await captureClient.systemPowerEvent("sleep") }`.
- `systemDidWake(at:)`: `guard appState.isRecording, let start = sleptAt`; `sleptAt = nil`; `captureClient.record(.systemWake, .info, ["seconds": "\(Int(at.timeIntervalSince(start)))"])`; `transcriptionRunner.recordCaptureGap(CaptureGap(start: start, end: at, reason: "sleep"))` (R0); `Task { await captureClient.systemPowerEvent("wake") }`; `transcriptionRunner.chunkRotator?.rotateNow()` (L8); `awaitingRecoveryFrames = true; appState.interruptionWarning = "Recording restarted — waiting for audio…"` (so "Resumed" waits for frames); `startStatusPoll()`.
- `systemWillPowerOff()`: `if appState.isRecording { _ = try? await withDeadline(seconds: 30, label: "power off stop") { await self.stopRecording() } }`.
- `prepareForQuit(confirm:)` per Interfaces (bounded 30 s via `withDeadline`).

`MenuView.swift:17-31`: `quitAfterUninstallingLaunchAgent(coordinator: RecordingCoordinator)`: `Task { guard await coordinator.prepareForQuit(confirm: { await MenuView.confirmQuitWhileRecording() }) else { return }; await LaunchAgentManager.uninstall(); NSApplication.shared.terminate(nil) }` — the 5 s fallback terminate stays but starts only after `prepareForQuit` returned true. `confirmQuitWhileRecording()` is an `NSAlert` ("Stop the recording and quit?" / Stop and Quit / Cancel) run on the main actor.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberApp/Services/SystemEventObserver.swift TranscriberCore/RecordingCoordinator.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "feat(lifecycle): sleep/wake recorded as gaps and re-armed on wake; logout/shutdown and quit-while-recording stop first (L12, §8.10)"
```

---

### Task L11: Evidence survives restarts; monotonic chunk clock (v1 P3.6 wiring) — needs C10, C11, E2 merged

**Files:**
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:113-121` (`record` → live log), `:168-204` (`finalizeSessionDiagnostics` merges + deletes), `:206-241` (`start`: reset only on a new session id, drain first), `TranscriberCore/ChunkRotator.swift:26-36, 108` (`MonotonicWallClock`)
- Test: `ChunkRotatorTests.swift` (add; red-first: `clock:` init parameter does not exist)

- [ ] **Step 1: Write the failing test**

```swift
    /// L15: chunk start times come from the monotonic clock anchored at the session start.
    @Test func chunkStartTimesComeFromTheMonotonicClock() async throws {
        let anchor = ContinuousClock.now
        let clock = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: anchor)
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, clock: clock, onChunkFinalized: { _ in })
        #expect(rotator.currentChunkInfo.startTime == Date(timeIntervalSince1970: 0))
        rotator.rotateNow()
        for _ in 0..<50 { await Task.yield() }
        let t = rotator.currentChunkInfo.startTime.timeIntervalSince1970
        #expect(t >= 0 && t < 5, "derived from the monotonic clock, not from Date()")
    }
```

- [ ] **Step 2: Run to verify it fails** → compile error (`clock:`).

- [ ] **Step 3: Implement**

`ChunkRotator`: `private let clock: MonotonicWallClock`; init gains `clock: MonotonicWallClock` (replacing `startTime: Date`; `currentChunkStartTime = clock.anchorWall`); keep a convenience `init(..., startTime: Date, ...)` that builds `MonotonicWallClock.start(now: startTime)` so `setupChunkedPipeline` (R's file) is unchanged; line 108 `self.currentChunkStartTime = clock.now()`.

`AudioCaptureClient`: `private var liveLog: LiveDiagnosticsLog?`; `record()` (113-121) also `liveLog?.append(event)`; `start` (206-241): replace `diagnostics.clear()` (214) with
```swift
        await drainHelperDiagnostics()   // bounded (L9): the previous helper's events before they are lost
        if sessionId != currentSessionId {
            diagnostics.resetSession()
            liveLog = LiveDiagnosticsLog(directory: outputDirectory, sessionId: sessionId)
        }
        currentSessionId = sessionId
```
(`interruptionPolicy.captureStarted()` stays unconditional.) `finalizeSessionDiagnostics` (168-204): after draining, `if let liveLog { diagnostics = liveLog.merged(into: diagnostics) }`; write `<session>.diag.jsonl` if anomalous as today; then `liveLog?.delete(); liveLog = nil`. A relaunch that resumes the same session id finds the previous process's `<session>.diag.live.jsonl` on disk and keeps appending to it, so the merge at finalize covers both processes with no extra API.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberApp/Services/AudioCaptureClient.swift TranscriberCore/ChunkRotator.swift SwiftTests/TranscriberTests/ChunkRotatorTests.swift
git commit -m "fix(evidence): app ring reset only on a new session id, helper drained first, anomalies written live and merged at finalize; chunk clock is monotonic (L4, L14, L15, H7)"
```

---

### Task L12: The completion notice names processing problems and empty transcripts (v1 P2.2 coordinator part) — needs R2 merged

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:733-778` (`presentCompletedTranscription` — make it internal, read the three counts)
- Test: `RecordingCoordinatorTests.swift` (add; red-first: `presentCompletedTranscription` is private today)

- [ ] **Step 1: Write the failing test**

```swift
    @Test func completionNoticeNamesProcessingProblemsAndEmptyTranscripts() async throws {
        let h = try Harness()
        let url = h.tmp.appendingPathComponent("done.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["processing_problem_chunks": 2, "capture_provenance": ["quality_anomaly_count": 0]],
            "segments": [["start": 0.0, "end": 1.0, "text": "x", "speaker": "S"]],
        ]).write(to: url)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete — 2 chunks had processing problems")
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [] as [Any]]).write(to: url)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete — no speech was transcribed")
    }
```

- [ ] **Step 2: Run to verify it fails** → compile error (`presentCompletedTranscription` is private).

- [ ] **Step 3: Implement**

`presentCompletedTranscription` (733): drop `private`; read `anomalies`, `problemChunks = CaptureQualityNotice.problemChunkCount(inTranscriptAt:)`, `segments = CaptureQualityNotice.segmentCount(inTranscriptAt:)` in the same detached task (743-745); call `completionTitle(anomalyCount:problemChunkCount:segmentCount:)` / `completionBody(fileName:anomalyCount:problemChunkCount:segmentCount:)` (764-768).

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "feat(record): the completion notice names processing problems and empty transcripts (P3)"
```

### L gate

Stream gate (council lens: every relaunch branch ends in an alarm or a notice; no path deletes the sentinel before salvage; every `await` in the crash handler re-checks state; the alarm presenter never blocks or stops a recording). Merge.

---
# Stream D — Product defaults (owner decisions of 2026-09-24, spec §11)

One implementer, two tasks. Branch after F merged (F3 touched `Config.swift`/`ConfigTests.swift`).

### Task D1: `Config.default.systemAudioSource = .coreAudioTap`; SCK relabelled (§11.1)

**Files:**
- Modify: `TranscriberCore/Config.swift:189` (`systemAudioSource: .screenCaptureKit` in `Config.default`), `:304` (`decodeIfPresent(...) ?? .screenCaptureKit` — the fallback for a config.json WITHOUT the key)
- Modify: `TranscriberApp/Views/SettingsView.swift:271-281` (picker labels)
- Test: `SwiftTests/TranscriberTests/ConfigTests.swift` (add; red-first: asserts the new default)

Decision (owner, 2026-09-24): new installs record with the tap. An existing `config.json` that names `"sck"` keeps it; an existing `config.json` that has NO `system_audio_source` key was written by a build that defaulted to SCK and behaved as SCK — it keeps SCK too (the decode fallback stays `.screenCaptureKit`), so the flip changes only `Config.default`, i.e. first-run installs. SCK stays selectable until #221 drops it.

- [ ] **Step 1: Write the failing test**

Append to `ConfigTests`:
```swift
    /// §11.1 (owner decision 2026-09-24): new installs use the Core Audio tap; an existing config.json
    /// without the key was written by an SCK-era build and stays SCK (no silent change of a live setup).
    @Test func newInstallsDefaultToTheCoreAudioTapAndOldConfigsKeepSCK() throws {
        #expect(Config.default.systemAudioSource == .coreAudioTap)
        let legacy = Data(#"{"recording_directory":"/tmp/r","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false}"#.utf8)
        #expect(try JSONDecoder().decode(Config.self, from: legacy).systemAudioSource == .screenCaptureKit)
        let explicit = Data(#"{"recording_directory":"/tmp/r","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false,"system_audio_source":"sck"}"#.utf8)
        #expect(try JSONDecoder().decode(Config.self, from: explicit).systemAudioSource == .screenCaptureKit)
    }
```
(The six keys in the fixtures are the ones `init(from:)` decodes strictly at `Config.swift:294-322`.)

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'ConfigTests'` → the first assertion fails (`.screenCaptureKit` today).

- [ ] **Step 3: Implement**

`Config.swift:189`: `systemAudioSource: .coreAudioTap,` with the comment `// §11.1: new installs record with the tap; the decode fallback below stays SCK for pre-existing configs.` Line 304 unchanged. `SettingsView.swift:273-274`:
```swift
                Text("Core Audio Tap (default — captures calls)").tag(SystemAudioSource.coreAudioTap)
                Text("Screen Recording (legacy, until #221)").tag(SystemAudioSource.screenCaptureKit)
```
(order: tap first).

- [ ] **Step 4: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'ConfigTests'` → pass; `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/Config.swift TranscriberApp/Views/SettingsView.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat(config): new installs default to the Core Audio tap; SCK relabelled legacy until #221 (§11.1, owner decision 2026-09-24)"
```

---

### Task D2: `EngineID.default = .fluidAudio`; Apple Speech labelled "not yet usable"; engine preflight at Setup Continue and Settings Save (§11.2, v1 P2.9) — needs C12 merged

**Files:**
- Modify: `TranscriberCore/EngineID.swift:28` (`default`), `:43-62` (descriptor: `isUsableEndToEnd`, `displayName`)
- Modify: `TranscriberApp/Views/SetupView.swift:220-238` (Continue runs the preflight), `TranscriberApp/Views/SettingsView.swift:199, 510-551` (Save runs it)
- Test: `SwiftTests/TranscriberTests/EngineIDTests.swift` (add; red-first)

Decision (owner, 2026-09-24; scan B P2.9(2)/C3): LABEL, never hide. `availableEngines` is unchanged, so no picker can preselect an engine that is not listed. The real fix is issue #223 (high priority, out of scope here).

**Interfaces:**
```swift
// EngineDescriptor: + isUsableEndToEnd: Bool
// EngineID.default == .fluidAudio; resolvedDefault unchanged in shape (fluidAudio is available on 15.0+, so it resolves to itself)
// EngineID.speechAnalyzer.descriptor.displayName == "Apple Speech — not yet usable (#223)"
```

- [ ] **Step 1: Write the failing test**

Append to `EngineIDTests`:
```swift
    /// §11.2 (owner decision 2026-09-24): FluidAudio is the default; Apple Speech stays listed but
    /// says why it cannot be trusted yet (#223). Nothing is hidden, so no picker preselects an unlisted engine.
    @Test func fluidAudioIsTheDefaultAndAppleSpeechIsLabelledNotYetUsable() {
        #expect(EngineID.default == .fluidAudio)
        #expect(EngineID.resolvedDefault == .fluidAudio)
        #expect(EngineID.fluidAudio.descriptor.isUsableEndToEnd)
        #expect(EngineID.speechAnalyzer.descriptor.isUsableEndToEnd == false)
        #expect(EngineID.speechAnalyzer.descriptor.displayName == "Apple Speech — not yet usable (#223)")
        #expect(EngineID.speechAnalyzer.descriptor.description.contains("language"))
        #expect(EngineID.availableEngines.contains(EngineID.default))
    }
```

- [ ] **Step 2: Run to verify it fails** — `$PARLEY_TEST --filter 'EngineIDTests'` → compile error on `isUsableEndToEnd`.

- [ ] **Step 3: Implement**

`EngineID.swift`: `EngineDescriptor` gains `public var isUsableEndToEnd: Bool = true` (a `var` with a default so the synthesized memberwise init keeps working for the other call sites); line 28 `public static let default: EngineID = .fluidAudio` with the comment `// §11.2 owner decision 2026-09-24; Apple Speech goes back to default when #223 lands`; the `.speechAnalyzer` descriptor (46-52): `displayName: "Apple Speech — not yet usable (#223)"`, `description: "Apple's on-device model. Produces blank transcripts on the live chunk path until it gets a language setting (#223). No download. Requires macOS 26."`, `isUsableEndToEnd: false`; `.fluidAudio` (54-60): `displayName: "FluidAudio (recommended)"`, `isUsableEndToEnd: true`.

`SetupView.swift` Continue (220-238): inside the `Task`, after `verifyFolderAccess` succeeds and before `onReady()`: `do { let (engine, _) = try TranscriptionRunner().prepareEngine(config: configManager.config); try await EnginePreflight.run(engine: engine) } catch { enginePreflightError = "This engine cannot transcribe on this Mac: \(error)"; checkingFolder = false; return }` with a `@State private var enginePreflightError: String?` rendered as an `AlertBanner(severity: .critical, …)` under the engine row; the Continue label reads "Checking…" while it runs (the existing `checkingFolder` flag covers both checks).

`SettingsView.swift` `save()` (510): before `configManager.update { $0 = config }` (540): `Task { do { let (engine, _) = try TranscriptionRunner().prepareEngine(config: config); try await EnginePreflight.run(engine: engine); await MainActor.run { commitSave() } } catch { await MainActor.run { saveStatus = "Not saved — this engine cannot transcribe on this Mac: \(error)" } } }` where `commitSave()` is the remainder of today's `save()` from line 538 on; the Save button (199) is disabled while the preflight runs (`isPreflighting` state).

- [ ] **Step 4: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'EngineIDTests'` → pass; `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/EngineID.swift TranscriberApp/Views/SetupView.swift TranscriberApp/Views/SettingsView.swift SwiftTests/TranscriberTests/EngineIDTests.swift
git commit -m "feat(engine): FluidAudio is the default; Apple Speech labelled not yet usable (#223); the chosen engine is preflighted at Setup Continue and Settings Save (§11.2, P1)"
```

### D gate

Stream gate; merge.

---
# Stream X — Final docs, checklist, measurement decisions (after every other stream has merged)

X owns every shared document; no other stream edits them, so nothing serializes on docs. X1 and X2 are commits; X3 is device time with the owner.

### Task X1: `scripts/test-checklist.md` — the overhaul's protocol (Regression section preserved verbatim)

**Files:**
- Modify: `scripts/test-checklist.md:1-49` — replace everything ABOVE line 50 `## Regression (always — do not trim; these are standing gates, not per-feature tests)` with the section below; keep line 50 and everything after it byte-for-byte.

- [ ] **Step 1: Replace the head of the checklist with this content**

```markdown
# Test Checklist — capture reliability overhaul (spec: docs/superpowers/specs/2026-09-24-capture-reliability-design.md)

Build and install this tree: `python3 scripts/dev.py`. Settings → Audio → Capture Method → **Core Audio Tap** (the default for new installs since §11.1).
"Remote" audio: a real call where stated, otherwise `afplay <file>`. Watch the helper with
`log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug` and read `<session>.diag.jsonl` after Stop.

The promise under test: for each side, **captured / healed within seconds / told loudly and persistently — never neither**.
Every mid-call item ends with the same check: after Stop the `.m4a` channel has the audio, or an alarm persisted, and
`metadata.capture.<side>.status` says which. Right channel: `ffmpeg -i <file>.m4a -af "pan=mono|c0=c1,volumedetect" -f null -`.
Diagnostic knobs in `config.json` (docs/parameters.md → Debugging): `tap_auto_start`, `remote_exact_zero_soft_alarm_seconds`, `debug_drop_tap_frames`.

## P0 — live safety
- [ ] **D-01 Idle-exit does not disarm crash detection.** Launch, wait 12 min without recording (helper idle-exits: `log stream` shows "XPC interrupted while idle — helper idle-exit, ignored" and no throwaway helper is spawned), start a recording, `pkill -9 -f audio-capture-helper-xpc`. Expect: "Recording restarted — waiting for audio…" then "Recording Resumed" only after frames; after Stop, `<session>.diag.jsonl` has `xpcInterruption`/`retry` (the idle-exit is not part of this session's log — it happened before it).
- [ ] **D-02 LaunchAgent verified and repaired.** After launch: `launchctl print gui/$(id -u)/eu.fmasi.parley` exits 0 and no "Crash protection is off" row. Quit → `launchctl print` exits non-zero AND `~/Library/LaunchAgents/eu.fmasi.parley.plist` is gone. Relaunch → loaded again, no row. Move the app bundle and launch from the new path → `launchctl print` shows the NEW path within seconds, still no row (repair succeeded silently). Force a failure: `chmod 500 ~/Library/LaunchAgents` then launch → the row AND a notification "Crash protection is off" appear; `chmod 700` and relaunch → row gone.
- [ ] **D-03 Crash relaunch within 5 s.** While recording, `kill -SEGV $(pgrep -x Parley)`. Parley relaunches, resumes the same session (menu timer continues from the original start), shows the floating alert "Parley crashed at HH:MM:SS and resumed at HH:MM:SS — N s not recorded", the red row "Recording resumed after a crash" stays until acknowledged, and after Stop `metadata.capture.gaps` lists `{reason: "app relaunch", seconds ≈ N}`.
- [ ] **D-04 Never-delivered → heal → alarm (deterministic).** `"debug_drop_tap_frames": true` in config.json (the helper drops every tap buffer before the heartbeat — Incident B's shape). Play audio, Record. Within ~10 s: `neverDelivered`, then `tapRecoveryRung` ×4 (aggregate, aggregate, tap, tap) inside 15 s, then `tapRecoveryGivenUp` and the floating window + sound + notification + red row "The other side may not be recorded". Click Later: the row stays; after 2 min a second notification; after 3 min the window returns; every 60 s a `tapRecoveryRung rebuildTap` (slow retry). Remove the knob, restart the helper (`pkill -9`) → frames flow, the row clears, "Recording Resumed". After Stop: `metadata.capture.remote.status == "neverDelivered"` for the first helper session and the summary header says so.
- [ ] **D-05 Wedged helper.** Record, `pkill -STOP -f audio-capture-helper-xpc`. Within ~25 s (3 missed 5-s polls with a 3-s deadline each) the row "The capture helper stopped answering" appears; `pkill -CONT` → it clears within ~10 s and the recording continues.
- [ ] **D-06 Muted remote, no alarm (M-A).** See the measurement matrix below; the acceptance is no alarm for 5 min of muted remote on every app/route pair.
- [ ] **D-07 Permission denied (the #220 path).** `tccutil reset AudioCapture eu.fmasi.parley`, deny the prompt, play audio, Record. Within ~15 s: the repair window (its own, §6.3) + red row "The other side may not be recorded" (`remotePermissionDenied`); the tap delivers exact zeros, so this is NOT never-delivered and no ladder rung runs (`tapRecoveryRung` absent). Grant in System Settings → the row clears only once remote audio plays (`reportRestored`).

## P1 — tap healing
- [ ] **D-10 Incident-B reproduction (M-C).** Mic = AirPods (HFP), default output = AirPods, anchor = built-in speaker, Safari playing to the AirPods. Record; wait 15 s past mic start. If callbacks stop (`log stream` shows `PauseIO` with no `ResumeIO`): expect `tapRecoveryRung` events in order, frames back within 10 s, no alarm. Record which rung restored callbacks (the `rung` and `token` details) and `AudioDeviceStop` latency. Control: wired mic.
- [ ] **D-11 Aggregate listeners (M-E).** During D-10, `.diag.jsonl` shows `aggregateIOStopped` with `selector` `goin`/`stpd`/`diff` — note which fired.
- [ ] **D-12 TapAutoStart A/B (M-B).** `"tap_auto_start": false` vs `true`: record 3 min with nothing playing, then 30 s of playback, then 2 min idle. Read callbacks/s from `capture_provenance.remote_coverage.heartbeat_callbacks` in the transcript JSON (÷ `expected_seconds`). `sudo powermetrics --samplers cpu_power,tasks -i 10000 -n 60` during each; `pmset -g assertions` after Stop (no coreaudiod assertion). Listen for relay/amp noise. Pass for `false`: continuous callbacks, CPU delta ≤ 1 %, no artefact.
- [ ] **D-13 coreaudiod restart (M-D).** Test recording with `afplay` looping: `sudo killall coreaudiod`. Expect `serviceRestarted`, `tapRecoveryRung rebuildTap`, frames back ≤ 10 s, mic back, no alarm (or an alarm that clears).
- [ ] **D-14 Insurance rebuild dead window (M-G).** Remote muted 60 s under both autostart settings: `capture_provenance.remote_coverage.rebuilds ≤ 1`, and the dead window (gap between the last and first buffer around `restartInPlace`) < 1 s.
- [ ] **D-15 First-frame latency (M-J).** From `captureStart`/`restartInPlace` to `firstFrames` in `.diag.jsonl`, 10 samples each under both settings → p99; thresholds are set to p99 + 2 s (see X3).

## P2 — honest record
- [ ] **D-20 Coverage on a real call.** 2-chunk call: `metadata.capture.remote.status healthy`, `expected_seconds ≈ delivered_seconds`, `processing_issues: []`, `dual_stream: true`.
- [ ] **D-21 Mic-empty chunk.** Unplug a USB mic for a whole chunk: that chunk archives system-only, the merged `.m4a` keeps R = remote, L silent for that stretch; no WAV left behind unless `preserve_source_wav`.
- [ ] **D-22 Re-detect timeline.** On a recording with a mic-only chunk, re-detect the remote channel: speaker turns land at the same timestamps as before; a `<transcript>.json.bak` exists *(X2 amendment: the code names it `.json.bak`, written before the first re-detect only; was `.rediarize-backup.json`)*.
- [ ] **D-23 Summary honesty.** Re-summarise `2026-09-24/160032-….json` after stamping `capture.remote.status: neverDelivered`: the summary opens by stating the remote side was not captured.
- [ ] **D-24 Engine preflight.** Settings → Engine → Apple Speech — not yet usable (#223) → Save: "Not saved — this engine cannot transcribe on this Mac: …" and the engine stays FluidAudio.

## P3 — lifecycle
- [ ] **D-30 App SIGKILL vs helper (M-L1).** Throwaway bundle: `kill -9` the app while the helper records; `launchctl print pid/<helper>` before/after; note survival time and whether the WAV headers were sealed. Decides whether a helper-side grace is worth a follow-up.
- [ ] **D-31 LaunchAgent after a crash (M-L2)** — covered by D-02/D-03; note the relaunch delay.
- [ ] **D-32 First-sample crash cap (M-L3).** `touch ~/Library/Application\ Support/Parley/CRASH_TEST` (gotcha #52); expect restart, restart, then "Recording Failed" with the salvage message naming what was written — never a loop.
- [ ] **D-33 Sleep 2 min mid-call (M-L4).** Close the lid on a call for 2 min: on wake a new chunk starts, frames resume, `metadata.capture.gaps` has a `sleep` entry ≈ 120 s, and "Resumed" appears only after frames.
- [ ] **D-34 Disk full (M-L5).** Fill the recordings volume with `mkfile` during a recording: the `diskLow` row within one rotation, then `diskWriteFailure`; after Stop the end message names what is on disk; free space → `diskLow` clears only once ≥ 2 chunks are free.
- [ ] **D-35 Reboot mid-recording.** `sudo reboot` while recording; after login: the salvage runs, a "Recording STOPPED at HH:MM:SS" alert appears, the sentinel is gone only afterwards.
- [ ] **D-36 Crash during finalize.** Stop a long recording and `kill -SEGV` Parley while "Transcribing…" shows: on relaunch the salvage runs and says STOPPED; it must NOT start recording again (the sentinel was marked `stopping`).
- [ ] **D-37 Quit while recording.** Quit from the menu: the confirm dialog; Cancel keeps recording; Stop and Quit stops first (transcript appears), then quits.

## Measurement matrix (M-A, fills the exact-zero census)
For each of Meet/Chrome, Meet/Safari, Zoom app, Teams, FaceTime, iPhone relay × AirPods, wired headphones:
- [ ] Record; join; remote mutes 5 min; unmutes; speaks. Log at 1 Hz (from `log stream --level debug`, the helper's per-tick line): the app's `piro`, `outDevs`, tap callbacks/s, exact-zero fraction. Pass: no alarm; `remote_coverage.rebuilds ≤ 1`.
- [ ] Fill in: app / route / `piro` while muted / callbacks per s / exact-zero fraction / first-audio latency after unmute / alarm? — this table decides `remote_exact_zero_soft_alarm_seconds` (§10 M-A).
```

- [ ] **Step 2: Verify the Regression section is untouched, commit**

Run: `git diff -U0 scripts/test-checklist.md | grep -n '^@@' | tail -1` and confirm the last hunk starts above the `## Regression` line (`grep -n '^## Regression' scripts/test-checklist.md`).
```bash
git add scripts/test-checklist.md
git commit -m "docs(checklist): capture reliability device protocol; Regression section preserved"
```

---

### Task X2: Gotchas, CLAUDE.md, pipeline/parameters docs, README badge and count, app-store note

**Files:** `docs/gotchas.md` (append #71–#79), `CLAUDE.md:44, 77, 100-101, 141` (file map + test count), `docs/pipeline.md:211-226` (a "Capture provenance and metadata" subsection under Stage 9), `docs/parameters.md:12, 92-98, 100-111` (rows), `README.md:10, 204` (badge AND the "N tests across M suites" line), `docs/app-store-blockers.md:11` (a note line).

- [ ] **Step 1: Append to `docs/gotchas.md`** (numbered, never renumber):
```
71. **A track that never delivers looks exactly like one that has not started yet (Incident B, 2026-09-24):** every detector was either driven from inside the audio callback (rate drift, pad ratio) or refused to judge `lastArrival == 0`. Stamp a heartbeat at the TOP of the callback and judge "expected but silent" from the moment capture/rebuild/wake armed the monitor — `TrackLivenessMonitor`. "Expected" for the tap means "some OTHER process is running output", never "the default output device is busy". Both clocks count only time during which the gate was open.
72. **`kAudioProcessPropertyIsRunningOutput` is IO state, not content, and includes us:** a process rendering exact digital zeros reads 1 until it exits, and the helper's own capture aggregate reports itself as running output on its anchor device. Exclude `getpid()`, or the gate holds itself open forever. Fail OPEN on a read failure.
73. **The HAL can pause an aggregate's IO after a successful `AudioDeviceStart` and never resume it, with no callback:** Incident B's context was started/stopped three times by a config-change sweep on the anchor (triggered by the helper's own mic opening on AirPods HFP, not by the call app), ended in `PauseIO` count 1, and `StartAndWaitForState` failed with EAGAIN inside the HAL client. `AudioDeviceStart` had returned `noErr`. `stpd`/`goin` listeners are accelerators; the heartbeat decides; the fix is a new IO context (aggregate rebuild), then a new tap. Every rebuild carries a token so an output-device rebuild finishing mid-rung is never mistaken for the rung's result.
74. **launchd idle-exits the embedded XPC helper ~10 min after its last message, and that interruption is not a crash:** the old `crashHandlerFired` latch treated it as "handled" and was reset only in `connect()`, so every real crash after that ran no recovery. Arm crash detection per capture generation (`XPCInterruptionPolicy`); never ping the helper while idle (the ping spawns a throwaway helper).
75. **`launchctl unload` from a launchd-spawned instance SIGTERMs the process before the plist removal runs — the plist survives and `isInstalled()` lies:** remove the plist FIRST, then `bootout`. A plist on disk proves nothing; `launchctl print gui/<uid>/<label>` does. Verify and repair at every launch, and say so only when repair fails.
76. **`ProcessInfo.systemUptime` excludes sleep:** measured 7.2 h short after four days, so a sentinel from a recording that started during that window was "from before the last boot" and deleted. Compare `kern.bootsessionuuid` instead. And mark the sentinel `stopping` before Stop asks the helper: a crash during finalize must never resume a recording the user stopped.
77. **`AudioConcatenator` given a mono WAV among stereo AACs re-encodes the mono into BOTH channels and deletes it (probe-proven):** the remote voice lands in the local slot for every channel-splitting consumer, and the only lossless copy is gone. Refuse mixed sources, never delete a non-`.m4a`, verify duration before deleting, honour `preserve_source_wav`.
78. **`kAudioAggregateDeviceTapAutoStartKey = true` defers `AudioDeviceStart` until a tapped process receives its first audio, and the HAL re-arms the autostart context after every IO stop.** Gotcha #66's leading silence is this key. Under `true`, "no callbacks" is ambiguous (idle or broken); under `false` the IOProc runs continuously and delivers zeros when idle. Which one ships is decided by measurement M-B (device checklist D-12); the setting is `tap_auto_start` and is stamped into `captureStart` provenance.
79. **A helper restart starts with an empty alarm registry; the app must not read that as "all clear":** the app keeps the previous helper's alarms as stale until the new helper's first frames on that track, and never resets the 2-minute notify clock on a 5-second poll (`CaptureAlarmRegistry.apply` / `noteFirstFrames`).
```
- [ ] **Step 2: Update the other docs**

- `CLAUDE.md`: line 77 (`LivenessGapDetector.swift`) → `TrackLivenessMonitor.swift -- pure liveness core: never-delivered / stalled (measured while the gate is open) / first frames per track, from heartbeats stamped at the top of the audio callback (§4.2)`; line 44 (`LivenessWatchdogDriver`) → "…driver for `TrackLivenessMonitor` with the process-level `OutputActivityProbe` gate…"; add one line each (same `- \`path\` -- description` format, alphabetical within their target block) for `CaptureAlarm.swift`, `CaptureOptions.swift`, `XPCInterruptionPolicy.swift`, `LaunchAgentHealth.swift`, `OutputActivity.swift`, `TapRecoveryLadder.swift`, `MicHealPolicy.swift`, `TrackAccounting.swift`, `RelaunchDecision.swift`, `BootSession.swift`, `DiskSpaceCheck.swift`, `RecoveryMessages.swift`, `MonotonicWallClock.swift`, `LiveDiagnosticsLog.swift`, `EnginePreflight.swift`, `SyntheticWAV.swift`, `Deadline.swift`, `AudioCaptureHelper/XPC/OutputActivityProbe.swift`, `AudioCaptureHelper/XPC/TapHealer.swift`, `TranscriberApp/Services/CaptureAlarmWindowController.swift`, `TranscriberApp/Services/SystemEventObserver.swift`, `TranscriberApp/Views/CaptureAlarmView.swift`; line 141: the real count from the final `$PARLEY_TEST --filter TranscriberTests` run ("`Test run with N tests in M suites`").
- `README.md:10` badge and `:204` ("N tests across M suites") → the same real numbers.
- `docs/parameters.md`: Recording table line 12 → default `"core_audio_tap"`, description "…`"sck"` = ScreenCaptureKit (legacy, until #221)…"; Debugging table (92-98) gains three rows in its `key | type | default | desc` layout: `tap_auto_start` (bool, `true`, "`kAudioAggregateDeviceTapAutoStartKey`; `false` keeps the tap IOProc running continuously (gotcha #78); default decided by M-B"), `remote_exact_zero_soft_alarm_seconds` (int, unset = off, "seconds of exact-zero remote audio after which the helper says 'can't confirm'; stays off unless the M-A census shows no call app renders zeros when muted"), `debug_drop_tap_frames` (bool, `false`, "DIAGNOSTIC: the helper drops every tap buffer before the heartbeat (device item D-04); never leave on"); Capture Reliability Detectors table (100-111): the `LivenessGapDetector` row becomes `TrackLivenessMonitor.init` defaults `firstFrameThresholdSeconds 5` / `stallThresholdSeconds 3`, plus rows for `TapRecoveryLadder.backoff [0.25, 0.5, 1, 2]`, `fastWindowSeconds 15`, `heartbeatDeadlineSeconds 3`, `slowRetrySeconds 60`, `rungBudget 2`, `AlarmRealarmPolicy.notifyInterval 120`, `RelaunchDecision.resumeWindow 180`, `DiskSpaceCheck.headroomBytes 200 MB`.
- `docs/pipeline.md` under Stage 9 (211-226): a "Capture provenance and metadata" subsection listing `capture_provenance.{local,remote}_coverage` (keys from `TrackAccounting.asMetadataDictionary`), `capture_provenance.{local,remote}_status`, `events_dropped`, `metadata.capture.{local,remote,gaps}`, `metadata.processing_issues` / `processing_issue_count` / `processing_problem_chunks`, `metadata.merged_audio`, the `<session>.diag.live.jsonl` file (merged into `.diag.jsonl` at finalize), and the `session.json` `gaps`/`issues` arrays.
- `docs/app-store-blockers.md`: after the table: "Process-object properties (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningOutput`) and `kern.bootsessionuuid` are public API and add no blocker."

- [ ] **Step 3: Commit**

```bash
git add docs/gotchas.md CLAUDE.md README.md docs/parameters.md docs/pipeline.md docs/app-store-blockers.md
git commit -m "docs: gotchas #71–#79, provenance/metadata reference, capture knobs, file map, test count"
```

---

### Task X3: Measurement-driven decisions (owner + device)

- [ ] After D-12/D-15: set `CaptureOptions.tapAutoStart`'s default and `TrackLivenessMonitor.init` threshold defaults; commit with the numbers ("p99 first-frame 1.3 s under false → firstFrame 5 s, stall 3 s kept"), updating `docs/parameters.md` in the same commit.
- [ ] After M-A: `remote_exact_zero_soft_alarm_seconds` stays unset unless NO app rendered exact zeros while muted; record the table in `docs/benchmarks/2026-09-capture-reliability.md` (new).
- [ ] After D-10: reorder or drop ladder rungs per which one cleared the stall (`TapRecoveryLadder.nextRung`); if `AudioDeviceStop` blocked, move rung execution in `TapHealer` to a throwaway queue.
- [ ] After D-30: if the helper survives the app's death, open a follow-up issue for a bounded helper-side grace (never a replacement for the resume path).
- [ ] Version: MINOR; release notes lead with the transcript changes (§14) and the two default flips (§11).

---

## Self-Review Notes (author, v2)

- **Spec coverage:** §4 → C3, H1; §5 → C4, C5, H3, H4, H5; §6 → F2, H2, L2 (+ L8 `sessionWriteFailed`, L3 `crashProtectionOff`); §7.1 → C6, E1, H6; §7.2–7.3 → R0, R1, R2, L12; §7.4 → R3–R7, L6; §8.1 → C1, L1; §8.2 → C2, L3; §8.3/8.9 → C7, L7; §8.4 → H1, L2, L4; §8.5 → L4; §8.6 → C13, L5; §8.7 → C8, L8; §8.8 → C13, L9; §8.10 → H7, L10; §8.11 → C11, E2, L11; §8.12 → C10, L11; §8.13 → L2; §9 scenarios → C3 (`gateClosedIsNeverAFault…`, `stallIsMeasuredFromGateOpen…`, `aSlowGateFlap…`), H4 soft-alarm suite, D-06; §10 → X1/X3; §11 → D1, D2 (+ R5 quota placement); §12 rows all map to a task or a documented non-goal.
- **Placeholder scan:** no "TBD", no "similar to", no prose-only test; every commit step has an explicit `git add`. The only `// RED-FIRST-EXEMPT` is F1's deletion-only change to `PadRatioMonitorTests.swift`.
- **Type consistency:** `TrackLivenessMonitor.Verdict` (C3) consumed identically by C5, H1, H4, H6; `TapRecoveryLadder.Action.run(_:token:afterSeconds:)` (C4) by H4's `TapHealer` and `SystemTapSession.rebuild(rung:token:reason:)` (H3); `AlarmKind` (F2) by H2, L2, L3, L6, L7, L8; `TrackAccounting.asDetail(prefix:)` (C6) written by H6 and read by E1; `CaptureOptions` (F3) threaded through F4's `start(... options:sessionId:)` and read by H3/H4; `CaptureGap` (R0) written by L7/L10 and read by R0's assembler; `SalvageOutcome` (C9) returned by L6 and consumed by L7; `RecordingCaptureClient` grows only in F4 — every later fake member (`rotateError`, `rotateCalls`) is added by L, which owns the test file after F.
- **Review Focus:** all five pinned (C3 ×3, F2, C4 ×2, C6).
- **Tests that enshrined bugs and change red-first:** `RecordingCoordinatorTests.swift:793-796, 844` (L4), the six #220 sticky tests at 349-425 (L2), `CaptureDiagnosticsTests.clearThenProvenanceReflectsOnlyNewEvents` (E2), `PadRatioMonitorDeadTrackTests` (deleted, F1), `LivenessGapDetectorTests` (deleted with its type, H1), `SpeakerAssignmentTests` dedup cases (R3), `EchoDeduplicatorTests`/`SpeakerAssignmentVadTests` (R7), `TapPermissionGuardTests` (`.rebuildTap` gains a reason; the three deliveryGap/noBuffers tests removed, H4), `RecordingCoordinatorSalvageTests` (L6), `ConfigTests` default (D1).
- **Unit-test blind spots (helper/app targets):** `SystemTapSession` listeners and rungs, `TapHealer` timers, `OutputActivityProbe`, `AudioCaptureClient` deadlines, the alarm window, `SystemEventObserver` — all thin executors of tested cores; each has a device item in X1.

---
## Appendix A — v2 changes: every preflight-scan item → its resolution

Scan: `.superpowers/sdd/2026-09-24-capture-reliability/preflight-scan.md` (code verified at `6a9966e`). "Fixed" = the plan changed; "Spec amended" = the spec was wrong and was changed (with the reason); no item was rejected — each one was re-verified against the code before it was resolved.

### A. Pair conflicts (22)

| Item | Resolution |
|---|---|
| A12 | Fixed (X1 D-01): the idle-exit is recorded while no session exists, so it can never be in a later session's `.diag.jsonl`; D-01 now expects the unified-log line ("helper idle-exit, ignored"), no throwaway helper, and only `xpcInterruption`/`retry` in the session log. L1's code comment says the same. |
| A18 | Fixed (X1 D-02): `verifyAndRepair` returns the post-repair state, so a successful stale-path rewrite shows nothing; D-02 now checks `launchctl print` shows the new path with no row, and forces a repair failure (`chmod 500 ~/Library/LaunchAgents`) to see the row + notification. L3 raises the alarm only when `userMessage(for:)` is non-nil after repair. |
| A23 | Fixed (H1): the tapGuard timer (`AudioCaptureService.swift:452-453`) switches to `livenessWatchdog.othersRunningOutput()` in the SAME task that deletes `SystemTapSession.isOutputDeviceRunningSomewhere()` (683-694); H4 later removes the parameter altogether. No build breaks between tasks. |
| A26 | Fixed (H6 + C3/H1): expected seconds accumulate by elapsed time between gate observations (capped at 2 s), never "+1 per call"; the accelerator's synthetic `.stalled(1)` first opens the monitor's episode (`TrackLivenessMonitor.openEpisodeExternally()`, tested) so the monitor's own tick cannot report the same stall again → `gapCount` counts one episode. |
| A34 | Fixed (F3, H3, X1 D-04/D-07): a diagnostic knob `debug_drop_tap_frames` makes the helper drop tap buffers BEFORE the heartbeat, reproducing "expected but never delivered" deterministically; D-04 exercises never-delivered → ladder → give-up alarm → slow retry; the permission-denied case is a separate item D-07 (`remotePermissionDenied`, no rungs). |
| A37 | Fixed (L2/L4): `noteFirstFrames(track:now:)` is declared once, in L2 (alarm clearing); L4 extends the same method's body with the recovery confirmation and says so explicitly. |
| A51 | Fixed (X1 D-05): "within ~25 s (3 missed 5-s polls with a 3-s deadline each)". |
| A55 | Fixed (F4 + L4): `isCapturing()`, `recordLaunchRecovery(_:)`, `onBriefInterruption`, `onRestartInPlace` are added to `RecordingCaptureClient` and `FakeCaptureClient` in F4, before any consumer; `recoverAtLaunch` (L4) uses them through the protocol; L7's relaunch tests set `client.isCapturingResult`. |
| A66 | Fixed (C4, H3, H4): every ladder `.run` carries a token; `SystemTapSession.rebuild(rung:token:reason:)` echoes it in `onRebuildResult`; `TapHealer.rebuildResult(rung:token:succeeded:)` routes token 0 (output change, rate drift, permission) to `TapRecoveryLadder.noteExternalRebuild`, which counts against the episode budget without completing a rung; a stale token is ignored (tested: `anOffLadderRebuildResultDoesNotCompleteTheRung`, `aStaleRungResultAfterAServiceRestartIsIgnored`). |
| A69 | Fixed (H1, H6): both sessions expose `generationValue()` (a `stateLock`-guarded counter bumped per build); `TrackHealthSnapshot.generation` for the mic comes from `MicCaptureSession.generationValue()`. |
| A78 | Fixed: `docs/parameters.md` rows are written once, in X2; F3 owns the `Config` keys; H4 and H3 touch no docs. |
| A82 | Fixed: as A78 (X2 only). |
| A95 | Fixed: as A78 (X2 only). |
| A113 | Fixed (R0): `TranscriptAssembler.assemble(captureGaps:)` creates `metadata.capture` on demand, so gaps land even when no coverage was stamped (tested: `captureGapsLandInMetadataCaptureEvenWithoutCoverage`); R1 merges `local`/`remote` into the same dictionary. |
| A115 | Fixed (X1 D-12/D-14): the checklist reads `capture_provenance.remote_coverage.heartbeat_callbacks` / `.rebuilds` from the transcript JSON. |
| A121 | Fixed (R2/R7): R2 records `.echoFlagged(count)` from `removedCount`; R7 only switches the source of that count to `flaggedCount` and says so. |
| A122 | Fixed (R2, C12): `ThrowingEngine` is declared at FILE scope in `ChunkProcessorTests.swift`; `EnginePreflightTests` declares its own `PreflightThrowingEngine`, so neither depends on the other's stream. |
| A133 | Fixed (C12, R4): `SyntheticWAV` is a COPY (with a tone), `RecoveryFixtures.writeFakeWav` stays and gains an optional `sampleRate:`; R2/R4 tests keep using it. |
| A163 | Spec amended (§8.3, §8.8) + fixed (C7, L7): the sentinel gains `stopping`, set by `markSentinelStopping()` before `captureClient.stop()`; `RelaunchDecision` maps it to `.salvageAndStop(reason: .wasStopping)` ahead of freshness (tested in C7 and L7; device item D-36). |
| A164 | Fixed (R0, L7, L10): `CaptureGap` + `SessionState.gaps` + `ChunkProcessor.appendGap` + `TranscriptionRunner.recordCaptureGap` land in R0; L7 appends the relaunch gap, L10 the sleep gap; one store, persisted in `session.json`. |
| A166 | Fixed: as A164 → D-03 is satisfiable (L7 test asserts `gaps.map(\.reason) == ["app relaunch"]`). |
| A169 | Fixed (C13, L5, L9): a Core `withDeadline(seconds:label:)` on `ResumeOnce` (throwing, tested); L5's post-start bounded stop uses it; L9's app client reuses it. |

### B. Per-task issues (22)

| Task | Resolution |
|---|---|
| P0.1 | Fixed (F1 doc comment, L1 code comment): `helperIdleExit` is documented as living in the unified log / live log only, never in a later session's `.diag.jsonl`. |
| P0.2 | Fixed (C2): `LaunchAgentHealth.logName(for:)` logs the state `.public` and the stale path separately `.private`; `MenuView.swift:17-31` is not in C2/L3's file list (the quit path belongs to L10). |
| P0.3 | Fixed: (1) A23; (2) F1 deletes lines 224-328 (suite at 227-297 AND its `extension` at 299-328); (3) F1 adds the `RED-FIRST-EXEMPT:` marker for the deletion-only change; (4) `captureOutput` cited at 407-413 (H1). |
| P0.4 | Fixed (L2, H2): (1) the eight `AppStateTests` (241-326) and six `RecordingCoordinatorTests` (349-425) are replaced with alarm-model tests; (2) both `noteSystemAudioLost` call sites (`RecordingCoordinator.swift:257`, `TranscriberApp.swift:482`) become transient notices, and H2 raises `remoteRecoveryFailed` from the helper's SCK give-up; (3) H2 lists `ExactZeroRunMonitor.swift`, `WavFileWriter.swift`, `AudioOutputHandler.swift` and writes `silentRunThenAudioReportsResumedOnce` in full; (4) first frames clear only the `NotDelivering`/`RecoveryFailed` kinds (explicit `clearAlarm` calls, no `clearTrack`); (5) `wireCaptureCallbacks()` runs in `handleXPCCrash` before the restart, so `onAlarmsChanged`/`onFirstFrames` are wired in the rewritten test; (6) the permission window opens from `presentAlarms` on newly raised kinds only — text and code agree; (7) single owner (A37). |
| P0.5 | Fixed (L4): (1) lines 793-796 are replaced as a block (no contradictory neighbours) and line 844 of `crashAfterDecayIntervalStartsAFreshStreak` changes too; (2) A55; (3) `engineFactory` is a real init parameter used by `recoverAtLaunch` and injected by the Harness; (4) A37. |
| P1.2 | Fixed (H1/H3): `generationValue()` is the one accessor; no `var generation { get }` in the interface. |
| P1.3 | Fixed (H4): (1) `TapPermissionGuardTests.swift` carries NO exemption — the `.rebuildTap(reason:)` payload makes the file red at the parent; the removed tests are named by line; (2) the case is labelled `.rebuildTap(reason: .grant)` / `.insurance` everywhere; (3) the payload change is in Step 1/Step 3, no mid-step reversal; (4)(5) the soft-alarm suite's `feed(from:)` keeps time continuous and returns the end time, so the 299 s + 2 s test crosses 300 s and the reset test is not vacuous (400 s of zeros total, 200 s since real audio); (6) `offByDefault…` drives `permissionChecked(.authorized, evidence: .exactZeroRun)` and asserts exactly one `.rebuildTap(reason: .insurance)`; (7) `MicHealPolicy.healFailed()` (C5) fed from `MicCaptureSession.onUnavailable` raises the alarm when the heal budget is exhausted. |
| P1.4 | Consistent in v1; split into F3 (options + config), F4 (protocol), H3 (`SystemTapSession(tapAutoStart:)`). |
| P1.5 | Consistent in v1 → H5 (adds `OutputActivityProbe.restart()` and `LivenessWatchdogDriver.serviceRestarted()` explicitly). |
| P2.1 | Fixed (E1, H6, H1): (1) `provenanceCarriesTapTrackExactZeroSeconds` stays green — the legacy `system_*` keys remain a fallback when no coverage keys exist; (2) A26; (3) A69. |
| P2.2 | Fixed (R2): (1) the 1-argument `completionTitle`/`completionBody` stay and delegate; (2) A122; (3) the title uses `problemChunkCount` = distinct chunks with a content-affecting issue (`processing_problem_chunks`), not the issue count. |
| P2.3 | Fixed (R4): (1) temp dirs are created inline as the suites do today (no `makeTempDir`/`cleanup`); (2) the empty mic header is written at 16 kHz via `writeFakeWav(sampleRate:)`, the real #183 shape, so the test is red at the parent (rate mismatch at `AudioArchiver.swift:99-106`). |
| P2.4 | Fixed (R3): `TranscriptSegment(start:end:text:language: nil)`; the `run()` path (`TranscriptionRunner.transcribeStream`, 680-733) has no issue sink and logs the count — stated. |
| P2.5 | Fixed (L6): the non-empty salvage asserts `.transcriptWritten(outDir/sess.json)` with the reasoning (one chunk → no concatenation; `finalize` reads no audio), plus a new `.finalizeFailed` test on a read-only directory. |
| P2.6 | Fixed (R6): `aSkipChunkWithUnknownDurationIsRefused` catches `RediarizeError.chunkDurationUnknown("call-0_mic.wav")` specifically. |
| P2.7 | Consistent in v1; R5 writes the three tests out in full (session id, `finish_reason: length`, banner). |
| P2.8 | Consistent in v1; R7 writes the tests out in full and only switches the `.echoFlagged` count source (A121). |
| P2.9 | Fixed (D2): the label is in `displayName` ("Apple Speech — not yet usable (#223)"); nothing is hidden (`availableEngines` unchanged); `EngineID.default = .fluidAudio` per the owner. |
| P3.1 | Fixed (C7, R0, L7): every touched file is listed (`RecordingSentinel`, `ChunkRotator.onRotated`, runner seam in R0); `isCapturing()` from F4; the relaunch gap is persisted via `recordCaptureGap` (A164). |
| P3.2 | Fixed (C13, R0, R2, L5): Core `withDeadline`; `processingTheSameChunkIndexTwiceAppendsOnce` has a real body (R2); `failSetupForTesting` is an R0 seam with its own test. |
| P3.3 | Fixed (C8, R2, L8): the hook is `ChunkProcessor.onSessionWriteFailure`; the coordinator takes `freeBytesProvider` (tested with 1 MB free); `rotationVerdict(…, currentlyLow:)` has hysteresis (tested). |
| P3.4 | Fixed (R0, L9): `finalizeDelayForTesting` is an R0 seam; `xpcTimeout` landed in F1; the sentinel test is written out. |
| P3.5 | Fixed (L8, L10, R0, F4, H7): `rotateNow()` (L8) is the name everywhere; quit is testable as `prepareForQuit(confirm:)`; `CaptureGap` lives in R0 with a single store (`SessionState.gaps`); `record(_:_:_:)` became internal in F4; `arm(track:)` is labelled. |
| P3.6 | Fixed (C10, C11, E2, L11): `ContinuousClock.now.advanced(by:)` in the clock test; `merge()` counts only the incoming events; `clearThenProvenanceReflectsOnlyNewEvents` is rewritten as `clearKeepsTheOutOfRingCountersAndResetSessionZeroesThem`; `start(... sessionId:)` is in F4's interface (the chunk session id); `countersSurviveEvictionAndClear` is real code; `droppedCount` is reused for `events_dropped`. |
| P4.1 | Fixed (X1): D-01, D-02, D-03, D-04 (+ D-07), D-05, D-12, D-14 rewritten; D-24, D-36, D-37 added. |
| P4.2 | Fixed (X2): `README.md:204` updated with the badge; the parameters rows live only here. |

### C. Constraint / spec contradictions (21)

| Item | Resolution |
|---|---|
| C1 | Fixed: every commit step lists its files with `git add` (F1 through X2); Global Constraints forbid `-a`/`-A`. |
| C2 | Fixed (C2): `LaunchAgentHealth.logName(for:)`; the path is logged `.private` in its own line. |
| C3 | Fixed (D2) per the owner: label, never hide; `usableEngines` does not exist. |
| C4 | Fixed (H1, H2): the driver's system heartbeat source is the tap callback OR `AudioOutputHandler.lastSystemBufferArrivalNanos()` under SCK; the gate is the process-level probe for both; the SCK give-up raises `remoteRecoveryFailed` from the helper. |
| C5 | Spec amended (§4.2) + fixed (C3): the stall clock starts at max(last heartbeat, gate open), the never-delivered clock at max(arm, gate open); each gate-open period ≥ threshold over a silent track is one episode; a 1 Hz flap never reports (`stallIsMeasuredFromGateOpenNotFromTheLastHeartbeat`, `aSlowGateFlapOverADeadTrackReportsOncePerOpenPeriod`). The spec's "a flap can re-report an old gap once" is replaced by that precise rule. |
| C6 | Fixed (F2, L2): `CaptureAlarmRegistry.apply` tracks `helperSessionId`; a new helper's alarms mark the old ones stale (kept, shown) until `noteFirstFrames(track:)`; the rewritten coordinator test asserts the empty `h2` snapshot does NOT clear. |
| C7 | Fixed (F2): `apply` preserves `lastNotifiedAt` for a kind still active in the same episode (`pollingDoesNotResetTheNotifyClock`). |
| C8 | Fixed (H3, H4): `remoteRecoveryFailed` is raised when a rung throws (`TapHealer.onRungFailed`) or gets stuck, and cleared by the next successful rung (`onRungSucceeded`), as §6.1 says. |
| C9 | Fixed (C4, H4): A66. |
| C10 | Fixed (C4, H4): `.cleared(.gateClosed)` → `TapHealer.gateClosed()` → `ladder.gateClosed()` cancels the slow retry and un-exhausts; a reopened gate over a still-dead tap starts a fresh fast episode (`gateClosedResetsAnExhaustedLadder`). |
| C11 | Fixed (C5, H4): `MicHealPolicy.healFailed()` from `mic.onUnavailable` raises `micNotDelivering`. |
| C12 | Fixed (E1): `CaptureEventKind.contentCompromising` (the six content kinds) drives `compromised`; healed liveness events do not (`aHealedStallDoesNotCompromiseTheTrackButRateDriftDoes`). |
| C13 | Spec amended (§7.2) + fixed (R2): `stream_empty` is recorded but `affectsContent == false`; `processing_issue_count`/`processing_problem_chunks` count content-affecting issues only. |
| C14 | Spec amended (§7.3) + fixed (R2): the four titles only, with precedence no-speech > anomalies > processing problems > complete; the body names every non-zero count. "— check the record" is gone. |
| C15 | Fixed (L4): `confirmRecoveryHealthy` also requires no `micNotDelivering` alarm since the first frame (`lastMicAlarmAt`), tested. |
| C16 | Spec amended (§8.3, §8.8) + fixed: A163. |
| C17 | Fixed (C8, L8): hysteresis, tested. |
| C18 | Spec amended (§8.10) + fixed (L10): `sessionDidResignActive` (fast user switching) is dropped — the recording continues; logout/shutdown/restart all arrive as `willPowerOffNotification` → bounded stop. |
| C19 | Fixed, one by one: `realAudioResetsTheSoftWindow` and `whenEnabledItSaysCantConfirmOnceAfterTheWindow` (continuous time, H4); `offByDefault…` (exercises the insurance rebuild, H4); the archiver test (16 kHz header, R4); `aSkipChunkWithUnknownDurationIsRefused` (specific case, R6); `processingTheSameChunkIndexTwiceAppendsOnce` (real body, R2); "restart keeps the retry event" (dropped — the behaviour is in the app target; replaced by `ChunkRotatorTests.chunkStartTimesComeFromTheMonotonicClock` for L11 and E2's counter tests); `crashRestartKeepsTheStickyStateUntilFramesArrive` (passes: callbacks re-wired in the crash path, stale rule, cleared by first frames); the 793-796 block (replaced whole). |
| C20 | Fixed: no "Hmm", no "check at execution time", no pseudo-code; `merge()` counts once (E2). |
| C21 | Acknowledged: `SyntheticWAV` is a deliberate copy (Core cannot import the test target); `recoverIfNeeded` is a move (L4). No other duplication. |

### D. Order problems (8)

| Item | Resolution |
|---|---|
| D1 | Fixed (H1): the tapGuard timer's gate source changes in the same task that deletes `isOutputDeviceRunningSomewhere()`. |
| D2 | Fixed (L2, H2): L2 rewrites both `noteSystemAudioLost` call sites; H2 provides the helper-side sticky alarm. The interim between the two merges is stated in *Parallel streams*. |
| D3 | Fixed (L2/L4): A37. |
| D4 | Fixed (F4): A55. |
| D5 | Fixed (R0 before L7): A164. |
| D6 | Fixed (C13 before L5): A169. |
| D7 | Fixed (F3 merges before H4): `CaptureOptions.remoteExactZeroSoftAlarmSeconds` exists when H4 reads it. |
| D8 | Fixed (H3 → H4, same stream, serial): H3 stubs the `onUnavailable` removal with an interim `onRebuildResult` closure; H4 rewires it into `TapHealer`. |

### Owner decisions folded in (2026-09-24)

1. §11.1 → D1 (default flip for new installs; SCK relabelled "legacy, until #221"; pre-existing configs untouched, including key-less ones).
2. §11.2 → D2 (`EngineID.default = .fluidAudio`; Apple Speech LABELLED not yet usable, never hidden; preflight ships in C12/D2; the real fix is #223).
3. §11.3 → out of scope (#224); R5 still moves the quota call out of the archive `catch`.
4. CI down → every "push for CI" is the Stream gate (full suite, build, `verify-regression-tests.sh <base>`, local council); nothing is pushed.
5. Maximum parallelism → *Parallel streams* (F, C1–C13, H, E, R, L, D, X), disjoint file sets, DAG, merge order, shared docs only in X.

## Appendix B — v1 → v2 task map

See *Parallel streams → Task index (v1 → v2)*.
