# Task 1 Report — Relocate the chunk pipeline into TranscriberCore (#135 prep)

## What moved

`git mv` (history preserved):
- `TranscriberApp/Services/ChunkProcessor.swift` → `TranscriberCore/ChunkProcessor.swift`
- `TranscriberApp/Services/TranscriptionRunner.swift` → `TranscriberCore/TranscriptionRunner.swift`
- `TranscriberApp/Services/ChunkRotator.swift` → `TranscriberCore/ChunkRotator.swift`

New file:
- `TranscriberCore/ChunkRotationClient.swift` — the seam protocol (verbatim from the plan's Step 1).

Modified:
- `TranscriberApp/Services/AudioCaptureClient.swift` — added `extension AudioCaptureClient: ChunkRotationClient {}` (empty conformance; the existing `rotateChunk(outputDirectory:newBaseName:)` signature already matches).

Deleted:
- `SwiftTests/TranscriberTests/ChunkProcessorTests.swift`
- `SwiftTests/TranscriberTests/ChunkRotatorTests.swift`
(both characterized hand-copied logic; Task 3 recreates real tests against the now-Core classes.)

`Package.swift` untouched, per the plan (directory-scoped targets already pick up files by location).

## Public surface exposed

- `TranscriptionResult` — `public struct` with `public let jsonPath: URL` and an explicit `public init(jsonPath:)` (needed since a public struct's memberwise init is otherwise only internal across module boundaries; Task 3's `ChunkedSessionRecovery` will need to construct/return one).
- `TranscriptionRunner` — `public final class`, explicit `public init()` (same cross-module-init reason — the class had no explicit init before since all stored properties had defaults; that implicit init is internal-only once the class is public). Public members: `RunnerError` (public enum, `public var errorDescription`), `chunkRotator`/`chunkProcessor` (`public private(set) var`), `run(...)`, `finalize(...)`, `setupChunkedPipeline(captureClient:outputDirectory:sessionBaseName:config:)` (parameter type changed — see seam below), `startChunkRotation()`, `stopChunkRotation()`, `teardownChunkedPipeline()`, `setDiarizer(_:)`, `disableDiarization()` (called from `CLIHandler.swift`). `discoverSegments(systemAudio:micAudio:)` stays `internal` (`static`, module-private) — never called from the app, only from `run()` itself.
- `ChunkProcessor` — `public final class`, `public init(config:outputDirectory:sessionState:transcriber:diarizer:)`, `public func processChunk(_:)`, `public nonisolated func processLastChunk(_:) async`, `public func awaitAllProcessed() async`, `public func getSessionState() async -> SessionState`. Private helpers (`StateStore`, `transcribeStream`, `processChunkAsync`, `StreamResult`) stay internal/private — the app never touches them.
- `ChunkRotator` — `public final class`, `public struct FinalizedChunk` (all 4 fields `public let` + explicit `public init`, since app call sites in `MenuView.swift` construct `ChunkRotator.FinalizedChunk(...)` directly), `public init(captureClient:outputDirectory:sessionBaseName:chunkDurationMinutes:startTime:onChunkFinalized:)`, `public var currentBaseName`, `public var currentChunkInfo`, `public func recoverFromCrash(now:)`, `public func start()`, `public func stop()`. `rotate()` stays private.
- `ChunkRotationClient` — `public protocol`, `@MainActor`, one requirement (`rotateChunk`).

## The seam

`ChunkRotator`'s stored `captureClient` and `TranscriptionRunner.setupChunkedPipeline`'s `captureClient` parameter both changed type from the concrete `AudioCaptureClient` (app-only, XPC) to `any ChunkRotationClient` (Core). `AudioCaptureClient` already had the exact matching signature, so the app-side fix is the one-line empty conformance extension — no other app call sites needed changes because they all already pass an `AudioCaptureClient` instance, which now satisfies the protocol.

## Deviations from the plan text

- Removed the redundant `import TranscriberCore` from all three moved files (they're now *inside* that module, so self-importing was no longer valid/needed) — this is a mechanical consequence of the move, not a logic change.
- `TranscriptionRunner`'s private `static func discoverSegments(systemAudio:micAudio:)` internally calls `TranscriberCore.discoverSegments(...)` (module-name-qualified, to disambiguate from itself) — this line is unchanged from before the move; Swift still permits qualifying with your own module's name from inside that module, so no edit was needed there, and it still compiles and resolves to the free function in `SegmentDiscovery.swift`.
- Made `TranscriptionResult` and `TranscriptionRunner` init `public` (not explicitly listed in the plan's Interfaces bullet, but necessary — Swift does not synthesize a public default/memberwise init for public types across module boundaries, so these are compile-forced, not optional).
- `RunnerError` was made `public` (plan didn't call it out) since it's a nested type of the moved `TranscriptionRunner` and keeping it internal would have been an equally valid choice (it's never referenced by name from the app — only thrown/caught as `Error`). Made public for API completeness/symmetry with the rest of the moved surface; this has no behavioral effect.
- `setDiarizer(_:)` was made `public` even though no current app call site uses it — it's part of `TranscriptionRunner`'s existing internal API surface and Task 3/later recovery code may need it (mirrors `disableDiarization()`, which IS called from `CLIHandler`).

No other logic was touched — every function body is byte-for-byte the same as before the move (only the self-import lines were removed and access modifiers added).

## Build + test

- `swift build` → `Build complete!` (only a pre-existing, unrelated warning about an unhandled FluidAudio benchmark.md resource file).
- Full suite: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
  → **750 tests, 79 suites, all passed**, exit code 0. (The CLAUDE.md reference count of 658/66 suites is stale — this worktree's baseline already had more tests before this task started; the 2 deleted suites are reflected in this count, no new suites were added in this task.)

## Surprising / noteworthy

- The move compiled clean on the **first** `swift build` attempt after adding `public` — no iteration needed. The prior dependency audit (3 files import only Foundation/os/TranscriberCore, one XPC dependency) held up exactly as described.
- No hidden app-only dependency was found beyond the already-known `AudioCaptureClient.rotateChunk`. `SpeechAnalyzerEngine`, `FluidAudioEngine`, `FluidAudioDiarizer`, `VadSpeechMap`, `SpeakerAssignment`, `EchoDeduplicator`, `AudioArchiver`, `StorageManager`, `TranscriptAssembler`, `TranscriptWriter`, `TranscriptMerger`, `SpeakerReconciler`, `AudioConcatenator`, `SessionState`/`ProcessedChunk`, `Logger` — all were already `public`/usable from Core (most already live in Core; the engine/diarizer types were already public since `TranscriptionRunner` itself constructed them even before the move).
- `chunkRecoveryPlan(sessionBaseName:currentChunkIndex:)` / `ChunkRecoveryPlan` (used by `ChunkRotator.recoverFromCrash`) were already `public` in `TranscriberCore/SegmentNaming.swift` from a prior task — no change needed there.
