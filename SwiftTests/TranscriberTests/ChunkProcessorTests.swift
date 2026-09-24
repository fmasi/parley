import Testing
import Foundation
@testable import TranscriberCore

/// An engine whose transcribe() always throws (ASR failure path).
struct ThrowingEngine: TranscriptionEngine {
    let name = "Throwing"
    struct Boom: Error {}
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

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

    private func makeProcessor(dir: URL, engine: any TranscriptionEngine) -> ChunkProcessor {
        ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
            transcriber: engine, diarizer: FakeDiarizer())
    }
    private func chunk0(in dir: URL) -> ChunkRotator.FinalizedChunk {
        ChunkRotator.FinalizedChunk(index: 0, systemPath: dir.appendingPathComponent("meeting-0.wav").path,
                                    micPath: dir.appendingPathComponent("meeting-0_mic.wav").path, startTime: Date(timeIntervalSince1970: 0))
    }

    /// P3: an ASR failure used to become an empty chunk and "Transcription Complete".
    @Test func anAsrFailureIsRecordedAsAChunkIssueAndKeepsTheWav() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sysURL = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sysURL, seconds: 1)
        let processor = makeProcessor(dir: dir, engine: ThrowingEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .asrFailed, track: "remote", count: nil)))
        #expect(FileManager.default.fileExists(atPath: sysURL.path), "the WAV of an ASR-failed chunk is kept for re-transcription")
        // ...alongside a successful archive: keeping the WAV is not an archive failure.
        #expect(chunk.audioPath.hasSuffix(".m4a"))
        #expect(!chunk.issues.contains { $0.code == .archiveFailed })
    }

    /// §7.1/§9 (scan C13): an empty side is recorded, but it is not a "processing problem".
    @Test func anEmptyStreamIsRecordedButDoesNotAffectContent() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 0)   // 44-byte header
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        let issue = try #require(chunk.issues.first { $0.code == .streamEmpty })
        #expect(issue.track == "remote" && issue.affectsContent == false)
    }

    /// L6/L7 (scan B P3.2): the orphan re-ingested by the crash path and the same index arriving again
    /// from the rotator must not produce two chunks.
    @Test func processingTheSameChunkIndexTwiceAppendsOnce() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        await processor.processLastChunk(chunk0(in: dir))
        await processor.processLastChunk(chunk0(in: dir))
        processor.processChunk(chunk0(in: dir))
        await processor.awaitAllProcessed()
        #expect(await processor.getSessionState().chunks.map(\.index) == [0])
    }

    /// L10: a session.json that cannot be written is reported to the coordinator hook and recorded.
    @Test func aSessionWriteFailureIsReportedAndRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        final class Sink { var indices: [Int?] = [] }
        let reported = Sink()
        processor.onSessionWriteFailure = { reported.indices.append($0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)   // no new files in dir
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        await processor.processLastChunk(chunk0(in: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(reported.indices == [0])
        #expect(await processor.getSessionState().issues.contains(SessionIssue(chunk: 0, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))))
    }

    private func seededProcessor(dir: URL, seededAudioPath: String) -> ChunkProcessor {
        let seededChunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: seededAudioPath,
                                         segments: [], speakerDatabase: [:])
        return ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio",
                                       chunkDurationMinutes: 10, chunks: [seededChunk]),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
    }

    /// Critical (review round 1): a resumed session holds chunk 0; an incoming chunk 0 from a
    /// DIFFERENT recording file is not a duplicate. Skipping it silently lost every word after
    /// the resume. It is processed under a fresh index and the collision is recorded.
    @Test func aDifferentSourceIndexCollisionIsProcessedAndRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-1.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        let processor = seededProcessor(dir: dir, seededAudioPath: "meeting-0.m4a")
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: sys.path, micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
            startTime: Date(timeIntervalSince1970: 600)))
        let state = await processor.getSessionState()
        #expect(state.chunks.map(\.index) == [0, 1])
        let added = try #require(state.chunks.first { $0.index == 1 })
        #expect(added.issues.contains(ChunkIssue(code: .chunkIndexCollision, track: nil, count: 0)))
    }

    /// The seeded store's own chunk arriving again (crash re-ingest of the same file) is a true
    /// duplicate: skipped, and its WAV is not touched.
    @Test func aSameSourceSeededChunkIsSkipped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        let processor = seededProcessor(dir: dir, seededAudioPath: "meeting-0.m4a")
        await processor.processLastChunk(chunk0(in: dir))
        #expect(await processor.getSessionState().chunks.count == 1)
        #expect(FileManager.default.fileExists(atPath: sys.path), "a skipped duplicate is not archived")
    }

    /// Review round 1 item 4: a duplicate `processLastChunk` waits for the original rather than
    /// returning while it is still running.
    @Test func aDuplicateLastChunkWaitsForTheOriginal() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        struct SlowEngine: TranscriptionEngine {
            let name = "Slow"
            func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
                try await Task.sleep(for: .milliseconds(300))
                return [TranscriptSegment(start: 0, end: 1, text: "hi", language: "en")]
            }
            func isReady() -> Bool { true }
            func prepare() async throws {}
        }
        let processor = makeProcessor(dir: dir, engine: SlowEngine())
        processor.processChunk(chunk0(in: dir))
        await processor.processLastChunk(chunk0(in: dir))
        #expect(await processor.getSessionState().chunks.map(\.index) == [0])
    }

    /// Important (review round 1 item 2): a gap whose session.json write fails goes through the
    /// same hook (nil = session-level) and is recorded.
    @Test func aGapWriteFailureIsReportedAndRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        final class Sink { var indices: [Int?] = [] }
        let reported = Sink()
        processor.onSessionWriteFailure = { reported.indices.append($0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(reported.indices == [nil])
        #expect(await processor.getSessionState().issues.contains(SessionIssue(chunk: nil, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))))
    }

    /// Review round 1 item 6: a system WAV that does not exist is not an idle side.
    @Test func aMissingSystemWavIsStreamMissingNotEmpty() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let processor = makeProcessor(dir: dir, engine: FakeEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        let issue = try #require(chunk.issues.first { $0.code == .streamMissing })
        #expect(issue.track == "remote" && issue.affectsContent)
        #expect(!chunk.issues.contains { $0.code == .streamEmpty })
    }
}
