import Foundation

/// At finalize, compares a track's total recorded frame count against the session's elapsed
/// wall-clock time — a session-wide backstop distinct from `PadRatioMonitor`'s per-chunk ratio
/// (#196).
///
/// This exists because padding itself can be skipped: `AudioOutputHandler.timelineSilencePad`
/// refuses to pad when the computed timeline delta is implausible (a cross-source PTS clock-epoch
/// mismatch) rather than risk an Int64 overflow trap, and in that case NEITHER real frames NOR
/// compensating padding land in the track for that gap — `PadRatioMonitor`, which only ever sees
/// what actually got appended, cannot see the hole. Comparing total frames written against how long
/// the session has actually been running catches that hole (and any other mechanism nobody has
/// thought of yet) without needing to know why it happened.
public enum FrameCountPlausibility {

    public struct Verdict: Equatable {
        public let track: String
        public let actualSeconds: Double
        public let elapsedSeconds: Double
        public let deficitSeconds: Double
    }

    /// Fraction of elapsed time that may be unaccounted for before this is called implausible.
    /// Mirrors `PadRatioMonitor.threshold` (10%) — the same "clearly wrong, not just a little
    /// short" bar.
    public static let defaultToleranceRatio: Double = 0.10
    /// Don't judge a session that has barely started — mirrors `PadRatioMonitor.minimumSeconds`.
    public static let defaultMinimumElapsedSeconds: Double = 30
    /// Absolute floor so a small, legitimate discrepancy (rounding, a startup offset already
    /// counted elsewhere) can't trip the ratio alone. Mirrors `PadRatioMonitor.minimumPaddedSeconds`.
    public static let defaultMinimumDeficitSeconds: Double = 15

    /// Returns a verdict only when the deficit is BOTH a high proportion of elapsed time AND a
    /// real absolute amount — same both-conditions shape as `PadRatioMonitor`, for the same reason:
    /// either alone misfires (the ratio near the start of a session, the absolute figure on a
    /// long one with an ordinary few seconds of legitimate skew).
    public static func check(
        track: String,
        framesWritten: Int64,
        rate: Double,
        elapsedSeconds: Double,
        toleranceRatio: Double = defaultToleranceRatio,
        minimumElapsedSeconds: Double = defaultMinimumElapsedSeconds,
        minimumDeficitSeconds: Double = defaultMinimumDeficitSeconds
    ) -> Verdict? {
        guard rate > 0, elapsedSeconds >= minimumElapsedSeconds, framesWritten >= 0 else { return nil }
        let actualSeconds = Double(framesWritten) / rate
        let deficit = elapsedSeconds - actualSeconds
        guard deficit >= minimumDeficitSeconds, deficit / elapsedSeconds >= toleranceRatio else { return nil }
        return Verdict(
            track: track, actualSeconds: actualSeconds,
            elapsedSeconds: elapsedSeconds, deficitSeconds: deficit
        )
    }
}
