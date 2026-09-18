import Foundation

/// Pure decision logic for the 1 Hz capture-liveness watchdog (#196).
///
/// The pad detectors judge missing frames only when the NEXT append arrives — a track that
/// delivers and then stops mid-recording (a wedged helper mic, `AVCaptureSession` going silent
/// with no device change, an IOProc stall, ScreenCaptureKit stopping without
/// `didStopWithError`) is never flagged, because there is no next buffer to compare against. A
/// mic delivers buffers even in total silence — that is what makes `ExactZeroRunMonitor`
/// meaningful — so a gap in delivery is itself an anomaly, checked by an off-audio-queue timer
/// rather than waiting for a buffer that may never arrive.
///
/// This type holds no timer, no queue, and no CoreAudio calls — it is fed a "now" and a "last
/// arrival" timestamp (both `mach`/`DispatchTime` monotonic nanoseconds, as already stamped by
/// `AudioOutputHandler` for the #86 liveness probe) and a `gateOpen` flag, and returns a verdict.
/// The driver (a `DispatchSourceTimer` in the XPC helper) owns everything side-effecting.
public struct LivenessGapDetector {

    public enum Verdict: Equatable {
        case healthy
        /// A gap crossed the threshold. Reports once per gap — cleared once delivery resumes (or
        /// the gate closes), so a track that goes silent again later is reported again. A gate
        /// close is deliberately treated the same as delivery resuming: it exists so a tap track's
        /// idle→active transition (gate re-opens with a fresh gap) stays observable rather than
        /// silently suppressed by a latch that never reset. The tradeoff: if the gate flaps closed
        /// and back open while `lastArrivalNanos` is unchanged (delivery never actually resumed),
        /// an already-reported gap is reported a second time.
        case gap(seconds: Double)
    }

    /// A gap over ~3 s is an anomaly for a source that is otherwise expected to deliver
    /// continuously (mic; SCK, which keeps delivering zero-filled buffers even in silence per
    /// gotcha #66). Short enough to catch a stall quickly, long enough to clear ordinary
    /// scheduling jitter on the delivery queue.
    public static let defaultGapThresholdSeconds: Double = 3

    public let track: String
    public let gapThresholdSeconds: Double
    private var reported = false

    public init(track: String, gapThresholdSeconds: Double = LivenessGapDetector.defaultGapThresholdSeconds) {
        self.track = track
        self.gapThresholdSeconds = gapThresholdSeconds
    }

    /// Judge one tick of the watchdog.
    ///
    /// - `nowNanos`: the watchdog's current monotonic timestamp.
    /// - `lastArrivalNanos`: the last time this track delivered a writable buffer, `0` if never
    ///   (not yet judged — mirrors `PadRatioMonitor`'s start-offset rule: a track that has not
    ///   started yet is not the same fault as one that stopped).
    /// - `gateOpen`: whether this track is currently EXPECTED to be delivering. For the mic and
    ///   SCK system audio this is just "capturing"; for the Core Audio tap it must additionally be
    ///   gated on `kAudioDevicePropertyDeviceIsRunningSomewhere` on the output device — the tap
    ///   legitimately delivers nothing while system output is idle (gotcha #66), and judging it
    ///   the same as SCK reproduces the exact false positive that gotcha describes.
    public mutating func check(nowNanos: UInt64, lastArrivalNanos: UInt64, gateOpen: Bool) -> Verdict {
        guard gateOpen, lastArrivalNanos != 0 else {
            reported = false
            return .healthy
        }
        let gapNanos = nowNanos >= lastArrivalNanos ? nowNanos - lastArrivalNanos : 0
        let gapSeconds = Double(gapNanos) / 1_000_000_000
        guard gapSeconds >= gapThresholdSeconds else {
            reported = false
            return .healthy
        }
        guard !reported else { return .healthy }
        reported = true
        return .gap(seconds: gapSeconds)
    }
}
