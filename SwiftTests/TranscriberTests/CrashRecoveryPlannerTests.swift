import Testing
import Foundation
@testable import TranscriberCore

struct CrashRecoveryPlannerTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryPlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func orphansAreWavsNotInSessionJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)

        #expect(
            CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0, 1])
                == [.init(index: 2, baseName: "m-2")]
        )
    }

    @Test func multipleUnprocessedWavsAllReturnedAscending() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)

        #expect(
            CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0]).map(\.index)
                == [1, 2]
        )
    }

    @Test func completedChunkWavIsNotAnOrphan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)

        #expect(
            CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: [0]).isEmpty
        )
    }

    @Test func recoverableWhenSessionJSONHasChunks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0]
        )

        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
    }

    @Test func notRecoverableWhenNothingOnDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
    }
}
