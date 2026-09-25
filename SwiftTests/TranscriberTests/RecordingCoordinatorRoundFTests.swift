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
