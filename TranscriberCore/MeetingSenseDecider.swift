import Foundation

/// How the app reacts when it senses a meeting starting (a meeting app grabs the microphone).
/// Airgap-safe: the trigger is a local Core Audio HAL property, never the network or a calendar.
///
/// There is deliberately NO auto-record mode: meeting sensing only ever *prompts*, so the app never
/// records without an explicit user action (a consent/courtroom-grade choice). If silent auto-arm is
/// ever wanted, add a case here + a branch in `decide` — the rest of the pipeline already generalizes.
public enum MeetingSenseMode: String, Codable, Equatable, Sendable {
    /// Never react to meeting sensing.
    case off
    /// Surface a "start recording?" prompt — never records without explicit consent.
    case prompt
}

/// The action the sensor should take for a given signal snapshot.
public enum MeetingSenseAction: Equatable, Sendable {
    case ignore
    case prompt
}

/// A snapshot of the local signals at one instant. All fields are observable on-device without any
/// network or calendar access.
public struct MeetingSignal: Equatable, Sendable {
    /// The default input device is in use by some process
    /// (`kAudioDevicePropertyDeviceIsRunningSomewhere`) — i.e. *something* is holding the mic.
    public var micActive: Bool
    /// A known meeting app (Zoom/Teams/Webex/…) is currently running.
    public var meetingAppRunning: Bool
    /// Parley is already recording — never prompt or arm on top of an active session.
    public var isRecording: Bool

    public init(micActive: Bool, meetingAppRunning: Bool, isRecording: Bool) {
        self.micActive = micActive
        self.meetingAppRunning = meetingAppRunning
        self.isRecording = isRecording
    }
}

/// Pure decision logic for meeting-sensing (P2). No Core Audio / AppKit here — the app-layer
/// `MeetingSensor` feeds it a `MeetingSignal` and acts on the returned `MeetingSenseAction`, which
/// keeps the policy fully unit-testable.
///
/// A meeting is treated as "started" only when the mic is in use AND a known meeting app is running.
/// The app-presence gate filters out the many non-meeting mic users (dictation, FaceTime, Voice
/// Memos, system sound checks). A cooldown then ensures one meeting yields at most one prompt: the
/// mic stays busy for the whole call, and mute/unmute can re-fire the HAL listener, so the raw signal
/// flickers even though it's the same meeting.
public enum MeetingSenseDecider {

    /// Minimum gap between two non-ignore decisions. One meeting → at most one action per window.
    public static let defaultCooldown: TimeInterval = 300  // 5 minutes

    /// Decide what to do for the current signal.
    ///
    /// - Parameters:
    ///   - signal: current local signals.
    ///   - mode: the user's meeting-sensing preference.
    ///   - secondsSinceLastAction: seconds since the last non-ignore decision, or `nil` if there has
    ///     never been one (so the first real meeting always acts).
    ///   - cooldown: suppression window; defaults to `defaultCooldown`.
    public static func decide(
        signal: MeetingSignal,
        mode: MeetingSenseMode,
        secondsSinceLastAction: TimeInterval?,
        cooldown: TimeInterval = defaultCooldown
    ) -> MeetingSenseAction {
        guard mode == .prompt else { return .ignore }  // .off is the only other mode
        guard !signal.isRecording else { return .ignore }
        // Both signals are required — mic-in-use alone is too noisy, a running app alone isn't a call.
        guard signal.micActive && signal.meetingAppRunning else { return .ignore }
        // Debounce: suppress if we already prompted within the cooldown window.
        if let since = secondsSinceLastAction, since < cooldown { return .ignore }
        return .prompt
    }
}

/// Bundle identifiers treated as "a meeting is happening", used by the app-layer sensor to compute
/// `MeetingSignal.meetingAppRunning`. Kept in core as reviewable, testable data.
///
/// Native conferencing apps are high-precision. Browser-based calls (Google Meet in Chrome/Safari)
/// are deliberately NOT matched by bundle id here — a running browser says nothing about whether a
/// call is active — so they're covered only when the mic-active gate fires while a browser is
/// frontmost, which the sensor may add later as a separate, lower-confidence heuristic.
public enum MeetingApps {
    public static let bundleIDs: Set<String> = [
        "us.zoom.xos",                 // Zoom
        "com.microsoft.teams",         // Microsoft Teams (classic)
        "com.microsoft.teams2",        // Microsoft Teams (new)
        "com.cisco.webexmeetingsapp",  // Cisco Webex Meetings
        "com.webex.meetingmanager",    // Cisco Webex (alt bundle)
        "com.hnc.Discord",             // Discord
        "com.tinyspeck.slackmacgap",   // Slack (huddles)
    ]
}
