import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// Who is late (#252): the original precedes its copy. A local cluster whose matched lines lead the remote
/// lines they match is the user's own voice, returned by the far end — not an echo of the far end. Synthetic
/// lines only; the margin needs a real recording of the mirror case to confirm.
enum MirrorFixture {
    /// `count` made-up words that appear nowhere else.
    static func words(_ tag: String, _ count: Int) -> String {
        (0..<count).map { "\(tag)x\($0)" }.joined(separator: " ")
    }

    static func remote(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Remote Speaker 1", text: text, source: "remote")
    }

    static func local(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Local Speaker 1", text: text, source: "local")
    }

    /// One local line and one remote line per lag, 8 s long, 20 s apart, the same 6 words: the local line
    /// starts `lag` seconds after the remote one (negative: the local side leads). Five or more make 40 s or
    /// more of matched speech: an echo cluster by its share alone.
    static func pairs(_ lags: [Double]) -> [LabeledSegment] {
        lags.enumerated().flatMap { i, lag -> [LabeledSegment] in
            let start = Double(i) * 20, text = words("p\(i)", 6)
            return [remote(start, start + 8, text), local(start + lag, start + 8 + lag, text)]
        }
    }

    /// The user's lines nobody else says: `count` of 10 s, in the gaps of `pairs`.
    static func own(_ count: Int) -> [LabeledSegment] {
        (0..<count).map { i in local(Double(i) * 20 + 9, Double(i) * 20 + 19, words("own\(i)", 8)) }
    }

    static func dedup(_ segments: [LabeledSegment], margin: Double? = nil) -> EchoDeduplicator.DeduplicationResult {
        EchoDeduplicator.deduplicate(segments: segments.sorted { $0.start < $1.start }, localSpeakerDatabase: [:],
                                     remoteSpeakerDatabase: [:], localLeadMarginSeconds: margin)
    }
}

@Suite struct EchoLeadLagTests {
    private typealias F = MirrorFixture

    /// The mirror case: the far end returns the user's voice 0.4 s late (AirPods, 2026-10-07: 0.4-0.6 s).
    /// By share alone the user's cluster was echo and every line hidden; the user's side leads, so it is kept.
    @Test func aClusterThatLeadsTheRemoteIsTheOriginalNotTheEcho() throws {
        let result = F.dedup(F.pairs(Array(repeating: -0.4, count: 5)))
        let verdict = try #require(result.clusters.first)
        #expect(verdict.share == 1 && verdict.seconds >= EchoDeduplicator.clusterMinimumSeconds, "an echo cluster by share")
        #expect(verdict.verdict == .kept)
        #expect(verdict.reason == EchoDeduplicator.ClusterVerdict.reasonLocalLeads)
        #expect(abs((verdict.medianLagSeconds ?? 0) + 0.4) < 1e-9)
        #expect(verdict.lagPairs == 5)
        #expect(result.flaggedCount == 0)
        let locals = Set(result.segments.indices.filter { result.segments[$0].source == "local" })
        #expect(result.heldBack == locals, "every matched line held back as the user's own")
        #expect(result.issues.isEmpty)
    }

    /// #242's bleed: the local copy trails the remote by a median of +0.08 s (IQR 0.00-0.08). Unchanged.
    @Test func theBleedCaseFrom242IsUnaffected() throws {
        let result = F.dedup(F.pairs([0, 0, 0.08, 0.08, 0.08, 0.16, -0.04, 0.24]))
        let verdict = try #require(result.clusters.first)
        #expect(verdict.verdict == .echo)
        #expect(verdict.reason == nil)
        #expect(abs((verdict.medianLagSeconds ?? 0) - 0.08) < 1e-9)
        #expect(result.flaggedCount == 8)
        #expect(result.heldBack.isEmpty)
    }

    /// About one pair in eight is placed more than 0.2 s off (the channels are segmented differently): a
    /// median, not a per-line rule, so one early line does not turn a bleed cluster into the original.
    @Test func aNoisyBleedClusterStillTrails() throws {
        let result = F.dedup(F.pairs([0.08, 0.08, -0.5, 0.0, 0.08, 0.16, 0.04, 0.08]))
        #expect(result.clusters.first?.verdict == .echo)
        #expect(result.flaggedCount == 8)
    }

    /// Outside an echo cluster: the user repeats lines the far end then plays back 0.2 s late — inside the
    /// per-line rule's 0.3 s timing tolerance, so only the cluster's median keeps them.
    @Test func theUsersLinesInAKeptClusterAreNotFlaggedWhenTheyLead() throws {
        let segments = F.pairs([-0.2, -0.2, -0.2]) + F.own(20)
        let result = F.dedup(segments)
        let verdict = try #require(result.clusters.first)
        #expect(verdict.verdict == .kept && verdict.reason == EchoDeduplicator.ClusterVerdict.reasonLocalLeads)
        #expect(result.flaggedCount == 0)
        #expect(result.heldBack.count == 3)

        // The same lines with a wider margin: the per-line rule flags them, as before #252.
        let wider = F.dedup(segments, margin: 0.25)
        #expect(wider.flaggedCount == 3)
        #expect(wider.clusters.first?.reason == nil)
        #expect(abs((wider.clusters.first?.medianLagSeconds ?? 0) + 0.2) < 1e-9, "the median is recorded either way")
    }

    /// Fewer than `minimumLagPairs` matched lines give no median worth trusting: the per-line rules decide.
    @Test func fewerThanThreeLinesDoNotDecide() throws {
        let result = F.dedup(F.pairs([-0.2, -0.2]) + F.own(20))
        let verdict = try #require(result.clusters.first)
        #expect(verdict.lagPairs == 2 && verdict.reason == nil)
        #expect(result.flaggedCount == 2)
    }

    /// Only near-identical pairs are timed, as the issue's data was: a short excerpt of a longer remote line
    /// (matched by containment) or a line matched against several remote lines joined is placed by where the
    /// recognisers cut it, not by who spoke first.
    @Test func onlyNearIdenticalPairsAreTimed() throws {
        var segments: [LabeledSegment] = []
        for i in 0..<5 {
            let start = Double(i) * 20, text = F.words("c\(i)", 12)
            segments.append(F.remote(start, start + 10, text))
            // The first 4 of its 12 words, placed 0.4 s before it: a containment match, not a copy's timing.
            let excerpt = text.split(separator: " ").prefix(4).joined(separator: " ")
            segments.append(F.local(start - 0.4, start + 7.6, excerpt))
        }
        let result = F.dedup(segments)
        let verdict = try #require(result.clusters.first)
        #expect(verdict.matchedSegments == 5)
        #expect(verdict.lagPairs == nil && verdict.medianLagSeconds == nil && verdict.reason == nil)
        #expect(verdict.verdict == .echo)
    }

    /// "More than the margin": a median exactly at it is not a lead.
    @Test func aMedianExactlyAtTheMarginIsNotALead() {
        #expect(F.dedup(F.pairs(Array(repeating: -0.25, count: 5)), margin: 0.25).clusters.first?.verdict == .echo)
        #expect(F.dedup(F.pairs(Array(repeating: -0.5, count: 5)), margin: 0.25).clusters.first?.verdict == .kept)
    }

    /// The default is 0.1 s; a margin outside 0-1 s is not obeyed; 0 is a valid margin.
    @Test func theMarginDefaultsAndIsBounded() {
        #expect(EchoDeduplicator.defaultLocalLeadMarginSeconds == 0.1)
        let leadsByTwoTenths = F.pairs(Array(repeating: -0.2, count: 5))
        for margin in [nil, -1, 5, .nan, .infinity] as [Double?] {
            #expect(F.dedup(leadsByTwoTenths, margin: margin).clusters.first?.verdict == .kept, "margin \(String(describing: margin))")
        }
        let leadsByFiveHundredths = F.pairs(Array(repeating: -0.05, count: 5))
        #expect(F.dedup(leadsByFiveHundredths).clusters.first?.verdict == .echo, "inside the default margin")
        #expect(F.dedup(leadsByFiveHundredths, margin: 0).clusters.first?.verdict == .kept)
    }

    /// The verdict says why, in session.json and in `metadata.echo_clusters`; a verdict written before #252
    /// still reads.
    @Test func theVerdictRecordsWhy() throws {
        let verdict = try #require(F.dedup(F.pairs(Array(repeating: -0.4, count: 5))).clusters.first)
        let entry = verdict.metadataDictionary(chunk: 2)
        #expect(entry["reason"] as? String == "local_leads")
        #expect(entry["median_lag_seconds"] as? Double == -0.4)
        #expect(entry["lag_pairs"] as? Int == 5)
        #expect(entry["verdict"] as? String == "kept")

        let data = try JSONEncoder().encode(verdict)
        #expect(try JSONDecoder().decode(EchoDeduplicator.ClusterVerdict.self, from: data) == verdict)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["reason"] = nil; older["median_lag_seconds"] = nil; older["lag_pairs"] = nil
        let decoded = try JSONDecoder().decode(EchoDeduplicator.ClusterVerdict.self,
                                               from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.reason == nil && decoded.medianLagSeconds == nil && decoded.lagPairs == nil)

        // Without a matched line there is no lag to record.
        let quiet = try #require(F.dedup(F.own(5)).clusters.first)
        #expect(quiet.medianLagSeconds == nil && quiet.lagPairs == nil)
        #expect(quiet.metadataDictionary(chunk: nil)["median_lag_seconds"] == nil)
    }
}

@Suite struct EchoLeadLagConfigTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func theMarginIsAConfigKey() throws {
        #expect(Config.default.echoLocalLeadMarginSeconds == nil)
        #expect(Config.default.resolvedEchoLocalLeadMarginSeconds == 0.1)
        var config = Config.default
        config.echoLocalLeadMarginSeconds = 0.3
        let data = try JSONEncoder().encode(config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["echo_local_lead_margin_seconds"] as? Double == 0.3)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.resolvedEchoLocalLeadMarginSeconds == 0.3)
    }

    @Test func aMarginOutsideItsRangeIsTheDefault() {
        for margin in [-0.1, 1.5, Double.nan] {
            var config = Config.default
            config.echoLocalLeadMarginSeconds = margin
            #expect(config.resolvedEchoLocalLeadMarginSeconds == 0.1, "\(margin)")
        }
        var zero = Config.default
        zero.echoLocalLeadMarginSeconds = 0
        #expect(zero.resolvedEchoLocalLeadMarginSeconds == 0)
    }
}

/// Plays the mirror case on the two streams: the mic holds the user's lines, the system the far end's copy
/// of them `lag` seconds later.
private struct MirrorEngine: TranscriptionEngine {
    let name = "Mirror"
    let lag: Double
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        (0..<5).map { i in
            let start = Double(i) * 20 + (audioSource == .system ? lag : 0)
            return TranscriptSegment(start: start, end: start + 8, text: MirrorFixture.words("p\(i)", 6), language: "en")
        }
    }
    func isReady() -> Bool { true }
    func prepare() async throws {}
}

@MainActor
@Suite struct EchoLeadLagWiringTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EchoLeadLag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The chunk path reads `echo_local_lead_margin_seconds`: with the default the user's lines stay, with a
    /// margin past the round trip they are hidden as before #252.
    @Test func theChunkPathReadsTheConfiguredMargin() async throws {
        for (margin, flagged) in [(nil, false), (1.0, true)] as [(Double?, Bool)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let sys = dir.appendingPathComponent("meeting-0.wav"), mic = dir.appendingPathComponent("meeting-0_mic.wav")
            try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
            try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
            var config = Config.default
            config.echoLocalLeadMarginSeconds = margin
            let processor = ChunkProcessor(
                config: config, outputDirectory: dir,
                sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0),
                                           engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
                transcriber: MirrorEngine(lag: 0.4), diarizer: FakeDiarizer(), scratchDirectory: dir)
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(
                index: 0, systemPath: sys.path, micPath: mic.path, startTime: Date(timeIntervalSince1970: 0)))
            let chunk = try #require(await processor.getSessionState().chunks.first)
            let locals = chunk.segments.filter { $0.source == "local" }
            #expect(locals.count == 5)
            #expect(locals.allSatisfy { $0.echo == flagged }, "margin \(String(describing: margin))")
            #expect((chunk.echoClusters.first?.reason == "local_leads") == !flagged)
        }
    }

    /// The single-file path (CLI, legacy recovery) too.
    @Test func theSingleFilePathReadsTheConfiguredMargin() async throws {
        for (margin, flagged) in [(nil, false), (1.0, true)] as [(Double?, Bool)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let sys = dir.appendingPathComponent("m.wav"), mic = dir.appendingPathComponent("m_mic.wav")
            try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1)
            try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1)
            var config = Config.default
            config.echoLocalLeadMarginSeconds = margin
            let runner = TranscriptionRunner()
            runner.engineFactoryForTesting = { _ in (MirrorEngine(lag: 0.4), FakeDiarizer()) }
            let result = try await runner.run(systemAudio: sys, micAudio: mic, outputDirectory: dir, config: config)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
            let locals = (json["segments"] as? [[String: Any]] ?? []).filter { $0["source"] as? String == "local" }
            #expect(locals.count == 5)
            #expect(locals.allSatisfy { ($0["echo"] as? Bool ?? false) == flagged }, "margin \(String(describing: margin))")
            let clusters = (json["metadata"] as? [String: Any])?["echo_clusters"] as? [[String: Any]] ?? []
            #expect((clusters.first?["reason"] as? String == "local_leads") == !flagged)
        }
    }

    /// The check before minority absorption (#249) judges by the same rule: a small mic cluster the far end
    /// returned is the user's, and is absorbed like any fragment instead of being kept apart as echo.
    @Test func thePreAbsorptionCheckDoesNotKeepALeadingClusterApart() {
        typealias Line = BleedFixture.Line
        let own: [Line] = (0..<40).map { i in
            Line(start: Double(i) * 40, end: Double(i) * 40 + 20, text: MirrorFixture.words("own\(i)", 8))
        }
        let returned: [Line] = (0..<8).map { i in
            Line(start: Double(i) * 40 + 25, end: Double(i) * 40 + 30, text: MirrorFixture.words("u\(i)", 8))
        }
        let micSegments: [TranscriptSegment] = (own + returned).sorted { $0.start < $1.start }.map(BleedFixture.segment)
        let turns: [DiarizedSegment] = BleedFixture.turns(own, "S1") + BleedFixture.turns(returned, "S2")
        let diarization = DiarizationResult(segments: turns.sorted { $0.start < $1.start },
                                            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
        // The far end plays the user's 8 lines back 0.4 s late.
        let copies: [LabeledSegment] = returned.map { line in
            LabeledSegment(start: line.start + 0.4, end: line.end + 0.4, speaker: "Speaker 1", text: line.text, source: "remote")
        }
        func absorbed(margin: Double) -> Int {
            StreamLabeling.withDiarization(
                segments: micSegments, diarizationResult: diarization, speechMap: nil, vadSpeechThreshold: 0.5,
                minSpeakerShare: DiarizationCleanup.defaultMinShare,
                echoReference: StreamLabeling.EchoReference(segments: copies, temporalThreshold: nil, textThreshold: nil,
                                                           localLeadMarginSeconds: margin)
            ).absorbed
        }
        #expect(absorbed(margin: 0.1) == 1, "the user's own fragment, absorbed")
        #expect(absorbed(margin: 1.0) == 0, "judged echo by share alone, kept apart")
    }

    /// Re-detect judges by the same rule, with the margin the dialog passes.
    @Test func reDetectKeepsTheUsersLinesWhenTheyLead() async throws {
        for (margin, flaggedAny) in [(nil, false), (1.0, true)] as [(Double?, Bool)] {
            let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
            for file in files {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                buffer.frameLength = 16000
                try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
            }
            let lines = MirrorFixture.pairs(Array(repeating: -0.4, count: 5))
            let segments: [[String: Any]] = lines.map {
                ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "source": $0.source, "text": $0.text, "confidence": 0.9]
            }
            let transcript = dir.appendingPathComponent("t.json")
            try JSONSerialization.data(withJSONObject: [
                "metadata": ["audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0]], "segments": segments,
            ]).write(to: transcript)
            let diarization = DiarizationResult(
                segments: lines.filter { $0.source == "local" }
                    .map { DiarizedSegment(start: $0.start, end: $0.end, speaker: "S1", qualityScore: 0.9) },
                speakerDatabase: ["S1": [1, 0, 0]])
            let outcome = try await TranscriptRediarizer.rediarize(
                transcript: transcript, source: "local", speakerCount: 1,
                diarizer: EchoLineMatchingTests.ScriptedDiarizer(result: diarization),
                echoCanceller: nil, echoLocalLeadMarginSeconds: margin, rawLabeling: TranscriptRediarizer.label)
            #expect((outcome.echoFlagged > 0) == flaggedAny, "margin \(String(describing: margin))")
        }
    }
}
