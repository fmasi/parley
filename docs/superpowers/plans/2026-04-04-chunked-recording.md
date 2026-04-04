# Chunked Recording & Parallel Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rotate WAV files during recording and process each chunk (transcribe + diarize + archive) in the background, so transcript is near-instant when the user stops.

**Architecture:** A timer-driven ChunkRotator dispatches writer swaps on the SCStream audio queue (zero-gap guarantee). Each finalized chunk enters a background ChunkProcessor. At end-of-recording, SpeakerReconciler matches speaker embeddings across chunks via cosine similarity, and TranscriptMerger assembles the final transcript with absolute timestamps.

**Tech Stack:** Swift, ScreenCaptureKit, FluidAudio SDK, GCD serial queues, Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-04-chunked-recording-design.md`

**Test command:**
```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

**Important context:**
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), NOT XCTest
- Test files go in `SwiftTests/TranscriberTests/`
- XPC service has separate queues for system and mic audio — this plan consolidates to a single shared queue for atomic writer swap
- `DiarizationResult.speakerDatabase` comes from FluidAudio SDK's `OfflineDiarizerManager.process()` return type
- Config uses snake_case JSON keys via `CodingKeys`
- All files in `TranscriberCore/` are `public` (shared target)

---

## File Structure

### New files
| File | Responsibility |
|------|---------------|
| `TranscriberCore/ChunkSession.swift` | `SessionState` + `ProcessedChunk` Codable models, atomic read/write |
| `TranscriberCore/SpeakerReconciler.swift` | Cosine similarity, cross-chunk speaker label reconciliation |
| `TranscriberCore/TranscriptMerger.swift` | Merge chunk results, absolute timestamps, speaker remapping |
| `TranscriberApp/Services/ChunkRotator.swift` | Timer-driven WAV rotation coordinator |
| `TranscriberApp/Services/ChunkProcessor.swift` | Background per-chunk transcribe + diarize + archive pipeline |
| `SwiftTests/TranscriberTests/ChunkSessionTests.swift` | Tests for session state persistence |
| `SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift` | Tests for cosine similarity + reconciliation |
| `SwiftTests/TranscriberTests/TranscriptMergerTests.swift` | Tests for merge + timestamp conversion |

### Modified files
| File | Changes |
|------|---------|
| `TranscriberCore/Config.swift` | Add `chunkDurationMinutes`, `chunkProcessingQos` fields |
| `TranscriberCore/DiarizationProvider.swift` | Add `DiarizationResult` type with embeddings |
| `TranscriberCore/FluidAudioDiarizer.swift` | Return `DiarizationResult` preserving `speakerDatabase` |
| `TranscriberCore/SegmentDiscovery.swift` | Update to 0-indexed chunk naming |
| `TranscriberCore/RecordingSentinel.swift` | Add `chunkIndex` field |
| `AudioCaptureProtocol/AudioCaptureProtocol.swift` | Add `rotateChunk` method |
| `AudioCaptureHelper/XPC/AudioOutputHandler.swift` | Mutable writers, `swapWriters()` method, single shared queue |
| `AudioCaptureHelper/XPC/AudioCaptureService.swift` | Implement `rotateChunk`, store audio queue reference |
| `TranscriberApp/Services/AudioCaptureClient.swift` | Add `rotateChunk()` XPC call |
| `TranscriberApp/Services/TranscriptionRunner.swift` | Rewrite for chunked pipeline |
| `SwiftTests/TranscriberTests/ConfigTests.swift` | Tests for new config fields |
| `SwiftTests/TranscriberTests/DiscoverSegmentsTests.swift` | Update for 0-indexed naming |
| `SwiftTests/TranscriberTests/RecordingSentinelTests.swift` | Tests for chunkIndex field |

---

## Task 1: Config — Add chunk parameters

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Test: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write failing tests for new config fields**

Add to `SwiftTests/TranscriberTests/ConfigTests.swift`:

```swift
@Test func chunkDurationMinutesDefault() {
    let config = Config.default
    #expect(config.chunkDurationMinutes == 30)
}

@Test func chunkDurationMinutesClampedToMinimum() {
    let config = Config(chunkDurationMinutes: 3)
    #expect(config.validatedChunkDuration == 10)
}

@Test func chunkDurationMinutesAboveMinimum() {
    let config = Config(chunkDurationMinutes: 15)
    #expect(config.validatedChunkDuration == 15)
}

@Test func chunkProcessingQosDefault() {
    let config = Config.default
    #expect(config.chunkProcessingQos == "utility")
}

@Test func chunkProcessingQosValidValues() {
    for qos in ["userInteractive", "userInitiated", "utility", "background"] {
        let config = Config(chunkProcessingQos: qos)
        #expect(config.resolvedQos != nil)
    }
}

@Test func chunkProcessingQosInvalidFallsBackToUtility() {
    let config = Config(chunkProcessingQos: "nonsense")
    #expect(config.resolvedQos == .utility)
}

@Test func chunkConfigRoundTripsJSON() throws {
    let original = Config(chunkDurationMinutes: 20, chunkProcessingQos: "background")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.chunkDurationMinutes == 20)
    #expect(decoded.chunkProcessingQos == "background")
}

@Test func chunkConfigMissingFieldsUseDefaults() throws {
    // Minimal JSON without chunk fields — should decode with defaults
    let json = """
    {
        "recording_directory": "/tmp",
        "silence_timeout_minutes": 5,
        "silence_detection_enabled": true,
        "output_format": "txt",
        "launch_on_startup": false,
        "suppress_capture_warning": false
    }
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(Config.self, from: json)
    #expect(config.chunkDurationMinutes == 30)
    #expect(config.chunkProcessingQos == "utility")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | grep -E "(FAIL|error:.*chunk|error:.*Chunk)"`
Expected: Compilation errors — `chunkDurationMinutes`, `chunkProcessingQos`, `validatedChunkDuration`, `resolvedQos` not found

- [ ] **Step 3: Add fields to Config.swift**

In `TranscriberCore/Config.swift`, add to the struct fields (after line 14):

```swift
    public var chunkDurationMinutes: Int
    public var chunkProcessingQos: String
```

Add to `Config.default` (after `audioArchiveLimitHours: 15`):

```swift
        chunkDurationMinutes: 30,
        chunkProcessingQos: "utility"
```

Add to `init(...)` parameters (after `audioArchiveLimitHours: Int = 15`):

```swift
        chunkDurationMinutes: Int = 30,
        chunkProcessingQos: String = "utility"
```

Add to `init(...)` body (after `self.audioArchiveLimitHours = audioArchiveLimitHours`):

```swift
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunkProcessingQos = chunkProcessingQos
```

Add to `CodingKeys` (after `audioArchiveLimitHours`):

```swift
        case chunkDurationMinutes = "chunk_duration_minutes"
        case chunkProcessingQos = "chunk_processing_qos"
```

Add to `init(from decoder:)` (after `audioArchiveLimitHours` line):

```swift
        chunkDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .chunkDurationMinutes) ?? 30
        chunkProcessingQos = try c.decodeIfPresent(String.self, forKey: .chunkProcessingQos) ?? "utility"
```

Add computed properties at the end of the struct (before closing brace):

```swift
    /// Chunk duration clamped to minimum of 10 minutes.
    public var validatedChunkDuration: Int {
        max(chunkDurationMinutes, 10)
    }

    /// Resolved DispatchQoS.QoSClass from config string. Returns nil for invalid values,
    /// but callers should fall back to .utility.
    public var resolvedQos: DispatchQoS.QoSClass? {
        switch chunkProcessingQos {
        case "userInteractive": return .userInteractive
        case "userInitiated": return .userInitiated
        case "utility": return .utility
        case "background": return .background
        default: return .utility
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`
Expected: All tests pass, including the new chunk config tests

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: add chunkDurationMinutes and chunkProcessingQos config fields"
```

---

## Task 2: DiarizationResult — Preserve speaker embeddings

**Files:**
- Modify: `TranscriberCore/DiarizationProvider.swift`
- Modify: `TranscriberCore/FluidAudioDiarizer.swift`
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift` (update call sites)

- [ ] **Step 1: Add DiarizationResult type**

In `TranscriberCore/DiarizationProvider.swift`, add above the protocol:

```swift
/// Result from diarization including speaker embeddings for cross-chunk reconciliation.
public struct DiarizationResult: Sendable {
    public let segments: [DiarizedSegment]
    /// Aggregated per-speaker embedding vectors (256D WeSpeaker).
    /// Key = speaker ID (e.g. "speaker_0"), value = embedding vector.
    public let speakerDatabase: [String: [Float]]

    public init(segments: [DiarizedSegment], speakerDatabase: [String: [Float]] = [:]) {
        self.segments = segments
        self.speakerDatabase = speakerDatabase
    }
}
```

Update the protocol signature:

```swift
public protocol DiarizationProvider: Sendable {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult
}
```

- [ ] **Step 2: Update FluidAudioDiarizer to return DiarizationResult**

In `TranscriberCore/FluidAudioDiarizer.swift`, change the `diarize` method return type and body. Replace the current mapping + return (lines 20-35):

```swift
    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
        let startTime = ContinuousClock.now
        Logger.transcription.info("FluidAudio diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

        let mgr = try await ensureLoaded()
        let result = try await mgr.process(audioPath)

        let segments = result.segments.map { seg in
            DiarizedSegment(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speaker: seg.speakerId,
                qualityScore: seg.qualityScore
            )
        }

        // Preserve per-speaker aggregated embeddings for cross-chunk reconciliation
        let speakerDatabase: [String: [Float]]
        if let db = result.speakerDatabase {
            speakerDatabase = db
        } else {
            speakerDatabase = [:]
        }

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info(
            "FluidAudio diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s"
        )

        return DiarizationResult(segments: segments, speakerDatabase: speakerDatabase)
    }
```

- [ ] **Step 3: Update TranscriptionRunner call sites**

In `TranscriberApp/Services/TranscriptionRunner.swift`, update the `transcribeStream` method. Change the diarizer call (around lines 246-258) from:

```swift
            let diarizedSegments = try await diarizedResult
```

to:

```swift
            let diarizationResult = try await diarizedResult
            let diarizedSegments = diarizationResult.segments
```

The rest of the method (SpeakerAssignment.assign call) remains unchanged since it already takes `[DiarizedSegment]`.

- [ ] **Step 4: Build and run tests**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`
Expected: All existing tests pass — this is a compatible change (DiarizationResult wraps existing data)

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/DiarizationProvider.swift TranscriberCore/FluidAudioDiarizer.swift TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: add DiarizationResult with speaker embeddings, update FluidAudioDiarizer"
```

---

## Task 3: ChunkSession — Session state model

**Files:**
- Create: `TranscriberCore/ChunkSession.swift`
- Create: `SwiftTests/TranscriberTests/ChunkSessionTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/ChunkSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscriberCore

@Test func processedChunkEncodesAndDecodes() throws {
    let chunk = ProcessedChunk(
        index: 0,
        startTime: Date(timeIntervalSince1970: 1712200000),
        audioPath: "meeting-0.m4a",
        segments: [
            ProcessedChunk.Segment(
                start: 0.0, end: 2.5, text: "Hello",
                speaker: "spk_0", source: "system", qualityScore: 0.87
            )
        ],
        speakerDatabase: ["spk_0": [0.1, 0.2, 0.3]]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(chunk)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProcessedChunk.self, from: data)

    #expect(decoded.index == 0)
    #expect(decoded.segments.count == 1)
    #expect(decoded.segments[0].text == "Hello")
    #expect(decoded.speakerDatabase["spk_0"]?.count == 3)
}

@Test func sessionStateAtomicWriteAndRead() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChunkSessionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let state = SessionState(
        sessionId: "test-session",
        meetingStart: Date(timeIntervalSince1970: 1712200000),
        engine: "fluidAudio",
        chunkDurationMinutes: 30,
        chunks: []
    )

    try SessionState.write(state, directory: dir)
    let loaded = SessionState.read(directory: dir)
    #expect(loaded != nil)
    #expect(loaded?.sessionId == "test-session")
    #expect(loaded?.chunks.isEmpty == true)
}

@Test func sessionStateAccumulatesChunks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChunkSessionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var state = SessionState(
        sessionId: "test",
        meetingStart: Date(timeIntervalSince1970: 1712200000),
        engine: "fluidAudio",
        chunkDurationMinutes: 30,
        chunks: []
    )

    let chunk0 = ProcessedChunk(
        index: 0,
        startTime: Date(timeIntervalSince1970: 1712200000),
        audioPath: "meeting-0.m4a",
        segments: [],
        speakerDatabase: [:]
    )
    state.chunks.append(chunk0)
    try SessionState.write(state, directory: dir)

    let chunk1 = ProcessedChunk(
        index: 1,
        startTime: Date(timeIntervalSince1970: 1712201800),
        audioPath: "meeting-1.m4a",
        segments: [],
        speakerDatabase: [:]
    )
    state.chunks.append(chunk1)
    try SessionState.write(state, directory: dir)

    let loaded = SessionState.read(directory: dir)
    #expect(loaded?.chunks.count == 2)
    #expect(loaded?.chunks[0].index == 0)
    #expect(loaded?.chunks[1].index == 1)
}

@Test func sessionStateMissingFileReturnsNil() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChunkSessionTests-nonexistent-\(UUID().uuidString)")
    let loaded = SessionState.read(directory: dir)
    #expect(loaded == nil)
}

@Test func sessionStateDeleteRemovesFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChunkSessionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let state = SessionState(
        sessionId: "delete-test",
        meetingStart: Date(),
        engine: "fluidAudio",
        chunkDurationMinutes: 30,
        chunks: []
    )
    try SessionState.write(state, directory: dir)
    #expect(SessionState.read(directory: dir) != nil)

    SessionState.delete(directory: dir)
    #expect(SessionState.read(directory: dir) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | grep -E "(error:.*SessionState|error:.*ProcessedChunk)"`
Expected: Compilation errors — types not found

- [ ] **Step 3: Implement ChunkSession.swift**

Create `TranscriberCore/ChunkSession.swift`:

```swift
import Foundation
import os

/// A single processed chunk's results, stored in session.json.
public struct ProcessedChunk: Codable {
    public struct Segment: Codable {
        public let start: Double
        public let end: Double
        public let text: String
        public let speaker: String
        public let source: String
        public let qualityScore: Float?

        public init(start: Double, end: Double, text: String, speaker: String, source: String, qualityScore: Float? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.source = source
            self.qualityScore = qualityScore
        }
    }

    public let index: Int
    public let startTime: Date
    public let audioPath: String
    public let segments: [Segment]
    public let speakerDatabase: [String: [Float]]

    public init(index: Int, startTime: Date, audioPath: String, segments: [Segment], speakerDatabase: [String: [Float]]) {
        self.index = index
        self.startTime = startTime
        self.audioPath = audioPath
        self.segments = segments
        self.speakerDatabase = speakerDatabase
    }
}

/// Session-level state persisted to session.json during recording.
/// Accumulates ProcessedChunk results as they complete.
public struct SessionState: Codable {
    public let sessionId: String
    public let meetingStart: Date
    public let engine: String
    public let chunkDurationMinutes: Int
    public var chunks: [ProcessedChunk]

    public init(sessionId: String, meetingStart: Date, engine: String, chunkDurationMinutes: Int, chunks: [ProcessedChunk]) {
        self.sessionId = sessionId
        self.meetingStart = meetingStart
        self.engine = engine
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunks = chunks
    }

    // MARK: - File I/O

    private static let fileName = "session.json"

    private static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomically write session state to disk (write to temp, rename).
    public static func write(_ state: SessionState, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = fileURL(directory: directory)
        let data = try makeEncoder().encode(state)
        let tmp = directory.appendingPathComponent("\(fileName).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        Logger.state.debug("SessionState written — \(state.chunks.count) chunks")
    }

    /// Read session state from disk. Returns nil if missing or corrupt.
    public static func read(directory: URL) -> SessionState? {
        let url = fileURL(directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? makeDecoder().decode(SessionState.self, from: data) else {
            Logger.state.warning("session.json at \(url.path, privacy: .public) is corrupt — ignoring")
            return nil
        }
        return state
    }

    /// Delete session.json. No-op if file does not exist.
    public static func delete(directory: URL) {
        let url = fileURL(directory: directory)
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/ChunkSession.swift SwiftTests/TranscriberTests/ChunkSessionTests.swift
git commit -m "feat: add SessionState and ProcessedChunk models with atomic persistence"
```

---

## Task 4: SpeakerReconciler — Cross-chunk speaker matching

**Files:**
- Create: `TranscriberCore/SpeakerReconciler.swift`
- Create: `SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscriberCore

@Test func cosineSimilarityIdenticalVectors() {
    let v = [Float](repeating: 0.5, count: 256)
    let sim = SpeakerReconciler.cosineSimilarity(v, v)
    #expect(abs(sim - 1.0) < 0.001)
}

@Test func cosineSimilarityOrthogonalVectors() {
    var a = [Float](repeating: 0, count: 256)
    var b = [Float](repeating: 0, count: 256)
    a[0] = 1.0
    b[1] = 1.0
    let sim = SpeakerReconciler.cosineSimilarity(a, b)
    #expect(abs(sim) < 0.001)
}

@Test func cosineSimilarityOppositeVectors() {
    let a: [Float] = [1.0, 0.0, 0.0]
    let b: [Float] = [-1.0, 0.0, 0.0]
    let sim = SpeakerReconciler.cosineSimilarity(a, b)
    #expect(abs(sim - (-1.0)) < 0.001)
}

@Test func reconcileSingleChunkReturnsIdentityMapping() {
    let chunks = [
        ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "m-0.m4a",
            segments: [],
            speakerDatabase: ["spk_0": [Float](repeating: 0.5, count: 256)]
        )
    ]
    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    // Single chunk: mapping should map spk_0 → spk_0 (identity)
    #expect(mapping[0]?["spk_0"] == "spk_0")
}

@Test func reconcileMatchesSpeakersAcrossChunks() {
    // Chunk 0: spk_0 and spk_1 with distinct embeddings
    var emb0_spk0 = [Float](repeating: 0, count: 256)
    emb0_spk0[0] = 1.0 // Distinct direction
    var emb0_spk1 = [Float](repeating: 0, count: 256)
    emb0_spk1[1] = 1.0

    // Chunk 1: labels swapped but same voices
    let chunks = [
        ProcessedChunk(
            index: 0, startTime: Date(), audioPath: "m-0.m4a",
            segments: [], speakerDatabase: ["spk_0": emb0_spk0, "spk_1": emb0_spk1]
        ),
        ProcessedChunk(
            index: 1, startTime: Date(), audioPath: "m-1.m4a",
            segments: [],
            speakerDatabase: ["spk_0": emb0_spk1, "spk_1": emb0_spk0] // Flipped!
        )
    ]

    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    // Chunk 1's spk_0 should map to chunk 0's spk_1, and vice versa
    #expect(mapping[1]?["spk_0"] == "spk_1")
    #expect(mapping[1]?["spk_1"] == "spk_0")
}

@Test func reconcileDetectsNewSpeaker() {
    var emb0 = [Float](repeating: 0, count: 256)
    emb0[0] = 1.0
    var embNew = [Float](repeating: 0, count: 256)
    embNew[100] = 1.0 // Orthogonal — no match

    let chunks = [
        ProcessedChunk(
            index: 0, startTime: Date(), audioPath: "m-0.m4a",
            segments: [], speakerDatabase: ["spk_0": emb0]
        ),
        ProcessedChunk(
            index: 1, startTime: Date(), audioPath: "m-1.m4a",
            segments: [], speakerDatabase: ["spk_0": emb0, "spk_1": embNew]
        )
    ]

    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    // spk_0 matches, spk_1 is new — gets next available global ID
    #expect(mapping[1]?["spk_0"] == "spk_0")
    // New speaker gets a unique global ID
    let newMapping = mapping[1]?["spk_1"]
    #expect(newMapping != nil)
    #expect(newMapping != "spk_0") // Must be distinct from existing
}

@Test func reconcileEmptyDatabaseProducesEmptyMapping() {
    let chunks = [
        ProcessedChunk(
            index: 0, startTime: Date(), audioPath: "m-0.m4a",
            segments: [], speakerDatabase: [:]
        )
    ]
    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    #expect(mapping[0]?.isEmpty == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: Compilation errors — `SpeakerReconciler` not found.

- [ ] **Step 3: Implement SpeakerReconciler**

Create `TranscriberCore/SpeakerReconciler.swift`:

```swift
import Foundation
import os

public enum SpeakerReconciler {

    /// Cosine similarity between two vectors. Returns value in [-1, 1].
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Reconcile speaker labels across chunks using cosine similarity on embeddings.
    ///
    /// Returns a mapping per chunk: `[chunkIndex: [localSpeakerID: globalSpeakerID]]`.
    /// Chunk 0 is the reference — its speakers become the initial global IDs.
    /// Subsequent chunks are matched against the reference using cosine similarity.
    /// Unmatched speakers (below threshold) get new global IDs.
    ///
    /// Reference embeddings are updated via EMA (alpha=0.9) as new chunks match.
    public static func reconcile(
        chunks: [ProcessedChunk],
        threshold: Float = 0.65
    ) -> [Int: [String: String]] {
        guard !chunks.isEmpty else { return [:] }

        // Global reference: grows as new speakers appear
        var reference: [String: [Float]] = chunks[0].speakerDatabase
        var nextSpeakerIndex = reference.count
        let emaAlpha: Float = 0.9

        var mapping: [Int: [String: String]] = [:]

        // Chunk 0: identity mapping
        var chunk0Map: [String: String] = [:]
        for key in chunks[0].speakerDatabase.keys {
            chunk0Map[key] = key
        }
        mapping[0] = chunk0Map

        // Subsequent chunks: match against reference
        for i in 1..<chunks.count {
            let chunkDB = chunks[i].speakerDatabase
            var chunkMap: [String: String] = [:]
            var usedGlobalIDs: Set<String> = []

            // Build similarity matrix and greedily assign best matches
            var pairs: [(local: String, global: String, similarity: Float)] = []
            for (localID, localEmb) in chunkDB {
                for (globalID, globalEmb) in reference {
                    let sim = cosineSimilarity(localEmb, globalEmb)
                    if sim >= threshold {
                        pairs.append((localID, globalID, sim))
                    }
                }
            }

            // Greedy assignment: highest similarity first
            pairs.sort { $0.similarity > $1.similarity }
            var assignedLocal: Set<String> = []
            for pair in pairs {
                guard !assignedLocal.contains(pair.local),
                      !usedGlobalIDs.contains(pair.global) else { continue }
                chunkMap[pair.local] = pair.global
                assignedLocal.insert(pair.local)
                usedGlobalIDs.insert(pair.global)

                // EMA update reference embedding
                if let refEmb = reference[pair.global], let localEmb = chunkDB[pair.local] {
                    reference[pair.global] = zip(refEmb, localEmb).map { old, new in
                        emaAlpha * old + (1 - emaAlpha) * new
                    }
                }

                Logger.transcription.debug(
                    "Speaker remap: chunk\(i).\(pair.local, privacy: .public) → \(pair.global, privacy: .public) (similarity: \(String(format: "%.2f", pair.similarity), privacy: .public))"
                )
            }

            // Unmatched local speakers → new global IDs
            for localID in chunkDB.keys where !assignedLocal.contains(localID) {
                let newGlobalID = "spk_\(nextSpeakerIndex)"
                nextSpeakerIndex += 1
                chunkMap[localID] = newGlobalID
                // Add to reference
                if let emb = chunkDB[localID] {
                    reference[newGlobalID] = emb
                }
                Logger.transcription.info(
                    "New speaker in chunk \(i): \(localID, privacy: .public) → \(newGlobalID, privacy: .public)"
                )
            }

            mapping[i] = chunkMap
        }

        return mapping
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/SpeakerReconciler.swift SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift
git commit -m "feat: add SpeakerReconciler with cosine similarity matching"
```

---

## Task 5: TranscriptMerger — Final transcript assembly

**Files:**
- Create: `TranscriberCore/TranscriptMerger.swift`
- Create: `SwiftTests/TranscriberTests/TranscriptMergerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/TranscriptMergerTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscriberCore

@Test func mergerSingleChunkPassthrough() {
    let meetingStart = Date(timeIntervalSince1970: 1712200000)
    let chunks = [
        ProcessedChunk(
            index: 0,
            startTime: meetingStart,
            audioPath: "m-0.m4a",
            segments: [
                .init(start: 0.0, end: 2.5, text: "Hello", speaker: "spk_0", source: "system"),
                .init(start: 3.0, end: 5.0, text: "Hi", speaker: "spk_1", source: "system")
            ],
            speakerDatabase: [:]
        )
    ]
    let mapping: [Int: [String: String]] = [0: ["spk_0": "spk_0", "spk_1": "spk_1"]]

    let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: meetingStart)

    #expect(result.segments.count == 2)
    #expect(result.segments[0].text == "Hello")
    #expect(result.segments[0].elapsed == 0.0)
    #expect(result.chunkCount == 1)
}

@Test func mergerAppliesTimestampOffsets() {
    let meetingStart = Date(timeIntervalSince1970: 1000)
    let chunk1Start = Date(timeIntervalSince1970: 2800) // 1800s later

    let chunks = [
        ProcessedChunk(
            index: 0, startTime: meetingStart, audioPath: "m-0.m4a",
            segments: [.init(start: 1.0, end: 2.0, text: "First", speaker: "spk_0", source: "system")],
            speakerDatabase: [:]
        ),
        ProcessedChunk(
            index: 1, startTime: chunk1Start, audioPath: "m-1.m4a",
            segments: [.init(start: 1.0, end: 2.0, text: "Second", speaker: "spk_0", source: "system")],
            speakerDatabase: [:]
        )
    ]
    let mapping: [Int: [String: String]] = [0: ["spk_0": "spk_0"], 1: ["spk_0": "spk_0"]]

    let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: meetingStart)

    #expect(result.segments.count == 2)
    // First segment: elapsed = 0 + 1.0 = 1.0
    #expect(result.segments[0].elapsed == 1.0)
    // Second segment: elapsed = 1800 + 1.0 = 1801.0
    #expect(result.segments[1].elapsed == 1801.0)
}

@Test func mergerRemapsSpeakerLabels() {
    let now = Date()
    let chunks = [
        ProcessedChunk(
            index: 0, startTime: now, audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 1, text: "A", speaker: "spk_0", source: "system")],
            speakerDatabase: [:]
        ),
        ProcessedChunk(
            index: 1, startTime: now.addingTimeInterval(1800), audioPath: "m-1.m4a",
            segments: [.init(start: 0, end: 1, text: "B", speaker: "spk_1", source: "system")],
            speakerDatabase: [:]
        )
    ]
    // Chunk 1's spk_1 is actually chunk 0's spk_0
    let mapping: [Int: [String: String]] = [
        0: ["spk_0": "spk_0"],
        1: ["spk_1": "spk_0"]
    ]

    let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: now)

    #expect(result.segments[1].speaker == "spk_0")
}

@Test func mergerSortsByElapsedTime() {
    let now = Date()
    let chunks = [
        ProcessedChunk(
            index: 0, startTime: now, audioPath: "m-0.m4a",
            segments: [
                .init(start: 5.0, end: 6.0, text: "Later", speaker: "spk_0", source: "system"),
                .init(start: 1.0, end: 2.0, text: "Earlier", speaker: "spk_0", source: "system")
            ],
            speakerDatabase: [:]
        )
    ]
    let mapping: [Int: [String: String]] = [0: ["spk_0": "spk_0"]]

    let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: now)

    #expect(result.segments[0].text == "Earlier")
    #expect(result.segments[1].text == "Later")
}

@Test func mergerEmptyChunksProduceEmptyResult() {
    let result = TranscriptMerger.merge(chunks: [], speakerMapping: [:], meetingStart: Date())
    #expect(result.segments.isEmpty)
    #expect(result.chunkCount == 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compilation errors — `TranscriptMerger` not found.

- [ ] **Step 3: Implement TranscriptMerger**

Create `TranscriberCore/TranscriptMerger.swift`:

```swift
import Foundation
import os

public enum TranscriptMerger {

    public struct MergedSegment {
        public let elapsed: Double
        public let timestamp: Date
        public let text: String
        public let speaker: String
        public let source: String
        public let qualityScore: Float?
    }

    public struct MergeResult {
        public let segments: [MergedSegment]
        public let meetingStart: Date
        public let chunkCount: Int
    }

    /// Merge processed chunks into a single chronological transcript.
    ///
    /// - Parameters:
    ///   - chunks: Processed chunks in order.
    ///   - speakerMapping: Per-chunk speaker ID remapping from SpeakerReconciler.
    ///   - meetingStart: Wall clock time of meeting start (for elapsed calculation).
    public static func merge(
        chunks: [ProcessedChunk],
        speakerMapping: [Int: [String: String]],
        meetingStart: Date
    ) -> MergeResult {
        var allSegments: [MergedSegment] = []

        for chunk in chunks {
            let chunkOffset = chunk.startTime.timeIntervalSince(meetingStart)
            let chunkMapping = speakerMapping[chunk.index] ?? [:]

            for seg in chunk.segments {
                let elapsed = chunkOffset + seg.start
                let timestamp = meetingStart.addingTimeInterval(elapsed)
                let globalSpeaker = chunkMapping[seg.speaker] ?? seg.speaker

                allSegments.append(MergedSegment(
                    elapsed: elapsed,
                    timestamp: timestamp,
                    text: seg.text,
                    speaker: globalSpeaker,
                    source: seg.source,
                    qualityScore: seg.qualityScore
                ))
            }
        }

        allSegments.sort { $0.elapsed < $1.elapsed }

        return MergeResult(
            segments: allSegments,
            meetingStart: meetingStart,
            chunkCount: chunks.count
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptMerger.swift SwiftTests/TranscriberTests/TranscriptMergerTests.swift
git commit -m "feat: add TranscriptMerger for cross-chunk transcript assembly"
```

---

## Task 6: SegmentDiscovery — Update to 0-indexed naming

**Files:**
- Modify: `TranscriberCore/SegmentDiscovery.swift`
- Modify: `SwiftTests/TranscriberTests/DiscoverSegmentsTests.swift`

- [ ] **Step 1: Write tests for 0-indexed naming**

Add to `SwiftTests/TranscriberTests/DiscoverSegmentsTests.swift`:

```swift
@Test func discoversZeroIndexedChunks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiscoverChunks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Create chunk files: meeting-0.wav, meeting-0_mic.wav, meeting-1.wav, meeting-1_mic.wav
    for i in 0...1 {
        let sys = dir.appendingPathComponent("meeting-\(i).wav")
        let mic = dir.appendingPathComponent("meeting-\(i)_mic.wav")
        try Data([0x00]).write(to: sys)
        try Data([0x00]).write(to: mic)
    }

    let base = dir.appendingPathComponent("meeting-0.wav")
    let baseMic = dir.appendingPathComponent("meeting-0_mic.wav")
    let segments = discoverSegments(systemAudio: base, micAudio: baseMic)

    #expect(segments.count == 2)
    #expect(segments[0].system.lastPathComponent == "meeting-0.wav")
    #expect(segments[1].system.lastPathComponent == "meeting-1.wav")
}
```

- [ ] **Step 2: Run to check current behavior**

Run the test. The current `discoverSegments` starts from segment 2 and uses a non-indexed base file. The new test expects 0-indexed behavior, so it may fail.

- [ ] **Step 3: Update SegmentDiscovery for 0-indexed chunks**

Replace the content of `TranscriberCore/SegmentDiscovery.swift`. The function must handle both legacy naming (base file without index + `-2`, `-3` suffixes from crash recovery) AND new 0-indexed naming (`-0`, `-1`, `-2` from chunked recording). Detection: if the base file has a `-0` suffix, use 0-indexed mode.

```swift
import Foundation
import os

/// Discovers multi-segment audio files from crash recovery or chunked recording.
///
/// Supports two naming conventions:
/// - **Legacy (crash recovery):** base file `meeting.wav` + segments `meeting-2.wav`, `meeting-3.wav`, ...
/// - **Chunked (0-indexed):** `meeting-0.wav`, `meeting-1.wav`, `meeting-2.wav`, ...
///
/// Detection: if the base file name ends with `-0`, 0-indexed mode is used.
///
/// - Parameters:
///   - systemAudio: URL to the first system audio file.
///   - micAudio:    URL to the first mic audio file.
/// - Returns: Array of `(system:, mic:)` tuples in order.
public func discoverSegments(
    systemAudio: URL,
    micAudio: URL
) -> [(system: URL, mic: URL)] {
    let dir = systemAudio.deletingLastPathComponent()
    let baseName = systemAudio.deletingPathExtension().lastPathComponent

    // Detect 0-indexed mode
    if baseName.hasSuffix("-0") {
        return discoverZeroIndexedSegments(dir: dir, baseName: baseName, systemAudio: systemAudio, micAudio: micAudio)
    }

    // Legacy mode: base file + -2, -3, ...
    var segments: [(system: URL, mic: URL)] = [(systemAudio, micAudio)]

    var seg = 2
    while true {
        let sysName = "\(baseName)-\(seg).wav"
        let micName = "\(baseName)-\(seg)_mic.wav"
        let sysPath = dir.appendingPathComponent(sysName)
        let micPath = dir.appendingPathComponent(micName)

        if FileManager.default.fileExists(atPath: sysPath.path) {
            segments.append((sysPath, micPath))
            seg += 1
        } else {
            break
        }
    }

    if segments.count > 1 {
        Logger.transcription.info("Discovered \(segments.count) audio segments for stitching")
    }

    return segments
}

private func discoverZeroIndexedSegments(
    dir: URL,
    baseName: String,
    systemAudio: URL,
    micAudio: URL
) -> [(system: URL, mic: URL)] {
    // Strip the "-0" suffix to get the root name
    let root = String(baseName.dropLast(2)) // Remove "-0"

    var segments: [(system: URL, mic: URL)] = []
    var index = 0

    while true {
        let sysName = "\(root)-\(index).wav"
        let micName = "\(root)-\(index)_mic.wav"
        let sysPath = dir.appendingPathComponent(sysName)
        let micPath = dir.appendingPathComponent(micName)

        if FileManager.default.fileExists(atPath: sysPath.path) {
            segments.append((sysPath, micPath))
            index += 1
        } else {
            break
        }
    }

    // If no files found at all, include the original pair
    if segments.isEmpty {
        segments.append((systemAudio, micAudio))
    }

    if segments.count > 1 {
        Logger.transcription.info("Discovered \(segments.count) chunked audio segments")
    }

    return segments
}
```

- [ ] **Step 4: Run all tests to verify they pass**

Run the full test suite. Expected: All existing and new tests pass. Legacy naming tests should still work.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/SegmentDiscovery.swift SwiftTests/TranscriberTests/DiscoverSegmentsTests.swift
git commit -m "feat: support 0-indexed chunk naming in SegmentDiscovery"
```

---

## Task 7: AudioOutputHandler — Writer swap support

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioOutputHandler.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (queue consolidation)

- [ ] **Step 1: Make writers mutable and add swap method**

In `AudioCaptureHelper/XPC/AudioOutputHandler.swift`, change writers from `let` to `var` and add a swap method:

```swift
final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private var systemWriter: WavFileWriter
    private var micWriter: WavFileWriter
    private var detectedSystemRate = false
    private let micConverter = AudioConverter()

    // Cached system format for new writers after rotation
    private var systemFormatInfo: FormatInfo?

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter
        micWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        micWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))
    }

    /// Swap writers for chunk rotation. MUST be called on the audio callback queue.
    /// Returns the old writers' paths after finalizing them.
    func swapWriters(
        newSystemWriter: WavFileWriter,
        newMicWriter: WavFileWriter
    ) -> (systemPath: String, micPath: String) {
        // Finalize current writers
        systemWriter.finalize()
        micWriter.finalize()

        let oldSystemPath = systemWriter.path
        let oldMicPath = micWriter.path

        // Configure new writers with detected formats
        if let info = systemFormatInfo {
            newSystemWriter.setSampleRate(UInt32(info.rate))
            newSystemWriter.setChannelCount(UInt16(info.channels))
        }
        newMicWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        newMicWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))

        // Atomic swap
        systemWriter = newSystemWriter
        micWriter = newMicWriter

        return (oldSystemPath, oldMicPath)
    }
```

Also update `handleSystemAudio` to cache the format info:

```swift
    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        if !detectedSystemRate {
            detectedSystemRate = true
            if let info = formatInfo(from: sampleBuffer) {
                systemFormatInfo = info // Cache for rotation
                systemWriter.setSampleRate(UInt32(info.rate))
                systemWriter.setChannelCount(UInt16(info.channels))
                Logger.audio.info("System audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
            }
        }
        // ... rest unchanged
    }
```

- [ ] **Step 2: Consolidate to single audio queue in AudioCaptureService**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`, change `configureAndStart` to use a single shared queue and store a reference to it:

Add a property:

```swift
    private var audioQueue: DispatchQueue?
```

In `configureAndStart`, replace the three separate queue creations:

```swift
        let sharedQueue = DispatchQueue(label: "audio-capture.shared")
        self.audioQueue = sharedQueue

        try captureStream.addStreamOutput(
            handler, type: .audio,
            sampleHandlerQueue: sharedQueue
        )
        try captureStream.addStreamOutput(
            handler, type: .microphone,
            sampleHandlerQueue: sharedQueue
        )
        try captureStream.addStreamOutput(
            handler, type: .screen,
            sampleHandlerQueue: sharedQueue
        )
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Compiles cleanly. Note: `WavFileWriter.path` may need to be exposed — check if it's already public. If not, add a `public let path: String` property to `WavFileWriter`.

- [ ] **Step 4: Commit**

```bash
git add AudioCaptureHelper/XPC/AudioOutputHandler.swift AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat: add writer swap support and consolidate to single audio queue"
```

---

## Task 8: XPC Protocol — Add rotateChunk method

**Files:**
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift`

- [ ] **Step 1: Add rotateChunk to the XPC protocol**

In `AudioCaptureProtocol/AudioCaptureProtocol.swift`, add to the protocol:

```swift
    /// Rotate WAV files for chunk recording. Finalizes current writers,
    /// creates new writers with the given base name, and returns old file paths.
    /// Reply: (oldSystemPath, oldMicPath, error)
    func rotateChunk(
        outputDirectory: String,
        newBaseName: String,
        reply: @escaping (String?, String?, String?) -> Void
    )
```

- [ ] **Step 2: Implement in AudioCaptureService**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`, add:

```swift
    func rotateChunk(
        outputDirectory: String,
        newBaseName: String,
        reply: @escaping (String?, String?, String?) -> Void
    ) {
        guard isCapturing, let handler = handler, let audioQueue = audioQueue else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Rotating chunk — new base: \(newBaseName, privacy: .public)")

        let newSysPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + ".wav")
        let newMicPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + "_mic.wav")

        do {
            let newSystemWriter = try WavFileWriter(path: newSysPath)
            let newMicWriter = try WavFileWriter(path: newMicPath)

            // Dispatch swap on the audio callback queue for zero-gap guarantee
            audioQueue.sync {
                let oldPaths = handler.swapWriters(
                    newSystemWriter: newSystemWriter,
                    newMicWriter: newMicWriter
                )

                self.systemPath = newSysPath
                self.micPath = newMicPath

                Logger.audio.info("Chunk rotated — old: \(oldPaths.systemPath, privacy: .public)")
                reply(oldPaths.systemPath, oldPaths.micPath, nil)
            }
        } catch {
            Logger.audio.error("Chunk rotation failed: \(error, privacy: .public)")
            reply(nil, nil, "Rotation failed: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 3: Add rotateChunk to AudioCaptureClient**

In `TranscriberApp/Services/AudioCaptureClient.swift`, add:

```swift
    func rotateChunk(
        outputDirectory: String,
        newBaseName: String
    ) async throws -> (systemPath: String, micPath: String) {
        let proxy = try getProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.rotateChunk(
                outputDirectory: outputDirectory,
                newBaseName: newBaseName
            ) { oldSys, oldMic, error in
                if let error {
                    continuation.resume(throwing: NSError(
                        domain: "AudioCapture", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: error]
                    ))
                } else if let sys = oldSys, let mic = oldMic {
                    continuation.resume(returning: (sys, mic))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AudioCapture", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Missing paths from rotation"]
                    ))
                }
            }
        }
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Compiles cleanly.

- [ ] **Step 5: Commit**

```bash
git add AudioCaptureProtocol/AudioCaptureProtocol.swift AudioCaptureHelper/XPC/AudioCaptureService.swift TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: add rotateChunk XPC method for chunk recording"
```

---

## Task 9: ChunkRotator — Timer-driven rotation coordinator

**Files:**
- Create: `TranscriberApp/Services/ChunkRotator.swift`

- [ ] **Step 1: Implement ChunkRotator**

Create `TranscriberApp/Services/ChunkRotator.swift`:

```swift
import Foundation
import os
import TranscriberCore

/// Coordinates WAV file rotation during recording.
/// Fires a timer every `chunkDurationMinutes` and calls the XPC service to rotate writers.
final class ChunkRotator {
    struct FinalizedChunk {
        let index: Int
        let systemPath: String
        let micPath: String
        let startTime: Date
    }

    private let captureClient: AudioCaptureClient
    private let outputDirectory: String
    private let sessionBaseName: String
    private let chunkDuration: TimeInterval
    private var timer: Timer?
    private var currentChunkIndex: Int = 0
    private var currentChunkStartTime: Date
    private let onChunkFinalized: (FinalizedChunk) -> Void

    init(
        captureClient: AudioCaptureClient,
        outputDirectory: String,
        sessionBaseName: String,
        chunkDurationMinutes: Int,
        startTime: Date,
        onChunkFinalized: @escaping (FinalizedChunk) -> Void
    ) {
        self.captureClient = captureClient
        self.outputDirectory = outputDirectory
        self.sessionBaseName = sessionBaseName
        self.chunkDuration = TimeInterval(chunkDurationMinutes * 60)
        self.currentChunkStartTime = startTime
        self.onChunkFinalized = onChunkFinalized
    }

    /// The base name for the current chunk's WAV files.
    var currentBaseName: String {
        "\(sessionBaseName)-\(currentChunkIndex)"
    }

    /// Start the rotation timer.
    func start() {
        Logger.audio.info("ChunkRotator started — interval: \(Int(chunkDuration))s, base: \(self.sessionBaseName, privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.rotate()
        }
    }

    /// Stop the timer. Does NOT finalize the current chunk.
    func stop() {
        timer?.invalidate()
        timer = nil
        Logger.audio.info("ChunkRotator stopped at chunk \(self.currentChunkIndex)")
    }

    /// Info about the current (in-progress) chunk for final processing.
    var currentChunkInfo: (index: Int, startTime: Date) {
        (currentChunkIndex, currentChunkStartTime)
    }

    private func rotate() {
        let finalizingIndex = currentChunkIndex
        let finalizingStartTime = currentChunkStartTime
        let nextIndex = finalizingIndex + 1
        let nextBaseName = "\(sessionBaseName)-\(nextIndex)"

        Logger.audio.info("Rotating chunk \(finalizingIndex) → \(nextIndex)")

        Task {
            do {
                let oldPaths = try await captureClient.rotateChunk(
                    outputDirectory: outputDirectory,
                    newBaseName: nextBaseName
                )

                self.currentChunkIndex = nextIndex
                self.currentChunkStartTime = Date()

                let chunk = FinalizedChunk(
                    index: finalizingIndex,
                    systemPath: oldPaths.systemPath,
                    micPath: oldPaths.micPath,
                    startTime: finalizingStartTime
                )

                Logger.audio.info("Chunk \(finalizingIndex) finalized — sys: \(oldPaths.systemPath, privacy: .public)")
                onChunkFinalized(chunk)
            } catch {
                Logger.audio.error("Chunk rotation failed: \(error, privacy: .public)")
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/ChunkRotator.swift
git commit -m "feat: add ChunkRotator for timer-driven WAV rotation"
```

---

## Task 10: ChunkProcessor — Background processing pipeline

**Files:**
- Create: `TranscriberApp/Services/ChunkProcessor.swift`

- [ ] **Step 1: Implement ChunkProcessor**

Create `TranscriberApp/Services/ChunkProcessor.swift`:

```swift
import Foundation
import os
import TranscriberCore

/// Processes finalized chunks in the background: transcribe, diarize, archive, persist.
final class ChunkProcessor {
    private let config: Config
    private let outputDirectory: URL
    private let transcriber: any TranscriptionEngine
    private let diarizer: any DiarizationProvider
    private let vadSpeechMap = VadSpeechMap()
    private let processingQueue: DispatchQueue
    private var sessionState: SessionState
    private let wavHeaderSize = 44

    init(
        config: Config,
        outputDirectory: URL,
        sessionState: SessionState,
        transcriber: any TranscriptionEngine,
        diarizer: any DiarizationProvider
    ) {
        self.config = config
        self.outputDirectory = outputDirectory
        self.sessionState = sessionState
        self.transcriber = transcriber
        self.diarizer = diarizer

        let qos: DispatchQoS = switch config.resolvedQos {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .background: .background
        default: .utility
        }
        self.processingQueue = DispatchQueue(label: "chunk-processor", qos: qos)
    }

    /// Process a finalized chunk in the background.
    func processChunk(_ chunk: ChunkRotator.FinalizedChunk) {
        processingQueue.async {
            Task {
                await self.processChunkAsync(chunk)
            }
        }
    }

    /// Process the final chunk synchronously (called at end-of-recording).
    func processLastChunk(_ chunk: ChunkRotator.FinalizedChunk) async {
        await processChunkAsync(chunk)
    }

    /// Get current session state for final merge.
    func getSessionState() -> SessionState {
        sessionState
    }

    private func processChunkAsync(_ chunk: ChunkRotator.FinalizedChunk) async {
        let startTime = ContinuousClock.now
        Logger.transcription.info("Chunk \(chunk.index) processing started (qos: \(self.config.chunkProcessingQos, privacy: .public))")

        let systemURL = URL(fileURLWithPath: chunk.systemPath)
        let micURL = URL(fileURLWithPath: chunk.micPath)
        var segments: [ProcessedChunk.Segment] = []

        do {
            // Transcribe system audio
            let sysSegments = try await transcribeIfNotEmpty(
                audioPath: systemURL, source: "system", audioSource: .system
            )
            segments.append(contentsOf: sysSegments)

            // Transcribe mic audio
            if FileManager.default.fileExists(atPath: chunk.micPath) {
                let micSegments = try await transcribeIfNotEmpty(
                    audioPath: micURL, source: "local", audioSource: .microphone
                )
                segments.append(contentsOf: micSegments)
            }
        } catch {
            Logger.transcription.error("Chunk \(chunk.index) transcription failed: \(error, privacy: .public)")
            return
        }

        // Diarize + VAD (concurrent, on system audio)
        var speakerDatabase: [String: [Float]] = [:]
        do {
            async let diarizeResult = diarizer.diarize(audioPath: systemURL, numSpeakers: nil)
            async let vadResult = vadSpeechMap.analyze(audioPath: systemURL)

            let diarizationResult = try await diarizeResult
            let speechMap: [SpeechRegion]? = (try? await vadResult) ?? nil

            // Assign speakers
            let transcriptSegments = segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, language: nil)
            }

            let labeled = SpeakerAssignment.assign(
                transcriptSegments: transcriptSegments,
                diarizationSegments: diarizationResult.segments,
                speechMap: speechMap,
                vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5
            )

            // Update segments with speaker labels
            segments = labeled.map { lab in
                ProcessedChunk.Segment(
                    start: lab.start, end: lab.end, text: lab.text,
                    speaker: lab.speaker, source: lab.source,
                    qualityScore: lab.confidence
                )
            }

            speakerDatabase = diarizationResult.speakerDatabase

            let speakerCount = Set(labeled.map(\.speaker)).count
            let elapsed = ContinuousClock.now - startTime
            Logger.transcription.info(
                "Chunk \(chunk.index) diarization complete: \(speakerCount) speakers in \(elapsed.components.seconds)s"
            )
        } catch {
            Logger.transcription.error("Chunk \(chunk.index) diarization failed: \(error, privacy: .public)")
            // Continue without diarization — segments still have transcription
        }

        // Archive to AAC
        var archivePath = ""
        do {
            let result = try await AudioArchiver.archive(
                systemAudio: systemURL,
                micAudio: micURL,
                outputDirectory: outputDirectory,
                bitrateKbps: config.archiveBitrateKbps
            )
            archivePath = result.archivePath.lastPathComponent
            Logger.audio.info("Chunk \(chunk.index) archived: \(archivePath, privacy: .public)")
        } catch {
            Logger.files.error("Chunk \(chunk.index) archive failed, keeping WAVs: \(error, privacy: .public)")
            archivePath = systemURL.lastPathComponent
        }

        // Persist to session.json
        let processed = ProcessedChunk(
            index: chunk.index,
            startTime: chunk.startTime,
            audioPath: archivePath,
            segments: segments,
            speakerDatabase: speakerDatabase
        )
        sessionState.chunks.append(processed)

        do {
            try SessionState.write(sessionState, directory: outputDirectory)
            Logger.transcription.info("Chunk \(chunk.index) persisted to session.json")
        } catch {
            Logger.state.error("Failed to write session.json: \(error, privacy: .public)")
        }
    }

    private func transcribeIfNotEmpty(
        audioPath: URL,
        source: String,
        audioSource: AudioSourceType
    ) async throws -> [ProcessedChunk.Segment] {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        guard fileSize > wavHeaderSize else {
            Logger.transcription.info("Skipping empty \(source, privacy: .public) audio (\(fileSize) bytes)")
            return []
        }

        let transcriptSegments = try await transcriber.transcribe(
            audioPath: audioPath, language: nil, audioSource: audioSource
        )

        return transcriptSegments.map { seg in
            ProcessedChunk.Segment(
                start: seg.start, end: seg.end, text: seg.text,
                speaker: "", source: source
            )
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/ChunkProcessor.swift
git commit -m "feat: add ChunkProcessor for background per-chunk processing"
```

---

## Task 11: TranscriptionRunner — Rewrite for chunked pipeline

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

This is the most complex task. TranscriptionRunner's `run()` method currently processes all segments sequentially after recording stops. The rewrite makes it the final merge step — it receives a completed `SessionState`, runs SpeakerReconciler, TranscriptMerger, and writes the final transcript.

- [ ] **Step 1: Add a new `finalize()` method for chunked pipeline**

Add to `TranscriptionRunner`:

```swift
    /// Finalize a chunked recording session: reconcile speakers, merge chunks, write transcript.
    func finalize(
        sessionState: SessionState,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // Speaker reconciliation across chunks
        Logger.transcription.info("Reconciling speakers across \(sessionState.chunks.count) chunks (cosine threshold: 0.65)")
        let speakerMapping = SpeakerReconciler.reconcile(
            chunks: sessionState.chunks,
            threshold: 0.65
        )

        // Merge chunks into unified transcript
        let mergeResult = TranscriptMerger.merge(
            chunks: sessionState.chunks,
            speakerMapping: speakerMapping,
            meetingStart: sessionState.meetingStart
        )

        // Convert MergedSegments to LabeledSegments for existing assembler
        var allSegments = mergeResult.segments.map { seg in
            LabeledSegment(
                start: seg.elapsed,
                end: seg.elapsed + 0.1, // Will be refined below
                speaker: seg.speaker,
                text: seg.text,
                source: seg.source,
                confidence: seg.qualityScore
            )
        }

        // Reconstruct proper end times from chunk data
        for chunk in sessionState.chunks {
            let chunkOffset = chunk.startTime.timeIntervalSince(sessionState.meetingStart)
            let chunkMapping = speakerMapping[chunk.index] ?? [:]
            for seg in chunk.segments {
                let elapsed = chunkOffset + seg.start
                let elapsedEnd = chunkOffset + seg.end
                if let idx = allSegments.firstIndex(where: { abs($0.start - elapsed) < 0.001 }) {
                    allSegments[idx].end = elapsedEnd
                }
            }
        }

        // Apply dual-stream source tagging
        let isDualStream = allSegments.contains { $0.source == "local" }
        if isDualStream {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // Collect audio paths from chunks
        let audioPaths = sessionState.chunks.map {
            outputDirectory.appendingPathComponent($0.audioPath)
        }

        // Detect language
        let languages = Set(allSegments.compactMap(\.language))
        let detectedLanguage: String
        switch languages.count {
        case 0: detectedLanguage = "auto"
        case 1: detectedLanguage = languages.first!
        default: detectedLanguage = "multilingual"
        }

        // Assemble final JSON
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: true,
            dualStream: isDualStream
        )

        let baseName = sessionState.sessionId
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        // Enforce storage quota
        do {
            try StorageManager.enforceQuota(
                in: outputDirectory,
                limitHours: config.audioArchiveLimitHours,
                bitrateKbps: config.archiveBitrateKbps,
                protectedFile: audioPaths.last
            )
        } catch {
            Logger.files.error("Quota enforcement failed: \(error, privacy: .public)")
        }

        // Clean up session.json
        SessionState.delete(directory: outputDirectory)

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Chunked pipeline finalized — \(elapsed.components.seconds)s, \(mergeResult.chunkCount) chunks, output: \(jsonPath.lastPathComponent, privacy: .public)")

        return TranscriptionResult(jsonPath: jsonPath)
    }
```

- [ ] **Step 2: Keep the existing `run()` method for now**

The existing `run()` method continues to work as the fallback/single-chunk path. In the integration task (Task 12), the recording flow will wire up ChunkRotator + ChunkProcessor + `finalize()`.

- [ ] **Step 3: Build and run existing tests**

Run the full test suite. Expected: All existing tests pass — we only added a new method.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: add finalize() method for chunked pipeline merge"
```

---

## Task 12: Integration — Wire chunked pipeline into recording flow

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift` (or wherever startRecording/stopRecording live)
- Modify: `TranscriberCore/RecordingSentinel.swift` (add chunkIndex)

This task wires everything together. The exact integration points depend on how `startRecording` and `stopRecording` are currently structured in MenuView. Read MenuView.swift before implementing.

- [ ] **Step 1: Update RecordingSentinel with chunkIndex**

In `TranscriberCore/RecordingSentinel.swift`, add `chunkIndex` field:

```swift
    public var chunkIndex: Int

    public init(
        startedAt: Date,
        sessionName: String,
        systemAudioPath: String,
        micAudioPath: String,
        micDeviceUID: String? = nil,
        segment: Int = 0,
        chunkIndex: Int = 0
    ) {
        // ... existing fields ...
        self.chunkIndex = chunkIndex
    }
```

Update `incrementedSegment` to preserve chunkIndex:

```swift
    public func incrementedSegment(systemAudioPath: String, micAudioPath: String) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: startedAt,
            sessionName: sessionName,
            systemAudioPath: systemAudioPath,
            micAudioPath: micAudioPath,
            micDeviceUID: micDeviceUID,
            segment: segment + 1,
            chunkIndex: chunkIndex
        )
    }
```

- [ ] **Step 2: Read MenuView.swift to understand integration points**

Read the current recording start/stop flow to identify where to wire in ChunkRotator and ChunkProcessor.

- [ ] **Step 3: Wire ChunkRotator into startRecording**

After `captureClient.startCapture(...)` succeeds, create and start ChunkRotator:

```swift
let rotator = ChunkRotator(
    captureClient: captureClient,
    outputDirectory: outputDir,
    sessionBaseName: baseName,
    chunkDurationMinutes: config.validatedChunkDuration,
    startTime: Date()
) { [weak self] chunk in
    self?.chunkProcessor?.processChunk(chunk)
}
rotator.start()
self.chunkRotator = rotator
```

The initial WAV base name should use `-0` suffix to trigger 0-indexed discovery:
```swift
let baseName = "\(sessionName)-0"
```

- [ ] **Step 4: Wire ChunkProcessor into startRecording**

After engine initialization, create the ChunkProcessor:

```swift
let sessionState = SessionState(
    sessionId: sessionName,
    meetingStart: Date(),
    engine: config.engine.rawValue,
    chunkDurationMinutes: config.validatedChunkDuration,
    chunks: []
)

let processor = ChunkProcessor(
    config: config,
    outputDirectory: outputDir,
    sessionState: sessionState,
    transcriber: transcriber,
    diarizer: diarizer
)
self.chunkProcessor = processor
```

- [ ] **Step 5: Wire finalize into stopRecording**

After `captureClient.stopCapture(...)`:

```swift
// Stop rotation timer
chunkRotator?.stop()

// Process the last chunk
let lastChunkInfo = chunkRotator!.currentChunkInfo
let lastChunk = ChunkRotator.FinalizedChunk(
    index: lastChunkInfo.index,
    systemPath: systemPath,
    micPath: micPath,
    startTime: lastChunkInfo.startTime
)
await chunkProcessor?.processLastChunk(lastChunk)

// Final merge
let sessionState = chunkProcessor!.getSessionState()
let result = try await transcriptionRunner.finalize(
    sessionState: sessionState,
    outputDirectory: outputDir,
    config: config
)
```

- [ ] **Step 6: Build and test manually**

Run: `swift build 2>&1 | tail -10`
Expected: Compiles cleanly. Full manual testing is required (recording, rotation, transcription).

- [ ] **Step 7: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift TranscriberCore/RecordingSentinel.swift TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: wire chunked recording pipeline into recording flow"
```

---

## Task 13: Logging and test checklist update

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add chunked recording tests to checklist**

Add a new section to `scripts/test-checklist.md`:

```markdown
## Chunked Recording
- [ ] Start recording — verify chunk-0 files created with `-0` suffix
- [ ] Wait past chunk duration — verify chunk rotation in logs (new `-1` files)
- [ ] Stop after rotation — verify final transcript has all speech from both chunks
- [ ] Short meeting (< chunk duration) — verify single-chunk pipeline works
- [ ] Check session.json created during recording, deleted after
- [ ] Check speaker labels consistent across chunks in final transcript
- [ ] Check absolute timestamps in transcript JSON (ISO 8601)
- [ ] Verify WAV files deleted after archival to AAC
- [ ] Verify log output shows chunk lifecycle events
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add chunked recording tests to manual test checklist"
```

---

## Task 14: Crash recovery and edge case tests

**Files:**
- Create: `SwiftTests/TranscriberTests/ChunkRecoveryTests.swift`
- Add to: `SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift`
- Add to: `SwiftTests/TranscriberTests/TranscriptMergerTests.swift`

- [ ] **Step 1: Write crash recovery tests**

Create `SwiftTests/TranscriberTests/ChunkRecoveryTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscriberCore

@Test func recoveryWithPartialSessionJson() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 3 audio files on disk, but only 2 in session.json
    for i in 0...2 {
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("m-\(i).m4a"))
    }
    var state = SessionState(
        sessionId: "test", meetingStart: Date(), engine: "fluidAudio",
        chunkDurationMinutes: 30, chunks: []
    )
    for i in 0...1 {
        state.chunks.append(ProcessedChunk(
            index: i, startTime: Date(), audioPath: "m-\(i).m4a",
            segments: [], speakerDatabase: [:]
        ))
    }
    try SessionState.write(state, directory: dir)

    let loaded = SessionState.read(directory: dir)
    #expect(loaded?.chunks.count == 2)
    // Chunk 2 needs reprocessing — verify it's missing from session
    let processedIndices = Set(loaded!.chunks.map(\.index))
    #expect(!processedIndices.contains(2))
}

@Test func recoveryWithNoSessionJson() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Audio files exist but no session.json
    for i in 0...1 {
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("m-\(i).m4a"))
    }

    let loaded = SessionState.read(directory: dir)
    #expect(loaded == nil)
    // All chunks need reprocessing
}

@Test func recoveryWithCompleteSessionJson() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var state = SessionState(
        sessionId: "test", meetingStart: Date(), engine: "fluidAudio",
        chunkDurationMinutes: 30, chunks: []
    )
    for i in 0...2 {
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("m-\(i).m4a"))
        state.chunks.append(ProcessedChunk(
            index: i, startTime: Date(), audioPath: "m-\(i).m4a",
            segments: [], speakerDatabase: [:]
        ))
    }
    try SessionState.write(state, directory: dir)

    let loaded = SessionState.read(directory: dir)
    #expect(loaded?.chunks.count == 3)
    // No reprocessing needed
}

@Test func sentinelPreservesChunkIndex() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SentinelChunk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sentinel = RecordingSentinel(
        startedAt: Date(), sessionName: "test",
        systemAudioPath: "/tmp/m-3.wav", micAudioPath: "/tmp/m-3_mic.wav",
        segment: 0, chunkIndex: 3
    )
    try RecordingSentinel.write(sentinel, directory: dir)

    let loaded = RecordingSentinel.read(directory: dir)
    #expect(loaded?.chunkIndex == 3)
}
```

- [ ] **Step 2: Add edge case tests to existing test files**

Add to `SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift`:

```swift
@Test func reconcileSpeakerLeavesAfterChunk1() {
    var emb0 = [Float](repeating: 0, count: 256)
    emb0[0] = 1.0
    var emb1 = [Float](repeating: 0, count: 256)
    emb1[1] = 1.0

    let chunks = [
        ProcessedChunk(
            index: 0, startTime: Date(), audioPath: "m-0.m4a",
            segments: [], speakerDatabase: ["spk_0": emb0, "spk_1": emb1]
        ),
        ProcessedChunk(
            index: 1, startTime: Date(), audioPath: "m-1.m4a",
            segments: [], speakerDatabase: ["spk_0": emb0] // spk_1 left
        )
    ]

    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    #expect(mapping[1]?["spk_0"] == "spk_0")
    #expect(mapping[1]?.count == 1)
}

@Test func reconcileSingleSpeakerThroughout() {
    var emb = [Float](repeating: 0, count: 256)
    emb[0] = 1.0

    let chunks = (0..<4).map { i in
        ProcessedChunk(
            index: i, startTime: Date(), audioPath: "m-\(i).m4a",
            segments: [], speakerDatabase: ["spk_0": emb]
        )
    }

    let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
    for i in 0..<4 {
        #expect(mapping[i]?["spk_0"] == "spk_0")
    }
}
```

Add to `SwiftTests/TranscriberTests/TranscriptMergerTests.swift`:

```swift
@Test func mergerSilentChunkProducesNoSegments() {
    let now = Date()
    let chunks = [
        ProcessedChunk(
            index: 0, startTime: now, audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 1, text: "A", speaker: "spk_0", source: "system")],
            speakerDatabase: [:]
        ),
        ProcessedChunk(
            index: 1, startTime: now.addingTimeInterval(1800), audioPath: "m-1.m4a",
            segments: [], // Silent chunk
            speakerDatabase: [:]
        ),
        ProcessedChunk(
            index: 2, startTime: now.addingTimeInterval(3600), audioPath: "m-2.m4a",
            segments: [.init(start: 0, end: 1, text: "B", speaker: "spk_0", source: "system")],
            speakerDatabase: [:]
        )
    ]
    let mapping: [Int: [String: String]] = [
        0: ["spk_0": "spk_0"], 1: [:], 2: ["spk_0": "spk_0"]
    ]

    let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: now)
    #expect(result.segments.count == 2)
    #expect(result.segments[0].text == "A")
    #expect(result.segments[1].text == "B")
    #expect(result.segments[1].elapsed == 3600.0)
}
```

- [ ] **Step 3: Run all tests**

Run the full test suite. Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add SwiftTests/TranscriberTests/ChunkRecoveryTests.swift SwiftTests/TranscriberTests/SpeakerReconcilerTests.swift SwiftTests/TranscriberTests/TranscriptMergerTests.swift
git commit -m "test: add crash recovery and edge case tests for chunked recording"
```

---

## Summary

| Task | Component | Type | Dependencies |
|------|-----------|------|--------------|
| 1 | Config fields | Data | None |
| 2 | DiarizationResult + embeddings | Data | None |
| 3 | ChunkSession (session.json) | Data | None |
| 4 | SpeakerReconciler | Algorithm | Task 3 |
| 5 | TranscriptMerger | Algorithm | Task 3 |
| 6 | SegmentDiscovery 0-indexed | Logic | None |
| 7 | AudioOutputHandler swap | XPC | None |
| 8 | XPC rotateChunk method | XPC | Task 7 |
| 9 | ChunkRotator timer | Coordinator | Task 8 |
| 10 | ChunkProcessor pipeline | Pipeline | Tasks 2, 3 |
| 11 | TranscriptionRunner finalize | Pipeline | Tasks 4, 5 |
| 12 | Integration + RecordingSentinel | Integration | Tasks 9, 10, 11 |
| 13 | Logging + test checklist | Docs | Task 12 |
| 14 | Crash recovery + edge case tests | Tests | Tasks 3, 4, 5, 12 |

**Parallelizable groups:**
- Tasks 1, 2, 3, 6, 7 can run in parallel (no dependencies)
- Tasks 4, 5, 8 can run in parallel after their deps
- Tasks 9, 10, 11 can run in parallel after their deps
- Tasks 12, 13, 14 are sequential at the end
