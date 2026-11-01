import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// P1 / §11.2: a fresh install on macOS 26 produced empty transcripts because the live chunk path
/// threw `languageRequired` on every chunk and swallowed it. Setup Continue and Settings Save now
/// run the chosen engine on one synthetic second and refuse on throw.
private struct PreflightThrowingEngine: TranscriptionEngine {
    let name = "PreflightThrowing"
    struct Boom: Error {}
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

@Suite struct EnginePreflightTests {
    @Test func aThrowingEngineFailsPreflightWithItsError() async {
        await #expect(throws: EnginePreflight.Failure.self) {
            try await EnginePreflight.run(engine: PreflightThrowingEngine())
        }
    }

    @Test func aWorkingEnginePassesOnASyntheticSecond() async throws {
        try await EnginePreflight.run(engine: FakeEngine())   // FakeEngine: ChunkedSessionRecoveryTests.swift:11
    }

    @Test func theSyntheticWavIsOneSecondOf16kHzMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticWAV.write(to: url, seconds: 1)
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        #expect(file.length == 16_000)
    }

    // MARK: - What a Settings Save does about the engine (pre-PR review)

    /// A model that is not downloaded is not a broken engine. The preflight could only throw `modelNotDownloaded`, and Save
    /// answered "Not saved" — so the download Save is there to start never started, and FluidAudio could not be chosen.
    @Test func aSaveWithItsModelNotDownloadedCommitsSoTheDownloadStarts() {
        #expect(EnginePreflight.saveStep(for: .fluidAudio, modelCached: false) == .commitThenDownload)
    }

    @Test func aSaveWithItsModelDownloadedIsPreflighted() {
        #expect(EnginePreflight.saveStep(for: .fluidAudio, modelCached: true) == .preflightThenCommit)
    }

    /// Apple Speech has no model of Parley's to wait for: it is preflighted whatever the cache says, and refused while it
    /// cannot transcribe (#223).
    @Test func anEngineWithNoDownloadIsAlwaysPreflighted() {
        #expect(EnginePreflight.saveStep(for: .speechAnalyzer, modelCached: false) == .preflightThenCommit)
        #expect(EnginePreflight.saveStep(for: .speechAnalyzer, modelCached: true) == .preflightThenCommit)
    }

    /// A model chosen for re-download may be the corrupt one: preflighting loads it, and FluidAudio's answer to a failed
    /// load is to delete the cache and download in place (#349, #351). The Save commits and runs the staged re-download.
    @Test func aModelChosenForRedownloadIsNeverPreflighted() {
        #expect(EnginePreflight.saveStep(for: .fluidAudio, modelCached: true, redownloadChosen: true) == .commitThenDownload)
        #expect(EnginePreflight.saveStep(for: .fluidAudio, modelCached: false, redownloadChosen: true) == .commitThenDownload)
    }

    /// Apple Speech has nothing to re-download: a stale request never skips its preflight.
    @Test func aRedownloadRequestNeverSkipsAppleSpeechsPreflight() {
        #expect(EnginePreflight.saveStep(for: .speechAnalyzer, modelCached: true, redownloadChosen: true) == .preflightThenCommit)
    }
}
