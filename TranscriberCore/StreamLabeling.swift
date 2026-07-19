import Foundation

/// Per-stream speaker labeling shared by the two transcription paths — `ChunkProcessor`
/// (the live chunked pipeline) and `TranscriptionRunner` (recovery / one-shot). Only the
/// **identical** labeling logic lives here; each caller keeps its own error policy (the chunk
/// path degrades, the runner throws), header repair, and detected-language capture. This exists
/// so a change to how segments are labeled against a diarization result lands once, not twice
/// (the #136 disease — a fix applied to one copy silently missing the other).
enum StreamLabeling {

    /// Label transcript segments against a **successful** diarization result: assign speakers via
    /// `SpeakerAssignment`, then remap the speaker-database keys from raw IDs ("S2") to the
    /// friendly names ("Speaker 1") used in the segments (so echo dedup and the reconciler match).
    static func withDiarization(
        segments: [TranscriptSegment],
        diarizationResult: DiarizationResult,
        speechMap: [SpeechRegion]?,
        vadSpeechThreshold: Double
    ) -> (labeled: [LabeledSegment], speakerDatabase: [String: [Float]]) {
        let labeled = SpeakerAssignment.assign(
            transcriptSegments: segments,
            diarizationSegments: diarizationResult.segments,
            speechMap: speechMap,
            vadSpeechThreshold: vadSpeechThreshold
        )
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
