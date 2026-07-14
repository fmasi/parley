import Foundation

/// Assembles a final, time-sorted transcript from all processed chunks.
///
/// Each chunk carries segments with chunk-relative timestamps. `merge()` converts
/// these to absolute wall-clock times, applies cross-chunk speaker remapping, and
/// returns a single sorted list ready for rendering or export.
public enum TranscriptMerger {

    // MARK: - Output types

    public struct MergedSegment: Sendable {
        /// Seconds elapsed from the meeting start.
        public let elapsed: Double
        /// Seconds elapsed from the meeting start, at the segment's end.
        public let elapsedEnd: Double
        /// Absolute wall-clock time of the segment's start.
        public let timestamp: Date
        public let text: String
        public let speaker: String
        public let source: String
        public let qualityScore: Float?

        public init(
            elapsed: Double,
            elapsedEnd: Double,
            timestamp: Date,
            text: String,
            speaker: String,
            source: String,
            qualityScore: Float?
        ) {
            self.elapsed = elapsed
            self.elapsedEnd = elapsedEnd
            self.timestamp = timestamp
            self.text = text
            self.speaker = speaker
            self.source = source
            self.qualityScore = qualityScore
        }
    }

    public struct MergeResult: Sendable {
        public let segments: [MergedSegment]
        public let meetingStart: Date
        public let chunkCount: Int
        /// Labels that the reconciler produced no mapping for, per chunk.
        ///
        /// A miss means the reconciler's namespace and the segment's label disagree, so the remap
        /// falls back to the identity and that chunk's LOCAL speaker numbering is laundered into the
        /// global namespace — silently swapping speakers. It is never correct, so it must never be
        /// silent. Empty on a healthy merge.
        public let unmappedLabels: [Int: [String]]

        public init(
            segments: [MergedSegment],
            meetingStart: Date,
            chunkCount: Int,
            unmappedLabels: [Int: [String]] = [:]
        ) {
            self.segments = segments
            self.meetingStart = meetingStart
            self.chunkCount = chunkCount
            self.unmappedLabels = unmappedLabels
        }
    }

    // MARK: - Public API

    /// Merge all processed chunks into a single time-sorted transcript.
    ///
    /// - Parameters:
    ///   - chunks: All chunks produced during the session.
    ///   - speakerMapping: Per-chunk speaker label remapping. Key is `chunk.index`;
    ///     value is a dictionary from original speaker label to global speaker label.
    ///     Any label absent from the inner dictionary is kept as-is.
    ///   - meetingStart: The wall-clock time the meeting began (used to compute
    ///     absolute timestamps from chunk-relative offsets).
    /// - Returns: A `MergeResult` containing all segments sorted by elapsed time.
    /// True for the Unknown sentinel, with or without a `Local `/`Remote ` source prefix.
    static func isUnknown(_ label: String) -> Bool {
        let stripped = label
            .replacingOccurrences(of: "Local ", with: "")
            .replacingOccurrences(of: "Remote ", with: "")
        return stripped == SpeakerAssignment.unknownSpeaker
    }

    public static func merge(
        chunks: [ProcessedChunk],
        speakerMapping: [Int: [String: String]],
        meetingStart: Date
    ) -> MergeResult {
        var merged: [MergedSegment] = []
        var unmapped: [Int: Set<String>] = [:]

        for chunk in chunks {
            let chunkOffset = chunk.startTime.timeIntervalSince(meetingStart)
            let labelMap = speakerMapping[chunk.index] ?? [:]

            for seg in chunk.segments {
                let elapsed = chunkOffset + seg.start
                let timestamp = meetingStart.addingTimeInterval(elapsed)

                // Only a NON-EMPTY mapping can miss: an empty one means the reconciler had nothing
                // to say about this chunk (seed chunk, or no embeddings), and the identity is right.
                //
                // The Unknown sentinel is NOT a miss. It carries no embedding by design, so the
                // reconciler can never key it, and the identity fallback is correct for it. Counting
                // it would fire the alarm on nearly every real meeting — and an alarm that cries wolf
                // is worse than no alarm, because this one exists to make silent speaker-namespace
                // laundering impossible to miss.
                if !labelMap.isEmpty, labelMap[seg.speaker] == nil, !Self.isUnknown(seg.speaker) {
                    unmapped[chunk.index, default: []].insert(seg.speaker)
                }
                let globalSpeaker = labelMap[seg.speaker] ?? seg.speaker

                merged.append(MergedSegment(
                    elapsed: elapsed,
                    elapsedEnd: chunkOffset + seg.end,
                    timestamp: timestamp,
                    text: seg.text,
                    speaker: globalSpeaker,
                    source: seg.source,
                    qualityScore: seg.qualityScore
                ))
            }
        }

        merged.sort { $0.elapsed < $1.elapsed }

        return MergeResult(
            segments: merged,
            meetingStart: meetingStart,
            chunkCount: chunks.count,
            unmappedLabels: unmapped.mapValues { $0.sorted() }
        )
    }
}
