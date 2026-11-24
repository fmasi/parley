import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// The far-end lift measured on every dual-stream chunk, with echo cancellation on or off (#374), and the
/// headphone guard (#365 (a)) reading it. Synthetic audio only: a tone that plays and stops on the far end,
/// and a mic that hears it (loudspeakers) or only its own noise (headphones).
enum LiftFixtures {
    /// What the mic hears.
    enum Mic { case headphones, loudspeaker }

    /// A 48 kHz mono Float32 WAV of `seconds`, written a second at a time; `sample(i)` gives sample `i`.
    static func write(_ url: URL, seconds: Double, sample: (Int) -> Float) throws {
        let rate = 48_000
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * Double(rate))
        var offset = 0
        while offset < total {
            let n = min(rate, total - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { buffer.floatChannelData![0][k] = sample(offset + k) }
            try file.write(from: buffer)
            offset += n
        }
    }

    /// The far end: a 440 Hz tone (about -23 dBFS) for one second, then a second of exact zeros (what the
    /// tap writes when nothing plays), from `0` to `talksUntil` seconds; zeros after.
    static func farEnd(_ i: Int, talksUntil: Double = .infinity, alwaysTalks: Bool = false) -> Float {
        let t = Double(i) / 48_000
        guard t < talksUntil, alwaysTalks || Int(t) % 2 == 0 else { return 0 }
        return 0.1 * Float(sin(2 * Double.pi * 440 * t))
    }

    /// The mic's own noise, about -65 dBFS: deterministic, so a run measures what the last one did.
    static func noise(_ i: Int) -> Float {
        var x = UInt64(truncatingIfNeeded: i) &* 6364136223846793005 &+ 1442695040888963407
        x ^= x >> 33
        return (Float(x % 2001) / 1000 - 1) * 0.001
    }

    /// The mic: its noise, plus the far end through the speakers (about 10 dB down, 20 ms late).
    static func mic(_ i: Int, hears: Mic, talksUntil: Double = .infinity, alwaysTalks: Bool = false) -> Float {
        let echo = hears == .loudspeaker && i >= 960 ? 0.3 * farEnd(i - 960, talksUntil: talksUntil, alwaysTalks: alwaysTalks) : 0
        return noise(i) + echo
    }

    /// A chunk's pair of WAVs: `system` and `mic`, `seconds` long.
    static func writePair(system: URL, mic: URL, hears: Mic, seconds: Double = 80) throws {
        try write(system, seconds: seconds) { farEnd($0) }
        try write(mic, seconds: seconds) { Self.mic($0, hears: hears) }
    }
}

/// Both streams say the same short phrase, the mic 0.2 s after the system: an echo copy or the user repeating
/// the far end, depending on the chunk's lift (#365, #374).
private final class RepeatedPhraseEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "RepeatedPhrase"
    static let phrase = "Not possible to wait now."
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        let start = audioSource == .system ? 10.0 : 10.2
        return [TranscriptSegment(start: start, end: start + 1.4, text: Self.phrase, language: "en")]
    }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

/// Copies the mic to the output and reports the lift it was given.
private struct LiftReportingCanceller: MicEchoCancelling {
    let farEndLiftDB: Double?
    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        try FileManager.default.copyItem(at: micURL, to: outputURL)
        return MicEchoCancelRecord(engine: "fake", modelSHA256: "a", framesReverted: 0, seconds: 1, erleDB: 0,
                                   farEndLiftDB: farEndLiftDB)
    }
}

@Suite struct FarEndLiftMeasureTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FarEndLift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aHeadphoneChunkLiftsNothingAndALoudspeakerOneLiftsWellAboveTheLine() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav")
        for (hears, range) in [(LiftFixtures.Mic.headphones, -3.0...3.0), (.loudspeaker, 25.0...38.0)] {
            let mic = dir.appendingPathComponent("m-\(hears).wav")
            try LiftFixtures.writePair(system: system, mic: mic, hears: hears)
            let record = try FarEndLift.measure(micURL: mic, systemURL: system)
            let lift = try #require(record.farEndLiftDB, "\(hears)")
            #expect(range.contains(lift), "\(hears): \(lift) dB")
            #expect(abs(record.seconds - 80) < 0.01)
            #expect(EchoDeduplicator.AcousticCoupling.chunk(lift: record).isUncoupled(start: 0, end: 1) == (hears == .headphones))
        }
    }

    /// Block by block, the same lift as the whole files decoded at once and measured as the canceller does.
    @Test func blockByBlockItIsTheWholeFilesMeasure() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav"), mic = dir.appendingPathComponent("m.wav")
        try LiftFixtures.writePair(system: system, mic: mic, hears: .loudspeaker)
        let micSamples = try AudioDecode.mono16kHzFloat(contentsOf: mic)
        var reference = try AudioDecode.mono16kHzFloat(contentsOf: system)
        reference = Array(reference.prefix(micSamples.count))
        let frame = NearEndGuard.frameLength(sampleRate: 16_000, parameters: NearEndGuard.Parameters())
        var micLevels = NearEndGuard.Frames(frame: frame), refLevels = micLevels
        micSamples.withUnsafeBufferPointer { micLevels.add($0) }
        reference.withUnsafeBufferPointer { refLevels.add($0) }
        let frames = (micSamples.count + frame - 1) / frame
        let whole = try #require(EchoReduction.farEndLift(micDB: micLevels.levels(frames: frames), refDB: refLevels.levels(frames: frames)))
        let streamed = try #require(try FarEndLift.measure(micURL: mic, systemURL: system).farEndLiftDB)
        #expect(abs(streamed - whole) <= 0.2, "streamed \(streamed), whole \(whole)")
    }

    /// Too little far-end speech to judge: measured, but unknown — never "headphones".
    @Test func tooLittleFarEndSpeechIsUnknown() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav"), mic = dir.appendingPathComponent("m.wav")
        try LiftFixtures.write(system, seconds: 80) { LiftFixtures.farEnd($0, talksUntil: 20) }
        try LiftFixtures.write(mic, seconds: 80) { LiftFixtures.mic($0, hears: .headphones, talksUntil: 20) }
        let record = try FarEndLift.measure(micURL: mic, systemURL: system)
        #expect(record.farEndLiftDB == nil)
        #expect(abs(record.seconds - 80) < 0.01)
        #expect(!EchoDeduplicator.AcousticCoupling.chunk(lift: record).isUncoupled(start: 0, end: 1))
    }

    /// A reference shorter than the mic is silence past its end, as for the canceller: a far end that talks
    /// without a pause still has a floor to measure against there.
    @Test func aReferenceShorterThanTheMicIsSilencePastItsEnd() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav"), mic = dir.appendingPathComponent("m.wav")
        try LiftFixtures.write(system, seconds: 40) { LiftFixtures.farEnd($0, alwaysTalks: true) }
        try LiftFixtures.write(mic, seconds: 80) { LiftFixtures.mic($0, hears: .loudspeaker, talksUntil: 40, alwaysTalks: true) }
        let lift = try #require(try FarEndLift.measure(micURL: mic, systemURL: system).farEndLiftDB)
        #expect(lift > EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB)
    }

    @Test func aMissingFileThrows() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav")
        try LiftFixtures.write(system, seconds: 1) { LiftFixtures.farEnd($0) }
        #expect(throws: (any Error).self) {
            try FarEndLift.measure(micURL: dir.appendingPathComponent("absent.wav"), systemURL: system)
        }
    }

    /// A mic of exact zeros (muted) has no level to compare: unknown.
    @Test func aMutedMicIsUnknown() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("s.wav"), mic = dir.appendingPathComponent("m.wav")
        try LiftFixtures.write(system, seconds: 80) { LiftFixtures.farEnd($0) }
        try LiftFixtures.write(mic, seconds: 80) { _ in 0 }
        #expect(try FarEndLift.measure(micURL: mic, systemURL: system).farEndLiftDB == nil)
    }
}

@Suite struct FarEndLiftRecordTests {
    @Test func theChunkKeepsItsLiftInSessionJSON() throws {
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "a.m4a", segments: [],
                                   speakerDatabase: [:], farEndLift: FarEndLiftRecord(seconds: 1800, farEndLiftDB: 2.5))
        let data = try JSONEncoder().encode(chunk)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(json["far_end_lift"] as? [String: Any])
        #expect(stored["seconds"] as? Double == 1800 && stored["far_end_lift_db"] as? Double == 2.5)
        #expect(try JSONDecoder().decode(ProcessedChunk.self, from: data).farEndLift == chunk.farEndLift)

        // Measured with too little far end: kept as measured, without a value.
        var unmeasured = json
        unmeasured["far_end_lift"] = ["seconds": 1800]
        let decoded = try JSONDecoder().decode(ProcessedChunk.self, from: JSONSerialization.data(withJSONObject: unmeasured))
        #expect(decoded.farEndLift == FarEndLiftRecord(seconds: 1800, farEndLiftDB: nil))

        // A chunk written before #374 has none; one this build cannot read keeps the chunk.
        var legacy = json
        legacy["far_end_lift"] = nil
        #expect(try JSONDecoder().decode(ProcessedChunk.self, from: JSONSerialization.data(withJSONObject: legacy)).farEndLift == nil)
        var future = json
        future["far_end_lift"] = ["seconds": "long"]
        let kept = try JSONDecoder().decode(ProcessedChunk.self, from: JSONSerialization.data(withJSONObject: future))
        #expect(kept.farEndLift == nil && kept.audioPath == "a.m4a")
    }

    /// A chunk written before #374 with echo cancellation on keeps the canceller's measure; its own wins.
    @Test func aChunkWithoutItsOwnMeasureFallsBackToTheCancellers() {
        let record = MicEchoCancelRecord(engine: "e", modelSHA256: "a", framesReverted: 0, seconds: 600, farEndLiftDB: 31)
        func chunk(lift: FarEndLiftRecord?, record: MicEchoCancelRecord?) -> ProcessedChunk {
            ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "a.m4a", segments: [],
                           speakerDatabase: [:], micEchoCancel: record, farEndLift: lift)
        }
        #expect(chunk(lift: nil, record: record).measuredFarEndLift == FarEndLiftRecord(seconds: 600, farEndLiftDB: 31))
        #expect(chunk(lift: FarEndLiftRecord(seconds: 600, farEndLiftDB: 2), record: record).measuredFarEndLift?.farEndLiftDB == 2)
        #expect(chunk(lift: nil, record: nil).measuredFarEndLift == nil)
    }

    /// `metadata.acoustic_coupling`: every measured chunk at its place, the line judged against, and nothing
    /// without a meeting start or a measure.
    @Test func theTranscriptKeepsEveryMeasuredChunkAtItsPlace() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let chunks = [
            ProcessedChunk(index: 0, startTime: start, audioPath: "a.m4a", segments: [], speakerDatabase: [:],
                           farEndLift: FarEndLiftRecord(seconds: 600, farEndLiftDB: 2.5)),
            ProcessedChunk(index: 1, startTime: start.addingTimeInterval(610), audioPath: "b.m4a", segments: [], speakerDatabase: [:],
                           micEchoCancel: MicEchoCancelRecord(engine: "e", modelSHA256: "a", framesReverted: 0, seconds: 600,
                                                              farEndLiftDB: 31)),
            ProcessedChunk(index: 2, startTime: start.addingTimeInterval(1220), audioPath: "c.m4a", segments: [], speakerDatabase: [:],
                           farEndLift: FarEndLiftRecord(seconds: 600, farEndLiftDB: nil)),
            ProcessedChunk(index: 3, startTime: start.addingTimeInterval(1830), audioPath: "d.m4a", segments: [], speakerDatabase: [:]),
        ]
        let d = try #require(TranscriptionRunner.acousticCouplingDictionary(chunks: chunks, meetingStart: start))
        #expect(d["uncoupled_below_db"] as? Double == 15)
        let entries = try #require(d["per_chunk"] as? [[String: Any]])
        #expect(entries.compactMap { $0["chunk"] as? Int } == [0, 1, 2])
        #expect(entries.compactMap { $0["start"] as? Double } == [0, 610, 1220])
        #expect(entries[0]["far_end_lift_db"] as? Double == 2.5 && entries[1]["far_end_lift_db"] as? Double == 31)
        #expect(entries[2]["far_end_lift_db"] == nil && entries[2]["seconds"] as? Double == 600)

        let coupling = EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["acoustic_coupling": d])
        #expect(coupling.isUncoupled(start: 100, end: 101))
        #expect(!coupling.isUncoupled(start: 700, end: 701))
        #expect(!coupling.isUncoupled(start: 1300, end: 1301), "measured, too little far end: unknown")
        #expect(!coupling.isUncoupled(start: 1900, end: 1901), "not measured: unknown")
        #expect(TranscriptionRunner.acousticCouplingDictionary(chunks: chunks, meetingStart: nil) == nil)
        #expect(TranscriptionRunner.acousticCouplingDictionary(chunks: [chunks[3]], meetingStart: start) == nil)
    }

    /// The reader: `acoustic_coupling` when present, else a #365 transcript's `mic_echo_cancel.per_chunk`,
    /// else unknown.
    @Test func theReaderPrefersTheNewPlaceAndStillReadsTheOld() {
        let old: [String: Any] = ["per_chunk": [["chunk": 0, "start": 0.0, "seconds": 600.0, "far_end_lift_db": 31.0]]]
        let new: [String: Any] = ["per_chunk": [["chunk": 0, "start": 0.0, "seconds": 600.0, "far_end_lift_db": 2.5]]]
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["mic_echo_cancel": old, "acoustic_coupling": new])
            .isUncoupled(start: 1, end: 2))
        #expect(!EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["mic_echo_cancel": old]).isUncoupled(start: 1, end: 2))
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["mic_echo_cancel": new]).isUncoupled(start: 1, end: 2))
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["acoustic_coupling": ["per_chunk": "x"]]) == .unknown)
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["acoustic_coupling": [:]]) == .unknown)
    }
}

@MainActor
@Suite struct FarEndLiftPipelineTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FarEndLiftPipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func processor(in dir: URL, setup: MicEchoCancelSetup) throws -> ChunkProcessor {
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return ChunkProcessor(
            config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
                                       engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
            transcriber: RepeatedPhraseEngine(), diarizer: FakeDiarizer(), scratchDirectory: scratch, micEchoCancel: setup)
    }

    private func chunkFiles(in dir: URL) -> (system: URL, mic: URL) {
        (dir.appendingPathComponent("meeting-0.wav"), dir.appendingPathComponent("meeting-0_mic.wav"))
    }

    private func run(_ processor: ChunkProcessor, in dir: URL, startTime: Date = Date(timeIntervalSince1970: 0)) async -> ProcessedChunk? {
        let files = chunkFiles(in: dir)
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: files.system.path, micPath: files.mic.path, startTime: startTime))
        return await processor.getSessionState().chunks.first
    }

    /// The issue's case: echo cancellation off. A headphone chunk keeps the user's repeated phrase, a
    /// loudspeaker chunk flags the same line as echo; each chunk keeps its lift.
    @Test func withCancellationOffEveryChunkIsMeasuredAndTheGuardUsesIt() async throws {
        for (hears, flagged) in [(LiftFixtures.Mic.headphones, false), (.loudspeaker, true)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let files = chunkFiles(in: dir)
            try LiftFixtures.writePair(system: files.system, mic: files.mic, hears: hears)
            let chunk = try #require(await run(try processor(in: dir, setup: .off), in: dir))
            let lift = try #require(chunk.farEndLift?.farEndLiftDB, "\(hears)")
            #expect((lift < EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB) == (hears == .headphones), "\(hears): \(lift) dB")
            #expect(chunk.micEchoCancel == nil)
            let line = try #require(chunk.segments.first { $0.source == "local" })
            #expect(line.text == RepeatedPhraseEngine.phrase)
            #expect(line.echo == flagged, "\(hears)")
        }
    }

    /// With cancellation on, the canceller's own measure is the chunk's: not measured a second time.
    @Test func withCancellationOnTheCancellersMeasureIsTheChunks() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = chunkFiles(in: dir)
        try LiftFixtures.writePair(system: files.system, mic: files.mic, hears: .loudspeaker)
        let chunk = try #require(await run(try processor(in: dir, setup: .on(LiftReportingCanceller(farEndLiftDB: 2.5))), in: dir))
        #expect(chunk.farEndLift == FarEndLiftRecord(seconds: 1, farEndLiftDB: 2.5))
        #expect(chunk.segments.first { $0.source == "local" }?.echo == false, "the canceller said: no coupling")
    }

    /// A failed cancellation still leaves the chunk measured, from levels.
    @Test func aFailedCancellationIsMeasuredFromLevels() async throws {
        struct Failing: MicEchoCancelling {
            func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
                throw LocalVQEEchoCanceller.Failure.nonFiniteOutput
            }
        }
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = chunkFiles(in: dir)
        try LiftFixtures.writePair(system: files.system, mic: files.mic, hears: .headphones)
        let chunk = try #require(await run(try processor(in: dir, setup: .on(Failing())), in: dir))
        #expect(chunk.issues.contains { $0.code == .echoCancelFailed })
        let lift = try #require(chunk.farEndLift?.farEndLiftDB)
        #expect(lift < EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB)
    }

    /// Nothing to measure without a far end with audio, or without a mic: unknown, the rule as before #365.
    @Test func noFarEndOrNoMicIsNotMeasured() async throws {
        for writeMic in [true, false] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let files = chunkFiles(in: dir)
            try RecoveryFixtures.writeFakeWav(at: files.system, seconds: 0)
            if writeMic { try LiftFixtures.write(files.mic, seconds: 80) { LiftFixtures.noise($0) } }
            let chunk = try #require(await run(try processor(in: dir, setup: .off), in: dir))
            #expect(chunk.farEndLift == nil, "mic: \(writeMic)")
        }
    }

    /// Finalize writes the measure where re-detect reads it, with cancellation off.
    @Test func finalizeWritesTheMeasureWithCancellationOff() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = chunkFiles(in: dir)
        try LiftFixtures.writePair(system: files.system, mic: files.mic, hears: .headphones)
        let processor = try processor(in: dir, setup: .off)
        _ = await run(processor, in: dir, startTime: Date(timeIntervalSince1970: 600))
        let result = try await TranscriptionRunner().finalize(sessionState: await processor.getSessionState(),
                                                              outputDirectory: dir, config: .default)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["mic_echo_cancel"] == nil)
        let entries = try #require((metadata["acoustic_coupling"] as? [String: Any])?["per_chunk"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["start"] as? Double == 600)
        #expect((entries.first?["far_end_lift_db"] as? Double ?? 99) < 15)
    }

    /// The single-file path (CLI, legacy recovery) measures each segment too, cancellation off.
    @Test func theSingleFilePathMeasuresWithCancellationOff() async throws {
        for (hears, flagged) in [(LiftFixtures.Mic.headphones, false), (.loudspeaker, true)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let system = dir.appendingPathComponent("m.wav"), mic = dir.appendingPathComponent("m_mic.wav")
            try LiftFixtures.writePair(system: system, mic: mic, hears: hears)
            let runner = TranscriptionRunner()
            runner.engineFactoryForTesting = { _ in (RepeatedPhraseEngine(), FakeDiarizer()) }
            let result = try await runner.run(systemAudio: system, micAudio: mic, outputDirectory: dir, config: .default)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
            let metadata = try #require(json["metadata"] as? [String: Any])
            let entries = try #require((metadata["acoustic_coupling"] as? [String: Any])?["per_chunk"] as? [[String: Any]])
            #expect(entries.compactMap { $0["chunk"] as? Int } == [0])
            let local = (json["segments"] as? [[String: Any]] ?? []).first { $0["source"] as? String == "local" }
            #expect((local?["echo"] as? Bool ?? false) == flagged, "\(hears)")
        }
    }

    /// Re-detect reads the measure from the new place: a transcript without echo cancellation holds back the
    /// repeated phrase on a headphone chunk and flags it on a loudspeaker one.
    @Test func reDetectReadsTheMeasureWithoutCancellation() async throws {
        for (lift, expected) in [(2.5, 0), (31.0, 1)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
            for file in files {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                buffer.frameLength = 16000
                try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
            }
            var lines: [LabeledSegment] = []
            for i in 0..<10 {
                let start = Double(i) * 12
                lines.append(LabeledSegment(start: start, end: start + 5, speaker: "Local Speaker 1",
                                            text: "own\(i) words of the user number \(i) here", source: "local"))
                lines.append(LabeledSegment(start: start + 6, end: start + 11, speaker: "Remote Speaker 1",
                                            text: "far\(i) words of the other side \(i) there", source: "remote"))
            }
            lines.append(LabeledSegment(start: 130, end: 131.4, speaker: "Remote Speaker 1", text: "Not possible to wait.", source: "remote"))
            lines.append(LabeledSegment(start: 130.2, end: 131.6, speaker: "Local Speaker 1", text: "Not possible to wait.", source: "local"))
            let segments: [[String: Any]] = lines.map {
                ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "source": $0.source, "text": $0.text, "confidence": 0.9]
            }
            let metadata: [String: Any] = [
                "audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0],
                "acoustic_coupling": ["per_chunk": [["chunk": 0, "start": 0.0, "seconds": 600.0, "far_end_lift_db": lift]]],
            ]
            let transcript = dir.appendingPathComponent("t.json")
            try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": segments]).write(to: transcript)
            let locals = lines.filter { $0.source == "local" }
            let diarization = DiarizationResult(
                segments: locals.map { DiarizedSegment(start: $0.start, end: $0.end, speaker: "S1", qualityScore: 0.9) },
                speakerDatabase: ["S1": [1, 0, 0]])
            let outcome = try await TranscriptRediarizer.rediarize(
                transcript: transcript, source: "local", speakerCount: 1,
                diarizer: EchoLineMatchingTests.ScriptedDiarizer(result: diarization),
                echoCanceller: nil, rawLabeling: TranscriptRediarizer.label)
            #expect(outcome.echoFlagged == expected, "lift \(lift)")
        }
    }
}
