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
        /// Absolute wall-clock time of the segment's start.
        public let timestamp: Date
        public let text: String
        public let speaker: String
        public let source: String
        public let qualityScore: Float?

        public init(
            elapsed: Double,
            timestamp: Date,
            text: String,
            speaker: String,
            source: String,
            qualityScore: Float?
        ) {
            self.elapsed = elapsed
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

        public init(segments: [MergedSegment], meetingStart: Date, chunkCount: Int) {
            self.segments = segments
            self.meetingStart = meetingStart
            self.chunkCount = chunkCount
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
    public static func merge(
        chunks: [ProcessedChunk],
        speakerMapping: [Int: [String: String]],
        meetingStart: Date
    ) -> MergeResult {
        var merged: [MergedSegment] = []

        for chunk in chunks {
            let chunkOffset = chunk.startTime.timeIntervalSince(meetingStart)
            let labelMap = speakerMapping[chunk.index] ?? [:]

            for seg in chunk.segments {
                let elapsed = chunkOffset + seg.start
                let timestamp = meetingStart.addingTimeInterval(elapsed)
                let globalSpeaker = labelMap[seg.speaker] ?? seg.speaker

                merged.append(MergedSegment(
                    elapsed: elapsed,
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
            chunkCount: chunks.count
        )
    }
}
