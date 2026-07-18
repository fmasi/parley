import Testing
import Foundation
@testable import TranscriberCore

/// Drives the real (now-Core) `ChunkProcessor` with the shared `FakeEngine`/`FakeDiarizer` from
/// `ChunkedSessionRecoveryTests`, replacing the old hand-copied characterization suite that never
/// touched the actual class.
@MainActor
struct ChunkProcessorTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkProcessorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func processingOneChunkGrowsSessionStateByOne() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sysURL = dir.appendingPathComponent("meeting-0.wav")
        // No mic WAV written — chunk.micPath below points at a file that doesn't exist, so
        // ChunkProcessor takes the system-only (non-dual-stream) path.
        let micURL = dir.appendingPathComponent("meeting-0_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sysURL, seconds: 1)

        let seeded = SessionState(
            sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
            engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []
        )
        let processor = ChunkProcessor(
            config: .default, outputDirectory: dir, sessionState: seeded,
            transcriber: FakeEngine(), diarizer: FakeDiarizer()
        )

        #expect(await processor.getSessionState().chunks.isEmpty)

        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: sysURL.path, micPath: micURL.path,
            startTime: Date(timeIntervalSince1970: 0)
        ))

        let state = await processor.getSessionState()
        #expect(state.chunks.count == 1)
        #expect(state.chunks.first?.index == 0)
    }

    @Test func processingTwoChunksAppendsBothInOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sys0 = dir.appendingPathComponent("meeting-0.wav")
        let sys1 = dir.appendingPathComponent("meeting-1.wav")
        try RecoveryFixtures.writeFakeWav(at: sys0, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: sys1, seconds: 1)

        let seeded = SessionState(
            sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
            engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []
        )
        let processor = ChunkProcessor(
            config: .default, outputDirectory: dir, sessionState: seeded,
            transcriber: FakeEngine(), diarizer: FakeDiarizer()
        )

        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: sys0.path, micPath: dir.appendingPathComponent("meeting-0_mic.wav").path,
            startTime: Date(timeIntervalSince1970: 0)
        ))
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 1, systemPath: sys1.path, micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
            startTime: Date(timeIntervalSince1970: 600)
        ))

        let state = await processor.getSessionState()
        #expect(state.chunks.map(\.index) == [0, 1])
    }
}
