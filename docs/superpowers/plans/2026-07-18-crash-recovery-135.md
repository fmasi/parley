# Crash-Recovery Rehydration (#135) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A crash on a long (>1 chunk) recording must produce a complete, correctly-ordered, correctly-attributed transcript from the data already on disk — never silently discard the session.

**Architecture:** The chunked `finalize(sessionState:outputDirectory:config:)` already does the right thing (offset-aware merge via `TranscriptMerger` + cross-chunk identity via `SpeakerReconciler`) and is decoupled from any live pipeline — it takes a `SessionState` value. The root defect is that after an app relaunch, `recoverIfNeeded` restarts capture but never rebuilds the pipeline, so the stop path falls through to `TranscriptionRunner.run()`, which stats a session-start WAV that `AudioArchiver` deleted at the first rotation (→ "No usable audio files", session discarded) and, even when it finds files, applies no time offsets (H2) and never reconciles speakers (H3). The fix routes recovery through `finalize()` by reading `session.json` (which `ChunkProcessor` rewrites after every chunk), seeding a fresh `ChunkProcessor` with that state, re-ingesting the un-archived orphan chunk WAV(s) still on disk, and finalizing. The legacy `run()` path is kept only for genuinely single-file/CLI inputs and is separately corrected for offsets + reconciliation so the CLI multi-segment case is also right.

**Tech Stack:** Swift 5 (tools 5.9), Swift Testing (not XCTest), `@MainActor` app targets, `os.Logger`. Build: `swift build`. Test: the long `swift test --filter TranscriberTests …` invocation in CLAUDE.md.

## Global Constraints

- macOS 15.0+ deployment target; Apple Silicon. No Xcode — CommandLineTools only.
- Tests use **Swift Testing** (`@Test`, `#expect`, `Issue.record`), placed in `SwiftTests/TranscriberTests/` (NOT `Tests/` — APFS case-collision with Python `tests/`).
- Test run command (verbatim): `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
- Data model is fixed and MUST be reused, not re-invented: `SessionState` / `ProcessedChunk` (`TranscriberCore/ChunkSession.swift`), `ChunkRotator.FinalizedChunk` (`{index, systemPath, micPath, startTime}`), `RecordingSentinel` (`{startedAt, sessionName, systemAudioPath, micAudioPath, micDeviceUID, segment, chunkIndex}`).
- `session.json` lives at `<outputDirectory>/session.json`; it is rewritten in full after every completed chunk and deleted by `finalize()` on success. Chunk WAVs are `<base>-<N>.wav` / `<base>-<N>_mic.wav`; archives are `<base>-<N>.m4a` (system-WAV base name). `<base>` == `SessionState.sessionId`.
- Airgap principle holds — no new network/telemetry. Logs keep the existing privacy posture (`privacy: .private` for names/paths).
- Follow the project process: council-before-CI on the finished diff, then device-test a real long-recording crash, then decide MINOR vs PATCH (this changes what recovered transcripts say → **MINOR**).

---

## File Structure

- **Create `TranscriberCore/CrashRecoveryPlanner.swift`** — pure logic (no I/O side effects beyond `FileManager` reads): decide what recovery is possible and enumerate orphan chunk indices. One responsibility: *given the on-disk facts, say what to do.* Fully unit-testable.
- **Create `TranscriberApp/Services/ChunkedSessionRecovery.swift`** — the `@MainActor` executor that reads `session.json`, seeds a `ChunkProcessor`, re-ingests orphans, and calls `finalize()`. Takes injected `transcriber`/`diarizer` so it's testable with fakes. One responsibility: *rehydrate → finalize.*
- **Modify `TranscriberApp/TranscriberApp.swift`** — `recoverIfNeeded` Flow B: before the stat-based single-file logic, try chunked rehydration.
- **Modify `TranscriberApp/Views/MenuView.swift`** — the stop-path fallback (`stopRecording`, ~446-491): when a chunked `session.json` exists, rehydrate+finalize instead of `run()`.
- **Modify `TranscriberApp/Services/TranscriptionRunner.swift`** — `run()`: apply per-segment time offsets (H2) and reconcile speakers across segments (H3) for the genuine multi-segment/CLI case. Extract the offset math to a pure helper.
- **Modify `TranscriberCore/SegmentDiscovery.swift`** — correct the "timestamps are absolute" doc comment (now false); no behavior change.
- **Create `SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift`**, **`ChunkedSessionRecoveryTests.swift`**, **`TranscriptionRunnerRunTests.swift`** — the three test files the issue calls out (`TranscriptionRunner` currently has zero tests).

Task order builds pure logic first (testable in isolation), then the executor (testable with fakes), then the app wiring (verified by device test), then the independent CLI `run()` corrections.

---

## Task 0: Test fixtures + confirm the failing baseline

**Files:**
- Create: `SwiftTests/TranscriberTests/RecoveryFixtures.swift`
- Test: (this task produces the shared helper other tasks consume)

**Interfaces:**
- Produces: `enum RecoveryFixtures { static func writeSessionJSON(dir:URL, sessionId:String, chunkIndices:[Int]) throws; static func writeFakeWav(at:URL, seconds:Double) throws }` — helpers that write a valid `session.json` with N completed chunks and small valid WAV files, so tests can stage a mid-recording crash on disk.

- [ ] **Step 1: Write the fixtures helper**

```swift
import Foundation
@testable import TranscriberCore

enum RecoveryFixtures {
    /// Write a session.json describing `chunkIndices` already-processed chunks (each with a lone
    /// segment + a one-speaker DB), so a test can simulate a crash after those chunks completed.
    static func writeSessionJSON(dir: URL, sessionId: String, meetingStart: Date, chunkIndices: [Int]) throws {
        let chunks = chunkIndices.map { i in
            ProcessedChunk(
                index: i,
                startTime: meetingStart.addingTimeInterval(Double(i) * 60),
                audioPath: "\(sessionId)-\(i).m4a",
                segments: [.init(start: 0, end: 5, text: "chunk \(i)", speaker: "Speaker 1", source: "remote", qualityScore: 1)],
                speakerDatabase: ["Speaker 1": [Float(i), 0, 0]],
                localSpeakerDatabase: [:],
                echoSegmentsRemoved: 0,
                isDualStream: false)
        }
        let state = SessionState(sessionId: sessionId, meetingStart: meetingStart, engine: "fluidAudio",
                                 chunkDurationMinutes: 1, chunks: chunks)
        try SessionState.write(state, directory: dir)
    }

    /// Minimal valid 48kHz mono Int16 WAV of `seconds` silence (enough for header/size checks).
    static func writeFakeWav(at url: URL, seconds: Double) throws {
        let sampleRate = 48_000, channels = 1, bits = 16
        let frames = Int(seconds * Double(sampleRate))
        let dataBytes = frames * channels * bits / 8
        var h = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        h.append("RIFF".data(using: .ascii)!); h.append(le(UInt32(36 + dataBytes))); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); h.append(le(UInt32(16))); h.append(le(UInt16(1))); h.append(le(UInt16(channels)))
        h.append(le(UInt32(sampleRate))); h.append(le(UInt32(sampleRate * channels * bits / 8)))
        h.append(le(UInt16(channels * bits / 8))); h.append(le(UInt16(bits)))
        h.append("data".data(using: .ascii)!); h.append(le(UInt32(dataBytes)))
        h.append(Data(count: dataBytes))
        try h.write(to: url)
    }
}
```

- [ ] **Step 2: Verify it compiles under the test target**

Run the full test command (Task 0 adds no `@Test`, so this just confirms the fixture compiles).
Expected: build succeeds, existing suite still green.

- [ ] **Step 3: Commit**

```bash
git add SwiftTests/TranscriberTests/RecoveryFixtures.swift
git commit -m "test(recovery): shared fixtures for staging a mid-recording crash on disk"
```

---

## Task 1: `CrashRecoveryPlanner` — pure recovery decision + orphan discovery

**Files:**
- Create: `TranscriberCore/CrashRecoveryPlanner.swift`
- Test: `SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift`

**Interfaces:**
- Consumes: `SessionState.read(directory:)`.
- Produces:
  ```swift
  public enum CrashRecoveryPlanner {
      public struct OrphanChunk: Equatable { public let index: Int; public let baseName: String }
      /// Chunk WAVs present on disk whose index is NOT already a completed chunk in session.json,
      /// ascending. These are the un-archived, un-processed chunks that must be re-ingested before finalize.
      public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk]
      /// Whether a chunked session is recoverable (session.json exists with >=1 chunk, OR at least one
      /// orphan WAV exists on disk). Drives the choice between rehydrate-and-finalize vs the legacy path.
      public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct CrashRecoveryPlannerTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("crp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    @Test func orphansAreWavsNotInSessionJSON() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        // Completed chunks 0,1 archived (only .m4a on disk); chunk 2 crashed mid-write (WAV present).
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        let orphans = CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0, 1])
        #expect(orphans == [.init(index: 2, baseName: "m-2")])
    }

    @Test func multipleUnprocessedWavsAllReturnedAscending() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        // Rotation outran processing: chunks 1 and 2 rotated to WAV but never made it into session.json.
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)
        let orphans = CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0])
        #expect(orphans.map(\.index) == [1, 2])
    }

    @Test func completedChunkWavIsNotAnOrphan() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1) // stale (archive raced)
        let orphans = CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0])
        #expect(orphans.isEmpty)
    }

    @Test func recoverableWhenSessionJSONHasChunks() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0])
        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
    }

    @Test func notRecoverableWhenNothingOnDisk() throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
    }
}
```

- [ ] **Step 2: Run the tests, verify they fail**

Run the test command filtered to `CrashRecoveryPlannerTests`.
Expected: FAIL — `CrashRecoveryPlanner` undefined.

- [ ] **Step 3: Implement `CrashRecoveryPlanner`**

```swift
import Foundation

/// Pure crash-recovery reasoning: given the files on disk, decide what is recoverable.
/// No mutation, no transcription — just facts. Kept in TranscriberCore so it is unit-testable.
public enum CrashRecoveryPlanner {
    public struct OrphanChunk: Equatable {
        public let index: Int
        public let baseName: String
        public init(index: Int, baseName: String) { self.index = index; self.baseName = baseName }
    }

    /// `<sessionId>-<N>.wav` files present on disk whose N is not already a completed chunk.
    public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let prefix = "\(sessionId)-"
        var found: [OrphanChunk] = []
        for name in names {
            guard name.hasSuffix(".wav"), !name.hasSuffix("_mic.wav"), name.hasPrefix(prefix) else { continue }
            let stem = String(name.dropLast(4))                 // drop ".wav"
            let idxStr = String(stem.dropFirst(prefix.count))    // after "<id>-"
            guard let idx = Int(idxStr), !completedIndices.contains(idx) else { continue }
            found.append(OrphanChunk(index: idx, baseName: stem))
        }
        return found.sorted { $0.index < $1.index }
    }

    public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool {
        if let state = SessionState.read(directory: outputDirectory), !state.chunks.isEmpty { return true }
        let completed = Set(SessionState.read(directory: outputDirectory)?.chunks.map(\.index) ?? [])
        return !orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed).isEmpty
    }
}
```

- [ ] **Step 4: Run the tests, verify they pass**

Expected: PASS, existing suite unaffected.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/CrashRecoveryPlanner.swift SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift
git commit -m "feat(recovery): pure planner — orphan-chunk discovery + recoverability (#135)"
```

---

## Task 2: `ChunkedSessionRecovery` — rehydrate `session.json` → re-ingest orphans → `finalize()`

**Files:**
- Create: `TranscriberApp/Services/ChunkedSessionRecovery.swift`
- Test: `SwiftTests/TranscriberTests/ChunkedSessionRecoveryTests.swift`

**Interfaces:**
- Consumes: `CrashRecoveryPlanner.orphanChunks`, `SessionState.read`, `ChunkProcessor(config:outputDirectory:sessionState:transcriber:diarizer:)`, `ChunkProcessor.processLastChunk/awaitAllProcessed/getSessionState`, `TranscriptionRunner.finalize(sessionState:outputDirectory:config:)`, `ChunkRotator.FinalizedChunk`.
- Produces:
  ```swift
  @MainActor enum ChunkedSessionRecovery {
      /// Read session.json, seed a ChunkProcessor with it, transcribe the orphan chunk WAV(s) still on
      /// disk, then finalize. Returns the finalized transcript, or nil if there is nothing to recover.
      static func recover(outputDirectory: URL, sessionId: String, config: Config,
                          transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                          runner: TranscriptionRunner) async throws -> TranscriptionRunner.TranscriptionResult?
  }
  ```

- [ ] **Step 1: Write the failing test** (uses fake engines so no models/audio decoding are needed)

```swift
import Testing
import Foundation
@testable import TranscriberCore
@testable import TranscriberApp  // if TranscriberApp is a testable module; else place executor in Core

struct ChunkedSessionRecoveryTests {
    // Fake engine that returns one segment per call; fake diarizer returns a single speaker.
    // (Concrete conformances to TranscriptionEngine / DiarizationProvider — mirror existing test doubles.)

    @Test func recoversTranscriptFromSessionJSONWhenBaseWavDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two chunks already processed (their -0/-1 WAVs are ARCHIVED+DELETED — only session.json remains),
        // and an orphan chunk 2 WAV still on disk (the crash point).
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1])
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2_mic.wav"), seconds: 1)

        let runner = TranscriptionRunner()
        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: runner)

        let json = try #require(result)
        #expect(FileManager.default.fileExists(atPath: json.jsonPath.path))   // a transcript was produced…
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path)) // …and finalize() cleaned up
    }

    @Test func returnsNilWhenNothingToRecover() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner())
        #expect(result == nil)
    }
}
```

> Reuse the existing test doubles for `TranscriptionEngine`/`DiarizationProvider` if present (grep `ChunkProcessorTests.swift` for `FakeEngine`/mock engines); otherwise add minimal ones next to this test. Keep them here — do NOT add test-only conformances to production types.

- [ ] **Step 2: Run the test, verify it fails**

Expected: FAIL — `ChunkedSessionRecovery` undefined.

- [ ] **Step 3: Implement the executor**

```swift
import Foundation
import TranscriberCore

@MainActor
enum ChunkedSessionRecovery {
    static func recover(outputDirectory: URL, sessionId: String, config: Config,
                        transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                        runner: TranscriptionRunner) async throws -> TranscriptionRunner.TranscriptionResult? {
        // Base state: what was already processed. If session.json is absent, start empty so a crash during
        // the very first chunk (orphan-only, no completed chunks) is still recoverable.
        let baseState = SessionState.read(directory: outputDirectory)
            ?? SessionState(sessionId: sessionId, meetingStart: Date(), engine: config.engine.rawValue,
                            chunkDurationMinutes: config.validatedChunkDuration, chunks: [])
        let completed = Set(baseState.chunks.map(\.index))
        let orphans = CrashRecoveryPlanner.orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed)

        guard !baseState.chunks.isEmpty || !orphans.isEmpty else { return nil }

        let processor = ChunkProcessor(config: config, outputDirectory: outputDirectory,
                                       sessionState: baseState, transcriber: transcriber, diarizer: diarizer)
        for orphan in orphans {
            // Best-effort start time: the orphan WAV's creation date, else meetingStart + index*chunkDuration.
            let sysURL = outputDirectory.appendingPathComponent(orphan.baseName + ".wav")
            let start = (try? sysURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? baseState.meetingStart.addingTimeInterval(Double(orphan.index) * Double(baseState.chunkDurationMinutes) * 60)
            let micURL = outputDirectory.appendingPathComponent(orphan.baseName + "_mic.wav")
            let hasMic = FileManager.default.fileExists(atPath: micURL.path)
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index, systemPath: sysURL.path,
                micPath: hasMic ? micURL.path : sysURL.path, startTime: start))
        }
        await processor.awaitAllProcessed()
        let state = await processor.getSessionState()
        guard !state.chunks.isEmpty else { return nil }
        return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
    }
}
```

> `TranscriptionResult` is currently a private nested type on `TranscriptionRunner`; make it (and `finalize`) visible to this file. If `TranscriptionRunner` is in the same module, no change needed beyond `internal` (default). Confirm `finalize`'s access level covers this call site; widen to `internal` if it is `private`.

- [ ] **Step 4: Run the test, verify it passes**

Expected: PASS. Existing suite green.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/ChunkedSessionRecovery.swift SwiftTests/TranscriberTests/ChunkedSessionRecoveryTests.swift
git commit -m "feat(recovery): rehydrate session.json + re-ingest orphan chunks + finalize (#135 C1/C2)"
```

---

## Task 3: Wire recovery into the app — relaunch (Flow B) and stop path

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift` (`recoverIfNeeded`, Flow B, ~242-296)
- Modify: `TranscriberApp/Views/MenuView.swift` (`stopRecording` fallback branch, ~448-495)

**Interfaces:**
- Consumes: `ChunkedSessionRecovery.recover(...)`, `CrashRecoveryPlanner.isChunkedSessionRecoverable`, `TranscriptionRunner.finalize`, the app's existing `transcriptionRunner`, engine/diarizer construction used by `setupChunkedPipeline`.

> This task is app-level `@MainActor` wiring around already-tested units; it is verified by the device test in Task 6, not a new unit test (it needs real engines + real capture). Keep the edits minimal and delegate all logic to the tested functions.

- [ ] **Step 1: In `recoverIfNeeded` Flow B, prefer chunked rehydration**

Before the `sysSize`/`incrementedSegment` restart logic, when the XPC service is dead and a chunked session is recoverable, finalize it instead of trying to resume capture. Compute `outputDirectory` = `sentinel.systemAudioPath` parent, `sessionId` = `stripSegmentSuffix(sentinel.systemAudioPath)` last component (the `<base>`), build the same `transcriber`/`diarizer` the pipeline uses, then:

```swift
// Flow B: XPC is dead. If a chunked session is on disk, rehydrate + finalize it (#135) rather than
// stat the session-start WAV (which AudioArchiver deleted at the first rotation).
let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
let sessionId = stripSegmentSuffix(URL(fileURLWithPath: sentinel.systemAudioPath).lastPathComponent)
if CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: outputDir, sessionId: sessionId) {
    appState.phase = .transcribing(progress: "Recovering…")
    do {
        let (transcriber, diarizer) = try await Self.makeEngines(config: ConfigManager.shared.config)
        if let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: outputDir, sessionId: sessionId, config: ConfigManager.shared.config,
            transcriber: transcriber, diarizer: diarizer, runner: /* the app's shared runner */) {
            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
        }
    } catch { Logger.state.error("Chunked recovery failed: \(error, privacy: .public)") }
    appState.phase = .idle
    RecordingSentinel.delete()
    return
}
// …existing single-file Flow B restart logic unchanged below…
```

> `makeEngines`/the shared `TranscriptionRunner` may need to be surfaced to `recoverIfNeeded` (it is a `static` today). Thread them through the call from `TranscriberApp` init (line ~140) — pass the same `transcriptionRunner`/engine factory the UI uses. Do not construct a second engine stack if one already exists.

- [ ] **Step 2: In `stopRecording`'s fallback branch, prefer chunked rehydration**

Replace the `run()` call in the `else` (no live pipeline) branch with a rehydration attempt, falling back to `run()` only for a genuinely single-file input:

```swift
} else {
    let outputDir = /* existing computation */
    let sessionId = stripSegmentSuffix(URL(fileURLWithPath: sentinel?.systemAudioPath ?? paths.systemAudio.path).lastPathComponent)
    if CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: outputDir, sessionId: sessionId),
       let result = try await ChunkedSessionRecovery.recover(
           outputDirectory: outputDir, sessionId: sessionId, config: configManager.config,
           transcriber: /* engine */, diarizer: /* diarizer */, runner: transcriptionRunner) {
        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
    } else {
        // genuine single-file input → legacy run()
        let result = try await transcriptionRunner.run(systemAudio: systemAudio, micAudio: micAudio,
            outputDirectory: outputDir, config: configManager.config, provenance: provenance)
        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
    }
    // …existing rename/summarize wiring unchanged…
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`, no warnings in the touched files.

- [ ] **Step 4: Run the full suite**

Expected: all tests pass (no unit test added here; confirms nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat(recovery): route relaunch + stop through chunked rehydration (#135 C1/C2)"
```

---

## Task 4: `run()` — per-segment time offsets for the multi-segment/CLI case (H2)

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift` (`run`, the discovery loop ~90-145; add a pure helper)
- Modify: `TranscriberCore/SegmentDiscovery.swift` (doc comment fix)
- Test: `SwiftTests/TranscriberTests/TranscriptionRunnerRunTests.swift`

**Interfaces:**
- Produces (pure helper, on `TranscriptionRunner` or free function in Core):
  ```swift
  /// Cumulative start offset (seconds) for each segment index, given each segment's own duration.
  /// offsets[0] == 0; offsets[k] == sum(durations[0..<k]).
  static func segmentStartOffsets(durations: [Double]) -> [Double]
  ```

- [ ] **Step 1: Write the failing test for the pure helper**

```swift
import Testing
@testable import TranscriberApp

struct TranscriptionRunnerRunTests {
    @Test func cumulativeOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [60, 45, 30]) == [0, 60, 105])
    }
    @Test func singleSegmentHasNoOffset() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [42]) == [0])
    }
}
```

- [ ] **Step 2: Run, verify it fails** — `segmentStartOffsets` undefined.

- [ ] **Step 3: Implement the helper + apply it in `run()`**

```swift
static func segmentStartOffsets(durations: [Double]) -> [Double] {
    var acc = 0.0
    return durations.map { d in defer { acc += d }; return acc }
}
```

In `run()`'s loop, before appending each segment's `LabeledSegment`s, add the segment's offset to every `start`/`end`. Derive per-segment duration from that segment's transcript (max `end` of its own segments) or the WAV frame count; accumulate via `segmentStartOffsets`. Segment 0 offset is 0 (unchanged behaviour for single-file input). Quote the applied shift:

```swift
let offset = offsets[index]   // offsets = segmentStartOffsets(durations: perSegmentDurations)
let shifted = systemResult.segments.map { var s = $0; s.start += offset; s.end += offset; return s }
allSegments.append(contentsOf: shifted)
```

- [ ] **Step 4: Fix the false doc comment in `SegmentDiscovery.swift`**

Change the "timestamps are absolute, so a missing middle segment is harmless" line to state that per-segment WAVs are file-relative and the consumer (`run()`) applies cumulative offsets, so a gap only shifts later segments by the missing segment's (unknown) duration — call that limitation out explicitly.

- [ ] **Step 5: Run tests, verify pass**; full suite green.

- [ ] **Step 6: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift TranscriberCore/SegmentDiscovery.swift SwiftTests/TranscriberTests/TranscriptionRunnerRunTests.swift
git commit -m "fix(recovery): apply cumulative per-segment offsets in run() (#135 H2)"
```

---

## Task 5: `run()` — reconcile speakers across segments instead of concatenating embeddings (H3)

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift` (`run`, the DB-merge lines ~107/123 and the post-loop labeling)
- Test: `SwiftTests/TranscriberTests/TranscriptionRunnerRunTests.swift` (add cases)

**Interfaces:**
- Consumes: `SpeakerReconciler.reconcile(...)` (already used by `finalize`). Reuse it; do not hand-roll matching.

- [ ] **Step 1: Write the failing test** — two segments, each a different single speaker under key `Speaker 1`, must yield two distinct speakers (not one concatenated embedding).

```swift
@Test func crossSegmentIdentityYieldsTwoSpeakers() {
    // Build two per-segment ProcessedChunk-equivalents: seg0 {Speaker 1: embA}, seg1 {Speaker 1: embB}
    // where embA and embB are far apart. Reconciliation must map them to two distinct global speakers,
    // NOT merge embeddings under one key.
    let mapping = TranscriptionRunner.reconcileRecoverySegments(
        databases: [["Speaker 1": [1, 0, 0]], ["Speaker 1": [0, 1, 0]]], threshold: 0.65)
    // Two distinct source (segmentIndex, localLabel) pairs → two distinct global labels.
    #expect(Set(mapping.values).count == 2)
}
```

- [ ] **Step 2: Run, verify it fails** — `reconcileRecoverySegments` undefined / current code merges under one key.

- [ ] **Step 3: Implement** — replace the `{ existing, new in existing + new }` merges with per-segment namespaced keys fed to `SpeakerReconciler`, mirroring how `finalize()` reconciles chunks. Extract `reconcileRecoverySegments(databases:threshold:) -> [SegmentLocalKey: GlobalLabel]` as a pure, testable function; apply the mapping to relabel `allSegments` before writing.

- [ ] **Step 4: Run tests, verify pass**; full suite green.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift SwiftTests/TranscriberTests/TranscriptionRunnerRunTests.swift
git commit -m "fix(recovery): reconcile speakers across run() segments (#135 H3)"
```

---

## Task 6: Verification — council, CI, device test

- [ ] **Step 1: Full suite green**, output pristine. Run the full test command.
- [ ] **Step 2: `/code-review`-style council over the whole diff** before pushing (project process). Address only findings that reduce to a RED test; decline opinions with a reply.
- [ ] **Step 3: Device test** (the real acceptance): record a >3-chunk meeting; **force-quit the app mid-chunk**; relaunch. Assert:
  - a complete transcript is produced (not "No usable audio files"), covering all chunks incl. the orphan;
  - timestamps are monotonic across chunk boundaries (no interleaving) — H2;
  - two different speakers in different chunks are NOT merged into one label — H3;
  - `session.json` is deleted afterward.
  Add these to `scripts/test-checklist.md`.
- [ ] **Step 4: Version** — recovered transcripts now say something different (and correct) → **MINOR**. Bump per the release process when v0.9.0 is cut.

---

## Self-Review Notes (author)

- **Spec coverage:** C1 → Tasks 1–3; C2 → Tasks 1–3 (orphan re-ingest + finalize; no more single-last-chunk `run()` on relaunch); H2 → Task 4; H3 → Task 5; "TranscriptionRunner has no tests" → Tasks 2, 4, 5 add its first tests. "Make the sentinel track the live chunk index" from the issue is intentionally **replaced** by disk-scan orphan discovery (Task 1) — it needs no per-rotation sentinel writes and is robust to a stale `chunkIndex`; noted as a deliberate divergence for the reviewer.
- **Open detail to confirm during Task 2/3:** the access level of `TranscriptionRunner.finalize` and `TranscriptionResult` (widen `private`→`internal` if needed); whether `TranscriberApp` is a testable module or the executor should live in Core. If the latter, move `ChunkedSessionRecovery` to `TranscriberCore` and inject `finalize` via a closure to avoid an app→core inversion.
- **Risk:** orphan `startTime` is best-effort (file creation date). If that proves inaccurate on device, record per-chunk start in `session.json` at rotation instead — but that's only needed if the device test shows drift.
