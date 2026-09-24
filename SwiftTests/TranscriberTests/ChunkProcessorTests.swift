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
        #expect(await processor.getSessionState().issues.isEmpty, "a same-index duplicate is not an issue")
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

    /// R3 review round 1: an abutting repeat is kept and flagged (`duplicates_flagged`), a
    /// zero-length segment is dropped and counted under its own code.
    @Test func repeatsAreFlaggedAndZeroLengthIsCountedSeparately() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        struct RepeatingEngine: TranscriptionEngine {
            let name = "Repeating"
            func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
                [TranscriptSegment(start: 0, end: 1, text: "No.", language: "en"),
                 TranscriptSegment(start: 1.1, end: 2, text: "No.", language: "en"),
                 TranscriptSegment(start: 3, end: 3, text: "x", language: "en")]
            }
            func isReady() -> Bool { true }
            func prepare() async throws {}
        }
        let processor = makeProcessor(dir: dir, engine: RepeatingEngine())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .duplicatesFlagged, track: "remote", count: 1)))
        #expect(chunk.issues.contains(ChunkIssue(code: .zeroLengthDropped, track: "remote", count: 1)))
        #expect(chunk.segments.count == 2)
        #expect(chunk.segments.filter(\.duplicate).map(\.text) == ["No."])
    }

    /// R5: a quota delete that fails no longer relabels an archived chunk as "archival failed".
    @Test func aQuotaFailureDoesNotRelabelAnArchivedChunk() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let old = locked.appendingPathComponent("old.m4a")
        try Data(count: 1024).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        var config = Config.default
        config.audioArchiveLimitHours = 0   // every archive is over quota → the locked file's delete throws
        let processor = ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        await processor.processLastChunk(chunk0(in: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.audioPath == "meeting-0.m4a")
        #expect(!chunk.issues.contains { $0.code == .archiveFailed })
        #expect(FileManager.default.fileExists(atPath: old.path), "the quota delete really failed")
    }

    /// Round 3 item 1: a file already processed under ANOTHER index (a collided chunk, re-indexed)
    /// arriving again — e.g. a relaunch orphan scan re-ingesting its preserved WAV — is a duplicate.
    @Test func aKnownSourceUnderAnotherIndexIsSkipped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-1.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        let reindexed = ProcessedChunk(index: 5, startTime: Date(timeIntervalSince1970: 0), audioPath: "meeting-1.m4a",
                                       segments: [], speakerDatabase: [:])
        let processor = ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio",
                                       chunkDurationMinutes: 10, chunks: [reindexed]),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 1, systemPath: sys.path, micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
            startTime: Date(timeIntervalSince1970: 600)))
        #expect(await processor.getSessionState().chunks.map(\.index) == [5])
        #expect(FileManager.default.fileExists(atPath: sys.path), "a skipped duplicate is not archived")
        // Round 5: a duplicate arriving under ANOTHER index is recorded (count = the incoming index).
        #expect(await processor.getSessionState().issues
                == [SessionIssue(chunk: 5, issue: ChunkIssue(code: .duplicateSourceOtherIndex, track: nil, count: 1))])
        #expect(!ChunkIssue.Code.duplicateSourceOtherIndex.affectsContent)
    }

    // MARK: - R2 council

    private func processor(dir: URL, preserve: Bool = false, engine: any TranscriptionEngine = FakeEngine(),
                           state: SessionState? = nil) -> ChunkProcessor {
        var config = Config.default
        config.preserveSourceWAV = preserve
        return ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: state ?? SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: engine, diarizer: FakeDiarizer())
    }

    /// C-I4: the WAVs used to be deleted before the chunk reached session.json, so a crash in that
    /// window dropped the chunk. At the moment session.json first holds the chunk (with its .m4a),
    /// its WAVs must still be on disk; only after that are they deleted.
    @Test func theChunkIsPersistedBeforeItsWavsAreDeleted() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        let processor = processor(dir: dir)
        final class Probe { var atWrite: [(persisted: [String], wavs: Bool)] = [] }
        let probe = Probe()
        processor.onSessionWriteSucceeded = {
            let persisted = SessionState.read(directory: dir)?.chunks.map(\.audioPath) ?? []
            probe.atWrite.append((persisted, FileManager.default.fileExists(atPath: sys.path) && FileManager.default.fileExists(atPath: mic.path)))
        }
        await processor.processLastChunk(chunk0(in: dir))
        #expect(probe.atWrite.count == 1)
        #expect(probe.atWrite.first?.persisted == ["meeting-0.m4a"])
        #expect(probe.atWrite.first?.wavs == true, "both WAVs still on disk when the chunk was first persisted")
        #expect(!FileManager.default.fileExists(atPath: sys.path) && !FileManager.default.fileExists(atPath: mic.path),
                "then deleted: preserve_source_wav is off")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-0.m4a").path))
    }

    /// C-I4: a chunk that could not be persisted keeps its WAVs — they are the only copy recovery can find.
    @Test func aChunkThatCouldNotBePersistedKeepsItsWavs() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        let processor = processor(dir: dir)
        await processor.failSessionWritesForTesting()
        await processor.processLastChunk(chunk0(in: dir))
        #expect(FileManager.default.fileExists(atPath: sys.path) && FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-0.m4a").path), "the archive itself succeeded")
        #expect(await processor.getSessionState().issues.contains(SessionIssue(chunk: 0, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))))
    }

    /// Stream L clears the sticky `sessionWriteFailed` alarm on the next good write: the success hook
    /// fires after every successful session.json write (chunk and gap), never after a failed one.
    @Test func onSessionWriteSucceededFiresAfterEverySuccessfulWrite() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = processor(dir: dir)
        final class Sink { var successes = 0; var failures: [Int?] = [] }
        let sink = Sink()
        processor.onSessionWriteSucceeded = { sink.successes += 1 }
        processor.onSessionWriteFailure = { sink.failures.append($0) }
        await processor.processLastChunk(chunk0(in: dir))
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
        #expect(sink.successes == 2 && sink.failures.isEmpty)
        await processor.failSessionWritesForTesting()
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 5), end: Date(timeIntervalSince1970: 6), reason: "sleep"))
        #expect(sink.successes == 2 && sink.failures == [nil], "a failed write is not a success")
    }

    /// B-I3: `awaitAllProcessed` snapshotted its task list once, so a chunk scheduled while it waited
    /// (a late rotation reply) was processed but left out of the final merge.
    @Test func awaitAllProcessedCoversAChunkScheduledWhileWaiting() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-1.wav"), seconds: 1)
        struct SlowEngine: TranscriptionEngine {
            let name = "Slow"
            func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
                try await Task.sleep(for: .milliseconds(400))
                return [TranscriptSegment(start: 0, end: 1, text: "hi", language: "en")]
            }
            func isReady() -> Bool { true }
            func prepare() async throws {}
        }
        let processor = processor(dir: dir, engine: SlowEngine())
        processor.processChunk(chunk0(in: dir))
        let waiter = Task { @MainActor in
            await processor.awaitAllProcessed()
            return await processor.getSessionState().chunks.map(\.index)
        }
        try await Task.sleep(for: .milliseconds(150))   // the waiter is now awaiting chunk 0
        processor.processChunk(ChunkRotator.FinalizedChunk(index: 1, systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                                           micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
                                                           startTime: Date(timeIntervalSince1970: 600)))
        #expect(await waiter.value.sorted() == [0, 1])
    }

    /// C-I3: this processor's first write lands on a day folder whose session.json belongs to another,
    /// unfinalized recording. That file is moved aside (not overwritten) and the move is recorded.
    @Test func aDisplacedSessionIsMovedAsideAndRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "morning", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1])
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = processor(dir: dir)
        await processor.processLastChunk(chunk0(in: dir))
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 2, "the other session survives, aside")
        let mine = try #require(SessionState.read(directory: dir, sessionId: "meeting"))
        #expect(mine.issues == [SessionIssue(chunk: nil, issue: ChunkIssue(code: .sessionFileDisplaced, track: nil, count: nil))],
                "the displacement is persisted with this session")
        #expect(!ChunkIssue.Code.sessionFileDisplaced.affectsContent, "nothing of this recording is missing")
    }

    /// C-I4 (orphan side): a chunk whose WAVs are gone but whose .m4a exists — the crash window of a
    /// build that deleted the WAVs first — is transcribed from its archive, which is kept as-is.
    @Test func anArchiveOnlyChunkIsTranscribedFromItsM4a() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        let archive = try await AudioArchiver.archiveSystemOnly(systemAudio: sys, outputDirectory: dir, bitrateKbps: 64).archivePath
        #expect(!FileManager.default.fileExists(atPath: sys.path))
        let before = try Data(contentsOf: archive)
        let processor = processor(dir: dir)
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.audioPath == "meeting-0.m4a")
        #expect(chunk.segments.map(\.text) == ["hello"], "the words come back from the archive")
        #expect(chunk.issues.contains(ChunkIssue(code: .transcribedFromArchive, track: nil, count: nil)))
        #expect(!chunk.issues.contains { $0.affectsContent }, "nothing was lost: \(chunk.issues)")
        #expect(try Data(contentsOf: archive) == before, "the only copy is never re-encoded")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["meeting-0.m4a", "session.json"],
                "no scratch audio is left behind")
    }
}
