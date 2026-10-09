import Testing
import Foundation
@testable import TranscriberCore

/// #323 follow-up: `session.json` is written when a session's pipeline is set up (#294), not with its first chunk. A session
/// that ends with nothing to salvage — no chunk, no chunk file on disk — must not leave it behind: the next recording in the
/// folder would move it aside and record a spurious `session_file_displaced`, and the copy would keep that id's archives from
/// the storage limit for good.
@MainActor
@Suite struct ZeroChunkSessionStateTests {
    private final class NoRotationClient: ChunkRotationClient {
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            throw CancellationError()
        }
    }

    /// Never the real recordings folder, never a real limit (#313).
    private func sandboxed(_ dir: URL) -> Config {
        var config = Config.default
        config.recordingDirectory = dir.path
        config.audioArchiveLimitHours = 100_000
        return config
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zero-chunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sessionFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0 == "session.json" || ($0.hasPrefix("session-") && $0.hasSuffix(".json")) }.sorted()
    }

    /// A pipeline set up as a recording's start sets it up, its first write done — then the process goes before any chunk.
    private func startedThenGone(_ id: String, in dir: URL) async throws {
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoRotationClient(), outputDirectory: dir, sessionBaseName: id, config: sandboxed(dir))
        let processor = try #require(runner.chunkProcessor)
        await processor.awaitAllProcessed()
        runner.teardownChunkedPipeline()
        #expect(try sessionFiles(dir) == ["session.json"], "precondition: the empty state written at the start (#294)")
    }

    /// The recovery of a session that ended with no chunk and no audio (a relaunch's salvage, or a pending session's retry)
    /// removes its state; the next recording there displaces nothing; the storage limit is not held by a leftover.
    @Test func aSessionThatEndsWithNoChunkLeavesNoSessionFile() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Gotcha 85 (c): an id can start another's — `100000-a-2.m4a` is `100000-a`'s chunk 2 (finished, deletable) and also
        // what a `100000-a-2` session's state keeps.
        let finished = dir.appendingPathComponent("100000-a-2.m4a")
        try Data(count: 4096).write(to: finished)
        try await startedThenGone("100000-a-2", in: dir)

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "100000-a-2", config: sandboxed(dir),
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner())

        #expect(result == nil, "nothing to salvage")
        #expect(try sessionFiles(dir).isEmpty, "no session.json left behind")
        #expect(SessionState.sessionIdsWithState(in: dir) == [])

        // The storage limit: the finished recording's archive is deletable again.
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])
        #expect(report.deleted.map(\.lastPathComponent) == ["100000-a-2.m4a"])
        #expect(report.kept.isEmpty)

        // The next recording in the folder displaces nothing.
        let next = TranscriptionRunner()
        try next.setupChunkedPipeline(captureClient: NoRotationClient(), outputDirectory: dir, sessionBaseName: "110000-b", config: sandboxed(dir))
        defer { next.teardownChunkedPipeline() }
        let processor = try #require(next.chunkProcessor)
        await processor.awaitAllProcessed()
        #expect(!(await processor.getSessionState()).issues.contains { $0.issue.code == .sessionFileDisplaced })
        #expect(try sessionFiles(dir) == ["session.json"], "no moved-aside copy")
    }

    /// The coordinator's unsalvaged outcome — a Stop, a failed restart or a give-up with nothing on disk — removes the empty
    /// state an earlier process wrote at the start.
    @Test func aFailedRestartWithNothingOnDiskLeavesNoSessionFile() async throws {
        let h = try Harness()
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue,
                                            chunkDurationMinutes: 10, chunks: []), directory: outDir)
        h.client.startError = FakeCaptureError()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.criticalError == "Recording failed — could not restart capture: fake capture failure. "
                + RecoveryMessages.outcomeSentence(SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)))
        #expect(try sessionFiles(outDir).isEmpty, "no session.json left behind")
    }

    /// A Stop with no live pipeline (a recording re-attached after a relaunch) whose session has no chunk and no chunk file:
    /// the empty state the earlier process wrote at the start goes with it.
    @Test func aStopWithNoPipelineAndNothingOnDiskLeavesNoSessionFile() async throws {
        let h = try Harness()
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue,
                                            chunkDurationMinutes: 10, chunks: []), directory: outDir)
        h.client.stopResult = AudioPaths(systemAudio: URL(fileURLWithPath: sentinel.systemAudioPath),
                                         micAudio: URL(fileURLWithPath: sentinel.micAudioPath))
        h.appState.phase = .recording(since: Date())
        #expect(h.runner.chunkProcessor == nil, "precondition: no live pipeline in this process")

        await h.coordinator.stopRecording()

        #expect(h.client.stopCalls == 1)
        #expect(try sessionFiles(outDir).isEmpty, "no session.json left behind")
    }

    /// A relaunch's salvage of a recording that crashed before its first chunk was written: nothing to salvage, no state left.
    @Test func aLaunchSalvageWithNothingOnDiskLeavesNoSessionFile() async throws {
        let h = try Harness()
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue,
                                            chunkDurationMinutes: 10, chunks: []), directory: outDir)

        await h.coordinator.salvageAtLaunch(sentinel: sentinel, outputDir: outDir)

        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "settled")
        #expect(try sessionFiles(outDir).isEmpty, "no session.json left behind")
    }

    /// A recovery that finds nothing to salvage removes only THIS session's empty state — here a moved-aside copy — and never
    /// the other session's `session.json` beside it, still in flight.
    @Test func onlyThisSessionsStateIsRemoved() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = { (id: String) in SessionState(sessionId: id, meetingStart: Date(), engine: "fluidAudio", chunkDurationMinutes: 1, chunks: []) }
        try SessionState.write(empty("100000-mine"), directory: dir)
        try SessionState.write(empty("110000-other"), directory: dir)   // moves mine aside
        #expect(try sessionFiles(dir) == ["session-100000-mine.json", "session.json"], "precondition")

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "100000-mine", config: sandboxed(dir),
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner())

        #expect(result == nil)
        #expect(try sessionFiles(dir) == ["session.json"], "mine's copy goes")
        #expect(SessionState.sessionIdsWithState(in: dir) == ["110000-other"], "the other session's state is kept")
    }
}
