import Foundation
import Testing
@testable import TranscriberCore

/// #249: minority absorption used to run before echo dedup. A bleed cluster holding under
/// `diarization_min_speaker_share` of a chunk (the user switched to headphones a minute in) was
/// folded into the user and never judged as a cluster: its verdict and its notice were lost, and
/// whatever of it the per-line rule could not flag stayed under the user's name.
///
/// Now the mic stream's RAW clusters are judged for echo against the other channel first, and a
/// cluster judged echo is neither absorbed nor absorbs anything. Every fixture here is procedural:
/// made-up words, no recording.
enum BleedFixture {
    struct Line { let start: Double, end: Double, text: String }

    /// `count` made-up words that appear nowhere else: "own3x0 own3x1 …".
    static func words(_ tag: String, _ count: Int) -> String {
        (0..<count).map { "\(tag)x\($0)" }.joined(separator: " ")
    }

    /// The user: 40 lines of 20 s, one every 40 s — 800 s of speech nobody else says.
    static let own: [Line] = (0..<40).map { i in
        Line(start: Double(i) * 40, end: Double(i) * 40 + 20, text: words("own\(i)", 8))
    }
    /// The other side: 8 lines of 5 s in the user's pauses — 40 s.
    static let far: [Line] = (0..<8).map { i in
        Line(start: Double(i) * 40 + 25, end: Double(i) * 40 + 30, text: words("far\(i)", 8))
    }
    /// The mic hears the far side 0.2 s after the system audio has it.
    static let delay = 0.2
    static var bleed: [Line] { far.map { Line(start: $0.start + delay, end: $0.end + delay, text: $0.text) } }

    /// 40 s of bleed in 840 s of mic speech: 4.8 %, under the 5 % absorption share, and long enough
    /// (>= 30 s) to be judged as a cluster.
    static var micSegments: [TranscriptSegment] { (own + bleed).sorted { $0.start < $1.start }.map(segment) }
    static var systemSegments: [TranscriptSegment] { far.map(segment) }

    static func segment(_ line: Line) -> TranscriptSegment {
        TranscriptSegment(start: line.start, end: line.end, text: line.text, language: "en", confidence: 0.9)
    }
    static func turns(_ lines: [Line], _ speaker: String) -> [DiarizedSegment] {
        lines.map { DiarizedSegment(start: $0.start, end: $0.end, speaker: speaker, qualityScore: 0.9) }
    }

    /// The mic as the diarizer splits it: the user (S1) and the bleed (S2).
    static var micDiarization: DiarizationResult {
        DiarizationResult(segments: (turns(own, "S1") + turns(bleed, "S2")).sorted { $0.start < $1.start },
                          speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
    }
    static var systemDiarization: DiarizationResult {
        DiarizationResult(segments: turns(far, "R1"), speakerDatabase: ["R1": [0, 0, 1]])
    }

    /// The other channel as `StreamLabeling` hands it over: labelled, `source` stamped.
    static var remoteLines: [LabeledSegment] {
        far.map { LabeledSegment(start: $0.start, end: $0.end, speaker: "Speaker 1", text: $0.text, source: "remote") }
    }
    static var reference: StreamLabeling.EchoReference {
        StreamLabeling.EchoReference(segments: remoteLines, temporalThreshold: nil, textThreshold: nil)
    }

    /// Hears `systemSegments` on the system stream and `micSegments` on the microphone.
    struct Engine: TranscriptionEngine {
        let name = "Bleed"
        func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
            audioSource == .microphone ? BleedFixture.micSegments : BleedFixture.systemSegments
        }
        func isReady() -> Bool { true }
        func prepare() async throws {}
    }

    /// Splits the mic file as `micDiarization` and the system file as `systemDiarization`; keeps the
    /// names of the files it was handed.
    final class Diarizer: DiarizationProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String] = []
        var asked: [String] { lock.withLock { files } }

        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            lock.withLock { files.append(audioPath.lastPathComponent) }
            let isSystem = audioPath.lastPathComponent == "meeting-0.wav" || audioPath.lastPathComponent == "m.wav"
            return isSystem ? BleedFixture.systemDiarization : BleedFixture.micDiarization
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            BleedFixture.micDiarization
        }
    }

    /// One channel's segments holding these lines' texts.
    static func found<S>(_ lines: [Line], in segments: [S], text: (S) -> String) -> [S] {
        let texts = Set(lines.map(\.text))
        return segments.filter { texts.contains(text($0)) }
    }
}

@Suite("Echo before absorption: labelling (#249)")
struct EchoBeforeAbsorptionLabelingTests {

    private func label(_ diarization: DiarizationResult, segments: [TranscriptSegment] = BleedFixture.micSegments,
                       reference: StreamLabeling.EchoReference?) -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]], absorbed: Int) {
        StreamLabeling.withDiarization(
            segments: segments, diarizationResult: diarization, speechMap: nil, vadSpeechThreshold: 0.5,
            minSpeakerShare: DiarizationCleanup.defaultMinShare, echoReference: reference)
    }

    private func speakers(_ lines: [BleedFixture.Line], in labeled: [LabeledSegment]) -> Set<String> {
        Set(BleedFixture.found(lines, in: labeled, text: \.text).map(\.speaker))
    }

    @Test("a bleed cluster under the absorption share is judged first and kept apart, not folded into the user")
    func aSmallBleedClusterIsNotAbsorbed() {
        let result = label(BleedFixture.micDiarization, reference: BleedFixture.reference)
        #expect(speakers(BleedFixture.own, in: result.labeled) == ["Speaker 1"])
        #expect(speakers(BleedFixture.bleed, in: result.labeled) == ["Speaker 2"])
        #expect(result.absorbed == 0)
        #expect(result.speakerDatabase.keys.sorted() == ["Speaker 1", "Speaker 2"])
        // Labelling only: the flags are the echo dedup's, which runs on the chunk afterwards.
        #expect(!result.labeled.contains { $0.echo })
        #expect(result.labeled.count == BleedFixture.micSegments.count)
    }

    @Test("without the other channel (the system stream, or no mic stream) absorption runs as before")
    func withoutAReferenceAbsorptionIsUnchanged() {
        let result = label(BleedFixture.micDiarization, reference: nil)
        #expect(Set(result.labeled.map(\.speaker)) == ["Speaker 1"])
        #expect(result.absorbed == 1)
        #expect(result.speakerDatabase.keys.sorted() == ["Speaker 1"])
    }

    @Test("a small cluster of the user's own voice, which repeats nothing on the other side, is absorbed as before")
    func aFragmentOfTheUserIsStillAbsorbed() {
        // The user's last line (20 s, 2.5 %) as a cluster of its own; no bleed at all.
        let main = Array(BleedFixture.own.dropLast(1)), fragment = Array(BleedFixture.own.suffix(1))
        let diarization = DiarizationResult(
            segments: BleedFixture.turns(main, "S1") + BleedFixture.turns(fragment, "S2"),
            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
        let segments = BleedFixture.own.map(BleedFixture.segment)
        let result = label(diarization, segments: segments, reference: BleedFixture.reference)
        let plain = label(diarization, segments: segments, reference: nil)
        #expect(Set(result.labeled.map(\.speaker)) == ["Speaker 1"])
        #expect(result.absorbed == 1)
        #expect(result.labeled.map(\.speaker) == plain.labeled.map(\.speaker))
        #expect(result.speakerDatabase.keys.sorted() == plain.speakerDatabase.keys.sorted())
    }

    @Test("when the echo voice holds most of the channel, the user's own fragment is not absorbed into it")
    func nothingIsAbsorbedIntoADominantEchoCluster() {
        // The user mostly listened: 8 bleed lines of 60 s (480 s), the user's 3 lines of 20 s
        // (60 s, 10 %) and one 10 s line (1.8 %) the clusterer split off.
        let far = (0..<8).map { i in BleedFixture.Line(start: Double(i) * 100, end: Double(i) * 100 + 60, text: BleedFixture.words("far\(i)", 8)) }
        let bleed = far.map { BleedFixture.Line(start: $0.start + 0.2, end: $0.end + 0.2, text: $0.text) }
        let user = (0..<3).map { i in BleedFixture.Line(start: Double(i) * 100 + 70, end: Double(i) * 100 + 90, text: BleedFixture.words("own\(i)", 8)) }
        let fragment = [BleedFixture.Line(start: 370, end: 380, text: BleedFixture.words("ownfragment", 8))]
        let diarization = DiarizationResult(
            segments: (BleedFixture.turns(bleed, "S1") + BleedFixture.turns(user, "S2") + BleedFixture.turns(fragment, "S3"))
                .sorted { $0.start < $1.start },
            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1]])
        let reference = StreamLabeling.EchoReference(
            segments: far.map { LabeledSegment(start: $0.start, end: $0.end, speaker: "Speaker 1", text: $0.text, source: "remote") },
            temporalThreshold: nil, textThreshold: nil)
        let result = label(diarization, segments: (bleed + user + fragment).sorted { $0.start < $1.start }.map(BleedFixture.segment),
                           reference: reference)
        #expect(result.absorbed == 0)
        #expect(speakers(fragment, in: result.labeled).count == 1)
        #expect(speakers(fragment, in: result.labeled) != speakers(bleed, in: result.labeled))
        #expect(result.speakerDatabase.count == 3)
    }

    @Test("a stated speaker count still turns absorption off, echo check or not")
    func aStatedCountStillDisablesAbsorption() {
        let result = StreamLabeling.withDiarization(
            segments: BleedFixture.micSegments, diarizationResult: BleedFixture.micDiarization, speechMap: nil,
            vadSpeechThreshold: 0.5, minSpeakerShare: DiarizationCleanup.defaultMinShare, echoReference: nil,
            speakerCountIsUserStated: true)
        #expect(result.absorbed == 0)
        #expect(Set(result.labeled.map(\.speaker)) == ["Speaker 1", "Speaker 2"])
    }
}

/// The live pipeline end to end: `ChunkProcessor` and `TranscriptionRunner.run` hand the mic stream
/// the system stream's lines, so the bleed cluster reaches the echo dedup as a cluster.
@MainActor
@Suite("Echo before absorption: the pipeline (#249)")
struct EchoBeforeAbsorptionPipelineTests {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EchoBeforeAbsorption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func process(in dir: URL, diarizer: BleedFixture.Diarizer,
                         micEchoCancel: MicEchoCancelSetup = .off) async throws -> ProcessedChunk {
        let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let processor = ChunkProcessor(
            config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
                                       engine: "fluidAudio", chunkDurationMinutes: 30, chunks: []),
            transcriber: BleedFixture.Engine(), diarizer: diarizer, scratchDirectory: scratch, micEchoCancel: micEchoCancel)
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: sys.path, micPath: mic.path, startTime: Date(timeIntervalSince1970: 0)))
        return try #require(await processor.getSessionState().chunks.first)
    }

    private func local(_ lines: [BleedFixture.Line], in chunk: ProcessedChunk) -> [ProcessedChunk.Segment] {
        BleedFixture.found(lines, in: chunk.segments.filter { $0.source == "local" }, text: \.text)
    }

    /// What the chunk must hold whichever way the mic was read.
    private func expectTheBleedJudgedAsACluster(_ chunk: ProcessedChunk) throws {
        // The user's lines: under the user's label, none hidden.
        #expect(Set(local(BleedFixture.own, in: chunk).map(\.speaker)) == ["Local Speaker 1"])
        #expect(!local(BleedFixture.own, in: chunk).contains { $0.echo })
        // The bleed: its own cluster, judged echo, every line flagged — none under the user's label.
        #expect(Set(local(BleedFixture.bleed, in: chunk).map(\.speaker)) == ["Local Speaker 2"])
        #expect(local(BleedFixture.bleed, in: chunk).allSatisfy { $0.echo })
        #expect(chunk.echoSegmentsFlagged == BleedFixture.bleed.count)
        let verdict = try #require(chunk.echoClusters.first { $0.label == "Local Speaker 2" })
        #expect(verdict.verdict == .echo && verdict.segments == 8 && verdict.matchedSegments == 8)
        #expect(chunk.echoClusters.first { $0.label == "Local Speaker 1" }?.verdict == .kept)
        #expect(chunk.issues.contains(ChunkIssue(code: .echoCluster, track: "local", count: 1)))
        #expect(!chunk.issues.contains { $0.code == .clustersAbsorbed && $0.track == "local" })
        #expect(chunk.localSpeakerDatabase.keys.sorted() == ["Speaker 1", "Speaker 2"])
        // Flagged, never deleted.
        #expect(chunk.segments.count == BleedFixture.micSegments.count + BleedFixture.systemSegments.count)
    }

    @Test("a chunk: the small bleed cluster keeps its verdict, its lines are flagged and none is the user's")
    func aChunkJudgesTheBleedAsACluster() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = try await process(in: dir, diarizer: BleedFixture.Diarizer())
        try expectTheBleedJudgedAsACluster(chunk)
    }

    /// #342: with echo cancellation on, ASR, diarization and so the echo check read the cleaned copy;
    /// the raw mic stays what is archived.
    @Test("with mic echo cancellation on, the cleaned mic is diarized and the raw mic archived")
    func theCleanedMicFeedsTheCheck() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let diarizer = BleedFixture.Diarizer()
        let chunk = try await process(in: dir, diarizer: diarizer, micEchoCancel: .on(CopyingMicCanceller()))
        try expectTheBleedJudgedAsACluster(chunk)
        #expect(diarizer.asked.first == "meeting-0.wav")
        #expect(diarizer.asked.last?.hasPrefix("parley-mic-aec-0-") == true, "the mic diarized was the cleaned copy: \(diarizer.asked)")
        #expect(chunk.audioPath == "meeting-0.m4a")
        #expect(chunk.micEchoCancel != nil)
    }

    @Test("the single-file path (CLI, legacy recovery): the bleed cluster is judged before absorption too")
    func theSingleFilePathJudgesTheBleedAsACluster() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("m.wav"), mic = dir.appendingPathComponent("m_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: system, seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
        let runner = TranscriptionRunner()
        runner.engineFactoryForTesting = { _ in (BleedFixture.Engine(), BleedFixture.Diarizer()) }
        let result = try await runner.run(systemAudio: system, micAudio: mic, outputDirectory: dir, config: .default)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]]).filter { $0["source"] as? String == "local" }
        let bleed = BleedFixture.found(BleedFixture.bleed, in: segments) { $0["text"] as? String ?? "" }
        let own = BleedFixture.found(BleedFixture.own, in: segments) { $0["text"] as? String ?? "" }
        #expect(Set(bleed.compactMap { $0["speaker"] as? String }) == ["Local Speaker 2"])
        #expect(bleed.allSatisfy { $0["echo"] as? Bool == true })
        #expect(Set(own.compactMap { $0["speaker"] as? String }) == ["Local Speaker 1"])
        #expect(own.allSatisfy { $0["echo"] == nil })
        let clusters = try #require((json["metadata"] as? [String: Any])?["echo_clusters"] as? [[String: Any]])
        #expect(clusters.first { $0["label"] as? String == "Local Speaker 2" }?["verdict"] as? String == "echo")
    }
}

/// Copies the mic to the output, as a canceller that removed nothing would.
private struct CopyingMicCanceller: MicEchoCancelling {
    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        try FileManager.default.copyItem(at: micURL, to: outputURL)
        return MicEchoCancelRecord(engine: "fake", modelSHA256: String(repeating: "b", count: 64), framesReverted: 0, seconds: 1)
    }
}
