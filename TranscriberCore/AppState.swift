import Foundation
import Observation

@Observable
public final class AppState {
    public enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(progress: String)
    }

    public var phase: Phase = .idle
    public var lastTranscriptPath: String?
    public var lastJsonPath: String?
    public var errorMessage: String?

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
        switch phase {
        case .idle: return "mic"
        case .recording: return "record.circle"
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
