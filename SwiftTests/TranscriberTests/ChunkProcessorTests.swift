import Testing
import Foundation
// Only the error type: FluidAudio's own `DiarizationResult` would make this file's bare name ambiguous.
import enum FluidAudio.OfflineDiarizationError
@testable import TranscriberCore

/// An engine whose transcribe() always throws (ASR failure path).
struct ThrowingEngine: TranscriptionEngine {
    let name = "Throwing"
    struct Boom: Error {}
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

/// An engine that hears no words: a track with audio and no speech (a muted mic, a listen-only call).
struct NoWordsEngine: TranscriptionEngine {
    let name = "NoWords"
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { [] }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

/// A diarizer that throws an error of its own: a diarizer failure that is not FluidAudio's "no speech" outcome.
struct ThrowingDiarizer: DiarizationProvider {
    struct NoSpeech: Error {}
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { throw NoSpeech() }
    func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { throw NoSpeech() }
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

    private func makeProcessor(dir: URL, engine: any TranscriptionEngine, diarizer: any DiarizationProvider = FakeDiarizer()) -> ChunkProcessor {
        ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
            transcriber: engine, diarizer: diarizer)
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

    /// Pre-PR review: a track with audio and no words has nothing to label, so it is not diarized. Diarizing it threw (no
    /// speech), and that was filed as a diarization failure — every listen-only call said its chunks had processing
    /// problems, and its transcript was stamped `diarization: false`.
    @Test func aStreamWithNoWordsIsNotADiarizationFailure() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: NoWordsEngine(), diarizer: ThrowingDiarizer())
        await processor.processLastChunk(chunk0(in: dir))
        let state = await processor.getSessionState()
        let chunk = try #require(state.chunks.first)
        #expect(!chunk.issues.contains { $0.code == .diarizationFailed })
        #expect(!chunk.issues.contains { $0.affectsContent }, "nothing for the completion notice to call a problem")
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
        let metadata = try #require(json?["metadata"] as? [String: Any])
        #expect(metadata["diarization"] as? Bool == true)
    }

    /// ...while a diarizer that throws on a stream that DOES have words is still a failure, and still recorded.
    @Test func aDiarizerThrowOnAStreamWithWordsIsStillRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = makeProcessor(dir: dir, engine: FakeEngine(), diarizer: ThrowingDiarizer())
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .diarizationFailed, track: "remote", count: nil)))
        #expect(chunk.segments.map(\.speaker) == [SpeakerAssignment.unknownSpeaker], "never a made-up Speaker 1")
    }

    /// Hears a line on each stream, different words per side so the echo check has nothing to match.
    private struct BothSidesEngine: TranscriptionEngine {
        let name = "BothSides"
        func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 5, text: audioSource == .system ? "yes" : "shall we start the review", language: "en")]
        }
        func isReady() -> Bool { true }
        func prepare() async throws {}
    }

    /// Throws `error` for the files named in `failing`; one speaker on any other.
    private struct ScriptedDiarizer: DiarizationProvider {
        let failing: Set<String>
        let error: OfflineDiarizationError
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            if failing.contains(audioPath.lastPathComponent) { throw error }
            return try await FakeDiarizer().diarize(audioPath: audioPath, numSpeakers: numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { throw error }
    }

    /// A 2-chunk dual-stream recording: both chunks have words on both sides; the diarizer throws `error` on chunk 1's
    /// system stream (the short last chunk of #302). Returns the session state and the finalized transcript.
    private func shortLastChunk(throwing error: OfflineDiarizationError) async throws
        -> (dir: URL, state: SessionState, transcript: URL) {
        let dir = try makeTempDir()
        for i in 0..<2 {
            try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-\(i).wav"), seconds: 1)
            try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-\(i)_mic.wav"), seconds: 1)
        }
        let processor = makeProcessor(dir: dir, engine: BothSidesEngine(),
                                      diarizer: ScriptedDiarizer(failing: ["meeting-1.wav"], error: error))
        for i in 0..<2 {
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(
                index: i, systemPath: dir.appendingPathComponent("meeting-\(i).wav").path,
                micPath: dir.appendingPathComponent("meeting-\(i)_mic.wav").path, startTime: Date(timeIntervalSince1970: Double(i) * 600)))
        }
        let state = await processor.getSessionState()
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        return (dir, state, result.jsonPath)
    }

    /// #302: FluidAudio's `noSpeechDetected` (NSError code 5) on a stream that HAS words — a short last chunk where the
    /// other side said a few words, too little speech for one embedding — is "too little speech to attribute", not a
    /// failure. The lines stay unattributed, the issue is informational, and the transcript stays diarized.
    @Test func tooLittleSpeechOnAShortLastChunkIsNotADiarizationFailure() async throws {
        #expect((OfflineDiarizationError.noSpeechDetected as NSError).code == 5, "the code the log shows for it")
        let (dir, state, transcript) = try await shortLastChunk(throwing: .noSpeechDetected)
        defer { try? FileManager.default.removeItem(at: dir) }

        let last = try #require(state.chunks.first { $0.index == 1 })
        #expect(!last.issues.contains { $0.code == .diarizationFailed })
        #expect(last.issues.contains(ChunkIssue(code: .diarizationTooLittleSpeech, track: "remote", count: nil)))
        #expect(!last.issues.contains { $0.affectsContent }, "nothing for the completion notice to call a problem")
        #expect(last.segments.filter { $0.source == "remote" }.map(\.speaker) == ["Remote Unknown"], "unattributed, never a made-up speaker")
        #expect(last.segments.filter { $0.source == "local" }.map(\.speaker) == ["Local Speaker 1"], "the other side is diarized as usual")

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["diarization"] as? Bool == true)
        #expect(metadata["processing_problem_chunks"] as? Int == 0)
        #expect(metadata["processing_issue_count"] as? Int == 0)
        #expect(CaptureQualityNotice.problemChunkCount(inTranscriptAt: transcript) == 0)
        let issues = try #require(metadata["processing_issues"] as? [[String: Any]])
        #expect(issues.contains { $0["code"] as? String == "diarization_too_little_speech" && $0["chunk"] as? Int == 1 && $0["track"] as? String == "remote" })
    }

    /// ...while any OTHER FluidAudio error on a stream with words is still a diarization failure: content-affecting, a
    /// problem chunk, and the transcript is not stamped diarized.
    @Test func anotherFluidAudioErrorOnAShortLastChunkIsStillADiarizationFailure() async throws {
        let (dir, state, transcript) = try await shortLastChunk(throwing: .processingFailed("synthetic"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let last = try #require(state.chunks.first { $0.index == 1 })
        #expect(last.issues.contains(ChunkIssue(code: .diarizationFailed, track: "remote", count: nil)))
        #expect(!last.issues.contains { $0.code == .diarizationTooLittleSpeech })
        #expect(last.segments.filter { $0.source == "remote" }.map(\.speaker) == ["Remote Unknown"])
        let metadata = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])?["metadata"] as? [String: Any])
        #expect(metadata["diarization"] as? Bool == false)
        #expect(metadata["processing_problem_chunks"] as? Int == 1)
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

    /// #242, end to end through the real processor: the mic hears what the system audio plays (the
    /// same numbered words 0.2 s later) for 48 s. Its segments are flagged, and the chunk keeps the
    /// cluster's verdict and an `echo_cluster` issue — in memory and in session.json.
    @Test func aBleedClusterIsFlaggedAndItsVerdictIsPersistedOnTheChunk() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0_mic.wav"), seconds: 1)
        struct BleedEngine: TranscriptionEngine {
            let name = "Bleed"
            func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
                let delay = audioSource == .microphone ? 0.2 : 0
                return (0..<6).map { i in
                    TranscriptSegment(start: Double(i) * 9 + delay, end: Double(i) * 9 + 8 + delay,
                                      text: EchoFixture.words(i * 100, 10), language: "en")
                }
            }
            func isReady() -> Bool { true }
            func prepare() async throws {}
        }
        // No diarizer: each stream is one speaker, with no embedding at all — the verdict needs none.
        let processor = ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: BleedEngine(), diarizer: nil)
        await processor.processLastChunk(chunk0(in: dir))

        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.segments.count == 12, "flagged, never deleted")
        #expect(chunk.segments.filter(\.echo).map(\.source) == Array(repeating: "local", count: 6))
        #expect(chunk.echoSegmentsFlagged == 6)
        #expect(chunk.echoClusters.map(\.label) == ["Local Speaker 1"])
        let verdict = try #require(chunk.echoClusters.first)
        #expect(verdict.verdict == .echo && verdict.segments == 6 && verdict.matchedSegments == 6 && verdict.share == 1)
        #expect(abs(verdict.seconds - 48) < 0.001 && verdict.words == 60 && verdict.bestEmbeddingSimilarity == nil)
        #expect(verdict.matchedRemote.keys.sorted() == ["Remote Speaker 1"])
        #expect(chunk.issues.contains(ChunkIssue(code: .echoFlagged, track: "local", count: 6)))
        #expect(chunk.issues.contains(ChunkIssue(code: .echoCluster, track: "local", count: 1)))

        let stored = try #require(SessionState.read(directory: dir, sessionId: "meeting")?.chunks.first)
        #expect(stored.echoClusters == chunk.echoClusters && stored.echoSegmentsFlagged == 6)
        #expect(stored.issues.contains(ChunkIssue(code: .echoCluster, track: "local", count: 1)))
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
                           state: SessionState? = nil, scratch: URL? = nil) -> ChunkProcessor {
        var config = Config.default
        config.preserveSourceWAV = preserve
        return ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: state ?? SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: engine, diarizer: FakeDiarizer(), scratchDirectory: scratch ?? FileManager.default.temporaryDirectory)
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
    /// (a late rotation reply) was processed but left out of the final merge. No sleeps (R2a M9):
    /// gates decide when each chunk's recognition may finish.
    @Test func awaitAllProcessedCoversAChunkScheduledWhileWaiting() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-1.wav"), seconds: 1)
        let gates = Gates()
        let processor = processor(dir: dir, engine: GatedEngine(gates: gates))
        processor.processChunk(chunk0(in: dir))
        await gates.arrival("meeting-0")
        let waiter = Task { @MainActor in
            await processor.awaitAllProcessed()
            return await processor.getSessionState().chunks.map(\.index)
        }
        await Task.yield()   // the waiter (main actor, enqueued first) is now awaiting chunk 0
        processor.processChunk(ChunkRotator.FinalizedChunk(index: 1, systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                                           micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
                                                           startTime: Date(timeIntervalSince1970: 600)))
        // Chunk 1 may finish only once chunk 0 is persisted: a waiter that stops at chunk 0 returns first.
        processor.onSessionWriteSucceeded = { Task { await gates.open("meeting-1") } }
        await gates.open("meeting-0")
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
        // Round 3 item 9: this test's own scratch parent, so a parallel test can't make it fail.
        let scratch = try makeTempDir(); defer { try? FileManager.default.removeItem(at: scratch) }
        let processor = processor(dir: dir, scratch: scratch)
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.audioPath == "meeting-0.m4a")
        #expect(chunk.segments.map(\.text) == ["hello"], "the words come back from the archive")
        #expect(chunk.issues.contains(ChunkIssue(code: .transcribedFromArchive, track: nil, count: nil)))
        #expect(!chunk.issues.contains { $0.affectsContent }, "nothing was lost: \(chunk.issues)")
        #expect(try Data(contentsOf: archive) == before, "the only copy is never re-encoded")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["meeting-0.m4a", "session.json"],
                "nothing else in the folder")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "no scratch audio is left behind")
    }

    // MARK: - R2b item 11

    /// C-M4: a chunk with no mic WAV became remote-only with nothing said. It is recorded — as
    /// information (a system-only source is legitimate; `capture.local` holds the coverage).
    @Test func aChunkWithoutAMicWavSaysSo() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = processor(dir: dir)
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .micStreamAbsent, track: "local", count: nil)))
        #expect(!ChunkIssue.Code.micStreamAbsent.affectsContent)
    }

    /// C-M9 / round 7 item 1: the storage quota NEVER deletes the audio of the session being
    /// processed — its earlier chunk archives and a merged `<id>.m4a` from an earlier finalize (the
    /// only copy of the chunks it holds). Another recording's old archive can still go.
    @Test func theQuotaNeverDeletesThisSessionsAudio() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = dir.appendingPathComponent("meeting-0.m4a"), merged = dir.appendingPathComponent("meeting.m4a")
        let otherRecording = dir.appendingPathComponent("older-0.m4a")
        for url in [earlier, merged, otherRecording] {
            try Data(count: 4096).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
        }
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-1.wav"), seconds: 1)
        var config = Config.default
        config.audioArchiveLimitHours = 0
        let seeded = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "meeting-0.m4a", segments: [], speakerDatabase: [:])
        let processor = ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio",
                                       chunkDurationMinutes: 10, chunks: [seeded]),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: 1, systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                                                     micPath: dir.appendingPathComponent("meeting-1_mic.wav").path,
                                                                     startTime: Date(timeIntervalSince1970: 600)))
        #expect(!FileManager.default.fileExists(atPath: otherRecording.path), "the quota really ran")
        #expect(FileManager.default.fileExists(atPath: earlier.path), "this session's earlier chunk archive is kept")
        #expect(FileManager.default.fileExists(atPath: merged.path), "this session's merged audio is kept")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-1.m4a").path))
    }

    // MARK: - R2 round 2 (R2a M2, M4, M5)

    /// R2a M2: the system WAV gone and the archive present is archive-only whatever the mic WAV —
    /// the archiver deleted the system WAV and died before the mic one. The archive is transcribed as
    /// is; the leftover mic WAV is cleaned up once the chunk is persisted (preserve_source_wav off).
    @Test func aMissingSystemWavWithAnArchiveIsArchiveOnlyWhateverTheMicWav() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        let archive = try await AudioArchiver.archive(systemAudio: sys, micAudio: mic, outputDirectory: dir, bitrateKbps: 64,
                                                      preserveSourceWAV: true).archivePath
        try FileManager.default.removeItem(at: sys)
        let before = try Data(contentsOf: archive)
        let processor = processor(dir: dir)
        await processor.processLastChunk(chunk0(in: dir))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.audioPath == "meeting-0.m4a" && chunk.issues.contains(ChunkIssue(code: .transcribedFromArchive, track: nil, count: nil)))
        #expect(chunk.isDualStream, "a mic WAV was there: the chunk had a mic stream")
        #expect(try Data(contentsOf: archive) == before, "never re-archived over itself")
        #expect(!FileManager.default.fileExists(atPath: mic.path), "the leftover mic WAV goes once the chunk is persisted")
    }

    /// R2a M4: the success and failure hooks run on the main actor from different tasks, so an older
    /// write's success could land after a newer write's failure and clear the alarm. Deliveries carry
    /// the write's sequence number; one older than the last delivered is dropped.
    @Test func anOutOfOrderWriteOutcomeIsDropped() {
        let processor = processor(dir: FileManager.default.temporaryDirectory)
        final class Sink { var events: [String] = [] }
        let sink = Sink()
        processor.onSessionWriteSucceeded = { sink.events.append("ok") }
        processor.onSessionWriteFailure = { sink.events.append("failed \($0.map(String.init) ?? "-")") }
        processor.deliverWriteOutcome(sequence: 2, failedChunk: .some(3))
        processor.deliverWriteOutcome(sequence: 1, failedChunk: nil)        // older success, late
        processor.deliverWriteOutcome(sequence: 3, failedChunk: nil)
        processor.deliverWriteOutcome(sequence: 3, failedChunk: nil)        // the same one twice
        #expect(sink.events == ["failed 3", "ok"])
    }

    /// R2a M5: another live recording writing the folder's session.json after us displaces us, and we
    /// displace it back — one `session_file_displaced` per displaced session, not one per write.
    @Test func aDisplacedSessionIsRecordedOncePerSession() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "morning", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0])
        let processor = processor(dir: dir)
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), reason: "sleep"))
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "morning", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1])
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 3), end: Date(timeIntervalSince1970: 4), reason: "sleep"))
        let issues = try #require(SessionState.read(directory: dir, sessionId: "meeting")).issues
        #expect(issues.filter { $0.issue.code == .sessionFileDisplaced }.count == 1)
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 2)
    }

    /// R2a M5: the chunk WAS persisted (the first write); only the second write, the one carrying the
    /// displacement note, failed. That is not a failed session write: no alarm, no issue, WAVs go.
    @Test func aFailedFollowUpWriteAfterADisplacementIsNotASessionWriteFailure() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "morning", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("meeting-0.wav"), seconds: 1)
        let processor = processor(dir: dir)
        final class Sink { var failures: [Int?] = []; var successes = 0 }
        let sink = Sink()
        processor.onSessionWriteFailure = { sink.failures.append($0) }
        processor.onSessionWriteSucceeded = { sink.successes += 1 }
        await processor.failSessionWritesForTesting(after: 1)
        await processor.processLastChunk(chunk0(in: dir))
        #expect(sink.failures.isEmpty && sink.successes == 1)
        #expect(SessionState.read(directory: dir, sessionId: "meeting")?.chunks.map(\.audioPath) == ["meeting-0.m4a"])
        #expect(!(await processor.getSessionState().issues.contains { $0.issue.code == .sessionWriteFailed }))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-0.wav").path))
    }
}

/// Lets a test decide when each chunk's recognition may finish: `pass` blocks until the gate named
/// after the audio file is opened; `arrival` waits until a chunk has reached its gate.
actor Gates {
    private var opened: Set<String> = []
    private var arrived: Set<String> = []
    private var blocked: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var watchers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func pass(_ name: String) async {
        arrived.insert(name)
        watchers.removeValue(forKey: name)?.forEach { $0.resume() }
        guard !opened.contains(name) else { return }
        await withCheckedContinuation { blocked[name, default: []].append($0) }
    }

    func open(_ name: String) {
        opened.insert(name)
        blocked.removeValue(forKey: name)?.forEach { $0.resume() }
    }

    func arrival(_ name: String) async {
        guard !arrived.contains(name) else { return }
        await withCheckedContinuation { watchers[name, default: []].append($0) }
    }
}

struct GatedEngine: TranscriptionEngine {
    let name = "Gated"
    let gates: Gates
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        await gates.pass(audioPath.deletingPathExtension().lastPathComponent)
        return [TranscriptSegment(start: 0, end: 1, text: "hi", language: "en")]
    }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}
