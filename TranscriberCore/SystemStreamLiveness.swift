import Foundation

/// Pure decision for the #86 in-place restart liveness probe: did the rebuilt system-audio SCStream
/// actually deliver a buffer after the restart?
///
/// `buildAndStartStream` succeeding only means SCStream ACCEPTED the configuration — not that it
/// delivers audio. The original false-success bug declared the restart healed the instant the rebuild
/// returned and lost 47 minutes of a real call when the rebuilt stream produced no frames. The probe
/// snapshots a `probeStart` timestamp before the rebuild, waits, then asks this type whether the
/// handler's last system-buffer arrival is newer than that snapshot — i.e. at least one real buffer
/// arrived after the rebuild. Pure and total so the decision is unit-testable off the audio path.
public enum SystemStreamLiveness {
    /// True when the most recent system-buffer arrival is strictly newer than the moment the probe
    /// began — at least one buffer arrived after the rebuild. Side-effect-free and monotonic-safe.
    public static func framesResumed(lastArrivalNanos: UInt64, probeStartNanos: UInt64) -> Bool {
        lastArrivalNanos > probeStartNanos
    }
}
