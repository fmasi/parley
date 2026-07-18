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

    // The first-rotation crash (#135): the recording died before `AudioArchiver` finished the
    // first chunk, so only `<sessionId>-0.wav` exists and there is NO `session.json`. This is the
    // primary path the whole feature guards — recoverability must still be true from the orphan
    // WAV alone. Covered end-to-end by `ChunkedSessionRecoveryTests`; asserted here directly on
    // the predicate that gates whether recovery runs at all.
    @Test func recoverableFromOrphanOnlyWhenNoSessionJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)

        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
    }

    // MARK: - nextFreeChunkIndex (#135 — restart naming must never collide with the chunk
    // namespace: a restart named with a colliding index either gets dropped as "already
    // completed" or, worse, truncates the in-progress chunk's WAV on create).

    @Test func nextFreeIndexIsBeyondCompletedAndOnDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1, 2]
        )
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-3.wav"), seconds: 1)

        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 4)
    }

    @Test func nextFreeIndexIsZeroWhenEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 0)
    }

    @Test func nextFreeIndexSkipsPastGaps() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1, 2, 5]
        )

        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 6)
    }

    @Test func nextFreeIndexFromDiskOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-3.wav"), seconds: 1)

        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 4)
    }

    @Test func nextFreeIndexAvoidsCollisionWithCompletedIndex() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1, 2]
        )
        // A collision file: a WAV named after an already-completed index (mirrors mode 1 of #135) —
        // it adds nothing beyond what session.json already reports, so the formula
        // (1 + max(completed ∪ on-disk)) correctly falls back to the completed max (2) and
        // returns 3. That still satisfies "avoids collision": 3 doesn't match any index already
        // in use (0, 1, 2), unlike a naive scheme that might repeat 2 or 3-via-segment-counter.
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)

        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 3)
    }
}
