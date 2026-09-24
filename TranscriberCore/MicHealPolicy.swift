import Foundation

/// Mic side of "heal, then alarm" (§5, §6.1): the first silence verdict of an episode rebuilds the
/// AVCaptureSession; a repeat, still silent, alarms as well. A heal that reports its restart budget
/// exhausted alarms at once (no re-arm → no second verdict).
///
/// Frames end the episode only once they have held for `sustainedHealthSeconds` (H review round 1,
/// mirroring the tap ladder): a mic that bursts after every rebuild and then stalls again is a
/// repeat each time, so it alarms instead of being healed forever.
public struct MicHealPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, alarm, clear, none }

    public static let sustainedHealthSeconds = TapRecoveryLadder.sustainedHealthSeconds

    private var healsThisEpisode = 0
    /// When frames came back after the episode's last silence; `nil` = silent since, or no episode.
    private var healthySince: Double?

    public init() {}

    /// `now` in seconds on a monotonic clock.
    public mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict, now: Double) -> Action {
        switch v {
        case .neverDelivered, .stalled:
            if let since = healthySince, now - since >= Self.sustainedHealthSeconds { healsThisEpisode = 0 }
            healthySince = nil
            healsThisEpisode += 1
            return healsThisEpisode >= 2 ? .healAndAlarm : .heal
        case .cleared, .firstFrames:
            if healsThisEpisode > 0, healthySince == nil { healthySince = now }
            return .clear
        case .healthy:
            return .none
        }
    }

    /// `MicCaptureSession.onUnavailable`: the heal gave up, so no second verdict will come.
    public mutating func healFailed() -> Action {
        healsThisEpisode = max(healsThisEpisode, 2)
        healthySince = nil
        return .alarm
    }
}
