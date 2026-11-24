import Foundation
import os

/// Per-stream speaker labeling shared by the two transcription paths — `ChunkProcessor`
/// (the live chunked pipeline) and `TranscriptionRunner` (recovery / one-shot). Only the
/// **identical** labeling logic lives here; each caller keeps its own error policy (the chunk
/// path degrades, the runner throws), header repair, and detected-language capture. This exists
/// so a change to how segments are labeled against a diarization result lands once, not twice
/// (the #136 disease — a fix applied to one copy silently missing the other).
enum StreamLabeling {

    /// The other channel, for judging this channel's clusters for echo before minority absorption
    /// (#249). Only the mic stream has one: the echo check asks whether a mic cluster is the other
    /// side's voice through the loudspeakers, and has no answer to the reverse.
    struct EchoReference {
        /// The system stream's labelled lines, `source` stamped `"remote"`. Flagged ones are ignored.
        let segments: [LabeledSegment]
        /// `echo_temporal_threshold` / `echo_text_threshold`, as the chunk's echo dedup is given them.
        let temporalThreshold: Double?
        let textThreshold: Double?
        /// `echo_local_lead_margin_seconds` (#252): a raw cluster that leads the other channel is no echo.
        var localLeadMarginSeconds: Double? = nil
    }

    /// Label transcript segments against a **successful** diarization result: absorb minority
    /// clusters (#65), assign speakers via `SpeakerAssignment`, then remap the speaker-database keys
    /// from raw IDs ("S2") to the friendly names ("Speaker 1") used in the segments (so echo dedup
    /// and the reconciler match).
    ///
    /// **Echo is judged before absorption (#249).** With `echoReference`, the clusters absorption
    /// would take are first labelled as the diarizer split them and judged by `EchoDeduplicator`
    /// against the other channel; a cluster it calls echo is neither absorbed nor absorbs anything
    /// (`DiarizationCleanup`'s `keeping:`). Absorbing first folded a bleed cluster under 5 % of a
    /// chunk into the user, where the echo dedup that runs on the chunk never saw it as a cluster.
    /// When absorption would take nothing, or no cluster is echo, the result is what it was before.
    ///
    /// - Parameter speakerCountIsUserStated: the user told us how many speakers this stream has, so
    ///   the diarizer was already forced to that count. Absorption is skipped entirely — second-
    ///   guessing an explicit answer by deleting one of the speakers they asked for is worse than
    ///   any fragment it might remove.
    static func withDiarization(
        segments: [TranscriptSegment],
        diarizationResult: DiarizationResult,
        speechMap: [SpeechRegion]?,
        vadSpeechThreshold: Double,
        /// No default on purpose: production callers pass `config.resolvedDiarizationMinSpeakerShare`,
        /// and a defaulted parameter would let a future transcription path silently absorb at the
        /// hardcoded value while ignoring the user's config, with nothing to warn them.
        minSpeakerShare: Double?,
        /// No default on purpose either: the mic stream passes the system stream's lines, every
        /// other caller nil. A default would let a new mic path absorb a bleed cluster unjudged.
        echoReference: EchoReference?,
        speakerCountIsUserStated: Bool = false
    ) -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]], absorbed: Int) {
        let minShare = speakerCountIsUserStated ? nil : minSpeakerShare
        let echoClusters = echoReference.map {
            judgedEcho(segments: segments, diarizationResult: diarizationResult, speechMap: speechMap,
                       vadSpeechThreshold: vadSpeechThreshold, minShare: minShare, reference: $0)
        } ?? []
        // Runs BEFORE assignment so the absorbed cluster never becomes a "Speaker N" label, and
        // before `buildSpeakerMap` so the database keys agree with the labels (the invariant below).
        // The absorbed count is returned so the chunk path can record it (`clusters_absorbed`, P7).
        let (diarizationResult, absorbed) = DiarizationCleanup.absorbMinorityClustersCounting(
            diarizationResult,
            minShare: minShare,
            keeping: echoClusters
        )
        let labeled = SpeakerAssignment.assign(
            transcriptSegments: segments,
            diarizationSegments: diarizationResult.segments,
            speechMap: speechMap,
            vadSpeechThreshold: vadSpeechThreshold
        )
        // INVARIANT: `assign()` and `buildSpeakerMap()` both derive the raw→friendly speaker map
        // from `diarizationResult.segments` in insertion order. The keys in `speakerDatabase` must
        // agree with the "Speaker N" labels in `labeled` — if either function's iteration order
        // ever changes independently, the DB keys would silently mismatch the segment labels,
        // breaking echo dedup and the cross-chunk reconciler. Keep their ordering logic in sync.
        let dbKeyMap = SpeakerAssignment.buildSpeakerMap(from: diarizationResult.segments)
        let speakerDatabase = SpeakerAssignment.remapDatabaseKeys(diarizationResult.speakerDatabase, using: dbKeyMap)
        return (labeled, speakerDatabase, absorbed)
    }

    /// The raw clusters `EchoDeduplicator` judges to be echo, by the diarizer's own IDs (#249) —
    /// the same rule, thresholds and other channel as the dedup the chunk runs afterwards, on the
    /// clusters as the diarizer returned them. Empty, without running the check, when absorption
    /// would take nothing: a kept cluster can only change what absorption does, so the result is
    /// then the same either way.
    ///
    /// The verdicts are not kept: the chunk's dedup judges the final clusters (an echo cluster
    /// spared here is one of them, on the same lines) and that is the record.
    private static func judgedEcho(
        segments: [TranscriptSegment],
        diarizationResult: DiarizationResult,
        speechMap: [SpeechRegion]?,
        vadSpeechThreshold: Double,
        minShare: Double?,
        reference: EchoReference
    ) -> Set<String> {
        guard !DiarizationCleanup.minorityClusters(diarizationResult, minShare: minShare).isEmpty else { return [] }
        var raw = SpeakerAssignment.assign(
            transcriptSegments: segments,
            diarizationSegments: diarizationResult.segments,
            speechMap: speechMap,
            vadSpeechThreshold: vadSpeechThreshold
        )
        for i in raw.indices { raw[i].source = "local" }
        Logger.transcription.info("Judging \(Set(diarizationResult.segments.map(\.speaker)).count, privacy: .public) raw mic cluster(s) for echo before minority absorption")
        let verdicts = EchoDeduplicator.deduplicate(
            segments: raw + reference.segments.filter { $0.source == "remote" },
            localSpeakerDatabase: [:],
            remoteSpeakerDatabase: [:],
            temporalThreshold: reference.temporalThreshold,
            textThreshold: reference.textThreshold,
            logPrefix: "Pre-absorption check (not the record): ",
            localLeadMarginSeconds: reference.localLeadMarginSeconds
        ).clusters
        let echoLabels = Set(verdicts.filter(\.isEcho).map(\.label))
        // "Unknown" (speech no turn covers) can be judged echo too; it is no cluster to keep.
        return Set(SpeakerAssignment.buildSpeakerMap(from: diarizationResult.segments)
            .filter { echoLabels.contains($0.value) }.keys)
    }

    /// Label every segment with one fixed speaker — used when there is no diarizer ("Speaker 1")
    /// and, on the chunk path, when diarization failed ("Unknown"). The empty `source` is stamped
    /// by the caller afterwards.
    static func singleSpeaker(_ segments: [TranscriptSegment], speaker: String) -> [LabeledSegment] {
        segments.map { seg in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: speaker,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                source: "",
                confidence: seg.confidence,
                language: seg.language
            )
        }
    }
}
