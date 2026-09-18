import Foundation

/// Watches the mic track for a sustained run of samples that are EXACTLY zero — not merely quiet.
///
/// Device-observed 2026-09-10 (#193): with the MacBook lid closed, the built-in mic is
/// hardware-disabled but REMAINS the default input device and keeps delivering buffers at full
/// rate, of exact digital zero. Every other detector stayed quiet: frames WERE delivered (no
/// padding, `trackNeverDelivered` never fires because `dataFrames > 0`), and the WAV grew at
/// exactly the expected byte rate — a structurally perfect, completely empty recording.
///
/// A real microphone always has a noise floor (thermal/electrical self-noise, room tone), so a run
/// of samples that are exactly `0` in every position has essentially no false-positive risk — unlike
/// a loudness/RMS threshold, which a quiet room can legitimately cross. This is why the detector can
/// use a much shorter window than `PadRatioMonitor` (which must tolerate long legitimate silence).
public struct ExactZeroRunMonitor {

    public enum Verdict: Equatable {
        /// Not enough consecutive zero samples yet, or already reported.
        case notYet
        /// A sustained run of exact-zero samples crossed the threshold. Reports ONCE per run — like
        /// `PadRatioMonitor`, a per-buffer log of a persistent condition tells nobody anything.
        case silentRun(seconds: Double)
    }

    /// How long a run of exact-zero samples must persist before it is reported. Named and public so
    /// the reasoning (and any future tuning) has one place to live: the incident ran for the entire
    /// 346 s recording, so 12 s catches it with ~29x margin while comfortably clearing any
    /// legitimate transient (a buffer of true digital silence — e.g. a muted USB mic momentarily
    /// gating to zero — lasting several seconds is exceptionally unusual, and 12 s is well inside the
    /// "notice during the recording, while there is still time to fix it" window the issue asks for.
    public static let defaultThresholdSeconds: Double = 12

    public let thresholdSeconds: Double
    private var consecutiveZeroFrames: Int64 = 0
    private var reported = false

    public init(thresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Feed one batch of REAL (not fabricated/padded) mic samples at `rate` Hz. Returns `.silentRun`
    /// at most once per contiguous run of exact zeros — audio resuming re-arms the detector, so a mic
    /// that goes silent again later (lid closed, reopened, closed again) is reported again.
    public mutating func record(samples: [Int16], rate: Double) -> Verdict {
        guard rate > 0, !samples.isEmpty else { return .notYet }
        if samples.allSatisfy({ $0 == 0 }) {
            consecutiveZeroFrames += Int64(samples.count)
        } else {
            consecutiveZeroFrames = 0
            reported = false
            return .notYet
        }
        guard !reported else { return .notYet }
        let seconds = Double(consecutiveZeroFrames) / rate
        guard seconds >= thresholdSeconds else { return .notYet }
        reported = true
        return .silentRun(seconds: seconds)
    }
}
