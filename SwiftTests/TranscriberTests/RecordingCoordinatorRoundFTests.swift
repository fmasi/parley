import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round F (items 219–234). The fake client and the harness are RecordingCoordinatorTests.swift's; `HungRead` is
// RecordingCoordinatorRoundCTests.swift's; `NotReadyEngine` is RecordingCoordinatorRoundDTests.swift's.

/// A pending session `name` in `folder` of `h`: chunk 0 transcribed in its session.json and — `orphan` — a chunk 1 on disk
/// that is not (it needs the engine).
@MainActor
func roundFPendingSession(_ h: Harness, _ name: String, in folder: String? = nil, orphan: Bool = false) throws -> RecordingSentinel {
    let dir = h.tmp.appendingPathComponent(folder ?? name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0])
    if orphan { try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("\(name)-1.wav"), seconds: 1) }
    return RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                             micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
}

@MainActor
func roundFTearDown(_ h: Harness) {
    h.runner.stopChunkRotation()
    h.runner.teardownChunkedPipeline()
    try? FileManager.default.removeItem(at: h.tmp)
}

// MARK: - The airgap: SpeechAnalyzer never downloads implicitly (229)

/// The speech models, faked (L review 229): which locales are installed and supported, and every install asked for.
final class FakeSpeechInventory: SpeechAssetInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var installedValue: [String]
    private var installsValue: [String] = []
    let supported: [String]
    init(installed: [String] = [], supported: [String] = ["en-US", "pt-BR"]) {
        installedValue = installed
        self.supported = supported
    }
    var installs: [String] { lock.withLock { installsValue } }
    func installedLocales() async -> [String] { lock.withLock { installedValue } }
    func supportedLocales() async -> [String] { supported }
    func install(locale: String) async throws {
        lock.withLock {
            installsValue.append(locale)
            installedValue.append(locale)
        }
    }
}

#if compiler(>=6.2)
@MainActor
@Suite struct SpeechAnalyzerAirgapRoundFTests {
    /// L review 229: ready only when its language's model is INSTALLED — a look at the installed locales. Without a
    /// language it can never transcribe, so it is never ready.
    @Test func speechAnalyzerIsReadyOnlyWithItsLanguagesModelInstalled() async {
        guard #available(macOS 26.0, *) else { return }
        #expect(await SpeechAnalyzerEngine(language: "en", inventory: FakeSpeechInventory()).isReady() == false)
        #expect(await SpeechAnalyzerEngine(language: "en", inventory: FakeSpeechInventory(installed: ["en-US"])).isReady())
        #expect(await SpeechAnalyzerEngine(inventory: FakeSpeechInventory(installed: ["en-US"])).isReady() == false, "no language")
        let reason = await SpeechAnalyzerEngine(language: "pt", inventory: FakeSpeechInventory()).notReadyReason()
        #expect(reason.contains("pt-BR") && reason.contains("not installed"), "\(reason)")
    }

    /// L review 229, IMPORTANT: a transcription whose model is not installed throws — it never downloads one (the airgap).
    /// The file is never even opened.
    @Test func aTranscriptionNeverDownloadsAMissingModel() async throws {
        guard #available(macOS 26.0, *) else { return }
        let inventory = FakeSpeechInventory()
        let engine = SpeechAnalyzerEngine(language: "en", inventory: inventory)
        await #expect(throws: SpeechAnalyzerError.self) {
            _ = try await engine.transcribe(audioPath: URL(fileURLWithPath: "/nonexistent.wav"), language: nil, audioSource: .system)
        }
        #expect(inventory.installs.isEmpty, "downloaded implicitly: \(inventory.installs)")
    }

    /// L review 229: only the explicit action installs it.
    @Test func onlyAnExplicitPrepareInstallsTheModel() async throws {
        guard #available(macOS 26.0, *) else { return }
        let inventory = FakeSpeechInventory()
        try await SpeechAnalyzerEngine(language: "en", inventory: inventory).prepare()
        #expect(inventory.installs == ["en-US"])
        try await SpeechAnalyzerEngine(language: "en", inventory: inventory).prepare()
        #expect(inventory.installs == ["en-US"], "installed once")
    }

    /// L review 229: a salvage whose SpeechAnalyzer model is not installed keeps its session PENDING — never a download, and
    /// never every chunk failed and the session forgotten.
    @Test func aSalvageWhoseSpeechModelIsNotInstalledWaitsAndNeverDownloads() async throws {
        guard #available(macOS 26.0, *) else { return }
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let inventory = FakeSpeechInventory()
        h.engine.value = SpeechAnalyzerEngine(language: "en", inventory: inventory)
        await h.coordinator.retryPendingSessions()
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [p.sessionKey], "kept")
        #expect(inventory.installs.isEmpty, "never an implicit download: \(inventory.installs)")
        #expect(h.presented.value.isEmpty, "nothing transcribed")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("transcription engine isn’t ready") && row.contains("not installed"), "\(row)")
    }
}
#endif

// MARK: - A slow quota pass or lengths read is never fatal (227)

/// A read named `label` that takes `seconds` — a slow but healthy share, never a hung one.
struct SlowRead: Sendable {
    let label: String
    let seconds: Double
    func delayIfNamed(_ name: String) { if name == label { Thread.sleep(forTimeInterval: seconds) } }
}

@MainActor
@Suite struct FinalizeBoundsRoundFTests {
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("finalize-f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A finished chunked session `f` in `d`, one chunk whose audio is a real WAV.
    private func session(in d: URL) throws -> SessionState {
        try RecoveryFixtures.writeSessionJSON(dir: d, sessionId: "f", meetingStart: Date(), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: d.appendingPathComponent("f-0.m4a"), seconds: 1)
        return try #require(SessionState.read(directory: d, sessionId: "f"))
    }

    private func issues(_ url: URL) throws -> [String] {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return ((json["metadata"] as? [String: Any])?["processing_issues"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
    }

    private func metadata(_ url: URL) throws -> [String: Any] {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(json["metadata"] as? [String: Any])
    }

    /// L review 227, IMPORTANT: a quota pass slower than its bound — it walks the whole recording root and deletes files — is
    /// NOT fatal: the transcript is written, and the record says the quota was not checked.
    @Test func aSlowQuotaPassIsNeverFatal() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let state = try session(in: d)
        let runner = TranscriptionRunner()
        let slow = SlowRead(label: "transcript: quota", seconds: 1.5)
        runner.folderReads = FolderReads(label: "runner-f-\(UUID().uuidString)", beforeEachRead: { slow.delayIfNamed($0) })
        runner.folderWriteSeconds = 1
        let result = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        let codes = try issues(result.jsonPath), lengths = try metadata(result.jsonPath)["chunk_durations"] as? [Double]
        #expect(codes.contains(ChunkIssue.Code.quotaNotChecked.rawValue), "\(codes)")
        #expect(lengths != nil, "the lengths were read")
    }

    /// L review 227: lengths that do not answer are written UNKNOWN — left out, never made up, never a failed transcript.
    @Test func lengthsThatDoNotAnswerAreWrittenUnknown() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let state = try session(in: d)
        let runner = TranscriptionRunner()
        let slow = SlowRead(label: "transcript: lengths", seconds: 1.5)
        runner.folderReads = FolderReads(label: "runner-f-\(UUID().uuidString)", beforeEachRead: { slow.delayIfNamed($0) })
        runner.folderReadSeconds = 1
        let result = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        let codes = try issues(result.jsonPath), lengths = try metadata(result.jsonPath)["chunk_durations"]
        #expect(lengths == nil, "unknown, never a guess")
        #expect(codes.contains(ChunkIssue.Code.audioLengthsUnknown.rawValue), "\(codes)")
    }
}

// MARK: - The merge is bounded on the folder's queue (231)

@MainActor
@Suite struct MergeBoundRoundFTests {
    /// L review 231, IMPORTANT: a merge whose folder does not answer — its sources' loads hung — is SKIPPED within its bound,
    /// never "Finishing…" forever: the chunk files are listed (the refusal path), the record says why, and nothing of the
    /// sources is deleted.
    @Test func aMergeWhoseFolderHangsIsSkippedAndSaid() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("merge-f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let t0 = Date()
        let chunks = (0..<2).map { i in
            ProcessedChunk(index: i, startTime: t0.addingTimeInterval(Double(i) * 60), audioPath: "m-\(i).m4a",
                           segments: [.init(start: 0, end: 1, text: "hi", speaker: "Speaker 1", source: "remote")],
                           speakerDatabase: ["Speaker 1": [1, 0, 0]])
        }
        for chunk in chunks { try Data(repeating: 1, count: 1_024).write(to: d.appendingPathComponent(chunk.audioPath)) }
        var config = Config.default
        config.mergeChunkedAudio = true
        config.preserveSourceWAV = false
        let state = SessionState(sessionId: "m", meetingStart: t0, engine: "fluid_audio", chunkDurationMinutes: 1, chunks: chunks)
        let hung = HungRead("merge: sources")
        defer { hung.release() }
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "merge-f-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        runner.folderWriteSeconds = 0.5
        runner.folderReadSeconds = 5
        let started = ContinuousClock.now
        let finalize = Task { try await runner.finalize(sessionState: state, outputDirectory: d, config: config) }
        await Harness.until { hung.reached }
        #expect(hung.reached, "the merge's loads run on the folder's queue")
        try await Task.sleep(for: .milliseconds(800))   // past the merge's bound: the folder answers again
        hung.release()
        let result = try await finalize.value
        #expect(ContinuousClock.now - started < .seconds(5), "within its bound, never the watchdog")
        let meta = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])?["metadata"] as? [String: Any])
        #expect(meta["audio_files"] as? [String] == ["m-0.m4a", "m-1.m4a"], "the chunk files are listed")
        let codes = (meta["processing_issues"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        #expect(codes.contains(ChunkIssue.Code.mergeSkippedFolderNotAnswering.rawValue), "\(codes)")
        #expect(chunks.allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0.audioPath).path) }, "no source deleted")
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("m.m4a").path), "no half merge left")
    }
}

// MARK: - A salvage's late write is announced (228)

@MainActor
@Suite struct LateSalvageWriteRoundFTests {
    /// L review 228, IMPORTANT: a salvage whose transcript write did not answer keeps its session — and WHY it was kept
    /// (`keptWhileWriting`), apart from why it stopped. When the write lands later, the next pass's finalized gate says it
    /// with the salvage's own row — a transcript written — and offers the rename panel. Never silent.
    @Test func aSalvageWriteThatLandsLaterIsSaidAndPresented() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let hung = HungRead("transcript: write")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-f-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderWriteDeadline = .milliseconds(300)
        h.coordinator.folderReadDeadline = .milliseconds(300)
        await h.coordinator.retryPendingSessions()
        let kept = try #require(RecordingSentinel.readPending(directory: h.tmp).first)
        #expect(kept.keptWhileWriting?.chunkCount == 2, "kept, and why: \(String(describing: kept.keptWhileWriting))")
        #expect(h.presented.value.isEmpty && h.appState.activeAlarms[.recordingStopped] == nil, "nothing claimed yet")
        hung.release()   // the write lands
        let transcript = h.tmp.appendingPathComponent("p/p.json")
        await Harness.until { FileManager.default.fileExists(atPath: transcript.path) }
        h.coordinator.folderReadDeadline = .seconds(5)
        await h.coordinator.retryPendingSessions()
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "finished")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("Recording STOPPED") && row.contains("p.json") && row.contains("2 chunks"), "the salvage's own row: \(row)")
        #expect(h.presented.value.map(\.lastPathComponent) == ["p.json"], "the rename panel is offered")
    }
}

// MARK: - The engine a salvage needs: the diarizer too, only for audio to recognise, and the right remedy (230, 232, 233)

/// A diarizer whose model is not downloaded (L review 232): made fine, never ready.
struct NotReadyDiarizer: DiarizationProvider {
    struct NotDownloaded: Error {}
    func isReady() async -> Bool { false }
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { throw NotDownloaded() }
    func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
        throw NotDownloaded()
    }
}

@MainActor
@Suite struct SalvageEngineRoundFTests {
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// L review 232: the readiness a salvage checks is Setup's — the speaker-diarization model too (VAD is optional: it is
    /// skipped without its model). With chunks to recognise and no diarization model, the session waits.
    @Test func aSalvageWhoseDiarizationModelIsMissingWaitsForIt() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.diarizer.value = NotReadyDiarizer()
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey], "kept")
        #expect(h.presented.value.isEmpty, "nothing transcribed without speakers")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("transcription engine isn’t ready") && row.contains("diarization model"), "\(row)")
    }

    /// L review 232: no asymmetry — an engine that cannot be made blocks only a session with something to recognise. One
    /// whose every chunk is transcribed is finished without it, never kept waiting for an engine it does not need.
    @Test func aSalvageWithNothingToRecogniseNeedsNoEngine() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engineError.value = TranscriptionRunner.RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty, "finished")
        #expect(h.presented.value.map(\.lastPathComponent) == ["p.json"])
    }

    /// L review 230: an engine that cannot be made on this macOS is never fixed by Setup or a download — the row's remedy
    /// is to choose another engine in Settings.
    @Test func anEngineThatCannotBeMadeHereSaysChooseAnother() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engineError.value = TranscriptionRunner.RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("choose another engine in Settings") && !row.contains("model download"), "\(row)")
    }

    /// … while a model not downloaded still says Setup or a download.
    @Test func aModelNotDownloadedSaysSetupOrADownload() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("after Setup or a model download") && !row.contains("choose another engine"), "\(row)")
    }

    /// L review 233: the waiting row is said once per run — never again at every retry while the engine is still not ready.
    @Test func theWaitingRowIsSaidOncePerRun() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
        h.appState.acknowledge(.recordingStopped)
        await h.coordinator.transcriptionEngineMayBeReady()   // a download that did not help
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingStopped] == nil, "said once")
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey], "still kept")
    }
}

// MARK: - Late audio's reference is the transcript's own write time (220)

@MainActor
@Suite struct LateAudioReferenceRoundFTests {
    /// L review 220: finalize stamps `transcript_written_at` into the record, and late-audio detection judges from it — so
    /// a rename or a disclosure stamp that rewrites the transcript BEFORE the first look never moves the reference and
    /// hides audio recorded after the transcript was written.
    @Test func aRewriteBeforeTheFirstLookNeverHidesLateAudio() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let dir = h.tmp.appendingPathComponent("day")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: Date(), chunkIndices: [0])
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "sess", config: h.config.config, transcriber: FakeEngine(), diarizer: FakeDiarizer(),
            runner: h.runner))
        let meta = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])?["metadata"] as? [String: Any])
        let stamp = try #require(meta["transcript_written_at"] as? String, "finalize stamps its write time")
        #expect(TranscriptAssembler.parseWrittenAt(stamp) != nil, "\(stamp)")
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: Date(), chunkIndices: [0])   // a leftover
        let late = dir.appendingPathComponent("sess-7.wav")
        try RecoveryFixtures.writeFakeWav(at: late, seconds: 30)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: late.path)
        // A rename — or the disclosure's stamp — rewrote the transcript after the late audio, before any look.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: result.jsonPath.path)
        let s = RecordingSentinel(startedAt: Date(), sessionName: "sess", systemAudioPath: dir.appendingPathComponent("sess-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("sess-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
        try RecordingSentinel.writePending([s], directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.audioAfterTranscript]?.message, "the late audio is said")
        #expect(row.contains("30 s") && row.contains("sess.json"), "\(row)")
    }
}

// MARK: - The pipeline's own file work: the seed's read and the progress file's writes (234)

/// A rotation client that is never asked: the tests below never rotate.
private final class IdleRotationClient: ChunkRotationClient {
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
        throw CancellationError()
    }
}

@MainActor
@Suite struct PipelineFileWorkRoundFTests {
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L review 234: a refused seed falls back to this session's own state as its CALLER's bounded look found it — the
    /// setup, on the main actor, never reads the folder itself.
    @Test func aRefusedSeedFallsBackToTheOwnStateItsCallerRead() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let own = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 100), engine: Config.default.engine.rawValue,
                               chunkDurationMinutes: 10,
                               chunks: [ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 100), audioPath: "m-0.m4a",
                                                       segments: [], speakerDatabase: [:])])
        let other = SessionState(sessionId: "other", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10)
        let runner = TranscriptionRunner()
        defer { runner.teardownChunkedPipeline() }
        try runner.setupChunkedPipeline(captureClient: IdleRotationClient(), outputDirectory: d, sessionBaseName: "m", config: .default,
                                        seededState: other, ownStateOnDisk: own, firstChunkIndex: 1)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.sessionId == "m" && state.chunks.map(\.audioPath) == ["m-0.m4a"], "the caller's look — nothing on disk to read")
        #expect(state.issues.contains(SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedMismatch, track: nil, count: nil))))
    }

    /// L review 234: a `session.json` write that does not answer within the write bound never blocks the pipeline: it is
    /// recorded as `sessionWriteFailed` — the existing alarm — and the pipeline goes on.
    @Test func aProgressFileWriteThatDoesNotAnswerIsAFailedWriteWithinItsBound() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let hung = HungRead("chunk: session file")
        defer { hung.release() }
        let state = SessionState(sessionId: "m", meetingStart: Date(), engine: "fluid_audio", chunkDurationMinutes: 10)
        let processor = ChunkProcessor(config: .default, outputDirectory: d, sessionState: state, transcriber: FakeEngine(), diarizer: nil,
                                       folderReads: FolderReads(label: "pipeline-f-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) }),
                                       writeSeconds: 0.3)
        let failures = Harness.Box<[Int?]>([])
        processor.onSessionWriteFailure = { failures.value.append($0) }
        let started = ContinuousClock.now
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
        #expect(ContinuousClock.now - started < .seconds(3), "within its bound, never the hung write")
        #expect(hung.reached, "the write ran on the folder's queue")
        #expect(failures.value == [nil], "said: the sessionWriteFailed alarm")
        #expect(await processor.getSessionState().issues.contains(SessionIssue(chunk: nil, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))))
    }
}
