import Testing
import Foundation
@testable import TranscriberCore

@Suite("ChunkSession")
struct ChunkSessionTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeSegment() -> ProcessedChunk.Segment {
        ProcessedChunk.Segment(
            start: 0.0,
            end: 5.5,
            text: "Hello world",
            speaker: "SPEAKER_00",
            source: "microphone",
            qualityScore: 0.95
        )
    }

    private func makeChunk(index: Int = 0) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: "/tmp/chunk-\(index).wav",
            segments: [makeSegment()],
            speakerDatabase: ["SPEAKER_00": [0.1, 0.2, 0.3]]
        )
    }

    private func makeSession(chunks: [ProcessedChunk] = []) -> SessionState {
        SessionState(
            sessionId: "session-abc",
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000),
            engine: "fluidAudio",
            chunkDurationMinutes: 5,
            chunks: chunks
        )
    }

    // MARK: - Tests

    @Test("processedChunkEncodesAndDecodes")
    func processedChunkEncodesAndDecodes() throws {
        let chunk = makeChunk()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chunk)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProcessedChunk.self, from: data)

        #expect(decoded.index == chunk.index)
        #expect(decoded.audioPath == chunk.audioPath)
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments[0].text == "Hello world")
        #expect(decoded.segments[0].speaker == "SPEAKER_00")
        #expect(decoded.segments[0].qualityScore == 0.95)
        #expect(decoded.speakerDatabase["SPEAKER_00"] == [0.1, 0.2, 0.3])
    }

    @Test("sessionStateAtomicWriteAndRead")
    func sessionStateAtomicWriteAndRead() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession(chunks: [makeChunk()])
        try SessionState.write(session, directory: dir)

        let read = SessionState.read(directory: dir)
        #expect(read != nil)
        #expect(read?.sessionId == "session-abc")
        #expect(read?.engine == "fluidAudio")
        #expect(read?.chunkDurationMinutes == 5)
        #expect(read?.chunks.count == 1)
        #expect(read?.chunks[0].audioPath == "/tmp/chunk-0.wav")
    }

    @Test("sessionStateAccumulatesChunks")
    func sessionStateAccumulatesChunks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write with zero chunks
        var session = makeSession(chunks: [])
        try SessionState.write(session, directory: dir)

        // Add a chunk and write again
        session = SessionState(
            sessionId: session.sessionId,
            meetingStart: session.meetingStart,
            engine: session.engine,
            chunkDurationMinutes: session.chunkDurationMinutes,
            chunks: [makeChunk(index: 0), makeChunk(index: 1)]
        )
        try SessionState.write(session, directory: dir)

        let read = SessionState.read(directory: dir)
        #expect(read?.chunks.count == 2)
        #expect(read?.chunks[0].index == 0)
        #expect(read?.chunks[1].index == 1)
    }

    @Test("sessionStateMissingFileReturnsNil")
    func sessionStateMissingFileReturnsNil() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkSessionTests-nonexistent-\(UUID().uuidString)")
        let result = SessionState.read(directory: dir)
        #expect(result == nil)
    }

    @Test("sessionStateDeleteRemovesFile")
    func sessionStateDeleteRemovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession()
        try SessionState.write(session, directory: dir)

        // Verify it exists
        #expect(SessionState.read(directory: dir) != nil)

        // Delete and verify gone
        SessionState.delete(directory: dir)
        #expect(SessionState.read(directory: dir) == nil)
    }
}
