import Foundation

/// Chooses which of a speaker's segments to offer as a voice sample in the rename dialog.
///
/// The obvious heuristic — "pick the longest segment" — is actively wrong. Overlapping speech
/// produces long, messy diarization segments, so ranking by duration alone systematically
/// surfaces crosstalk: on a real 5-speaker call the top sample for the most talkative speaker
/// was 40s of her talking *under* someone else, while 399 of her 448 segments were clean.
/// A sample exists to let a human recognise one voice, so isolation beats length.
public enum SpeakerSampleSelector {

    public struct Candidate: Equatable {
        public let speaker: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let source: String
        public let text: String

        public init(speaker: String, start: TimeInterval, end: TimeInterval, source: String, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.source = source
            self.text = text
        }

        public var duration: TimeInterval { end - start }
    }

    /// Ignore slivers of overlap — a neighbouring segment clipping by a fraction of a second
    /// (breaths, backchannel, boundary jitter) does not make a sample unusable.
    public static let defaultOverlapTolerance: TimeInterval = 0.3

    /// Rank one speaker's segments best-first: clean (no one else talking) before overlapped,
    /// longest first within each group.
    ///
    /// Overlapped segments are kept as a fallback rather than dropped — a speaker whose every
    /// segment is crosstalk must still get *some* sample, otherwise they become unrenameable.
    public static func rank(
        speaker: String,
        allSegments: [Candidate],
        overlapTolerance: TimeInterval = defaultOverlapTolerance
    ) -> [Candidate] {
        let mine = allSegments.filter { $0.speaker == speaker && $0.duration > 0 }
        guard !mine.isEmpty else { return [] }

        // Only *other* speakers contaminate a sample. Same-speaker segments may legitimately
        // abut or overlap (a split segment is still one voice).
        let others = allSegments.filter { $0.speaker != speaker && $0.duration > 0 }
            .sorted { $0.start < $1.start }

        func isClean(_ candidate: Candidate) -> Bool {
            for other in others {
                if other.start >= candidate.end { break }   // sorted: nothing later can overlap
                guard other.end > candidate.start else { continue }
                let overlap = min(candidate.end, other.end) - max(candidate.start, other.start)
                if overlap > overlapTolerance { return false }
            }
            return true
        }

        let (clean, overlapped) = mine.reduce(into: ([Candidate](), [Candidate]())) { acc, c in
            if isClean(c) { acc.0.append(c) } else { acc.1.append(c) }
        }

        let byDuration: (Candidate, Candidate) -> Bool = { $0.duration > $1.duration }
        return clean.sorted(by: byDuration) + overlapped.sorted(by: byDuration)
    }
}
