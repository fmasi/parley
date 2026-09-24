import Foundation

/// Mic side of "heal, then alarm" (§5, §6.1): the first silence verdict of an episode rebuilds the
/// AVCaptureSession; a repeat, still silent, alarms as well. A heal that reports its restart budget
/// exhausted alarms at once (no re-arm → no second verdict).
///
/// Frames end the episode only once they have held for `sustainedHealthSeconds` (H review round 1,
/// mirroring the tap ladder): a mic that bursts after every rebuild and then stalls again is a
/// repeat each time, so it alarms instead of being healed forever.
///
/// Every reopen has a deadline (H2 council, A-C2), mirroring the tap's stuck watchdog: a reopen
/// that blocks (gotcha #68) or a heal that is a no-op behind a recovery already in flight never
/// re-arms the monitor, so no second verdict comes — `tick` alarms instead. A deadline never crosses a
/// sleep (round 2 item 11): sleep clears it, and the wake's reopen starts a fresh one.
public struct MicHealPolicy: Equatable, Sendable {
    /// `.reopenStuck`: the deadline passed with the reopen still in flight (alarm; record it as stuck).
    /// `.alarm` from `tick`: the reopen returned but delivered nothing (alarm, not "stuck", round 2
    /// item 15). `.followFailed`: a failed follow while the current mic keeps recording — the
    /// acknowledgeable `micFollowFailed`, never the sticky `micNotDelivering` (A-I5, round 2 item 12).
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, alarm, reopenStuck, clear, followFailed, none }

    public static let sustainedHealthSeconds = TapRecoveryLadder.sustainedHealthSeconds
    /// A reopen that has not delivered a newer heartbeat by then alarms (A-C2).
    public static let reopenDeadlineSeconds: Double = 8
    /// A heartbeat younger than this means the mic is delivering: the liveness monitor's stall threshold.
    public static let deliveringWithinSeconds: Double = 3

    private var healsThisEpisode = 0
    /// When frames came back after the episode's last silence; `nil` = silent since, or no episode.
    private var healthySince: Double?
    /// When the pending reopen was asked for; `nil` = none pending.
    private var reopenRequestedAt: Double?
    /// The mic heartbeat when it was asked for: only a NEWER one proves the reopen delivered.
    private var reopenHeartbeat: UInt64 = 0
    /// The deadline alarmed; the mic's next frames clear it.
    private var reopenAlarmed = false

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

    /// Whether the mic the recover loop leaves behind is still recording: a heartbeat within
    /// `deliveringWithinSeconds` AND its device still present — a fresh heartbeat from a device that
    /// just vanished is not "still recording" (round 2 item 12, minor 2). The session keeps its current
    /// device id on true, so an unrelated HAL event can't tear down a working mic (round 2 item 14).
    public static func stillRecording(heartbeatAgeSeconds: Double?, currentDevicePresent: Bool) -> Bool {
        guard let age = heartbeatAgeSeconds else { return false }
        return age < deliveringWithinSeconds && currentDevicePresent
    }

    /// `MicCaptureSession.onUnavailable`: the recover loop gave up, so no second verdict will come.
    /// Alarms only if the mic is actually silent: a follow that failed BEFORE the session swap leaves
    /// the current mic recording, and a `micNotDelivering` raised then would never be cleared (A-I5) —
    /// that is `.followFailed`. If the current mic stops later, the normal liveness path alarms. Either
    /// way no reopen deadline is left behind: the give-up already reported it (round 2 item 15).
    public mutating func healFailed(heartbeatAgeSeconds: Double?, currentDevicePresent: Bool) -> Action {
        reopenRequestedAt = nil
        if Self.stillRecording(heartbeatAgeSeconds: heartbeatAgeSeconds, currentDevicePresent: currentDevicePresent) {
            return .followFailed
        }
        healsThisEpisode = max(healsThisEpisode, 2)
        healthySince = nil
        return .alarm
    }

    /// The service asked the mic to reopen (a silence verdict, wake, a coreaudiod restart), with the
    /// mic heartbeat seen then. A reopen already pending keeps its start: asking again (or a heal that
    /// is a no-op behind a recovery in flight) never pushes the deadline back — except the WAKE's
    /// reopen (`restartingDeadline`), which replaces a deadline that ran before the sleep (item 11).
    public mutating func reopenRequested(now: Double, heartbeat: UInt64, restartingDeadline: Bool = false) {
        guard reopenRequestedAt == nil || restartingDeadline else { return }
        reopenRequestedAt = now
        reopenHeartbeat = heartbeat
    }

    /// Sleep: a pending reopen's deadline must not run across it and fire at the wake (item 11).
    public mutating func slept() {
        reopenRequestedAt = nil
    }

    /// Every awake 1 Hz tick, with the mic's last heartbeat and whether a reopen is still running.
    /// Once a reopen has delivered nothing newer within `reopenDeadlineSeconds`: `.reopenStuck` if it
    /// is still in flight, else `.alarm` (it returned, silent). `.clear` once when the mic's frames
    /// arrive after that — evidence, whether or not anything re-armed the monitor.
    public mutating func tick(now: Double, heartbeat: UInt64, reopenInFlight: Bool) -> Action {
        if heartbeat > reopenHeartbeat, reopenRequestedAt != nil || reopenAlarmed {
            reopenRequestedAt = nil
            guard reopenAlarmed else { return .none }
            reopenAlarmed = false
            if healsThisEpisode > 0, healthySince == nil { healthySince = now }
            return .clear
        }
        guard let at = reopenRequestedAt, now - at >= Self.reopenDeadlineSeconds else { return .none }
        reopenRequestedAt = nil
        reopenAlarmed = true
        healsThisEpisode = max(healsThisEpisode, 2)
        healthySince = nil
        return reopenInFlight ? .reopenStuck : .alarm
    }
}
