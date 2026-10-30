import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// Mic echo cancellation in the chunk pipeline (#342): the `mic_echo_cancel` setting, what a chunk
/// transcribes and records with it on, off, failing or unavailable, and the session's metadata.

/// Records the file each stream was transcribed from.
private final class PathRecordingEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "PathRecording"
    private let lock = NSLock()
    private var paths: [AudioSourceType: URL] = [:]
    func path(for source: AudioSourceType) -> URL? { lock.withLock { paths[source] } }

    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        lock.withLock { paths[audioSource] = audioPath }
        return [TranscriptSegment(start: 0, end: 5, text: audioSource == .system ? "remote words" : "local words", language: "en")]
    }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

/// Copies the mic to the output and reports `framesReverted`; remembers whether it ran and whether
/// its output still existed when the mic pass read it.
private final class CopyingCanceller: MicEchoCancelling, @unchecked Sendable {
    let framesReverted: Int
    private let lock = NSLock()
    private var outputs: [URL] = []
    init(framesReverted: Int = 0) { self.framesReverted = framesReverted }
    var calls: Int { lock.withLock { outputs.count } }
    var lastOutput: URL? { lock.withLock { outputs.last } }

    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        try FileManager.default.copyItem(at: micURL, to: outputURL)
        lock.withLock { outputs.append(outputURL) }
        return MicEchoCancelRecord(engine: "fake", modelSHA256: String(repeating: "a", count: 64),
                                   framesReverted: framesReverted, seconds: 1)
    }
}

private struct ThrowingCanceller: MicEchoCancelling {
    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        FileManager.default.createFile(atPath: outputURL.path, contents: Data([1, 2, 3]))  // a partial write
        throw LocalVQEEchoCanceller.Failure.nonFiniteOutput
    }
}

@MainActor
@Suite struct MicEchoCancelPipelineTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MicEchoCancelPipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Processes one dual-stream chunk (both WAVs written unless told otherwise) and returns it.
    private func process(_ setup: MicEchoCancelSetup, engine: PathRecordingEngine, in dir: URL,
                         writeSystem: Bool = true, writeMic: Bool = true) async throws -> ProcessedChunk? {
        let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
        if writeSystem { try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1) }
        if writeMic { try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1) }
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let processor = ChunkProcessor(
            config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
                                       engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
            transcriber: engine, diarizer: FakeDiarizer(), scratchDirectory: scratch, micEchoCancel: setup)
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: sys.path, micPath: mic.path, startTime: Date(timeIntervalSince1970: 0)))
        return await processor.getSessionState().chunks.first
    }

    @Test func transcribesTheCleanedMicAndRecordsWhatCancellationDid() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PathRecordingEngine(), canceller = CopyingCanceller(framesReverted: 3)
        let chunk = try #require(try await process(.on(canceller), engine: engine, in: dir))

        #expect(canceller.calls == 1)
        let cleaned = try #require(canceller.lastOutput)
        #expect(engine.path(for: .microphone) == cleaned)
        #expect(engine.path(for: .system)?.lastPathComponent == "meeting-0.wav")
        #expect(chunk.micEchoCancel == MicEchoCancelRecord(engine: "fake", modelSHA256: String(repeating: "a", count: 64),
                                                           framesReverted: 3, seconds: 1))
        #expect(chunk.issues.contains(ChunkIssue(code: .echoCancelReverted, track: "local", count: 3)))
        #expect(!chunk.issues.contains { $0.code == .echoCancelFailed })
        #expect(chunk.segments.contains { $0.source == "local" })
        // The cleaned copy is scratch: gone once the chunk is done.
        #expect(!FileManager.default.fileExists(atPath: cleaned.path))
    }

    @Test func recordsNoRevertIssueWhenTheGuardGaveNothingBack() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = try #require(try await process(.on(CopyingCanceller(framesReverted: 0)), engine: PathRecordingEngine(), in: dir))
        #expect(chunk.micEchoCancel?.framesReverted == 0)
        #expect(!chunk.issues.contains { $0.code == .echoCancelReverted })
    }

    @Test func aFailureFallsBackToTheRawMicAndIsRecorded() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PathRecordingEngine()
        let chunk = try #require(try await process(.on(ThrowingCanceller()), engine: engine, in: dir))

        #expect(engine.path(for: .microphone)?.lastPathComponent == "meeting-0_mic.wav")
        #expect(chunk.micEchoCancel == nil)
        let issue = try #require(chunk.issues.first { $0.code == .echoCancelFailed })
        #expect(issue.track == "local")
        #expect(issue.detail == "nonFiniteOutput")
        #expect(!issue.affectsContent)
        #expect(chunk.segments.contains { $0.source == "local" })
        // The partial output is removed.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("scratch").path)
        #expect(leftovers.isEmpty)
    }

    @Test func anUnavailableCancellerIsRecordedOnEveryDualStreamChunk() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PathRecordingEngine()
        let chunk = try #require(try await process(.unavailable(reason: "no model"), engine: engine, in: dir))
        #expect(engine.path(for: .microphone)?.lastPathComponent == "meeting-0_mic.wav")
        #expect(chunk.issues.contains(ChunkIssue(code: .echoCancelFailed, track: "local", count: nil, detail: "no model")))
    }

    @Test func offChangesNothing() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PathRecordingEngine()
        let chunk = try #require(try await process(.off, engine: engine, in: dir))
        #expect(engine.path(for: .microphone)?.lastPathComponent == "meeting-0_mic.wav")
        #expect(chunk.micEchoCancel == nil)
        #expect(!chunk.issues.contains { $0.code == .echoCancelFailed || $0.code == .echoCancelReverted })
    }

    @Test func needsBothStreams() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let noSystem = CopyingCanceller()
        let chunk = try #require(try await process(.on(noSystem), engine: PathRecordingEngine(), in: dir, writeSystem: false))
        #expect(noSystem.calls == 0)
        #expect(chunk.micEchoCancel == nil)

        let dir2 = try makeDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        let noMic = CopyingCanceller()
        _ = try await process(.on(noMic), engine: PathRecordingEngine(), in: dir2, writeMic: false)
        #expect(noMic.calls == 0)
        // Nor does a system-only chunk report the canceller as missing.
        let dir3 = try makeDir(); defer { try? FileManager.default.removeItem(at: dir3) }
        let systemOnly = try #require(try await process(.unavailable(reason: "no model"), engine: PathRecordingEngine(), in: dir3, writeMic: false))
        #expect(!systemOnly.issues.contains { $0.code == .echoCancelFailed })
    }

    @Test func theRecordSurvivesSessionJSON() throws {
        let record = MicEchoCancelRecord(engine: "localvqe-v1.4-aec-coreml", modelSHA256: "ab", framesReverted: 2, seconds: 1800)
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "a.m4a", segments: [],
                                   speakerDatabase: [:], micEchoCancel: record)
        let data = try JSONEncoder().encode(chunk)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(json["mic_echo_cancel"] as? [String: Any])
        #expect(stored["model_sha256"] as? String == "ab")
        #expect(stored["frames_reverted"] as? Int == 2)
        #expect(try JSONDecoder().decode(ProcessedChunk.self, from: data).micEchoCancel == record)

        // A chunk written before #342 has none; one this build cannot read keeps the chunk.
        var legacy = json
        legacy["mic_echo_cancel"] = nil
        #expect(try JSONDecoder().decode(ProcessedChunk.self, from: JSONSerialization.data(withJSONObject: legacy)).micEchoCancel == nil)
        var future = json
        future["mic_echo_cancel"] = ["engine": 7]
        #expect(try JSONDecoder().decode(ProcessedChunk.self, from: JSONSerialization.data(withJSONObject: future)).micEchoCancel == nil)
    }
}

@Suite struct MicEchoCancelMetadataTests {
    private func chunk(_ index: Int, record: MicEchoCancelRecord?, issues: [ChunkIssue] = []) -> ProcessedChunk {
        ProcessedChunk(index: index, startTime: Date(timeIntervalSince1970: 0), audioPath: "a.m4a", segments: [],
                       speakerDatabase: [:], issues: issues, micEchoCancel: record)
    }

    @Test func isLeftOutWhenCancellationNeverRan() {
        #expect(TranscriptionRunner.micEchoCancelDictionary(chunks: [chunk(0, record: nil), chunk(1, record: nil)]) == nil)
    }

    @Test func sumsTheChunksAndCountsFailures() throws {
        let r = MicEchoCancelRecord(engine: "localvqe-v1.4-aec-coreml", modelSHA256: "ab", framesReverted: 2, seconds: 1800)
        let failed = [ChunkIssue(code: .echoCancelFailed, track: "local", count: nil, detail: "x")]
        let d = try #require(TranscriptionRunner.micEchoCancelDictionary(chunks: [
            chunk(0, record: r), chunk(1, record: r), chunk(2, record: nil, issues: failed),
        ]))
        #expect(d["chunks"] as? Int == 2)
        #expect(d["chunks_failed"] as? Int == 1)
        #expect(d["seconds"] as? Double == 3600)
        #expect(d["frames_reverted"] as? Int == 4)
        #expect(d["engine"] as? String == "localvqe-v1.4-aec-coreml")
        #expect(d["model_sha256"] as? String == "ab")
    }

    @Test func listsBothModelsWhenASessionMixedTwo() throws {
        let a = MicEchoCancelRecord(engine: "e", modelSHA256: "aa", framesReverted: 0, seconds: 1)
        let b = MicEchoCancelRecord(engine: "e", modelSHA256: "bb", framesReverted: 0, seconds: 1)
        let d = try #require(TranscriptionRunner.micEchoCancelDictionary(chunks: [chunk(0, record: a), chunk(1, record: b)]))
        #expect(d["model_sha256"] as? [String] == ["aa", "bb"])
        #expect(d["engine"] as? String == "e")
    }

    @Test func isStampedIntoTheTranscript() {
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en",
                                                numSpeakers: nil, diarization: true, dualStream: true,
                                                micEchoCancel: ["chunks": 1])
        let metadata = json["metadata"] as? [String: Any]
        #expect((metadata?["mic_echo_cancel"] as? [String: Any])?["chunks"] as? Int == 1)
        let off = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en",
                                               numSpeakers: nil, diarization: true, dualStream: true)
        #expect((off["metadata"] as? [String: Any])?["mic_echo_cancel"] == nil)
    }
}

@Suite struct MicEchoCancelSettingTests {
    private func decode(_ value: Any?) throws -> Config {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config.default)) as? [String: Any])
        json["mic_echo_cancel"] = value
        return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func isOffByDefaultAndWhenAbsent() throws {
        #expect(Config.default.micEchoCancel == .off)
        #expect(try decode(nil).micEchoCancel == .off)
    }

    @Test func readsOnAndWritesItBack() throws {
        let config = try decode("on")
        #expect(config.micEchoCancel == .on)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        #expect(json?["mic_echo_cancel"] as? String == "on")
    }

    @Test func readsAnUnknownModeAsOffInsteadOfFailingTheConfig() throws {
        #expect(try decode("auto").micEchoCancel == .off)
    }

    @Test func resolvesToNothingWhenOff() {
        guard case .off = MicEchoCancelSetup.resolve(.default) else { Issue.record("expected .off"); return }
    }

    @Test func resolvesToUnavailableWithoutTheModel() throws {
        var config = Config.default
        config.micEchoCancel = .on
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        let bundle = try #require(Bundle(url: bare))
        guard case .unavailable = MicEchoCancelSetup.resolve(config, bundle: bundle) else {
            Issue.record("expected .unavailable"); return
        }
    }

    @Test func resolvesToTheBundledModel() throws {
        var config = Config.default
        config.micEchoCancel = .on
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        let assets = fake.appendingPathComponent("LocalVQE-CoreML")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        FileManager.default.createFile(atPath: assets.appendingPathComponent("MANIFEST.json").path, contents: Data("{}".utf8))
        let bundle = try #require(Bundle(url: fake))
        guard case .on(let canceller) = MicEchoCancelSetup.resolve(config, bundle: bundle) else {
            Issue.record("expected .on"); return
        }
        #expect((canceller as? LocalVQEMicEchoCanceller)?.assetsDirectory.standardizedFileURL == assets.standardizedFileURL)
    }
}

/// Re-detect on a transcript whose mic was echo-cancelled cancels it again (#342), with the archive's
/// system side as the reference; otherwise it leaves the mic alone.
@Suite(.serialized) struct RediarizeEchoCancelTests {
    /// Records what it was handed and returns a constant, so the diarizer's input shows it ran.
    final class MarkingCanceller: MicEchoSampleCancelling, @unchecked Sendable {
        private(set) var calls: [(microphone: [Float], reference: [Float])] = []
        func cancelEcho(microphone: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) {
            calls.append((microphone, reference))
            return ([Float](repeating: 0.25, count: microphone.count), 0)
        }
    }

    final class RecordingDiarizer: DiarizationProvider, @unchecked Sendable {
        private(set) var audio: [Float] = []
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await FakeDiarizer().diarize(audioPath: audioPath, numSpeakers: numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            self.audio = audio
            return try await FakeDiarizer().diarize(audio: audio, numSpeakers: numSpeakers, progress: progress)
        }
    }

    private func tone(_ frequency: Double, seconds: Double, rate: Double = 48_000, at url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * frequency * Double(i) / rate)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// One stereo archive (mic 440 Hz left, system 1760 Hz right) and a transcript over it.
    private func makeRecording(cancelled: Bool) async throws -> (transcript: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-aec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sys = dir.appendingPathComponent("call-0.wav"), mic = dir.appendingPathComponent("call-0_mic.wav")
        try tone(1760, seconds: 2, at: sys); try tone(440, seconds: 2, at: mic)
        let archive = try await AudioArchiver.archive(systemAudio: sys, micAudio: mic, outputDirectory: dir, bitrateKbps: 64)
        var metadata: [String: Any] = ["audio_paths": [archive.archivePath.path], "chunk_durations": [2.0]]
        if cancelled { metadata["mic_echo_cancel"] = ["chunks": 1, "chunks_failed": 0] }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": metadata,
            "segments": [["start": 0.2, "end": 1.8, "text": "hi", "speaker": "Local Speaker 1", "source": "local"]],
        ]).write(to: transcript)
        return (transcript, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Zero crossings per second: tells the 440 Hz side from the 1760 Hz side.
    private func crossingsPerSecond(_ x: [Float]) -> Double {
        let n = zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(n) / (Double(x.count) / 16_000)
    }

    @Test func cancelsTheMicAgainWithTheSystemSideAsReference() async throws {
        let (t, cleanup) = try await makeRecording(cancelled: true); defer { cleanup() }
        let canceller = MarkingCanceller(), diarizer = RecordingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "local", speakerCount: 1, diarizer: diarizer,
                                                     echoCanceller: canceller)
        let call = try #require(canceller.calls.first)
        #expect(canceller.calls.count == 1)
        #expect(abs(crossingsPerSecond(call.microphone) - 880) < 60)   // 440 Hz: the mic side
        #expect(abs(crossingsPerSecond(call.reference) - 3520) < 200)  // 1760 Hz: the system side
        #expect(!diarizer.audio.isEmpty && diarizer.audio.allSatisfy { $0 == 0.25 })
    }

    @Test func leavesTheMicAloneWhenItWasNotCancelled() async throws {
        let (t, cleanup) = try await makeRecording(cancelled: false); defer { cleanup() }
        let canceller = MarkingCanceller(), diarizer = RecordingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "local", speakerCount: 1, diarizer: diarizer,
                                                     echoCanceller: canceller)
        #expect(canceller.calls.isEmpty)
        #expect(!diarizer.audio.allSatisfy { $0 == 0.25 })
    }

    @Test func neverCancelsTheSystemChannel() async throws {
        let (t, cleanup) = try await makeRecording(cancelled: true); defer { cleanup() }
        let canceller = MarkingCanceller()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1,
                                                     diarizer: RecordingDiarizer(), echoCanceller: canceller)
        #expect(canceller.calls.isEmpty)
    }
}
