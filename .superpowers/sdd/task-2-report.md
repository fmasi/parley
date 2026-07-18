# Task 2 Report — CrashRecoveryPlanner (pure orphan discovery + recoverability)

Plan: `docs/superpowers/plans/2026-07-18-crash-recovery-135.md`, Task 2.

## Files

- Created `SwiftTests/TranscriberTests/RecoveryFixtures.swift` — shared fixtures
  (`writeSessionJSON`, `writeFakeWav`), copied verbatim from the plan.
- Created `SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift` — the 5 exact
  tests specified in the task brief, each in its own temp dir created via
  `FileManager.default.temporaryDirectory.appendingPathComponent(...)` and cleaned up
  with `defer { try? FileManager.default.removeItem(at: dir) }`.
- Created `TranscriberCore/CrashRecoveryPlanner.swift` — `CrashRecoveryPlanner` enum
  with `OrphanChunk`, `orphanChunks(outputDirectory:sessionId:completedIndices:)`, and
  `isChunkedSessionRecoverable(outputDirectory:sessionId:)`, copied verbatim from the
  plan's Step 4 code block.

No deviation from the plan's code was needed — `SessionState`/`ProcessedChunk`
initializer signatures in `TranscriberCore/ChunkSession.swift` matched exactly what
`RecoveryFixtures.writeSessionJSON` assumes (`ProcessedChunk(index:startTime:audioPath:
segments:speakerDatabase:localSpeakerDatabase:echoSegmentsRemoved:isDualStream:)`,
`ProcessedChunk.Segment(start:end:text:speaker:source:qualityScore:)`,
`SessionState(sessionId:meetingStart:engine:chunkDurationMinutes:chunks:)`,
`SessionState.write(_:directory:)`).

## TDD sequence (verified)

1. Wrote `RecoveryFixtures.swift` + `CrashRecoveryPlannerTests.swift` first, with no
   `CrashRecoveryPlanner.swift` yet.
2. Ran the filtered suite — confirmed RED. Compile failure:
   ```
   CrashRecoveryPlannerTests.swift:21:13: error: cannot find 'CrashRecoveryPlanner' in scope
   ```
   (repeated at each of the 6 call sites across the 5 tests; one cascading `'Any' cannot
   be constructed` from the `.init(...)` literal losing its target type, and one cascading
   key-path inference error — both downstream of the same missing-symbol root cause, not
   independent defects).
3. Implemented `TranscriberCore/CrashRecoveryPlanner.swift` verbatim from the plan.
4. `swift build` → `Build complete!` (one pre-existing unrelated warning about an
   unhandled FluidAudio checkout resource file, not from this change).
5. Ran the filtered suite again — GREEN:
   ```
   Suite CrashRecoveryPlannerTests passed after 0.003 seconds.
   Test run with 5 tests in 1 suite passed after 0.003 seconds.
   ```
   All 5: `orphansAreWavsNotInSessionJSON`, `multipleUnprocessedWavsAllReturnedAscending`,
   `completedChunkWavIsNotAnOrphan`, `recoverableWhenSessionJSONHasChunks`,
   `notRecoverableWhenNothingOnDisk`.
6. Ran the FULL suite (`--filter TranscriberTests`) — GREEN:
   ```
   Test run with 755 tests in 80 suites passed after 7.114 seconds.
   ```
   Task 1's baseline was 750 tests (per `.superpowers/sdd/progress.md`); +5 for this
   task's new suite, 0 regressions, 0 other suites changed.

## Commit

```
git add -A
git commit -m "feat(recovery): pure planner — orphan discovery + recoverability (#135)"
```

## Concerns

None. Pure `FileManager`-only logic, no app-side wiring in this task (that's Task 4).
`orphanChunks` correctly excludes `_mic.wav` files (via the `!name.hasSuffix("_mic.wav")`
guard before the general `.wav` suffix check) so a chunk's mic-stream WAV is never
double-counted as a second orphan for the same index — not directly exercised by the 5
required tests but implicit in the fixture set's naming convention and worth flagging for
Task 3, which will need to re-ingest both the system and mic WAV per orphan.
