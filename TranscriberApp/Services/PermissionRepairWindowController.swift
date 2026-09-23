import AppKit
import SwiftUI
import TranscriberCore
import UserNotifications
import os

/// Detects a missing recording permission at the moments that matter and puts the fix in front of
/// the user (#220, #174). No background polling: it runs at launch, at record start, when the
/// capture method changes, and when the capture helper reports evidence (a tap delivering exact
/// zeros with the permission denied). When it finds a gap it opens a floating repair window, not
/// just a notification, because a notification doesn't tell the user how to fix anything.
@MainActor
final class PermissionRepairWindowController {
    static let shared = PermissionRepairWindowController()

    enum Trigger: String {
        case launch
        case recordStart = "record start"
        case settingsChange = "settings change"
        case captureEvidence = "capture evidence"
    }

    private var panel: NSPanel?
    /// Everything the open window lists — new gaps found while it is open are merged in.
    private var listed: [CapturePermission] = []

    private weak var permissionManager: PermissionManager?
    private weak var appState: AppState?
    private var captureClient: AudioCaptureClient?
    private var configManager: ConfigManager = .shared

    func configure(permissionManager: PermissionManager, captureClient: AudioCaptureClient, appState: AppState) {
        self.permissionManager = permissionManager
        self.captureClient = captureClient
        self.appState = appState
    }

    /// Check what a recording needs and, if anything is missing, open the repair window. Never blocks
    /// or stops a recording.
    func verify(trigger: Trigger) async {
        guard let permissionManager else { return }
        permissionManager.systemAudioSource = configManager.config.systemAudioSource
        await permissionManager.refreshRequired()

        // The one gap a system prompt fixes by itself: a System Audio Recording permission that was
        // never asked for. Raise the real prompt first; the window is only for what that doesn't fix.
        if permissionManager.systemAudioSource == .coreAudioTap,
           permissionManager.systemAudioRecording == .notDetermined {
            await permissionManager.requestSystemAudioRecording()
        }

        let missing = permissionManager.missingRequired
        Logger.permissions.info("Permission check (\(trigger.rawValue, privacy: .public)): missing \(missing.map(\.rawValue), privacy: .public)")
        guard !missing.isEmpty else {
            // Evidence said the tap was denied but the permission is granted now (the user fixed it
            // in between, or it was a transient answer). Rebuild so capture actually resumes.
            if trigger == .captureEvidence { await restoreSystemAudioIfRecording() }
            return
        }
        show(missing: missing, trigger: trigger)
    }

    private func show(missing: [CapturePermission], trigger: Trigger) {
        guard let permissionManager else { return }
        let recording = appState?.isRecording ?? false
        if recording {
            appState?.interruptionWarning = "\(ListFormatter.localizedString(byJoining: missing.map(\.displayName))) is off — part of this meeting isn’t being recorded."
        }
        let merged = listed + missing.filter { !listed.contains($0) }
        if let panel, panel.isVisible, merged == listed {
            panel.orderFrontRegardless()
            return
        }
        panel?.close()
        listed = merged

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let view = PermissionRepairView(
            permissionManager: permissionManager,
            permissions: merged,
            isRecording: recording,
            onResolved: { [weak self, weak newPanel] in
                guard let self else { return }
                newPanel?.close()
                self.windowClosed(newPanel)
                Task { await self.restoreSystemAudioIfRecording() }
            },
            onDismiss: { [weak self, weak newPanel] in
                newPanel?.close()
                self?.windowClosed(newPanel)
            }
        )
        newPanel.title = "Parley — Permission Needed"
        newPanel.contentView = NSHostingView(rootView: view)
        // Floats over the meeting app without taking it over: the user can keep talking and fix this.
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.setContentSize(newPanel.contentView?.fittingSize ?? PermissionRepairView.preferredSize)
        newPanel.center()
        newPanel.orderFrontRegardless()
        NSApp.activate()
        panel = newPanel

        if trigger == .recordStart || trigger == .captureEvidence {
            postNotification(missing: missing, recording: recording)
        }
    }

    private func windowClosed(_ closed: NSPanel?) {
        guard panel === closed else { return }
        panel = nil
        listed = []
    }

    /// After a mid-recording fix, rebuild the tap so remote audio resumes in the same recording.
    private func restoreSystemAudioIfRecording() async {
        guard let appState, appState.isRecording,
              configManager.config.systemAudioSource == .coreAudioTap,
              let captureClient else { return }
        if await captureClient.restartSystemAudio() {
            appState.interruptionWarning = "System Audio Recording is on — the other side of the call is being recorded again."
        }
    }

    private func postNotification(missing: [CapturePermission], recording: Bool) {
        let content = UNMutableNotificationContent()
        let names = ListFormatter.localizedString(byJoining: missing.map(\.displayName))
        content.title = recording ? "Parley isn’t recording everything" : "Parley needs a permission"
        content.body = "\(names) is off. Use the window Parley just opened to fix it."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "permission-repair", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
