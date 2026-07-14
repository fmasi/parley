import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// Metamorphic diarization oracles: assert RELATIONS between outputs of related inputs,
/// because we cannot label every recording (#137, item 3).
///
/// "The transcript is correct" has no cheap ground truth, but "two different voices glued
/// together must yield at least two speakers", "padding silence at the head must shift every
/// timestamp by exactly that much", and "the same file twice must produce the same answer"
/// are all checkable with zero labels. Each relation catches a distinct failure class that a
/// green unit suite historically missed.
///
/// All fixtures are synthesized at test time (SyntheticSpeech) — no downloads, no git bytes.
/// Tolerances are measured, not guessed; see each test.
@Suite struct DiarizationMetamorphicTests {

    /// One shared diarizer for the suite: the actor serializes runs, keeping CI memory flat,
    /// and stock config is the shipping default — these oracles guard what users actually run.
    private static let diarizer = FluidAudioDiarizer()

    private func speakers(in result: DiarizationResult) -> Set<String> {
        Set(result.segments.map(\.speaker))
    }

    // MARK: - Relations

    /// Two DIFFERENT single-speaker clips, concatenated -> at least 2 speakers.
    ///
    /// The headline relation from #137. No labels, no ground truth: if the diarizer cannot
    /// tell two cleanly separated, acoustically distinct voices apart, speaker attribution is
    /// meaningless for every downstream consumer (labels, rename, echo dedup).
    @Test func concatenatingTwoDistinctVoicesYieldsTwoSpeakers() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try SyntheticSpeech.speakerClips(2)
        let joined = try SyntheticSpeech.scratchURL("two-voices")
        try SyntheticSpeech.concatenate(clips, to: joined, gap: 0.5)

        let result = try await Self.diarizer.diarize(audioPath: joined, numSpeakers: nil)
        #expect(
            speakers(in: result).count >= 2,
            "Two distinct concatenated voices must not merge into one speaker (got \(speakers(in: result).count))"
        )
    }

    /// A turn-taking conversation with 1s barge-in overlaps -> still at least 2 speakers.
    ///
    /// Unlike pure concatenation this exercises the overlap-mask path in embedding extraction
    /// — the code region where `embeddingExcludeOverlap` lives. If a regression made the mask
    /// discard all speech (the original "all remote speech is technically overlapping" fear)
    /// or blend it wholesale, separation degrades here first. Measured: 1s overlaps -> 2
    /// speakers with the stock config; 2s overlaps collapse even correct configs on TTS
    /// audio, so 1s is the reliable operating point for this fixture.
    @Test func overlappingConversationStillSeparatesSpeakers() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try SyntheticSpeech.speakerClips(2)

        // Alternate the two voices, each turn starting 1s before the previous ends.
        var sources: [(url: URL, offset: Double)] = []
        var cursor = 0.0
        for turn in 0..<4 {
            let clip = clips[turn % 2]
            sources.append((clip, max(0, cursor)))
            let file = try AVAudioFile(forReading: clip)
            cursor += Double(file.length) / file.processingFormat.sampleRate - 1.0
        }
        let conversation = try SyntheticSpeech.scratchURL("conversation")
        try SyntheticSpeech.mix(sources, to: conversation)

        let result = try await Self.diarizer.diarize(audioPath: conversation, numSpeakers: nil)
        #expect(!result.segments.isEmpty, "overlap masking must not discard all speech")
        #expect(
            speakers(in: result).count >= 2,
            "A 2-voice conversation with brief overlaps must keep 2 speakers (got \(speakers(in: result).count))"
        )
    }

    /// Padding N seconds of silence at the head -> every timestamp shifts by exactly N.
    ///
    /// Catches timeline bugs (chunk-rotation offsets, resampling drift, window misalignment)
    /// that leave speaker counts intact while silently corrupting WHEN things were said —
    /// fatal for a courtroom-grade record. Measured shift error on this fixture: < 0.06s;
    /// the 0.25s tolerance leaves room for model-version drift without letting a real
    /// off-by-a-chunk bug (whole seconds) through.
    @Test func paddingSilenceAtHeadShiftsTimestampsByThatAmount() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try SyntheticSpeech.speakerClips(2)
        let pad = 3.0

        let base = try SyntheticSpeech.scratchURL("unpadded")
        try SyntheticSpeech.concatenate(clips, to: base, gap: 0.5)
        let padded = try SyntheticSpeech.scratchURL("padded")
        try SyntheticSpeech.concatenate(clips, to: padded, gap: 0.5, leadingSilence: pad)

        let baseResult = try await Self.diarizer.diarize(audioPath: base, numSpeakers: nil)
        let paddedResult = try await Self.diarizer.diarize(audioPath: padded, numSpeakers: nil)

        try #require(!baseResult.segments.isEmpty)
        #expect(baseResult.segments.count == paddedResult.segments.count,
                "leading silence must not change segmentation, only shift it")
        for (unshifted, shifted) in zip(baseResult.segments, paddedResult.segments) {
            #expect(abs(shifted.start - unshifted.start - pad) < 0.25,
                    "segment start must shift by \(pad)s (got \(unshifted.start) -> \(shifted.start))")
            #expect(abs(shifted.end - unshifted.end - pad) < 0.25,
                    "segment end must shift by \(pad)s (got \(unshifted.end) -> \(shifted.end))")
        }
    }

    /// The same file, diarized twice -> the same answer.
    ///
    /// Catches nondeterminism and cross-run model-state leakage. A record that changes on
    /// re-run is not a record. Measured: bit-identical on this machine; the 1ms timestamp
    /// tolerance only absorbs float-scheduling noise, never a real segmentation change.
    @Test func sameInputTwiceIsDeterministic() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clips = try SyntheticSpeech.speakerClips(2)
        let joined = try SyntheticSpeech.scratchURL("determinism")
        try SyntheticSpeech.concatenate(clips, to: joined, gap: 0.5)

        let first = try await Self.diarizer.diarize(audioPath: joined, numSpeakers: nil)
        let second = try await Self.diarizer.diarize(audioPath: joined, numSpeakers: nil)

        try #require(first.segments.count == second.segments.count,
                     "same input must yield the same number of segments")
        for (a, b) in zip(first.segments, second.segments) {
            #expect(a.speaker == b.speaker, "speaker labels must be stable across runs")
            #expect(abs(a.start - b.start) < 0.001)
            #expect(abs(a.end - b.end) < 0.001)
        }
    }

    /// A single voice -> exactly one speaker.
    ///
    /// The inverse relation: guards against over-splitting, where one person shatters into
    /// several "speakers" and downstream reconciliation invents phantom participants.
    @Test func singleVoiceYieldsExactlyOneSpeaker() async throws {
        guard try await TestModels.ensureDiarization() else { return }
        let clip = try SyntheticSpeech.speakerClips(1)[0]

        let result = try await Self.diarizer.diarize(audioPath: clip, numSpeakers: nil)
        #expect(!result.segments.isEmpty)
        #expect(
            speakers(in: result).count == 1,
            "One clean voice must yield one speaker, not \(speakers(in: result).count)"
        )
    }
}
