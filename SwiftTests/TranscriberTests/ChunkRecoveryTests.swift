import Foundation
import Testing
@testable import TranscriberCore

@Suite("ChunkRecovery")
struct ChunkRecoveryTests {

    @Test func recoveryWithPartialSessionJson() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 3 audio files on disk, but only 2 chunks in session.json
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
        let processedIndices = Set(loaded!.chunks.map(\.index))
        #expect(!processedIndices.contains(2))
    }

    @Test func recoveryWithNoSessionJson() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0...1 {
            try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("m-\(i).m4a"))
        }
        let loaded = SessionState.read(directory: dir)
        #expect(loaded == nil)
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
    }
}
