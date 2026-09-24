import Foundation
import Observation
import os

@MainActor
@Observable
public final class AppState {
    public enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(progress: String)
    }

    public var phase: Phase = .idle {
        didSet {
            if oldValue != self.phase {
                Logger.state.info("State: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.phase), privacy: .public)")
            }
            // Alarms scoped to the recording go with it; machine-level and unacknowledged ones stay.
            if !isRecording { alarms.recordingEnded() }
        }
    }
    public var lastTranscriptPath: String?
    public var lastJsonPath: String?
    /// Non-nil when recording was interrupted and auto-recovered.
    /// Shown as a warning in the menu until the user explicitly dismisses it.
    public var interruptionWarning: String?
    /// Non-nil when recording failed unrecoverably (e.g. XPC crash with failed retry).
    /// Shown as a critical alert in the menu. Stays until user explicitly dismisses.
    public var criticalError: String?
    /// Sticky alarms (§6). Helper-owned kinds mirror the helper's snapshot; app-owned kinds are
    /// raised here. Nothing benign can overwrite them; `interruptionWarning` stays the transient slot.
    /// A single past-tense banner is exactly how #220 went unnoticed for 51 minutes.
    public private(set) var alarms = CaptureAlarmRegistry()
    public var activeAlarms: [AlarmKind: ActiveAlarm] { alarms.alarms }

    public var errorMessage: String? {
        didSet {
            if let msg = self.errorMessage {
                Logger.state.info("Error set: \(msg, privacy: .private)")
            } else if oldValue != nil {
                Logger.state.info("Error cleared")
            }
        }
    }

    public var truncatedErrorMessage: String? {
        guard let msg = errorMessage else { return nil }
        if msg.count <= 80 { return msg }
        return String(msg.prefix(80)) + "..."
    }

    public init() {}

    /// Apply a live capture-quality anomaly from the helper: a transient notice only (the sticky state
    /// is the helper's alarm snapshot). Returns true when the System Audio Recording permission needs
    /// fixing, so the caller can open the repair window (#220).
    @discardableResult
    public func noteQualityAnomaly(kind: String, message: String) -> Bool {
        interruptionWarning = message
        return kind == CaptureEventKind.systemAudioPermissionDenied.rawValue
    }

    /// Applies the helper's snapshot; a kind this build does not know becomes one generic app alarm
    /// (never silently dropped — a newer helper is telling us something), cleared once it is gone.
    /// Returns whether the registry adopted it: a rejected (late or replaced-helper) snapshot changes
    /// nothing, the unknown-kind alarm included.
    @discardableResult
    public func applyHelperSnapshot(_ snapshot: CaptureStatusSnapshot) -> Bool {
        guard alarms.apply(snapshot) else { return false }
        if snapshot.unknownAlarmKinds.isEmpty {
            _ = alarms.clear(.unknownHelperAlarm)
        } else {
            alarms.raise(.unknownHelperAlarm, message: "The capture helper reported a problem this version of Parley can’t show (\(snapshot.unknownAlarmKinds.joined(separator: ", "))). Update Parley.", now: Date())
        }
        return true
    }
    @discardableResult
    public func raiseAppAlarm(_ kind: AlarmKind, message: String, now: Date = Date()) -> Bool { alarms.raise(kind, message: message, now: now) }
    public func clearAppAlarm(_ kind: AlarmKind) { _ = alarms.clear(kind) }
    /// Only past events (`isAcknowledgeable`) can be dismissed; a live condition clears only when it ends.
    public func acknowledge(_ kind: AlarmKind) { guard kind.isAcknowledgeable else { return }; _ = alarms.clear(kind) }
    public func markNotified(_ kind: AlarmKind, now: Date = Date()) { alarms.markNotified(kind, now: now) }
    /// The helper's evidence (§6.2): each clears only the stale kinds it disproves on that track.
    public func noteFirstFrames(track: CaptureTrack, helperSessionId: String) { alarms.noteFirstFrames(track: track, helperSessionId: helperSessionId) }
    public func noteRealAudio(track: CaptureTrack, helperSessionId: String) { alarms.noteRealAudio(track: track, helperSessionId: helperSessionId) }
    public func noteWriteSucceeded(helperSessionId: String) { alarms.noteWriteSucceeded(helperSessionId: helperSessionId) }

    /// The other side is not being captured, for whatever reason the helper reported.
    public var remoteAudioNotCaptured: Bool { alarms.alarms.keys.contains { $0.track == .system } }
    public var crashProtectionOff: Bool { alarms.alarms[.crashProtectionOff] != nil }

    /// Whether the menu's alert area has anything to show. The sticky alarm rows live in that area, so
    /// they must count here: gating the area on the dismissible banners alone hid the row as soon as
    /// the user dismissed one (PR #222 review).
    public var hasMenuAlerts: Bool {
        criticalError != nil || interruptionWarning != nil || truncatedErrorMessage != nil || !alarms.isEmpty
    }

    public var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    public var menuBarIcon: String {
        if criticalError != nil { return "exclamationmark.triangle.fill" }
        if errorMessage != nil { return "exclamationmark.triangle" }
        switch phase {
        // Only kinds that outlive a recording can still be active while idle.
        case .idle: return alarms.isEmpty ? "mic" : "exclamationmark.triangle"
        case .recording:
            if !alarms.isEmpty || interruptionWarning != nil { return "exclamationmark.bubble" }
            return "microphone.and.signal.meter.fill"
        case .transcribing: return "hourglass"
        }
    }

}
