import Foundation
import os

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let language: String?

    public init(start: Double, end: Double, text: String, language: String?) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
    }
}

public struct LabeledSegment: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var source: String

    public init(start: Double, end: Double, speaker: String, text: String, source: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.source = source
    }
}

public enum SpeakerAssignment {

    /// Remove zero-duration and consecutively repeated segments.
    public static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var cleaned: [TranscriptSegment] = []
        var lastText: String?

        for seg in segments {
            if seg.start == seg.end { continue }
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            if trimmed == lastText { continue }
            lastText = trimmed
            cleaned.append(seg)
        }

        Logger.transcription.debug("Deduplicate: \(segments.count) → \(cleaned.count) segments")
        return cleaned
    }

    /// Assign speaker labels to transcript segments based on time overlap with diarization.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment]
    ) -> [LabeledSegment] {
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        let speakerMap = Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )

        Logger.transcription.debug("Speaker map: \(speakerMap.count) speakers — \(speakerMap, privacy: .public)")

        return transcriptSegments.map { seg in
            let segMid = (seg.start + seg.end) / 2
            var bestSpeaker = "Unknown"
            var bestOverlap: Double = 0

            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }

                if sp.start <= segMid && segMid <= sp.end && overlap >= bestOverlap {
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }
            }

            return LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: bestSpeaker,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                source: ""
            )
        }
    }

    /// Tag labeled segments with source prefix for dual-stream mode.
    public static func tagWithSourcePrefix(_ segments: inout [LabeledSegment]) {
        for i in segments.indices {
            let source = segments[i].source
            let label = source == "local" ? "Local" : "Remote"
            let speaker = segments[i].speaker
            if !speaker.isEmpty && speaker != "Unknown" {
                segments[i].speaker = "\(label) \(speaker)"
            } else if speaker != "Unknown" {
                segments[i].speaker = label
            }
        }
    }
}
