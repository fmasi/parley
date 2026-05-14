# Echo Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove duplicate transcript segments caused by mic bleed of remote speakers, using triple confirmation (temporal overlap + text similarity + speaker embedding).

**Architecture:** `EchoDeduplicator` is a pure static function in TranscriberCore. It takes merged segments + both speaker databases, filters echo segments where all three signals agree, and returns clean segments. Called in `ChunkProcessor` per-chunk where both databases are in memory.

**Tech Stack:** Swift, Swift Testing

---

### Task 1: Core Helper Functions

**Files:**
- Create: `TranscriberCore/EchoDeduplicator.swift`
- Create: `SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift`

- [ ] **Step 1: Write failing tests for helper functions**

Create `SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct EchoDeduplicatorTests {

    // MARK: - Temporal overlap

    @Test func fullOverlapReturnsOne() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 15.0, bStart: 10.0, bEnd: 15.0
        )
        #expect(ratio == 1.0)
    }

    @Test func halfOverlapReturnsFifty() {
        // A: 10-20, B: 15-25 → overlap 15-20 = 5s, shorter = 10s → 0.5
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 20.0, bStart: 15.0, bEnd: 25.0
        )
        #expect(abs(ratio - 0.5) < 0.01)
    }

    @Test func noOverlapReturnsZero() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 0.0, aEnd: 5.0, bStart: 10.0, bEnd: 15.0
        )
        #expect(ratio == 0.0)
    }

    @Test func containedSegmentReturnsOne() {
        // Short segment fully inside long one
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 12.0, bStart: 8.0, bEnd: 20.0
        )
        #expect(ratio == 1.0)
    }

    // MARK: - Text similarity

    @Test func identicalTextReturnsOne() {
        let ratio = EchoDeduplicator.textSimilarity(
            "the quick brown fox jumps over the lazy dog",
            "the quick brown fox jumps over the lazy dog"
        )
        #expect(ratio == 1.0)
    }

    @Test func nearIdenticalTextReturnsHigh() {
        // Real example: minor transcription difference
        let ratio = EchoDeduplicator.textSimilarity(
            "Adding these two strikes caused like vortex generation",
            "Adding these two strakes caused like vortex generation"
        )
        // 7/8 shared words = 0.875
        #expect(ratio > 0.7)
    }

    @Test func completelyDifferentTextReturnsLow() {
        let ratio = EchoDeduplicator.textSimilarity(
            "the quick brown fox",
            "lorem ipsum dolor sit amet"
        )
        #expect(ratio < 0.3)
    }

    @Test func emptyTextReturnsZero() {
        #expect(EchoDeduplicator.textSimilarity("", "") == 0.0)
        #expect(EchoDeduplicator.textSimilarity("hello", "") == 0.0)
    }

    // MARK: - Cosine similarity

    @Test func identicalEmbeddingsReturnOne() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [1, 0, 0, 0]
        #expect(abs(EchoDeduplicator.cosineSimilarity(a, b) - 1.0) < 0.001)
    }

    @Test func orthogonalEmbeddingsReturnZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        #expect(abs(EchoDeduplicator.cosineSimilarity(a, b)) < 0.001)
    }

    @Test func similarEmbeddingsReturnHigh() {
        let a: [Float] = [1.0, 0.9, 0.8, 0.7]
        let b: [Float] = [1.0, 0.85, 0.82, 0.72]
        #expect(EchoDeduplicator.cosineSimilarity(a, b) > 0.99)
    }

    @Test func emptyEmbeddingsReturnZero() {
        #expect(EchoDeduplicator.cosineSimilarity([], []) == 0.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EchoDeduplicatorTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -10`
Expected: Compilation errors — `EchoDeduplicator` doesn't exist.

- [ ] **Step 3: Implement the helper functions**

Create `TranscriberCore/EchoDeduplicator.swift`:

```swift
import Foundation
import os

public enum EchoDeduplicator {

    // MARK: - Thresholds

    /// Minimum temporal overlap ratio (overlap / shorter segment duration) to consider as echo.
    static let temporalThreshold: Double = 0.5

    /// Minimum word overlap ratio to consider as echo.
    static let textThreshold: Double = 0.7

    /// Minimum cosine similarity between speaker embeddings to consider as same voice.
    static let embeddingThreshold: Float = 0.8

    // MARK: - Helper functions

    /// Compute temporal overlap ratio: overlap duration / shorter segment duration.
    /// Returns 0 if no overlap, 1 if one segment fully contains the other.
    public static func temporalOverlap(
        aStart: Double, aEnd: Double,
        bStart: Double, bEnd: Double
    ) -> Double {
        let overlapStart = max(aStart, bStart)
        let overlapEnd = min(aEnd, bEnd)
        let overlap = max(overlapEnd - overlapStart, 0)
        let shorter = min(aEnd - aStart, bEnd - bStart)
        guard shorter > 0 else { return 0 }
        return min(overlap / shorter, 1.0)
    }

    /// Compute word overlap ratio: |shared words| / |union of words|.
    /// Case-insensitive. Returns 0 for empty strings.
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    /// Cosine similarity between two float vectors. Returns 0 for empty or zero-norm vectors.
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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run same test command. Expected: All 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/EchoDeduplicator.swift SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift
git commit -m "feat: add EchoDeduplicator helper functions (temporal, text, embedding)"
```

---

### Task 2: Deduplication Logic

**Files:**
- Modify: `TranscriberCore/EchoDeduplicator.swift`
- Modify: `SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift`

- [ ] **Step 1: Write failing tests for the deduplicate function**

Add to `EchoDeduplicatorTests.swift`:

```swift
    // MARK: - Deduplication

    @Test func removesEchoWhenAllThreeSignalsMatch() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10.1, end: 15.2, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].source == "remote")
        #expect(result.removedCount == 1)
    }

    @Test func keepsLocalWhenTextDiffers() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "I totally agree with that", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
        #expect(result.removedCount == 0)
    }

    @Test func keepsLocalWhenTimestampsDontOverlap() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "Hello world", source: "remote"),
            LabeledSegment(start: 30, end: 35, speaker: "Local Speaker 1", text: "Hello world", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
    }

    @Test func keepsLocalWhenEmbeddingsDiffer() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Same text here", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "Same text here", source: "local"),
        ]
        // Very different embeddings — different people
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [0, 0, 0, 1]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
    }

    @Test func handlesEmptySegments() {
        let result = EchoDeduplicator.deduplicate(
            segments: [], localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.segments.isEmpty)
        #expect(result.removedCount == 0)
    }

    @Test func handlesSingleSourceOnly() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "Hello", source: "remote"),
            LabeledSegment(start: 6, end: 10, speaker: "Remote Speaker 2", text: "World", source: "remote"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.segments.count == 2)
        #expect(result.removedCount == 0)
    }

    @Test func handlesMultipleEchoesInSequence() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "First sentence here", source: "remote"),
            LabeledSegment(start: 0.1, end: 5.1, speaker: "Local Speaker 1", text: "First sentence here", source: "local"),
            LabeledSegment(start: 6, end: 10, speaker: "Remote Speaker 1", text: "Second sentence here", source: "remote"),
            LabeledSegment(start: 6.1, end: 10.2, speaker: "Local Speaker 1", text: "Second sentence here", source: "local"),
            LabeledSegment(start: 11, end: 15, speaker: "Local Speaker 2", text: "My own unique thought", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = [
            "Speaker 1": [0.98, 0.52, 0.31, 0.19],  // matches remote (echo)
            "Speaker 2": [0.1, 0.9, 0.1, 0.1],       // different person
        ]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 3)
        #expect(result.removedCount == 2)
        // Remote segments + local Speaker 2 survive
        #expect(result.segments.contains { $0.text == "My own unique thought" })
    }

    @Test func worksWithoutEmbeddings() {
        // When no embeddings available, embedding gate can't confirm → no removal
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Same text", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "Same text", source: "local"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        // No embeddings → embedding gate fails → kept
        #expect(result.segments.count == 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EchoDeduplicatorTests 2>&1 | tail -10`
Expected: Compilation errors — `deduplicate` doesn't exist.

- [ ] **Step 3: Implement the deduplicate function**

Add to `EchoDeduplicator.swift`:

```swift
    // MARK: - Result

    public struct DeduplicationResult {
        public let segments: [LabeledSegment]
        public let removedCount: Int
    }

    // MARK: - Main deduplication

    /// Remove local segments that are echo (mic bleed) of remote segments.
    /// A local segment is removed only when ALL THREE signals confirm:
    /// 1. Temporal overlap >50% with a remote segment
    /// 2. Text similarity >70% with that remote segment
    /// 3. Local speaker embedding matches any remote speaker embedding >0.8
    ///
    /// Returns filtered segments + count of removed echo segments.
    public static func deduplicate(
        segments: [LabeledSegment],
        localSpeakerDatabase: [String: [Float]],
        remoteSpeakerDatabase: [String: [Float]]
    ) -> DeduplicationResult {
        let remoteSegments = segments.filter { $0.source == "remote" }
        guard !remoteSegments.isEmpty else {
            return DeduplicationResult(segments: segments, removedCount: 0)
        }

        var kept: [LabeledSegment] = []
        var removedCount = 0

        for seg in segments {
            // Always keep remote segments
            guard seg.source == "local" else {
                kept.append(seg)
                continue
            }

            if isEcho(local: seg, remoteSegments: remoteSegments,
                      localDb: localSpeakerDatabase, remoteDb: remoteSpeakerDatabase) {
                removedCount += 1
            } else {
                kept.append(seg)
            }
        }

        if removedCount > 0 {
            Logger.transcription.info("Echo dedup: removed \(removedCount) local segments (mic bleed of remote speaker)")
        }

        return DeduplicationResult(segments: kept, removedCount: removedCount)
    }

    /// Check if a local segment is echo of any remote segment using triple confirmation.
    private static func isEcho(
        local: LabeledSegment,
        remoteSegments: [LabeledSegment],
        localDb: [String: [Float]],
        remoteDb: [String: [Float]]
    ) -> Bool {
        // Gate 3: check embedding similarity first (cheapest to short-circuit)
        let localSpeakerName = local.speaker
            .replacingOccurrences(of: "Local ", with: "")
        guard let localEmbedding = localDb[localSpeakerName],
              !localEmbedding.isEmpty else {
            return false  // No embedding → can't confirm → keep
        }

        let matchesRemoteVoice = remoteDb.values.contains { remoteEmbedding in
            cosineSimilarity(localEmbedding, remoteEmbedding) > embeddingThreshold
        }
        guard matchesRemoteVoice else { return false }

        // Gate 1 + 2: find a remote segment with temporal + text match
        for remote in remoteSegments {
            let overlap = temporalOverlap(
                aStart: local.start, aEnd: local.end,
                bStart: remote.start, bEnd: remote.end
            )
            guard overlap > temporalThreshold else { continue }

            let textSim = textSimilarity(local.text, remote.text)
            guard textSim > textThreshold else { continue }

            return true  // All three gates passed
        }

        return false
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run same test command. Expected: All 20 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/EchoDeduplicator.swift SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift
git commit -m "feat: implement triple-confirmed echo deduplication"
```

---

### Task 3: Integration into ChunkProcessor

**Files:**
- Modify: `TranscriberApp/Services/ChunkProcessor.swift`

- [ ] **Step 1: Add dedup call after merge step**

In `ChunkProcessor.swift`, after step 3 (merge + source prefix tagging, around line 113) and before step 4 (convert to ProcessedChunk), add:

```swift
        // 3b. Remove echo segments (mic bleed of remote speaker)
        if hasDualStream {
            let dedupResult = EchoDeduplicator.deduplicate(
                segments: allSegments,
                localSpeakerDatabase: micResult.speakerDatabase,
                remoteSpeakerDatabase: systemResult.speakerDatabase
            )
            allSegments = dedupResult.segments
        }
```

The `import TranscriberCore` is already present at the top of ChunkProcessor.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/ChunkProcessor.swift
git commit -m "feat: integrate echo dedup into ChunkProcessor pipeline"
```

---

### Task 4: Add echo_segments_removed to Transcript Metadata

**Files:**
- Modify: `TranscriberCore/TranscriptAssembler.swift`

- [ ] **Step 1: Add echoSegmentsRemoved parameter to assemble()**

In `TranscriptAssembler.swift`, add a new parameter `echoSegmentsRemoved: Int = 0` to the `assemble()` function signature.

Add to the metadata dictionary:
```swift
if echoSegmentsRemoved > 0 {
    metadata["echo_segments_removed"] = echoSegmentsRemoved
}
```

Note: `metadata` must be changed from `let` to `var` to allow conditional insertion.

The full updated function signature:
```swift
public static func assemble(
    segments: [LabeledSegment],
    audioPaths: [URL],
    outputFormat: String,
    language: String,
    numSpeakers: Int?,
    diarization: Bool,
    dualStream: Bool,
    echoSegmentsRemoved: Int = 0
) -> [String: Any] {
```

- [ ] **Step 2: Update ChunkProcessor to pass the count**

In `ChunkProcessor.processChunkAsync()`, the dedup result's `removedCount` needs to be tracked. However, `TranscriptAssembler.assemble()` is not called in ChunkProcessor — it's called in `TranscriptionRunner.finalize()`. The count is available per-chunk but needs to flow through.

For simplicity, add the count to `ProcessedChunk.Segment` is overkill. Instead, track it as a property on ProcessedChunk:

In `TranscriberCore/ChunkSession.swift`, add to `ProcessedChunk`:
```swift
public let echoSegmentsRemoved: Int
```

Update the `init` to include it (with default `= 0` for backward compat):
```swift
public init(
    index: Int,
    startTime: Date,
    audioPath: String,
    segments: [Segment],
    speakerDatabase: [String: [Float]],
    echoSegmentsRemoved: Int = 0
) {
    ...
    self.echoSegmentsRemoved = echoSegmentsRemoved
}
```

Add a CodingKeys entry and handle it in decoding with a default of 0 for backward compat with existing session.json files.

Update ChunkProcessor to pass the count:
```swift
let processed = ProcessedChunk(
    index: chunk.index,
    startTime: chunk.startTime,
    audioPath: audioPath,
    segments: chunkSegments,
    speakerDatabase: speakerDatabase,
    echoSegmentsRemoved: dedupResult.removedCount  // 0 if not dual-stream
)
```

The `dedupResult` variable needs to be accessible. Restructure the dedup section:
```swift
// 3b. Remove echo segments (mic bleed of remote speaker)
var echoRemoved = 0
if hasDualStream {
    let dedupResult = EchoDeduplicator.deduplicate(
        segments: allSegments,
        localSpeakerDatabase: micResult.speakerDatabase,
        remoteSpeakerDatabase: systemResult.speakerDatabase
    )
    allSegments = dedupResult.segments
    echoRemoved = dedupResult.removedCount
}
```

Then pass `echoRemoved` to ProcessedChunk.

- [ ] **Step 3: Update TranscriptionRunner.finalize() to sum echo counts**

In `TranscriptionRunner.finalize()`, before calling `TranscriptAssembler.assemble()`, sum the counts:
```swift
let totalEchoRemoved = sessionState.chunks.reduce(0) { $0 + $1.echoSegmentsRemoved }
```

Pass it to assemble:
```swift
let json = TranscriptAssembler.assemble(
    segments: allSegments,
    audioPaths: audioPaths,
    outputFormat: config.outputFormat,
    language: detectedLanguage,
    numSpeakers: nil,
    diarization: true,
    dualStream: isDualStream,
    echoSegmentsRemoved: totalEchoRemoved
)
```

Also update the `run()` single-file path similarly (pass 0 since dedup happens in ChunkProcessor).

- [ ] **Step 4: Build and run full test suite**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -5`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptAssembler.swift TranscriberCore/ChunkSession.swift TranscriberApp/Services/ChunkProcessor.swift TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: track echo_segments_removed in metadata and session state"
```

---

### Task 5: Update CLAUDE.md + Full Test Run

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run full test suite**

Run: `swift test --filter TranscriberTests ...`
Expected: All tests pass.

- [ ] **Step 2: Update CLAUDE.md**

Add to TranscriberCore file list:
```
- `TranscriberCore/EchoDeduplicator.swift` -- triple-confirmed echo dedup: removes local segments that are mic bleed of remote speakers (temporal overlap + text similarity + speaker embedding)
```

Update test count.

Add gotcha:
```
46. **Echo deduplication (triple confirmation):** Local segments are removed only when ALL three signals agree: temporal overlap >50%, word overlap >70%, and speaker embedding cosine similarity >0.8 with a remote speaker. Without all three, the segment is kept. No embeddings available = no removal. Raw audio archive is never modified.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with echo deduplication"
```
