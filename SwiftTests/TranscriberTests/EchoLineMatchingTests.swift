import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// The per-line echo decision (#363, #365). Synthetic lines only, nothing from a recording.
struct EchoLineMatchingTests {

    private func remote(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Remote Speaker 1", text: text, source: "remote")
    }

    private func local(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Local Speaker 1", text: text, source: "local")
    }

    private func flagged(_ result: EchoDeduplicator.DeduplicationResult) -> [String] {
        result.segments.filter(\.echo).map(\.text)
    }

    // MARK: - #363: numbers written two ways

    /// The loudspeaker call behind #363: the mic's recogniser spelled the numbers out, the system's wrote
    /// digits. Word overlap was 40-67 %, so these echo lines were not flagged.
    @Test func anEchoWhoseNumbersTheTwoSidesWroteDifferentlyIsFlagged() {
        let segments = [
            remote(10, 13, "The price is 195 per seat."),
            local(10.2, 13.2, "The price is one ninety five per seat."),
            remote(20, 24, "In 2026 we had 183 of them."),
            local(20.2, 24.2, "In twenty twenty six we had one eighty three of them."),
            remote(30, 33, "We budgeted 7,500 for it."),
            local(30.2, 33.2, "We budgeted seven thousand five hundred for it."),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 3)
        #expect(result.segments.filter { $0.source == "local" }.allSatisfy { $0.echo })
    }

    /// A short line whose number differs does not match: the number is one word, whatever its spelling.
    /// (Its unnormalised words matched no better: "one eighty five" against "195" shares nothing.)
    @Test func aLineWithADifferentNumberIsNotFlagged() {
        let segments = [
            remote(10, 12, "It was 195."),
            local(10.2, 12.2, "It was one eighty five."),
            remote(20, 23, "We budgeted 7,500."),
            local(20.2, 23.2, "We budgeted seven thousand six hundred."),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 0)
    }

    // MARK: - #365 (a): no acoustic coupling, no per-line flag

    private func record(lift: Double?) -> MicEchoCancelRecord {
        MicEchoCancelRecord(engine: "e", modelSHA256: "a", framesReverted: 0, seconds: 600, delaySamples: 384,
                            erleDB: lift.map { $0 > 15 ? 45 : 0 }, farEndLiftDB: lift)
    }

    /// The user's own lines on a headphone call, plus one short phrase that repeats the far end's word for
    /// word at the same moment: what the per-line rule cannot tell from an echo by time and text alone.
    private func headphoneChunk() -> [LabeledSegment] {
        var segments: [LabeledSegment] = []
        for i in 0..<10 {
            let start = Double(i) * 12
            segments.append(local(start, start + 5, "own\(i) words of the user number \(i) here"))
            segments.append(remote(start + 6, start + 11, "far\(i) words of the other side \(i) there"))
        }
        segments.append(remote(130, 131.4, "Not possible to wait."))
        segments.append(local(130.2, 131.6, "Not possible to wait."))
        return segments
    }

    /// The issue's test: echo cancellation measured the far end 2.5 dB above the mic's floor (a headphone
    /// call; a loudspeaker call that day measured 31 dB), so a phrase the user repeats stays theirs.
    @Test func aRepeatedPhraseOnAHeadphoneChunkIsNotFlagged() {
        let result = EchoDeduplicator.deduplicate(
            segments: headphoneChunk(), localSpeakerDatabase: [:], remoteSpeakerDatabase: [:],
            coupling: .chunk(record(lift: 2.5)))
        #expect(result.flaggedCount == 0)
        #expect(result.clusters.first?.matchedSegments == 1, "it still matches, and the verdict says so")
    }

    /// The same line where the canceller measured the far end in the mic: a loudspeaker echo copy.
    @Test func aLoudspeakerEchoCopyIsStillFlagged() {
        let result = EchoDeduplicator.deduplicate(
            segments: headphoneChunk(), localSpeakerDatabase: [:], remoteSpeakerDatabase: [:],
            coupling: .chunk(record(lift: 31)))
        #expect(flagged(result) == ["Not possible to wait."])
    }

    /// No record (cancellation off), or a lift too little far-end speech was there to measure: unknown,
    /// and the per-line rule applies as before.
    @Test func withoutAMeasureThePerLineRuleApplies() {
        for coupling in [EchoDeduplicator.AcousticCoupling.unknown, .chunk(nil), .chunk(record(lift: nil))] {
            let result = EchoDeduplicator.deduplicate(
                segments: headphoneChunk(), localSpeakerDatabase: [:], remoteSpeakerDatabase: [:], coupling: coupling)
            #expect(flagged(result) == ["Not possible to wait."])
        }
    }

    /// The threshold is the canceller's own line for "the mic heard the far end".
    @Test func theCouplingThresholdIsTheAudibleEchoLift() {
        #expect(EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB == EchoReduction.audibleEchoLiftDB)
        #expect(EchoDeduplicator.AcousticCoupling.chunk(record(lift: 14.9)).isUncoupled(start: 0, end: 1))
        #expect(!EchoDeduplicator.AcousticCoupling.chunk(record(lift: 15)).isUncoupled(start: 0, end: 1))
    }

    /// An echo CLUSTER is judged as before: (a) holds back only the lines outside one.
    @Test func anEchoClusterIsFlaggedWhateverTheCoupling() {
        var segments: [LabeledSegment] = []
        for i in 0..<10 {
            let start = Double(i) * 6
            let text = "far\(i) words of the other side \(i) there"
            segments.append(remote(start, start + 5, text))
            segments.append(LabeledSegment(start: start + 0.2, end: start + 5.2, speaker: "Local Speaker 2", text: text, source: "local"))
        }
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:], coupling: .chunk(record(lift: 2.5)))
        #expect(result.flaggedCount == 10)
        #expect(result.clusters.first?.verdict == .echo)
    }

    /// Over a whole transcript (re-detect) the measure is per chunk: a line in a chunk without coupling is
    /// held back, the same line in a chunk with coupling is flagged.
    @Test func overATranscriptTheMeasureAppliesToItsOwnChunk() {
        let coupling = EchoDeduplicator.AcousticCoupling(spans: [
            .init(start: 0, end: 600, farEndLiftDB: 2.5),
            .init(start: 600, end: 1200, farEndLiftDB: 31),
        ])
        let segments = [
            remote(100, 101.4, "Not possible to wait."), local(100.2, 101.6, "Not possible to wait."),
            remote(700, 701.4, "Okay then thank you."), local(700.2, 701.6, "Okay then thank you."),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:], coupling: coupling)
        #expect(flagged(result) == ["Okay then thank you."])
        // A line across the boundary touches the uncoupled chunk: held back.
        #expect(coupling.isUncoupled(start: 599, end: 601))
        #expect(!coupling.isUncoupled(start: 601, end: 602))
        #expect(!coupling.isUncoupled(start: 1300, end: 1301), "past every measured chunk: unknown")
    }

    // MARK: - #365 (a): the record reaches the transcript and re-detect

    @Test func theTranscriptKeepsEachChunksMeasureAndPlace() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let chunks = [
            ProcessedChunk(index: 0, startTime: start, audioPath: "a.m4a", segments: [], speakerDatabase: [:],
                           micEchoCancel: record(lift: 2.5)),
            ProcessedChunk(index: 1, startTime: start.addingTimeInterval(610), audioPath: "b.m4a", segments: [], speakerDatabase: [:],
                           micEchoCancel: record(lift: nil)),
            ProcessedChunk(index: 2, startTime: start.addingTimeInterval(1220), audioPath: "c.m4a", segments: [], speakerDatabase: [:]),
        ]
        let d = try #require(TranscriptionRunner.micEchoCancelDictionary(chunks: chunks, meetingStart: start))
        let entries = try #require(d["per_chunk"] as? [[String: Any]])
        #expect(entries.count == 2, "only the chunks cancellation ran on")
        #expect(entries[0]["chunk"] as? Int == 0 && entries[0]["start"] as? Double == 0 && entries[0]["seconds"] as? Double == 600)
        #expect(entries[0]["far_end_lift_db"] as? Double == 2.5 && entries[0]["erle_db"] as? Double == 0)
        #expect(entries[1]["chunk"] as? Int == 1 && entries[1]["start"] as? Double == 610 && entries[1]["far_end_lift_db"] == nil)

        let coupling = EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["mic_echo_cancel": d])
        #expect(coupling.isUncoupled(start: 100, end: 101))
        #expect(!coupling.isUncoupled(start: 700, end: 701), "no measure there")
        #expect(TranscriptionRunner.micEchoCancelDictionary(chunks: chunks)?["per_chunk"] == nil, "no meeting start, no places")
    }

    @Test func aTranscriptWithoutTheMeasureIsUnknown() {
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: [:]) == .unknown)
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: ["mic_echo_cancel": ["chunks": 2]]) == .unknown)
        let odd: [String: Any] = ["mic_echo_cancel": ["per_chunk": [
            ["start": "x", "seconds": 1, "far_end_lift_db": 1], ["start": 0, "seconds": -5, "far_end_lift_db": 1],
            ["start": Double.nan, "seconds": 5, "far_end_lift_db": 1], ["start": 0, "seconds": 5],
        ]]]
        #expect(EchoDeduplicator.AcousticCoupling(transcriptMetadata: odd).isUncoupled(start: 1, end: 2) == false)
    }

    /// Re-detect runs the same rules, with the chunks' measure read from the transcript.
    @Test func reDetectHoldsBackARepeatedPhraseOnAnUncoupledChunk() async throws {
        for (lift, expected) in [(2.5, 0), (31.0, 1)] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-line-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let files = [dir.appendingPathComponent("call-0_mic.wav"), dir.appendingPathComponent("call-1.wav")]
            for file in files {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                buffer.frameLength = 16000
                try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
            }
            let segments: [[String: Any]] = headphoneChunk().map {
                ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "source": $0.source, "text": $0.text, "confidence": 0.9]
            }
            let metadata: [String: Any] = [
                "audio_paths": files.map(\.path), "chunk_durations": [1.0, 1.0],
                "mic_echo_cancel": ["chunks": 1, "chunks_failed": 0,
                                    "per_chunk": [["chunk": 0, "start": 0.0, "seconds": 600.0, "far_end_lift_db": lift]]],
            ]
            let transcript = dir.appendingPathComponent("t.json")
            try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": segments]).write(to: transcript)
            let locals = headphoneChunk().filter { $0.source == "local" }
            let diarization = DiarizationResult(
                segments: locals.map { DiarizedSegment(start: $0.start, end: $0.end, speaker: "S1", qualityScore: 0.9) },
                speakerDatabase: ["S1": [1, 0, 0]])
            let outcome = try await TranscriptRediarizer.rediarize(
                transcript: transcript, source: "local", speakerCount: 1, diarizer: ScriptedDiarizer(result: diarization),
                echoCanceller: nil, rawLabeling: TranscriptRediarizer.label)
            #expect(outcome.echoFlagged == expected, "lift \(lift)")
        }
    }

    struct ScriptedDiarizer: DiarizationProvider {
        let result: DiarizationResult
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult { result }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { result }
    }

    // MARK: - #365 (b): an echo copy's timing and length

    /// A repetition adds words: "No, not possible to wait." after "Not possible to wait." matches on time
    /// and on 4 of its 5 words, and is not flagged. No coupling measure needed.
    @Test func aRepetitionThatAddsWordsIsNotFlagged() {
        let result = EchoDeduplicator.deduplicate(
            segments: [remote(10, 11.5, "Not possible to wait."), local(10.6, 11.9, "No, not possible to wait.")],
            localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.clusters.first?.matchedSegments == 1)
        #expect(result.flaggedCount == 0)
    }

    /// A repetition of the whole line starts after the far end said it: later than any echo delay
    /// (`maximumEchoDelaySeconds` plus `echoTimingToleranceSeconds`) after the remote line began.
    @Test func aFullRepetitionThatStartsLateIsNotFlagged() {
        let late = EchoDeduplicator.maximumEchoDelaySeconds + EchoDeduplicator.echoTimingToleranceSeconds + 0.1
        let result = EchoDeduplicator.deduplicate(
            segments: [remote(10, 12, "We cannot wait any longer."), local(10 + late, 12.4, "We cannot wait any longer.")],
            localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.clusters.first?.matchedSegments == 1)
        #expect(result.flaggedCount == 0)
    }

    /// An echo never precedes its source: a line that starts before the remote one (beyond the timing
    /// tolerance) is the user's, said with or ahead of the far end.
    @Test func aLineThatStartsBeforeTheRemoteOneIsNotFlagged() {
        let early = EchoDeduplicator.echoTimingToleranceSeconds + 0.1
        let result = EchoDeduplicator.deduplicate(
            segments: [remote(10, 12, "Let us meet on Friday then."), local(10 - early, 11.8, "Let us meet on Friday then.")],
            localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.clusters.first?.matchedSegments == 1)
        #expect(result.flaggedCount == 0)
    }

    /// The true loudspeaker echo copies (b) must keep: the same words a little later, at the edges of the
    /// window, with the numbers written the other way; a dropped word; an excerpt of a long remote line
    /// that starts mid-way through it; one local line over two remote ones.
    @Test func trueEchoCopiesAreStillFlagged() {
        let tolerance = EchoDeduplicator.echoTimingToleranceSeconds
        let latest = EchoDeduplicator.maximumEchoDelaySeconds + tolerance
        let segments = [
            remote(10, 13, "The quarterly number was 7,500 in total."),
            local(10 + latest - 0.01, 13.4, "The quarterly number was seven thousand five hundred in total."),
            remote(20, 23, "We should ship it on Monday morning."),
            local(20 - tolerance + 0.01, 23, "We should ship it on Monday morning."),
            remote(30, 33, "Please send the contract to legal today."),
            local(30.1, 33.1, "Please send the contract to legal."),
            remote(40, 55, "So the plan is to finish the draft this week and then review it together with the whole team next week"),
            local(48, 54.5, "and then review it together with the whole team"),
            remote(60, 63, "First we open the account"),
            remote(63, 66, "then we move the money"),
            local(60.2, 66.2, "First we open the account then we move the money"),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 5)
        #expect(result.segments.filter { $0.source == "local" }.allSatisfy { $0.echo })
    }

    /// The two recognisers cut lines differently: an echo line often carries the tail of the remote line
    /// before the one it matches, and so starts before it and holds more words than it. It is judged against
    /// the far end's speech around it, which holds those words too.
    @Test func anEchoLineThatCarriesTheTailOfThePreviousRemoteLineIsFlagged() {
        let segments = [
            remote(74, 76.5, "That sounds right to me."),
            remote(77.5, 83.5, "The second draft goes to the review board on Thursday morning"),
            remote(83.7, 85, "So anyway."),
            local(76.8, 83.6, "to me. The second draft goes to the review board on Thursday morning so"),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 1)
    }

    // MARK: - Review fixes

    /// A spoken number is one word once normalised: "Twenty twenty six." is ONE word against "2026", too
    /// short to be flagged on its own outside an echo cluster (it is not flagged on main either).
    @Test func aSpokenNumberCountsAsOneWordForTheThreeWordGate() {
        let segments = [remote(10, 13, "So in 2026 we will do that."), local(10.2, 11.2, "Twenty twenty six.")]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.clusters.first?.matchedSegments == 1)
        #expect(result.flaggedCount == 0)
    }

    /// The issue's pattern while the far end goes on talking 0.2 s after the user's line ends: that next
    /// line was never in the mic's line, so it does not make the repetition "short enough" to be a copy.
    @Test func aRepetitionStaysUnflaggedWhenTheFarEndSpeaksAgainRightAfter() {
        let segments = [
            remote(10, 11.5, "Not possible to wait."),
            local(10.6, 11.9, "No, not possible to wait."),
            remote(12.1, 14, "We need the signed papers by the morning"),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.clusters.first?.matchedSegments == 1)
        #expect(result.flaggedCount == 0)
    }

    /// Nor does a remote line that ended just before it, unless the local line starts with that line's
    /// words (the tail an echo copy carries).
    @Test func aRepetitionStaysUnflaggedWhenTheFarEndSpokeJustBefore() {
        let segments = [
            remote(8, 9.9, "Because otherwise things get worse."),
            remote(10, 11.5, "Not possible to wait."),
            local(10.6, 11.9, "No, not possible to wait."),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 0)
    }

    /// The limit that remains: when the far end's next line, starting within 0.3 s, holds the repetition's
    /// last word, that word counts as carried and the length test passes. Only (a) holds such a line back.
    @Test func limitARepetitionEndingInTheFarEndsNextWordIsFlaggedWithoutCoupling() {
        let segments = [
            remote(10, 11.5, "Not possible to wait."),
            local(10.6, 11.9, "No, not possible to wait."),
            remote(12.1, 14, "Wait for the signed papers then"),
        ]
        let flaggedWithout = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(flaggedWithout.flaggedCount == 1)
        let headphones = MicEchoCancelRecord(engine: "e", modelSHA256: "a", framesReverted: 0, seconds: 60, farEndLiftDB: 2.5)
        let flaggedWith = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:],
                                                       coupling: .chunk(headphones))
        #expect(flaggedWith.flaggedCount == 0)
    }

    /// An echo copy can trail its source by the whole echo delay: the remote line before counts when it
    /// ended within `maximumEchoDelaySeconds` + the tolerance (0.8 s) of the local line's start, and a
    /// remote line already flagged (`filtered`, `duplicate`) is still the far end's sound.
    @Test func theContextReachesBackTheWholeEchoDelayAndHoldsFlaggedRemoteSpeech() {
        var earlier = remote(70, 76.2, "The plan is ready on Friday.")
        let source = remote(77, 82, "The second draft goes to the review board")
        let local = local(76.8, 82.3, "on Friday. The second draft goes to the review board")
        #expect(EchoDeduplicator.deduplicate(segments: [earlier, source, local], localSpeakerDatabase: [:],
                                             remoteSpeakerDatabase: [:]).flaggedCount == 1)
        earlier.filtered = true
        #expect(EchoDeduplicator.deduplicate(segments: [earlier, source, local], localSpeakerDatabase: [:],
                                             remoteSpeakerDatabase: [:]).flaggedCount == 1)
    }

    /// The matches the per-line rules hold back are listed, whatever their length, so a caller that spares
    /// matched lines (re-detect's fold) spares only those that can be an echo copy.
    @Test func theHeldBackMatchesAreListedWhateverTheirLength() {
        let headphones = MicEchoCancelRecord(engine: "e", modelSHA256: "a", framesReverted: 0, seconds: 60, farEndLiftDB: 2.5)
        let segments = [
            remote(10, 11, "Right."), local(9.4, 11, "Right."),                         // one word, precedes its source
            remote(20, 21.5, "Not possible to wait."), local(20.6, 21.9, "No, not possible to wait."),
            remote(30, 31, "Fine."), local(30.2, 31.2, "Fine."),                         // one word, a plain copy
        ]
        let plain = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(plain.matchedLocal == [1, 3, 5])
        #expect(plain.heldBack == [1, 3])
        #expect(plain.flaggedCount == 0)
        let uncoupled = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:],
                                                     coupling: .chunk(headphones))
        #expect(uncoupled.heldBack == [1, 3, 5])
    }
}
