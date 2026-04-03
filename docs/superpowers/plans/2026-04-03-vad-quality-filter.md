# VAD Quality Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VAD as a parallel quality signal in SpeakerAssignment to filter noise segments and leverage diarizer qualityScore.

**Architecture:** VAD runs concurrently with diarization on the same audio file. `SpeakerAssignment` fuses three signals (ASR transcript, diarized segments with qualityScore, VAD speech map) to produce cleaner labeled output. Each signal is independently tunable and observable.

**Tech Stack:** Swift Testing, FluidAudio (VadManager, VadConfig, VadSegmentationConfig), TranscriberCore

**Spec:** `docs/superpowers/specs/2026-04-03-vad-quality-filter-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `TranscriberCore/VadSpeechMap.swift` | `SpeechRegion` struct + `VadSpeechMap` actor wrapping `VadManager` |
| Create | `SwiftTests/TranscriberTests/VadSpeechMapTests.swift` | Unit tests for speech overlap calculation |
| Create | `SwiftTests/TranscriberTests/SpeakerAssignmentVadTests.swift` | Unit tests for combined VAD+qualityScore filtering |
| Modify | `TranscriberCore/SpeakerAssignment.swift` | New `assign` overload accepting speech map + qualityScore filtering |
| Modify | `TranscriberCore/Config.swift` | Add `vadSpeechThreshold` field |
| Modify | `TranscriberCore/FluidAudioDiarizer.swift` | VAD model cache check + download in `preDownloadModels()` |
| Modify | `TranscriberApp/Services/TranscriptionRunner.swift` | Run VAD concurrently with diarization, pass speech map to `assign()` |

---

### Task 1: SpeechRegion struct and speechOverlap calculation

**Files:**
- Create: `TranscriberCore/VadSpeechMap.swift`
- Create: `SwiftTests/TranscriberTests/VadSpeechMapTests.swift`

- [ ] **Step 1: Write failing tests for speechOverlap**

In `SwiftTests/TranscriberTests/VadSpeechMapTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct VadSpeechMapTests {

    // MARK: - speechOverlap

    @Test func fullOverlapReturnsOne() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 1.0)
    }

    @Test func noOverlapReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 2.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 8.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func partialOverlapReturnsProportionalValue() {
        let regions = [SpeechRegion(start: 0.0, end: 3.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 6.0, threshold: 0.5)
        // 1s overlap out of 4s segment = 0.25
        #expect(abs(result - 0.25) < 0.001)
    }

    @Test func multipleRegionsSpanningOneSegment() {
        let regions = [
            SpeechRegion(start: 0.0, end: 2.0, probability: 0.9),
            SpeechRegion(start: 4.0, end: 6.0, probability: 0.9),
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 8.0, threshold: 0.5)
        // 4s overlap out of 8s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test func emptyRegionsReturnsZero() {
        let result = SpeechRegion.speechOverlap(regions: [], start: 0.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func zeroDurationSegmentReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func regionBelowThresholdIsIgnored() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.3)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func mixedProbabilityRegions() {
        let regions = [
            SpeechRegion(start: 0.0, end: 5.0, probability: 0.9),  // above threshold
            SpeechRegion(start: 5.0, end: 10.0, probability: 0.2), // below threshold
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 10.0, threshold: 0.5)
        // 5s overlap out of 10s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter VadSpeechMapTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: Compile error — `SpeechRegion` not defined yet

- [ ] **Step 3: Implement SpeechRegion and speechOverlap**

In `TranscriberCore/VadSpeechMap.swift`:

```swift
import Foundation
import os

/// Time-indexed speech probability from Silero VAD.
/// Used as a parallel quality signal in SpeakerAssignment.
public struct SpeechRegion: Sendable {
    public let start: Double
    public let end: Double
    public let probability: Float

    public init(start: Double, end: Double, probability: Float) {
        self.start = start
        self.end = end
        self.probability = probability
    }

    /// Calculate what fraction of [start, end] overlaps with speech regions
    /// whose probability meets the threshold.
    /// Returns 0.0–1.0.
    public static func speechOverlap(
        regions: [SpeechRegion],
        start: Double,
        end: Double,
        threshold: Float
    ) -> Double {
        let duration = end - start
        guard duration > 0 else { return 0.0 }

        var overlap = 0.0
        for region in regions {
            guard region.probability >= threshold else { continue }
            let overlapStart = max(start, region.start)
            let overlapEnd = min(end, region.end)
            let regionOverlap = max(0, overlapEnd - overlapStart)
            overlap += regionOverlap
        }

        return min(1.0, overlap / duration)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2
Expected: All 8 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberCore/VadSpeechMap.swift SwiftTests/TranscriberTests/VadSpeechMapTests.swift
git commit -m "feat: add SpeechRegion struct with speechOverlap calculation"
```

---

### Task 2: SpeakerAssignment VAD + qualityScore filtering

**Files:**
- Create: `SwiftTests/TranscriberTests/SpeakerAssignmentVadTests.swift`
- Modify: `TranscriberCore/SpeakerAssignment.swift:59-108`

- [ ] **Step 1: Write failing tests for filtered assignment**

In `SwiftTests/TranscriberTests/SpeakerAssignmentVadTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct SpeakerAssignmentVadTests {

    // Helper to create diarized segments with quality scores
    private func diarized(_ start: Double, _ end: Double, _ speaker: String, quality: Float? = nil) -> DiarizedSegment {
        DiarizedSegment(start: start, end: end, speaker: speaker, qualityScore: quality)
    }

    private func transcript(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, language: nil)
    }

    // MARK: - High speech + high quality → assign speaker

    @Test func highSpeechHighQualityAssignsSpeaker() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.9)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    // MARK: - High speech + low quality → "Unknown"

    @Test func highSpeechLowQualityAssignsUnknown() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.1)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Unknown")
    }

    // MARK: - Low speech + low quality → filtered out

    @Test func lowSpeechLowQualityFiltered() {
        let transcript = [
            transcript(0.0, 5.0, "real speech"),
            transcript(5.0, 10.0, "noise segment"),
        ]
        let diarization = [
            diarized(0.0, 5.0, "SPEAKER_00", quality: 0.9),
            diarized(5.0, 10.0, "SPEAKER_01", quality: 0.1),
        ]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]
        // No speech region for 5-10s → overlap = 0.0

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].text == "real speech")
    }

    // MARK: - Low speech + high quality → trust diarizer

    @Test func lowSpeechHighQualityTrustsDiarizer() {
        let transcript = [transcript(5.0, 10.0, "quiet speaker")]
        let diarization = [diarized(5.0, 10.0, "SPEAKER_00", quality: 0.9)]
        let speechMap: [SpeechRegion] = []  // No speech detected

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    // MARK: - Nil speech map → fallback to current behavior

    @Test func nilSpeechMapFallsBackToOriginal() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.1)]

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: nil,
            vadSpeechThreshold: 0.5
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")  // No filtering applied
    }

    // MARK: - qualityScore nil → treat as high quality (engine may not provide it)

    @Test func nilQualityScoreTreatedAsHighQuality() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: nil)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    // MARK: - vadSpeechThreshold 0.0 disables filtering

    @Test func zeroThresholdDisablesVadFiltering() {
        let transcript = [transcript(5.0, 10.0, "noise")]
        let diarization = [diarized(5.0, 10.0, "SPEAKER_00", quality: 0.1)]
        let speechMap: [SpeechRegion] = []  // No speech

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization,
            speechMap: speechMap,
            vadSpeechThreshold: 0.0,
            qualityScoreThreshold: 0.3
        )
        // With vadSpeechThreshold=0.0, VAD filtering is disabled, but qualityScore still applies
        #expect(result.count == 1)
        #expect(result[0].speaker == "Unknown")
    }

    // MARK: - Original assign method still works unchanged

    @Test func originalAssignMethodUnchanged() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00")]

        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript,
            diarizationSegments: diarization
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter SpeakerAssignmentVadTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: Compile error — `assign` overload with `speechMap` parameter doesn't exist

- [ ] **Step 3: Implement filtered assign overload in SpeakerAssignment**

Add this method after the existing `assign` method in `TranscriberCore/SpeakerAssignment.swift` (after line 108, before `tagWithSourcePrefix`):

```swift
    /// Assign speaker labels with VAD + qualityScore filtering.
    ///
    /// Decision matrix:
    /// - High speech + high quality → assign speaker
    /// - High speech + low quality → assign "Unknown"
    /// - Low speech + high quality → trust diarizer (assign speaker)
    /// - Low speech + low quality → filter from output
    ///
    /// When speechMap is nil, falls back to original behavior (no VAD filtering).
    /// When vadSpeechThreshold is 0.0, VAD filtering is disabled but qualityScore is still applied.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment],
        speechMap: [SpeechRegion]?,
        vadSpeechThreshold: Double = 0.5,
        qualityScoreThreshold: Float = 0.3
    ) -> [LabeledSegment] {
        // Build speaker map (same logic as original)
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        let speakerMap = Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )

        Logger.transcription.debug("Speaker map: \(speakerMap.count) speakers — \(speakerMap, privacy: .public)")

        var results: [LabeledSegment] = []

        for seg in transcriptSegments {
            let segMid = (seg.start + seg.end) / 2
            var bestSpeaker = "Unknown"
            var bestOverlap: Double = 0
            var bestQuality: Float? = nil

            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }

                if sp.start <= segMid && segMid <= sp.end && overlap >= bestOverlap {
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }
            }

            // Compute VAD speech overlap for this segment
            let speechOverlap: Double
            if let speechMap, vadSpeechThreshold > 0 {
                speechOverlap = SpeechRegion.speechOverlap(
                    regions: speechMap,
                    start: seg.start,
                    end: seg.end,
                    threshold: 0.5  // probability threshold for individual VAD regions
                )
            } else {
                speechOverlap = 1.0  // No VAD → treat everything as speech
            }

            let hasHighSpeech = speechOverlap >= vadSpeechThreshold || speechMap == nil
            let quality = bestQuality ?? 1.0  // nil = treat as high quality
            let hasHighQuality = quality >= qualityScoreThreshold

            // Decision matrix
            let finalSpeaker: String
            let shouldInclude: Bool

            if hasHighSpeech && hasHighQuality {
                finalSpeaker = bestSpeaker
                shouldInclude = true
            } else if hasHighSpeech && !hasHighQuality {
                finalSpeaker = "Unknown"
                shouldInclude = true
            } else if !hasHighSpeech && hasHighQuality {
                finalSpeaker = bestSpeaker
                shouldInclude = true
            } else {
                // Low speech + low quality = noise
                finalSpeaker = bestSpeaker
                shouldInclude = false
                Logger.transcription.debug(
                    "VAD filtered [\(seg.start, privacy: .public)–\(seg.end, privacy: .public)] \(bestSpeaker, privacy: .public): speechOverlap=\(speechOverlap, privacy: .public), quality=\(quality, privacy: .public)"
                )
            }

            if shouldInclude {
                results.append(LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: finalSpeaker,
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "",
                    confidence: seg.confidence,
                    language: seg.language
                ))
            }
        }

        let filtered = transcriptSegments.count - results.count
        if filtered > 0 {
            Logger.transcription.info("VAD quality filter: \(filtered) segments filtered from \(transcriptSegments.count) total")
        }

        return results
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter SpeakerAssignmentVadTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: All 8 tests PASS

- [ ] **Step 5: Run all existing tests to verify no regressions**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: All 220+ tests PASS (existing `SpeakerAssignmentTests` unchanged, original `assign` method not modified)

- [ ] **Step 6: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberCore/SpeakerAssignment.swift SwiftTests/TranscriberTests/SpeakerAssignmentVadTests.swift
git commit -m "feat: add SpeakerAssignment.assign with VAD + qualityScore filtering"
```

---

### Task 3: VadSpeechMap actor (FluidAudio VadManager wrapper)

**Files:**
- Modify: `TranscriberCore/VadSpeechMap.swift`

- [ ] **Step 1: Add VadSpeechMap actor to existing file**

Append to `TranscriberCore/VadSpeechMap.swift` after the `SpeechRegion` struct:

```swift
import FluidAudio

/// Wraps FluidAudio's VadManager to produce a speech map for quality filtering.
/// Runs concurrently with diarization — near-zero added latency (RTFx ~100x).
public actor VadSpeechMap {
    private var manager: VadManager?

    public init() {}

    /// Analyze audio and return speech regions with probabilities.
    /// Returns nil if VAD model is not cached (graceful degradation).
    public func analyze(audioPath: URL) async throws -> [SpeechRegion]? {
        guard Self.isModelCached() else {
            Logger.transcription.debug("VAD model not cached — skipping speech map analysis")
            return nil
        }

        let startTime = ContinuousClock.now
        let mgr = try await ensureLoaded()

        let results = try await mgr.process(audioPath)

        let chunkDuration = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        let regions = results.enumerated().map { (index, result) in
            SpeechRegion(
                start: Double(index) * chunkDuration,
                end: Double(index + 1) * chunkDuration,
                probability: result.probability
            )
        }

        let elapsed = ContinuousClock.now - startTime
        let speechCount = regions.filter { $0.probability >= 0.5 }.count
        let speechRatio = regions.isEmpty ? 0.0 : Double(speechCount) / Double(regions.count)
        Logger.transcription.info(
            "VAD analysis: \(regions.count) chunks, \(String(format: "%.0f", speechRatio * 100))% speech in \(elapsed.components.seconds)s"
        )

        return regions
    }

    /// Check if the Silero VAD model is present in the local cache.
    public static func isModelCached() -> Bool {
        let baseDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("FluidAudio", isDirectory: true)
        let modelsDir = baseDir.appendingPathComponent("Models")
        let vadDir = modelsDir.appendingPathComponent(Repo.vad.folderName)
        return ModelNames.VAD.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: vadDir.appendingPathComponent($0).path)
        }
    }

    /// Download the Silero VAD model to the local cache.
    /// Safe to call if already cached.
    public static func preDownloadModel() async throws {
        let _ = try await VadManager()
        Logger.transcription.info("VAD model pre-download complete")
    }

    private func ensureLoaded() async throws -> VadManager {
        if let mgr = manager {
            return mgr
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading Silero VAD model from cache...")

        let mgr = try await VadManager()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("VAD model loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift build 2>&1 | tail -5`
Expected: Build succeeded

Note: `VadSpeechMap.isModelCached()` and `preDownloadModel()` use FluidAudio's `Repo.vad`, `ModelNames.VAD`, and `VadManager` — check that these are public in FluidAudio. If `Repo` or `ModelNames` are internal, use the simpler approach of attempting `VadManager()` init and catching errors. The implementer should adjust based on what's actually public.

- [ ] **Step 3: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberCore/VadSpeechMap.swift
git commit -m "feat: add VadSpeechMap actor wrapping FluidAudio VadManager"
```

---

### Task 4: Config field for vadSpeechThreshold

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write failing test**

Add to existing `ConfigTests.swift`:

```swift
@Test func vadSpeechThresholdDefaultsToNil() {
    let config = Config.default
    #expect(config.vadSpeechThreshold == nil)
}

@Test func vadSpeechThresholdRoundTrips() throws {
    var config = Config.default
    config.vadSpeechThreshold = 0.7
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.vadSpeechThreshold == 0.7)
}

@Test func missingVadSpeechThresholdDecodesToNil() throws {
    // Existing config JSON without the field should decode fine
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,"output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.vadSpeechThreshold == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter ConfigTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: Compile error — `vadSpeechThreshold` doesn't exist on Config

- [ ] **Step 3: Add vadSpeechThreshold to Config**

In `TranscriberCore/Config.swift`:

Add property after `engine`:
```swift
    public var vadSpeechThreshold: Double?
```

Add to `CodingKeys`:
```swift
        case vadSpeechThreshold = "vad_speech_threshold"
```

Add to `init(from decoder:)` at the end:
```swift
        vadSpeechThreshold = try c.decodeIfPresent(Double.self, forKey: .vadSpeechThreshold)
```

Add parameter to `init(...)`:
```swift
        vadSpeechThreshold: Double? = nil
```
and assignment:
```swift
        self.vadSpeechThreshold = vadSpeechThreshold
```

Add to `Config.default`:
```swift
        vadSpeechThreshold: nil
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2, plus full test suite
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: add vadSpeechThreshold to Config"
```

---

### Task 5: Wire VAD into FluidAudioDiarizer model download flow

**Files:**
- Modify: `TranscriberCore/FluidAudioDiarizer.swift:39-57`

- [ ] **Step 1: Add isFullyReady and keep isDiarizationCached unchanged**

In `TranscriberCore/FluidAudioDiarizer.swift`, keep `isDiarizationCached()` as diarization-only (used by `ensureLoaded()`), and add a new `isFullyReady()` for the UI:

```swift
    /// Returns true if ALL models (diarization + VAD) are present.
    /// Used by Setup/Settings UI to gate "ready" state — ensures full capability after setup.
    public static func isFullyReady() -> Bool {
        isDiarizationCached() && VadSpeechMap.isModelCached()
    }
```

Then update all UI call sites (`SetupView`, `SettingsView`, `TranscriberApp`) to use `isFullyReady()` instead of `isDiarizationCached()`.

- [ ] **Step 2: Update preDownloadModels to also download VAD model**

In `TranscriberCore/FluidAudioDiarizer.swift`, modify `preDownloadModels()`:

```swift
    /// Download diarization + VAD models to the local cache without keeping them in memory.
    /// Safe to call if already cached — managers skip re-download.
    public static func preDownloadModels(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()
        Logger.transcription.info("FluidAudio diarization model pre-download complete")

        try await VadSpeechMap.preDownloadModel()
    }
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift build 2>&1 | tail -5`
Expected: Build succeeded

Note: If `Repo.vad` or `ModelNames.VAD` are internal to FluidAudio and `VadSpeechMap.isModelCached()` doesn't compile, the implementer should simplify `isModelCached()` to attempt loading and catch errors, or always return `true` and let `analyze()` handle the fallback.

- [ ] **Step 4: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberCore/FluidAudioDiarizer.swift
git commit -m "feat: include VAD model in diarization cache check and download"
```

---

### Task 6: Wire VAD into TranscriptionRunner pipeline

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift:29,173-222`

- [ ] **Step 1: Add VadSpeechMap to TranscriptionRunner**

In `TranscriberApp/Services/TranscriptionRunner.swift`, add a property after `diarizer`:

```swift
    private let vadSpeechMap = VadSpeechMap()
```

- [ ] **Step 2: Update transcribeStream to run VAD concurrently and use filtered assign**

Replace the diarizer section in `transcribeStream()` (lines 195-214) with:

```swift
        var labeled: [LabeledSegment]
        if let diarizer = diarizer {
            // Run VAD concurrently with diarization (both read the same audio file)
            async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
            async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

            let diarizedSegments = try await diarizedResult
            let speechMap = try? await speechMapResult  // nil on failure = graceful degradation

            labeled = SpeakerAssignment.assign(
                transcriptSegments: segments,
                diarizationSegments: diarizedSegments,
                speechMap: speechMap,
                vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5
            )
        } else {
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "",
                    confidence: seg.confidence,
                    language: seg.language
                )
            }
        }
```

Note: `transcribeStream` needs access to `config`. Add `config: Config` parameter to `transcribeStream()` signature, and pass it from the call sites in `run()`.

Update the private method signature:
```swift
    private func transcribeStream(
        audioPath: URL,
        source: String,
        transcriber: any TranscriptionEngine,
        label: String,
        audioSource: AudioSourceType,
        config: Config
    ) async throws -> [LabeledSegment] {
```

Update call sites in `run()` (lines 70-76 and 83-89) to pass `config: config`.

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Run all tests**

Run: `cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter && swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: run VAD concurrently with diarization, wire into SpeakerAssignment"
```

---

### Task 7: Update test checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Read current checklist**

Read `scripts/test-checklist.md` to understand the existing format.

- [ ] **Step 2: Add VAD quality filter test items**

Append a new section to the checklist:

```markdown
## VAD Quality Filter
- [ ] Record with background music → verify music segments filtered, not labeled as speaker
- [ ] Record meeting with long muted period → verify silence doesn't create phantom speaker
- [ ] Record with keyboard noise → verify clicks filtered from transcript
- [ ] Record normal meeting → verify no real speech segments lost (false negative check)
- [ ] Set vad_speech_threshold to 0.0 in config → verify VAD filtering disabled, all segments present
- [ ] Delete VAD model from cache → verify graceful degradation (no crash, no filtering)
- [ ] Check rename dialog → verify filtered segments don't appear as speaker samples
```

- [ ] **Step 3: Commit**

```bash
cd /Users/fmasi/Git/Transcriber/.worktrees/feat/vad-pre-filter
git add scripts/test-checklist.md
git commit -m "docs: add VAD quality filter to test checklist"
```
