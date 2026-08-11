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
    /// Absolute floor, and the reason this detector is usable at all.
    ///
    /// A ratio alone fires far too easily near the start: one gap of G seconds evaluated at the 30 s
    /// mark reads G/30, so a 4-second gap is 13% and trips. Four-second gaps at the start of a HEALTHY
    /// recording are ordinary — a Bluetooth mic taking seconds to negotiate HFP, or one #86 restart
    /// whose first liveness probe misses. Labelling those "content is compromised" would make the
    /// warning background noise within a week, which is worse than not warning at all.
    ///
    /// Requiring real fabricated seconds as well as a high proportion separates them cleanly, and
    /// costs almost nothing in detection latency: a ~50% deficit (the incident) accrues 15 s of pad
    /// within about 30 s of audio, so the real thing is still caught in well under a minute.
    public let minimumPaddedSeconds: Double

    private var padFrames: Int64 = 0
    private var totalFrames: Int64 = 0
    private var reported = false
    /// Whether this track has ever delivered real frames.
    ///
    /// Padding BEFORE the first delivered frame is a start offset, not a deficit: there was nothing
    /// to capture, so nothing went missing. This distinction is what makes the detector usable —
    /// the Core Audio tap delivers NO buffers while the output device is idle, so a recording
    /// started before joining a call accrues pure padding until the call connects. Device-observed
    /// 2026-08-11: a healthy recording read 97.6% zeros in its first 30s and fired at ratio 0.911
    /// on leading silence alone. Starting the recording first is the ordinary way to use the app,
    /// so counting that as corruption makes the label worthless.
    private var hasDeliveredData = false

    public init(threshold: Double = 0.10, minimumSeconds: Double = 30, minimumPaddedSeconds: Double = 15) {
        self.threshold = threshold
        self.minimumSeconds = minimumSeconds
        self.minimumPaddedSeconds = minimumPaddedSeconds
    }

    /// Feed one append. `padFrames` is the silence just fabricated, `dataFrames` the real samples
    /// written alongside it.
    public mutating func record(padFrames newPad: Int64, dataFrames: Int64, rate: Double) -> Verdict {
        guard rate > 0, !reported else { return .notYet }
        // Nothing counts until the track proves it can deliver. Once it has, everything counts —
        // including padding, which is the whole point.
        if dataFrames > 0 { hasDeliveredData = true }
        guard hasDeliveredData else { return .notYet }
        padFrames += max(0, newPad)
        totalFrames += max(0, newPad) + max(0, dataFrames)

        let totalSeconds = Double(totalFrames) / rate
        guard totalSeconds >= minimumSeconds, totalFrames > 0 else { return .notYet }

        let ratio = Double(padFrames) / Double(totalFrames)
        let paddedSeconds = Double(padFrames) / rate
        // BOTH conditions: a high proportion AND enough absolute fabricated time. Either alone
        // misfires — the ratio on early gaps, the absolute figure on genuinely long recordings.
        guard ratio > threshold, paddedSeconds >= minimumPaddedSeconds else { return .healthy }
        reported = true
        return .excessive(ratio: ratio, paddedSeconds: paddedSeconds, totalSeconds: totalSeconds)
    }

    public mutating func reset() {
        padFrames = 0
        totalFrames = 0
        reported = false
        hasDeliveredData = false
    }
}
