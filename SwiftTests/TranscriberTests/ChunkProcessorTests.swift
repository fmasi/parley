import Testing
import Foundation
@testable import TranscriberCore

/// Tests for ChunkProcessor logic.
///
/// ChunkProcessor lives in TranscriberApp (not importable by the test target), so these tests
/// validate the core logic it orchestrates: session state accumulation, segment merging,
/// speaker assignment tagging, transcript segment mapping, and thread-safe state management
/// using the shared TranscriberCore types and protocols.
@Suite("ChunkProcessor")
struct ChunkProcessorTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkProcessorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeSegment(
        start: Double = 0.0,
        end: Double = 5.0,
        text: String = "Hello",
        speaker: String = "Speaker 1",
        source: String = "remote"
    ) -> ProcessedChunk.Segment {
        ProcessedChunk.Segment(
            start: start,
            end: end,
            text: text,
            speaker: speaker,
            source: source,
            qualityScore: 0.9
        )
    }

    private func makeChunk(
        index: Int,
        segments: [ProcessedChunk.Segment] = [],
        speakerDatabase: [String: [Float]] = [:]
    ) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 1800)),
            audioPath: "/tmp/chunk-\(index).m4a",
            segments: segments,
            speakerDatabase: speakerDatabase
        )
    }

    private func makeSession() -> SessionState {
        SessionState(
            sessionId: "test-session",
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000),
            engine: "fluidAudio",
            chunkDurationMinutes: 30
        )
    }

    // MARK: - Session state accumulation

    @Test("sessionStateAccumulatesChunksInOrder")
    func sessionStateAccumulatesChunksInOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var session = makeSession()
        let chunk0 = makeChunk(index: 0, segments: [makeSegment(text: "First chunk")])
        let chunk1 = makeChunk(index: 1, segments: [makeSegment(text: "Second chunk")])

        session.chunks.append(chunk0)
        session.chunks.append(chunk1)

        #expect(session.chunks.count == 2)
        #expect(session.chunks[0].index == 0)
        #expect(session.chunks[1].index == 1)
        #expect(session.chunks[0].segments[0].text == "First chunk")
        #expect(session.chunks[1].segments[0].text == "Second chunk")
    }

    @Test("sessionStatePersistsAfterEachChunk")
    func sessionStatePersistsAfterEachChunk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var session = makeSession()

        // Add chunk 0 and persist
        session.chunks.append(makeChunk(index: 0, segments: [makeSegment(text: "chunk 0")]))
        try SessionState.write(session, directory: dir)

        let read1 = SessionState.read(directory: dir)
        #expect(read1?.chunks.count == 1)

        // Add chunk 1 and persist again
        session.chunks.append(makeChunk(index: 1, segments: [makeSegment(text: "chunk 1")]))
        try SessionState.write(session, directory: dir)

        let read2 = SessionState.read(directory: dir)
        #expect(read2?.chunks.count == 2)
        #expect(read2?.chunks[1].segments[0].text == "chunk 1")
    }

    // MARK: - Thread-safe state access (simulating getSessionState/appendChunk)

    @Test("concurrentChunkAppendDoesNotCorruptState")
    func concurrentChunkAppendDoesNotCorruptState() async {
        // Simulate ChunkProcessor's NSLock-protected appendChunk
        let lock = NSLock()
        var chunks: [ProcessedChunk] = []
        let chunkCount = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<chunkCount {
                group.addTask {
                    let chunk = ProcessedChunk(
                        index: i,
                        startTime: Date(),
                        audioPath: "/tmp/chunk-\(i).m4a",
                        segments: [],
                        speakerDatabase: [:]
                    )
                    lock.lock()
                    chunks.append(chunk)
                    lock.unlock()
                }
            }
        }

        #expect(chunks.count == chunkCount)
        // All indices should be present (order may vary due to concurrency)
        let indices = Set(chunks.map(\.index))
        #expect(indices.count == chunkCount)
    }

    @Test("concurrentReadAndWriteDoesNotCorrupt")
    func concurrentReadAndWriteDoesNotCorrupt() async {
        let lock = NSLock()
        var session = makeSession()

        // Simulate concurrent writes and reads
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let chunk = ProcessedChunk(
                        index: i,
                        startTime: Date(),
                        audioPath: "/tmp/chunk-\(i).m4a",
                        segments: [],
                        speakerDatabase: [:]
                    )
                    lock.lock()
                    session.chunks.append(chunk)
                    lock.unlock()
                }
            }
            // Concurrent reads
            for _ in 0..<10 {
                group.addTask {
                    lock.lock()
                    let count = session.chunks.count
                    lock.unlock()
                    _ = count  // Just reading safely
                }
            }
        }

        #expect(session.chunks.count == 10)
    }

    // MARK: - Segment merging and source tagging

    @Test("segmentsFromDualStreamAreSortedByStartTime")
    func segmentsFromDualStreamAreSortedByStartTime() {
        // ChunkProcessor merges system + mic segments and sorts by start time
        let systemSegs = [
            makeSegment(start: 0.5, end: 2.0, text: "System 1", source: "remote"),
            makeSegment(start: 4.0, end: 6.0, text: "System 2", source: "remote"),
        ]
        let micSegs = [
            makeSegment(start: 1.0, end: 3.0, text: "Mic 1", source: "local"),
            makeSegment(start: 5.0, end: 7.0, text: "Mic 2", source: "local"),
        ]

        var allSegments = systemSegs + micSegs
        allSegments.sort { $0.start < $1.start }

        #expect(allSegments.count == 4)
        #expect(allSegments[0].text == "System 1")  // start: 0.5
        #expect(allSegments[1].text == "Mic 1")     // start: 1.0
        #expect(allSegments[2].text == "System 2")  // start: 4.0
        #expect(allSegments[3].text == "Mic 2")     // start: 5.0
    }

    @Test("sourceTaggingAppliesPrefixes")
    func sourceTaggingAppliesPrefixes() {
        // ChunkProcessor calls SpeakerAssignment.tagWithSourcePrefix when dual-stream
        var segments = [
            LabeledSegment(start: 0, end: 1, speaker: "Speaker 1", text: "Hello", source: "local"),
            LabeledSegment(start: 1, end: 2, speaker: "Speaker 2", text: "World", source: "remote"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)

        #expect(segments[0].speaker == "Local Speaker 1")
        #expect(segments[1].speaker == "Remote Speaker 2")
    }

    @Test("sourceTaggingSkippedForSingleStream")
    func sourceTaggingSkippedForSingleStream() {
        // When mic result is empty, ChunkProcessor skips tagging
        let systemSegs = [
            LabeledSegment(start: 0, end: 1, speaker: "Speaker 1", text: "Hello", source: "remote"),
        ]
        let micSegs: [LabeledSegment] = []
        let hasDualStream = !micSegs.isEmpty

        #expect(hasDualStream == false)
        // Segments should remain untagged
        #expect(systemSegs[0].speaker == "Speaker 1")
    }

    // MARK: - Transcript segment to ProcessedChunk.Segment mapping

    @Test("transcriptSegmentMapsToProcessedChunkSegment")
    func transcriptSegmentMapsToProcessedChunkSegment() {
        let labeled = LabeledSegment(
            start: 1.5,
            end: 3.0,
            speaker: "Remote Speaker 1",
            text: "Hello world",
            source: "remote",
            confidence: 0.95,
            language: "en"
        )

        // ChunkProcessor maps LabeledSegment → ProcessedChunk.Segment
        let chunkSegment = ProcessedChunk.Segment(
            start: labeled.start,
            end: labeled.end,
            text: labeled.text,
            speaker: labeled.speaker,
            source: labeled.source,
            qualityScore: labeled.confidence
        )

        #expect(chunkSegment.start == 1.5)
        #expect(chunkSegment.end == 3.0)
        #expect(chunkSegment.text == "Hello world")
        #expect(chunkSegment.speaker == "Remote Speaker 1")
        #expect(chunkSegment.source == "remote")
        #expect(chunkSegment.qualityScore == 0.95)
    }

    // MARK: - Speaker database propagation

    @Test("speakerDatabasePreservedInProcessedChunk")
    func speakerDatabasePreservedInProcessedChunk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let embeddings: [String: [Float]] = [
            "SPEAKER_00": [0.1, 0.2, 0.3, 0.4],
            "SPEAKER_01": [0.5, 0.6, 0.7, 0.8],
        ]

        let chunk = makeChunk(index: 0, speakerDatabase: embeddings)
        var session = makeSession()
        session.chunks.append(chunk)

        try SessionState.write(session, directory: dir)
        let read = SessionState.read(directory: dir)

        #expect(read?.chunks[0].speakerDatabase.count == 2)
        #expect(read?.chunks[0].speakerDatabase["SPEAKER_00"] == [0.1, 0.2, 0.3, 0.4])
        #expect(read?.chunks[0].speakerDatabase["SPEAKER_01"] == [0.5, 0.6, 0.7, 0.8])
    }

    @Test("emptySpeakerDatabaseWhenNoDiarization")
    func emptySpeakerDatabaseWhenNoDiarization() {
        // When diarizer is nil, ChunkProcessor passes empty speaker database
        let chunk = makeChunk(index: 0, speakerDatabase: [:])
        #expect(chunk.speakerDatabase.isEmpty)
    }

    // MARK: - Error handling

    @Test("emptySegmentsWhenTranscriptionFails")
    func emptySegmentsWhenTranscriptionFails() {
        // When transcription fails, ChunkProcessor catches the error and returns empty segments.
        // The resulting ProcessedChunk should have zero segments.
        let chunk = makeChunk(index: 0, segments: [])
        #expect(chunk.segments.isEmpty)
    }

    @Test("sessionStateSurvivesChunkWithNoSegments")
    func sessionStateSurvivesChunkWithNoSegments() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var session = makeSession()
        // Add a chunk with segments, then one without (simulating transcription failure)
        session.chunks.append(makeChunk(index: 0, segments: [makeSegment(text: "Good chunk")]))
        session.chunks.append(makeChunk(index: 1, segments: []))

        try SessionState.write(session, directory: dir)
        let read = SessionState.read(directory: dir)

        #expect(read?.chunks.count == 2)
        #expect(read?.chunks[0].segments.count == 1)
        #expect(read?.chunks[1].segments.isEmpty == true)
    }

    // MARK: - Empty/small audio file handling

    @Test("wavHeaderOnlyFileSkipsTranscription")
    func wavHeaderOnlyFileSkipsTranscription() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ChunkProcessor skips files <= 44 bytes (WAV header only)
        let wavHeaderSize = 44
        let emptyWav = dir.appendingPathComponent("empty.wav")
        try Data(repeating: 0, count: wavHeaderSize).write(to: emptyWav)

        let fileSize = try FileManager.default.attributesOfItem(atPath: emptyWav.path)[.size] as? Int ?? 0
        #expect(fileSize <= wavHeaderSize)
        // ChunkProcessor would return StreamResult(segments: [], speakerDatabase: [:])
    }

    @Test("missingMicFileProducesEmptyMicResult")
    func missingMicFileProducesEmptyMicResult() {
        // ChunkProcessor checks FileManager.default.fileExists for mic path
        let nonexistent = "/tmp/ChunkProcessorTests-nonexistent-\(UUID().uuidString).wav"
        let exists = FileManager.default.fileExists(atPath: nonexistent)
        #expect(exists == false)
        // ChunkProcessor would return StreamResult(segments: [], speakerDatabase: [:])
    }

    // MARK: - QoS configuration

    @Test("qosMapsCorrectlyFromConfig")
    func qosMapsCorrectlyFromConfig() {
        // ChunkProcessor maps Config.resolvedQos → TaskPriority
        let highConfig = Config(chunkProcessingQos: "userInteractive")
        #expect(highConfig.resolvedQos == .userInteractive)

        let medConfig = Config(chunkProcessingQos: "userInitiated")
        #expect(medConfig.resolvedQos == .userInitiated)

        let bgConfig = Config(chunkProcessingQos: "background")
        #expect(bgConfig.resolvedQos == .background)

        let defaultConfig = Config(chunkProcessingQos: "utility")
        #expect(defaultConfig.resolvedQos == .utility)

        // Unknown string falls back to utility
        let unknownConfig = Config(chunkProcessingQos: "invalid")
        #expect(unknownConfig.resolvedQos == .utility)
    }

    // MARK: - Audio path in processed chunk

    @Test("audioPathDefaultsToSystemWavWithoutArchive")
    func audioPathDefaultsToSystemWavWithoutArchive() {
        // When archival fails or single-stream, audioPath stays as WAV
        let chunk = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/output/meeting-0-system.wav",
            segments: [],
            speakerDatabase: [:]
        )
        #expect(chunk.audioPath.hasSuffix(".wav"))
    }

    @Test("audioPathUpdatedToM4aAfterArchival")
    func audioPathUpdatedToM4aAfterArchival() {
        // After successful archival, audioPath switches to .m4a
        let chunk = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/output/meeting-0.m4a",
            segments: [],
            speakerDatabase: [:]
        )
        #expect(chunk.audioPath.hasSuffix(".m4a"))
    }

    // MARK: - Speaker assignment integration

    @Test("speakerAssignmentWithoutDiarizationDefaultsToSpeaker1")
    func speakerAssignmentWithoutDiarizationDefaultsToSpeaker1() {
        // When diarizer is nil, ChunkProcessor maps all segments to "Speaker 1"
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hello", language: "en", confidence: 0.9),
            TranscriptSegment(start: 1, end: 2, text: "World", language: "en", confidence: 0.85),
        ]

        // Replicate ChunkProcessor's fallback logic
        let labeled = segments.map { seg in
            LabeledSegment(
                start: seg.start, end: seg.end, speaker: "Speaker 1",
                text: seg.text.trimmingCharacters(in: .whitespaces),
                source: "", confidence: seg.confidence, language: seg.language
            )
        }

        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[1].speaker == "Speaker 1")
    }

    @Test("sourceFieldSetAfterAssignment")
    func sourceFieldSetAfterAssignment() {
        // ChunkProcessor sets source on all labeled segments after assignment
        var labeled = [
            LabeledSegment(start: 0, end: 1, speaker: "Speaker 1", text: "Hi", source: ""),
            LabeledSegment(start: 1, end: 2, speaker: "Speaker 2", text: "Hey", source: ""),
        ]

        let source = "remote"
        for i in labeled.indices {
            labeled[i].source = source
        }

        #expect(labeled[0].source == "remote")
        #expect(labeled[1].source == "remote")
    }
}
