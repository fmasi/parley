import Foundation

/// Mic side of "heal, then alarm" (§5, §6.1): the first silence verdict of an episode rebuilds the
/// AVCaptureSession; a second, still silent, alarms as well. A heal that reports its restart budget
/// exhausted alarms at once (no re-arm → no second verdict). Frames end the episode.
public struct MicHealPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, alarm, clear, none }
    private var healsThisEpisode = 0
    public init() {}

    public mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict) -> Action {
        switch v {
        case .neverDelivered, .stalled:
            healsThisEpisode += 1
            return healsThisEpisode == 2 ? .healAndAlarm : .heal
        case .cleared, .firstFrames:
            healsThisEpisode = 0
            return .clear
        case .healthy:
            return .none
        }
    }

    /// `MicCaptureSession.onUnavailable`: the heal gave up, so no second verdict will come.
    public mutating func healFailed() -> Action {
        healsThisEpisode = max(healsThisEpisode, 2)
        return .alarm
    }
}
