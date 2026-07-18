# Task 3 Report — ChunkedSessionRecovery (rehydrate → re-ingest orphans → finalize)

Plan: `docs/superpowers/plans/2026-07-18-crash-recovery-135.md`, Task 3.

## Signature verification (before writing code)

Checked every referenced signature against the real types:

- `ChunkProcessor.init(config:outputDirectory:sessionState:transcriber:diarizer:)` —
  matches (`TranscriberCore/ChunkProcessor.swift:42`).
- `ChunkProcessor.processLastChunk(_:)`, `.awaitAllProcessed()`, `.getSessionState()` —
  all `public`, match.
- `ChunkRotator.FinalizedChunk(index:systemPath:micPath:startTime:)` — matches.
- `config.engine.rawValue` (`EngineID: String`) and `config.validatedChunkDuration`
  (`Int`, clamped ≥10) — both match `SessionState.engine: String` /
  `chunkDurationMinutes: Int`.
- `SessionState.read(directory:)`, `SessionState.init(sessionId:meetingStart:engine:
  chunkDurationMinutes:chunks:)` — match.
- `CrashRecoveryPlanner.orphanChunks(outputDirectory:sessionId:completedIndices:)` →
  `[OrphanChunk]` with `.index`/`.baseName` — matches (Task 2, already landed).
- `Config.default` — exists as a fully-populated static value; used it for `config:` in
  tests instead of hand-building a `Config`.
- **One discrepancy found:** the plan's signature returns
  `TranscriptionRunner.TranscriptionResult?`, but `TranscriptionResult` is a **top-level**
  struct in `TranscriberCore` (`TranscriptionRunner.swift:4`), not nested inside
  `TranscriptionRunner` — there is no typealias bridging the two. `TranscriptionRunner.
  TranscriptionResult` does not compile. Fixed by using the correct top-level name
  `TranscriptionResult` as the return type; no other change. This is a scoping/naming fix,
  not a behavior change — `TranscriptionRunner.finalize(...)` already returns
  `TranscriptionResult` and the deliverable's body is otherwise verbatim from the plan.

Everything else in the plan's Deliverable A code block was implemented **verbatim**.

## Files

- Created `TranscriberCore/ChunkedSessionRecovery.swift` — `ChunkedSessionRecovery.recover`,
  as specified (with the `TranscriptionResult` return-type fix above).
- Created `SwiftTests/TranscriberTests/ChunkedSessionRecoveryTests.swift` — the two
  specified tests, plus `FakeEngine`/`FakeDiarizer` test doubles (none existed anywhere in
  `SwiftTests` — confirmed via `grep -rln "TranscriptionEngine\|DiarizationProvider"
  SwiftTests` returning nothing before this task). Made the fakes internal (not `private`)
  so `ChunkProcessorTests` could reuse them instead of duplicating.
- Created `SwiftTests/TranscriberTests/ChunkRotatorTests.swift` — replaces the deleted
  characterization suite. Drives the real `ChunkRotator` via a `FakeChunkRotationClient`:
  `currentBaseName`/`currentChunkInfo` initial state, and `recoverFromCrash(now:)` index
  math (single and repeated recovery). The timer-driven `rotate()` path is private and
  scheduled off `Timer`, so it isn't exercised — only the synchronously-callable surface is.
- Created `SwiftTests/TranscriberTests/ChunkProcessorTests.swift` — replaces the deleted
  characterization suite. Drives the real `ChunkProcessor` with a seeded `SessionState` +
  `FakeEngine`/`FakeDiarizer`: one chunk grows `getSessionState().chunks` by one; two
  chunks append in order.

## Does a fake engine work against real WAV decoding?

Traced `ChunkProcessor.processChunkAsync` → `transcribeStream`: the only real audio
*decoding* is (a) `WavFileWriter.repairHeader` (header patch, no decode) and (b)
`AudioArchiver.archive`/`archiveSystemOnly`, which opens the WAV via `AVAudioFile(forReading:)`
purely to re-encode it to AAC — this works fine on `RecoveryFixtures.writeFakeWav`'s valid
44-byte-header silent PCM WAV, no ML involved. The actual ASR call
(`transcriber.transcribe(audioPath:...)`) and diarization (`diarizer.diarize(...)`) are both
fully delegated to the injected `FakeEngine`/`FakeDiarizer` — they never look at the audio
content. `VadSpeechMap.analyze` runs FluidAudio's real Silero VAD if the model happens to be
locally cached (it was, on this machine) but degrades gracefully to `nil` if not — either way
it's a parallel quality signal, not a hard dependency, and doesn't gate the test's assertions.
So: real code path, no faked assertions, and the test is not order/environment-fragile on
whether the VAD model is cached.

## TDD sequence (verified)

1. Wrote `ChunkedSessionRecoveryTests.swift` first, temporarily moved the not-yet-written
   `ChunkedSessionRecovery.swift` out of the tree, ran the filtered suite — confirmed RED:
   ```
   error: cannot find 'ChunkedSessionRecovery' in scope   (x2 call sites)
   error: cannot infer contextual base in reference to member 'default'   (cascading)
   ```
2. Restored `ChunkedSessionRecovery.swift`, ran `swift build` → `Build complete!`.
3. Ran `--filter ChunkedSessionRecoveryTests` — GREEN, 2/2:
   `recoversTranscriptFromSessionJSONWhenBaseWavDeleted`, `returnsNilWhenNothingToRecover`.
4. Wrote `ChunkRotatorTests.swift` + `ChunkProcessorTests.swift` (Step 5 of the plan — these
   drive already-implemented real classes, so there was no separate RED phase for them: the
   types they exercise already existed from Task 1/prior work; the tests themselves are the
   new artifact). Ran `--filter "ChunkRotatorTests|ChunkProcessorTests"` — GREEN, 5/5:
   `currentBaseNameStartsAtChunkZero`, `recoverFromCrashAdvancesIndexAndKeepsOrphanAtCurrent`,
   `secondRecoveryAdvancesFromTheNewIndex`, `processingOneChunkGrowsSessionStateByOne`,
   `processingTwoChunksAppendsBothInOrder`.
5. Ran the FULL suite (`--filter TranscriberTests`, full flag set) — GREEN:
   ```
   Test run with 762 tests in 83 suites passed after 3.984 seconds.
   ```
   Task 2's baseline was 755 tests; +7 for this task (2 + 3 + 2), 0 regressions.

## Commit

```
git add -A
git commit -m "feat(recovery): rehydrate session.json + re-ingest orphans + finalize, with real pipeline tests (#135 C1/C2)"
```

## Concerns

- **`ChunkedSessionRecovery.recover`'s orphan-without-mic fallback** (given verbatim by the
  plan): when an orphan has no `_mic.wav`, the code passes `micPath: sysURL.path` (same file
  as `systemPath`) rather than a path that doesn't exist. `ChunkProcessor` determines
  `hasDualStream` via `FileManager.default.fileExists(atPath: chunk.micPath)` — since that
  path is the system WAV, it *does* exist, so a system-only orphan would be misclassified as
  dual-stream: the same audio gets transcribed twice (once as "remote", once as "local"), then
  run through echo-dedup against itself. This is a plausible-but-unverified logic bug, not a
  type-signature mismatch, so it was implemented exactly as specified per the task's scope
  ("this exact code... STOP if signatures differ" — this is a behavioral concern, not a
  signature one). Deliverable B's own test sidesteps it by writing both `m-2.wav` and
  `m-2_mic.wav`, so it isn't exercised by the required tests. Flagging for the plan author /
  a follow-up: either pass a genuinely non-existent mic path in the no-mic branch, or teach
  `ChunkProcessor` to treat `micPath == systemPath` as "no mic."
- No other concerns. Full suite green, no regressions, no test-only methods added to
  production types (`FakeEngine`/`FakeDiarizer` are pure protocol conformances with no
  production-type changes).
