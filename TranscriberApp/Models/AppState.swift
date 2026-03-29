import Foundation
import SwiftUI

@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(progress: String)
    }

    var phase: Phase = .idle
    var lastTranscriptPath: String?
    var lastJsonPath: String?
    var errorMessage: String?

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    var menuBarIcon: String {
        switch phase {
        case .idle: return "mic"
        case .recording: return "record.circle"
        case .transcribing: return "hourglass"
        }
    }

    var recordingToggleLabel: String {
        switch phase {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing..."
        }
    }
}
