import AppKit
import SwiftUI
import TranscriberCore
import UserNotifications
import os

/// Detects a missing recording permission at the moments that matter and puts the fix in front of
/// the user (#220, #174). No background polling: it runs at launch, after a recording starts, when the
/// capture method changes, and when the capture helper reports the tap is being denied. When it finds
/// a gap it opens a floating repair window, not just a notification, because a notification doesn't
/// tell the user how to fix anything.
///
/// Rebuilding the tap after a grant is the HELPER's job (`TapPermissionGuard`): it sees fresh TCC
/// state, the app process does not. The app only nudges it when its own window sees the fix.
@MainActor
final class PermissionRepairWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionRepairWindowController()

    enum Trigger: String {
        case launch
        case recordStart = "record start"
        case settingsChange = "settings change"
        /// The helper reported the tap running without its permission (initial or a re-report).
        case captureEvidence = "capture evidence"
        /// The user tapped the sticky menu-bar banner.
        case userRequest = "user request"
    }

    private var panel: NSPanel?
    /// Everything the open window lists; new gaps found while it is open are merged in.
    private var listed: [CapturePermission] = []
    /// "Later" snoozes re-opening on repeated helper reports (the sticky banner keeps saying so).
    private var lastDismissedAt: Date?
    /// Collapses overlapping verify() calls (record start + a helper report can land together).
    private var verifying = false
    /// The most urgent trigger that arrived while another verify() was running. Re-run once afterwards
    /// instead of dropping it: a helper report outranks the rest, and a tap on the menu row or a
    /// Settings change must not be silently ignored.
    private var pendingTrigger: Trigger?

    private weak var permissionManager: PermissionManager?
    private weak var appState: AppState?
    private var captureClient: AudioCaptureClient?
    private let configManager: ConfigManager = .shared

    func configure(permissionManager: PermissionManager, captureClient: AudioCaptureClient, appState: AppState) {
        self.permissionManager = permissionManager
        self.captureClient = captureClient
        self.appState = appState
    }

    /// Check what a recording needs and, if anything is missing, open the repair window. Never blocks
    /// or stops a recording.
    func verify(trigger: Trigger) async {
        guard let permissionManager else { return }
        if verifying {
            if pendingTrigger != .captureEvidence { pendingTrigger = trigger }
            return
        }
        verifying = true
        await performVerify(trigger: trigger, permissionManager: permissionManager)
        verifying = false
        if let next = pendingTrigger {
            pendingTrigger = nil
            await verify(trigger: next)
        }
    }

    private func performVerify(trigger: Trigger, permissionManager: PermissionManager) async {
        // The source is a LOCAL decision: nothing here repoints `permissionManager.systemAudioSource`,
        // which drives the Settings and Setup rows. A report from a running tap outranks the config.
        let source = CaptureReadiness.sourceToVerify(
            configured: configManager.config.systemAudioSource,
            tapReportedProblem: trigger == .captureEvidence || appState?.remoteAudioNotCaptured == true
        )
        await permissionManager.refresh(CaptureReadiness.required(for: source))

        // The one gap a system prompt fixes by itself: a System Audio Recording permission that was
        // never asked for. Raise the real prompt first, but never let an unanswered prompt keep the
        // window away.
        if source == .coreAudioTap, permissionManager.systemAudioRecording == .notDetermined {
            await Self.withDeadline(seconds: 10) { await permissionManager.requestSystemAudioRecording() }
        }

        let missing = CaptureReadiness.missing(for: source) { permissionManager.status(of: $0) }
        Logger.permissions.info("Permission check (\(trigger.rawValue, privacy: .public)): missing \(missing.map(\.rawValue), privacy: .public)")
        guard !missing.isEmpty else {
            // Granted now. If a recording is running on the tap, let the helper confirm and rebuild.
            // Not awaited: a wedged helper must never hold `verifying` and silence every later check.
            Task { await self.nudgeHelperIfRecording() }
            return
        }
        guard CaptureReadiness.shouldOpenRepairWindow(
            isCaptureEvidence: trigger == .captureEvidence,
            windowIsOpen: panel?.isVisible ?? false,
            lastDismissedAt: lastDismissedAt,
            now: Date()
        ) else { return }   // snoozed; the sticky banner and menu-bar icon still say it
        show(missing: missing, source: source, trigger: trigger)
    }

    private func show(missing: [CapturePermission], source: SystemAudioSource, trigger: Trigger) {
        guard let permissionManager, let appState else { return }
        let required = CaptureReadiness.required(for: source)
        let merged = (listed + missing.filter { !listed.contains($0) }).filter { required.contains($0) }
        if let panel, panel.isVisible, merged == listed {
            panel.orderFrontRegardless()
            return
        }
        let wasOpen = panel?.isVisible ?? false
        closePanel()
        listed = merged

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let view = PermissionRepairView(
            permissionManager: permissionManager,
            appState: appState,
            permissions: merged,
            assumeRecording: trigger == .recordStart || trigger == .captureEvidence,
            onResolved: { [weak self] in
                guard let self else { return }
                self.closePanel()
                Task { await self.nudgeHelperIfRecording() }
            },
            onDismiss: { [weak self] in
                self?.lastDismissedAt = Date()
                self?.closePanel()
            }
        )
        newPanel.title = "Parley — Permission Needed"
        newPanel.contentView = NSHostingView(rootView: view)
        newPanel.delegate = self
        // Floats over the meeting app without taking it over: the user can keep talking and fix this.
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.setContentSize(newPanel.contentView?.fittingSize ?? PermissionRepairView.preferredSize)
        newPanel.center()
        newPanel.orderFrontRegardless()
        // Mid-call, don't steal keyboard focus from the meeting (push-to-talk, chat).
        if trigger != .captureEvidence { NSApp.activate() }
        panel = newPanel

        if !wasOpen, trigger == .recordStart || trigger == .captureEvidence {
            // Both triggers that reach here happen around a recording (the phase may not have flipped yet).
            postNotification(missing: merged, recording: true)
        }
    }

    /// Close via the title-bar button counts as "Later" too.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel, closing === panel else { return }
        lastDismissedAt = Date()
        teardown(closing)
    }

    private func closePanel() {
        guard let panel else { return }
        panel.delegate = nil
        panel.close()
        teardown(panel)
    }

    private func teardown(_ closed: NSPanel) {
        // Dropping the hosting view cancels the window's refresh task.
        closed.contentView = nil
        if panel === closed {
            panel = nil
            listed = []
        }
    }

    /// Ask the helper to re-check and rebuild the tap if it needs to. It decides with its own, fresh
    /// view of the permission, so this can't produce a false "restored".
    private func nudgeHelperIfRecording() async {
        guard let appState, appState.isRecording, let captureClient,
              configManager.config.systemAudioSource == .coreAudioTap || appState.remoteAudioNotCaptured
        else { return }
        await captureClient.restartSystemAudio()
    }

    private func postNotification(missing: [CapturePermission], recording: Bool) {
        let content = UNMutableNotificationContent()
        content.title = recording ? "Parley isn’t recording everything" : "Parley needs a permission"
        content.body = "\(CaptureReadiness.offPhrase(for: missing)). Use the window Parley just opened to fix it."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "permission-repair", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// Run `work`, but stop waiting after `seconds` (the work itself keeps running).
    private static func withDeadline(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(())
            }
            Task { @MainActor in
                await work()
                deadline.cancel()
                once.resume(())
            }
        }
    }
}
