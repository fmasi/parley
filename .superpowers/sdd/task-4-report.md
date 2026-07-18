# Task 4 Report — Wire recovery into the app (relaunch Flow B + stop path)

Plan: `docs/superpowers/plans/2026-07-18-crash-recovery-135.md`, Task 4.

## What was wired

### 1. Engine/diarizer factory reuse (the investigation the plan required)

`TranscriptionRunner.setupChunkedPipeline` built the transcriber + diarizer inline:
```swift
let engineID = config.engine
if transcriber == nil || lastEngineID != engineID {
    transcriber = try createEngine(for: engineID, config: config)
    lastEngineID = engineID
}
applyDiarizerConfig(config)
```
`createEngine(for:config:)` and `diarizer`/`applyDiarizerConfig` are all `private`. Rather than
inventing a second construction path (forbidden by the task), I factored this exact block into
one new `public` method on `TranscriptionRunner`:

```swift
public func prepareEngine(config: Config) throws
    -> (transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?)
```

`setupChunkedPipeline` now calls `prepareEngine(config:)` itself (its body shrank to that one
call + the `SessionState`/`ChunkProcessor`/`ChunkRotator` construction) — so there is exactly one
place the engine/diarizer are ever chosen from `config`, and both the live pipeline and recovery
go through it. This mutates the runner's cached `transcriber`/`lastEngineID`/`diarizer` fields
(same fields `setupChunkedPipeline` mutated before), so calling it from recovery also warms the
engine cache for a subsequent live recording — a bonus, not a side effect I had to guard against.

This is a behavior-neutral extraction: `setupChunkedPipeline`'s observable behavior is identical
(same calls, same order), confirmed by the full suite staying green.

### 2. `recoverIfNeeded` Flow B (`TranscriberApp/TranscriberApp.swift`)

- `recoverIfNeeded` gained a third parameter, `transcriptionRunner: TranscriptionRunner` — threaded
  from the one call site in `init()` (the same `transcriptionRunner` instance the UI uses; no
  second runner constructed).
- Inserted a new branch between the Flow A check and the existing stat-based Flow B check:
  ```swift
  let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
  let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
  if CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: outputDir, sessionId: sessionId) {
      appState.phase = .transcribing(progress: "Recovering…")
      do {
          let (transcriber, diarizer) = try transcriptionRunner.prepareEngine(config: config)
          if let result = try await ChunkedSessionRecovery.recover(...) {
              appState.lastJsonPath = result.jsonPath.path
              appState.lastTranscriptPath = result.jsonPath.path
          }
          RecordingSentinel.delete()
          appState.phase = .idle
      } catch {
          appState.criticalError = "..."
          RecordingSentinel.delete()
          appState.phase = .idle
          CriticalAlertController.shared.show(...)
      }
      return
  }
  // Flow B (legacy, non-chunked/single-file): unchanged stat-based check below
  ```
- `sessionId`/`outputDir` computed exactly as specified: `stripSegmentSuffix` of the sentinel's
  `systemAudioPath` (strips any `-N` segment suffix, giving `SessionState.sessionId`), and that
  path's parent directory.
- The existing stat-based single-file logic (the `sysSize > 44` check and its restart-recording
  branch) is untouched and only runs when `isChunkedSessionRecoverable` is `false` — i.e. for a
  genuine single-file/CLI-produced recording with no `session.json` and no orphan chunk WAV.

### 3. `stopRecording` fallback (`TranscriberApp/Views/MenuView.swift`)

The `else` branch (no live `chunkRotator`/`chunkProcessor` — the case after a Flow A relaunch
re-attach, since Flow A never calls `setupChunkedPipeline` in the new process) now:
- Computes `sessionOutputDir`/`sessionId` the same way (from `sentinel.systemAudioPath` via
  `stripSegmentSuffix`, falling back to `paths.systemAudio` when there's no sentinel — mirrors the
  existing pattern already used one line below for the legacy path).
- If `CrashRecoveryPlanner.isChunkedSessionRecoverable`, calls `transcriptionRunner.prepareEngine`
  then `ChunkedSessionRecovery.recover(...)` and takes its optional `TranscriptionResult?`.
- Otherwise runs the **unchanged** legacy single-file `systemAudio`/`micAudio` derivation +
  `transcriptionRunner.run(...)` call (byte-for-byte the old code, just moved into the `else` of
  the new `if`).
- Both paths feed a single `let result: TranscriptionResult?`; the rename/summarize/notification
  wiring after it is unchanged and runs once, guarded by `if let result` (the nil case — recovery
  raced to find nothing — logs and goes idle without a bogus rename dialog).
- This whole thing sits inside `stopRecording`'s existing outer `do { ... } catch { ... }`, so a
  thrown recovery error is caught by the existing catch block (which checks
  `transcriptionRunner.chunkProcessor != nil` — false here, since this is the no-live-pipeline
  branch — so it falls to the `else` teardown + `errorMessage` + failure notification, exactly the
  existing behavior for any other `stopRecording` failure). No new catch was needed here because
  one already wrapped this code; `recoverIfNeeded` in `TranscriberApp.swift` needed its own new
  `do/catch` because it sits outside any existing one.

## Control-flow subtlety worth flagging

`ChunkedSessionRecovery.recover` returns `nil` when there's truly nothing to salvage
(`baseState.chunks.isEmpty && orphans.isEmpty`, or the seeded `ChunkProcessor` ends up with zero
chunks after ingesting orphans). Since both call sites gate on `isChunkedSessionRecoverable` first,
that guard's own preconditions (`!state.chunks.isEmpty || orphans not empty`) should make a `nil`
return here rare/race-only — but both call sites still handle it defensively (log + go idle,
no crash, no bogus UI) rather than assuming it can't happen.

## Build + test results

- `swift build`: clean, `Build complete!`, no errors or warnings in the three touched files.
- Full suite: `swift test --filter TranscriberTests` with the full flag set from Global
  Constraints — **763 tests passed, 0 failures** (same count as the Task 3 baseline; this task adds
  no new unit-testable surface per the plan — it's `@MainActor` app wiring verified by Task 7's
  device test).

## Concerns for the reviewer

- No new automated test covers this wiring directly (by design, per the task brief). The two new
  branches (`recoverIfNeeded` chunked path, `stopRecording` chunked fallback) are exercised only by
  Task 7's device test (force-quit mid-chunk, relaunch; and stop-after-relaunch-reattach).
- `prepareEngine`'s side effect on the runner's cached engine/diarizer state is intentional reuse,
  not accidental sharing — flagging in case a reviewer wants it called out explicitly.
