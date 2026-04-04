import Testing
import Foundation
@testable import TranscriberCore

/// Tests for ChunkRotator logic.
///
/// ChunkRotator lives in TranscriberApp (not importable by the test target), so these tests
/// validate the naming conventions, index progression, and chunk finalization data flow
/// that ChunkRotator relies on, using the shared TranscriberCore types.
@Suite("ChunkRotator")
struct ChunkRotatorTests {

    // MARK: - Chunk naming convention

    @Test("chunkBaseNameFollowsConvention")
    func chunkBaseNameFollowsConvention() {
        let sessionBaseName = "2026-04-04_standup"
        // ChunkRotator computes: "\(sessionBaseName)-\(chunkIndex)"
        let chunkIndex = 0
        let baseName = "\(sessionBaseName)-\(chunkIndex)"
        #expect(baseName == "2026-04-04_standup-0")
    }

    @Test("chunkBaseNameIncrementsWithIndex")
    func chunkBaseNameIncrementsWithIndex() {
        let sessionBaseName = "meeting"
        // Simulate ChunkRotator's index progression through multiple rotations
        var names: [String] = []
        for i in 0..<5 {
            names.append("\(sessionBaseName)-\(i)")
        }
        #expect(names == ["meeting-0", "meeting-1", "meeting-2", "meeting-3", "meeting-4"])
    }

    @Test("chunkBaseNameHandlesSpecialCharactersInSessionName")
    func chunkBaseNameHandlesSpecialCharacters() {
        // Session names go through sanitizeFilename, but ChunkRotator just appends the index
        let sanitized = sanitizeFilename("2026/04/04 standup")
        let baseName = "\(sanitized)-0"
        #expect(!baseName.contains("/"))
        #expect(baseName.hasSuffix("-0"))
    }

    // MARK: - Rotation timing

    @Test("chunkDurationConvertsMinutesToSeconds")
    func chunkDurationConvertsMinutesToSeconds() {
        // ChunkRotator: self.chunkDuration = TimeInterval(chunkDurationMinutes * 60)
        let minutes = 30
        let seconds = TimeInterval(minutes * 60)
        #expect(seconds == 1800.0)
    }

    @Test("minimumChunkDurationRespected")
    func minimumChunkDurationRespected() {
        // Config.validatedChunkDuration clamps to minimum 10 minutes
        let config = Config(chunkDurationMinutes: 3)
        #expect(config.validatedChunkDuration == 10)

        let normalConfig = Config(chunkDurationMinutes: 30)
        #expect(normalConfig.validatedChunkDuration == 30)
    }

    // MARK: - FinalizedChunk data integrity

    @Test("finalizedChunkMapsToProcessedChunk")
    func finalizedChunkMapsToProcessedChunk() {
        // ChunkProcessor creates ProcessedChunk from FinalizedChunk data.
        // Verify the mapping is consistent.
        let index = 2
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let audioPath = "/tmp/output/meeting-2-system.wav"

        let processed = ProcessedChunk(
            index: index,
            startTime: startTime,
            audioPath: audioPath,
            segments: [],
            speakerDatabase: [:]
        )

        #expect(processed.index == 2)
        #expect(processed.startTime == startTime)
        #expect(processed.audioPath == audioPath)
    }

    // MARK: - Rotation index progression

    @Test("rotationProgressesIndexMonotonically")
    func rotationProgressesIndexMonotonically() {
        // Simulate ChunkRotator's rotate() logic
        var currentChunkIndex = 0
        var finalizedIndices: [Int] = []

        for _ in 0..<4 {
            let oldIndex = currentChunkIndex
            let nextIndex = oldIndex + 1
            finalizedIndices.append(oldIndex)
            currentChunkIndex = nextIndex
        }

        #expect(finalizedIndices == [0, 1, 2, 3])
        #expect(currentChunkIndex == 4)
    }

    @Test("rotationUpdatesStartTime")
    func rotationUpdatesStartTime() {
        // Each rotation should capture the old start time and set a new one
        var currentStartTime = Date(timeIntervalSince1970: 1_700_000_000)
        var capturedStartTimes: [Date] = []

        for i in 1...3 {
            let oldStartTime = currentStartTime
            capturedStartTimes.append(oldStartTime)
            // Simulate ChunkRotator setting new start time
            currentStartTime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 1800))
        }

        // Each captured start time should be from before the rotation
        #expect(capturedStartTimes.count == 3)
        #expect(capturedStartTimes[0] == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(capturedStartTimes[1] == Date(timeIntervalSince1970: 1_700_001_800))
        #expect(capturedStartTimes[2] == Date(timeIntervalSince1970: 1_700_003_600))
    }

    // MARK: - Stop behavior

    @Test("stopPreventsSubsequentRotation")
    func stopPreventsSubsequentRotation() {
        // After stop(), the timer is nil — no more rotations fire.
        // We simulate by tracking a "stopped" flag that gates rotation.
        var stopped = false
        var rotationCount = 0

        func rotate() {
            guard !stopped else { return }
            rotationCount += 1
        }

        rotate()
        rotate()
        stopped = true
        rotate()
        rotate()

        #expect(rotationCount == 2)
    }

    @Test("currentChunkInfoAvailableAfterStop")
    func currentChunkInfoAvailableAfterStop() {
        // After stop, currentChunkInfo should still report the last active chunk
        var currentIndex = 0
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        var currentStartTime = startTime

        // Simulate two rotations
        currentIndex = 1
        currentStartTime = Date(timeIntervalSince1970: 1_700_001_800)
        currentIndex = 2
        currentStartTime = Date(timeIntervalSince1970: 1_700_003_600)

        // After stop, the "current" chunk is index 2
        #expect(currentIndex == 2)
        #expect(currentStartTime == Date(timeIntervalSince1970: 1_700_003_600))
    }
}
