import Foundation
import Observation
import TranscriberCore
import os

/// The two ways a recording starts, reachable from anywhere in the app (menu, island, banner) — hoisted
/// out of `MenuView` (#118). Owns the remembered mic pick; the coordinator owns the lifecycle.
@MainActor
@Observable
final class RecordingLauncher {
    /// The user's pick for this session, if they have made one. Two levels on purpose: `.none` = no
    /// in-session pick, `.some(nil)` = they picked the system default.
    private var userPick: String??
    /// The mic the next recording uses (nil = system default). Observable: the menu's mic label reads
    /// it. An in-session pick wins; with none, the answer is whatever Settings last saved — without
    /// that fallback this would be seeded once per process, and a mic changed in Settings → Save would
    /// not reach the menu until the app relaunched (the regression the #118 hoist introduced, since
    /// `MenuView.init` used to re-seed on every panel re-creation).
    var selectedMicId: String? {
        get {
            if case .some(let picked) = userPick { return picked }
            return configManager.config.lastMicrophoneDeviceId
        }
        set { userPick = .some(newValue) }
    }
    private let coordinator: RecordingCoordinator
    private let configManager: ConfigManager
    private let calendarService: CalendarService

    init(coordinator: RecordingCoordinator, configManager: ConfigManager, calendarService: CalendarService) {
        self.coordinator = coordinator
        self.configManager = configManager
        self.calendarService = calendarService
    }

    /// The naming panel flow (moved verbatim from MenuView.promptAndStartRecording).
    func promptAndStart() async {
        let suggestedName = await calendarService.currentEventTitle(
            lookaheadMinutes: configManager.config.calendarLookaheadMinutes
        )
        SessionNameWindowController.shared.show(
            suggestedName: suggestedName,
            lastMicrophoneDeviceId: selectedMicId
        ) { [weak self] sessionName, micDeviceId in
            guard let self else { return }
            self.selectedMicId = micDeviceId
            // Captured locally so the task doesn't retain the launcher for the length of a start.
            let coordinator = self.coordinator
            Task { await coordinator.startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
        }
    }

    /// One click from "call started" to "recording": no panel. Name = the calendar title when the
    /// presenter already found one, else "<App> call"; mic = last used (the helper falls back to the
    /// default device if it is gone — `MicCaptureSession.buildAndStart`). Rename after transcription is
    /// unchanged. Returns whether the coordinator started (false = not idle / start in flight).
    func quickStart(app: MeetingApp, calendarTitle: String?) async -> Bool {
        let name = calendarTitle ?? "\(app.displayName) call"
        Logger.state.info("Quick start from meeting sensing — \(app.displayName, privacy: .public)")
        return await coordinator.startRecording(sessionName: name, microphoneDeviceId: selectedMicId)
    }
}
