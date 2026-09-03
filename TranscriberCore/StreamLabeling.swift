import Foundation

/// Per-stream speaker labeling shared by the two transcription paths — `ChunkProcessor`
/// (the live chunked pipeline) and `TranscriptionRunner` (recovery / one-shot). Only the
/// **identical** labeling logic lives here; each caller keeps its own error policy (the chunk
/// path degrades, the runner throws), header repair, and detected-language capture. This exists
/// so a change to how segments are labeled against a diarization result lands once, not twice
/// (the #136 disease — a fix applied to one copy silently missing the other).
enum StreamLabeling {

    /// Label transcript segments against a **successful** diarization result: absorb minority
    /// clusters (#65), assign speakers via `SpeakerAssignment`, then remap the speaker-database keys
    /// from raw IDs ("S2") to the friendly names ("Speaker 1") used in the segments (so echo dedup
    /// and the reconciler match).
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
        minSpeakerShare: Double? = DiarizationCleanup.defaultMinShare,
        speakerCountIsUserStated: Bool = false
    ) -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]]) {
        // Runs BEFORE assignment so the absorbed cluster never becomes a "Speaker N" label, and
        // before `buildSpeakerMap` so the database keys agree with the labels (the invariant below).
        let diarizationResult = DiarizationCleanup.absorbMinorityClusters(
            diarizationResult,
            minShare: speakerCountIsUserStated ? nil : minSpeakerShare
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
        return (labeled, speakerDatabase)
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
