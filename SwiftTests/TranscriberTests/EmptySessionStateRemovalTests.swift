import Testing
import Foundation
@testable import TranscriberCore

/// #323 follow-up: `CrashRecoveryPlanner.removeEmptySessionState` / `SessionState.deleteIfEmpty` remove a session's state only
/// when it holds no chunk and no chunk file of it is on disk. Anything else keeps it all: when in doubt, keep and log.
@Suite struct EmptySessionStateRemovalTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func empty(_ id: String) -> SessionState {
        SessionState(sessionId: id, meetingStart: Date(), engine: "fluidAudio", chunkDurationMinutes: 1, chunks: [])
    }

    private func exists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    @Test func anEmptyStateWithNoAudioIsRemoved() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("m"), directory: dir)
        #expect(CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
        #expect(!exists(dir, "session.json"))
    }

    @Test func nothingThereIsNotAFailure() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
    }

    @Test func aStateThatHoldsAChunkIsKept() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(), chunkIndices: [0])
        #expect(!SessionState.deleteIfEmpty(directory: dir, sessionId: "m"))
        #expect(SessionState.read(directory: dir, sessionId: "m")?.chunks.count == 1)
    }

    @Test func aChunkFileOnDiskKeepsTheState() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("m"), directory: dir)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)
        #expect(!CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
        #expect(exists(dir, "session.json"))
    }

    @Test func aChunkArchiveOnDiskKeepsTheState() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("m"), directory: dir)
        try Data(count: 64).write(to: dir.appendingPathComponent("m-3.m4a"))
        #expect(!CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
        #expect(exists(dir, "session.json"))
    }

    @Test func anotherSessionsFileIsNeverTouched() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("other"), directory: dir)
        #expect(CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"), "none of m's state there")
        #expect(SessionState.read(directory: dir, sessionId: "other") != nil)
    }

    @Test func aStateThatCannotBeReadIsKept() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Its id reads (as a newer build's might), its shape does not decode here.
        try Data(#"{"sessionId":"m","chunks":"not a list"}"#.utf8).write(to: dir.appendingPathComponent("session.json"))
        #expect(!SessionState.deleteIfEmpty(directory: dir, sessionId: "m"))
        #expect(exists(dir, "session.json"))
    }

    /// One copy holding a chunk keeps every copy: the empty `session.json` and the moved-aside one alike.
    @Test func aMovedAsideCopyWithAChunkKeepsEveryCopy() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(), chunkIndices: [0])
        try SessionState.write(empty("other"), directory: dir)   // moves m's aside to session-m.json
        #expect(exists(dir, "session-m.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("session.json"))
        try SessionState.write(empty("m"), directory: dir)       // m's own, empty, in session.json again
        #expect(!SessionState.deleteIfEmpty(directory: dir, sessionId: "m"))
        #expect(exists(dir, "session.json") && exists(dir, "session-m.json"))
    }

    @Test func emptyMovedAsideCopiesGoWithIt() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("m"), directory: dir)
        try SessionState.write(empty("other"), directory: dir)   // m's moved aside
        #expect(CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
        #expect(!exists(dir, "session-m.json"))
        #expect(SessionState.read(directory: dir, sessionId: "other") != nil, "the other session's session.json stays")
    }

    @Test func aFinalizedSessionIsLeftToItsOwnCleanup() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(empty("m"), directory: dir)
        try SessionState.markFinalized(directory: dir, sessionId: "m", transcript: "m.json")
        #expect(!CrashRecoveryPlanner.removeEmptySessionState(outputDirectory: dir, sessionId: "m"))
        #expect(exists(dir, "session.json"))
    }
}
