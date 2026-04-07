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
            if interruptionWarning != nil { return "exclamationmark.bubble" }
            return "microphone.and.signal.meter.fill"
        case .transcribing: return "hourglass"
        }
    }

    public var recordingToggleLabel: String {
        switch phase {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing..."
        }
    }
}
