import Foundation

/// Watches how much of a written track is silence we FABRICATED rather than captured.
///
/// The timeline padder inserts silence so a track's next sample lands at its true wall-clock
/// position. That is correct behaviour — it is how mic and system stay aligned across start skew and
/// restart gaps — but it has a dangerous side effect: when a device delivers fewer frames than its
/// declared rate implies, the padder quietly makes up the difference, and a detectably-short file
/// becomes an undetectably-corrupt one of exactly the right length. That is what turned the
/// 2026-08-04 rate drift from an obvious failure into 22 minutes nobody noticed.
///
/// The saving grace is that padding only ever fires on DELIVERY DEFICIT, never on quiet audio: a
/// silent remote still delivers buffers full of zeros and needs no padding at all. So the pad ratio
/// separates cleanly — measured 61.1% on the corrupted track versus 0.1% on the healthy mic in the
/// same recording — and it does so without knowing anything about *why* frames went missing. That
/// makes it the one guard that catches this bug class in mechanisms nobody has thought of yet.
public struct PadRatioMonitor {

    public enum Verdict: Equatable {
        /// Not enough audio yet to judge, or already reported.
        case notYet
        /// Padding is within the expected band.
        case healthy
        /// Sustained fabrication. Reports ONCE — a persistent condition, and the original failure was
        /// lost precisely because its per-buffer log fired ~57,000 times.
        case excessive(ratio: Double, paddedSeconds: Double, totalSeconds: Double)
    }

    /// Fraction of the track that may be fabricated before we call it broken. Legitimate padding in a
    /// real meeting lands around 0.1-3% (start skew plus any restart windows); the incident was ~50%.
    /// 10% sits more than an order of magnitude clear of both.
    public let threshold: Double
    /// Leading silence dominates the ratio before real audio arrives, so hold off judging until the
    /// track has enough material that the number means something.
    public let minimumSeconds: Double

    private var padFrames: Int64 = 0
    private var totalFrames: Int64 = 0
    private var reported = false

    public init(threshold: Double = 0.10, minimumSeconds: Double = 30) {
        self.threshold = threshold
        self.minimumSeconds = minimumSeconds
    }

    /// Feed one append. `padFrames` is the silence just fabricated, `dataFrames` the real samples
    /// written alongside it.
    public mutating func record(padFrames newPad: Int64, dataFrames: Int64, rate: Double) -> Verdict {
        guard rate > 0, !reported else { return .notYet }
        padFrames += max(0, newPad)
        totalFrames += max(0, newPad) + max(0, dataFrames)

        let totalSeconds = Double(totalFrames) / rate
        guard totalSeconds >= minimumSeconds, totalFrames > 0 else { return .notYet }

        let ratio = Double(padFrames) / Double(totalFrames)
        guard ratio > threshold else { return .healthy }
        reported = true
        return .excessive(
            ratio: ratio,
            paddedSeconds: Double(padFrames) / rate,
            totalSeconds: totalSeconds
        )
    }

    /// Fraction of the track fabricated so far, for finalize-time provenance regardless of verdict.
    public var currentRatio: Double {
        totalFrames > 0 ? Double(padFrames) / Double(totalFrames) : 0
    }

    public mutating func reset() {
        padFrames = 0
        totalFrames = 0
        reported = false
    }
}
