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
            // Scoped to the recording it describes.
            if !isRecording { remoteAudioNotCaptured = false }
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
    /// The helper reported the tap running without its System Audio Recording permission and real
    /// audio hasn't come back yet (#220). Unlike `interruptionWarning` this can't be dismissed or
    /// overwritten by a later, unrelated anomaly: it clears only when real remote audio arrives or the
    /// recording ends. A single past-tense banner is exactly how #220 went unnoticed for 51 minutes.
    public var remoteAudioNotCaptured = false

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

    /// Apply a live capture-quality anomaly from the helper. Returns true when the System Audio
    /// Recording permission needs fixing, so the caller opens the repair window (#220).
    @discardableResult
    public func noteQualityAnomaly(kind: String, message: String) -> Bool {
        interruptionWarning = message
        switch kind {
        case CaptureEventKind.systemAudioPermissionDenied.rawValue:
            remoteAudioNotCaptured = true
            return true
        case CaptureEventKind.systemAudioPermissionRestored.rawValue:
            remoteAudioNotCaptured = false
            return false
        default:
            return false
        }
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
        case .idle: return "mic"
        case .recording:
            if remoteAudioNotCaptured || interruptionWarning != nil { return "exclamationmark.bubble" }
            return "microphone.and.signal.meter.fill"
        case .transcribing: return "hourglass"
        }
    }

}
