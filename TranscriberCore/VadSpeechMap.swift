import Foundation
import os

/// Time-indexed speech probability from Silero VAD.
/// Used as a parallel quality signal in SpeakerAssignment.
public struct SpeechRegion: Sendable {
    public let start: Double
    public let end: Double
    public let probability: Float

    public init(start: Double, end: Double, probability: Float) {
        self.start = start
        self.end = end
        self.probability = probability
    }

    /// Calculate what fraction of [start, end] overlaps with speech regions
    /// whose probability meets the threshold.
    /// Returns 0.0–1.0.
    public static func speechOverlap(
        regions: [SpeechRegion],
        start: Double,
        end: Double,
        threshold: Float
    ) -> Double {
        let duration = end - start
        guard duration > 0 else { return 0.0 }

        var overlap = 0.0
        for region in regions {
            guard region.probability >= threshold else { continue }
            let overlapStart = max(start, region.start)
            let overlapEnd = min(end, region.end)
            let regionOverlap = max(0, overlapEnd - overlapStart)
            overlap += regionOverlap
        }

        return min(1.0, overlap / duration)
    }
}
