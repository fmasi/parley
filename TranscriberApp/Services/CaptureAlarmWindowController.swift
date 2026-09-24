import AppKit
import SwiftUI
import TranscriberCore
import os

/// Presents capture alarms (§6.3): a floating panel listing every active alarm, and a time-sensitive
/// notification. The coordinator decides WHEN (the per-kind notify floor); `AlarmRealarmPolicy.presentation`
/// decides what: the notification names a due alarm, and the window opens at once for a newly raised
/// kind, otherwise only once "Later" is older than the snooze. The permission alarms keep their own
/// repair window: while it is open, their rows and their notifications are left to it.
@MainActor
final class CaptureAlarmWindowController: NSObject, NSWindowDelegate {
    static let shared = CaptureAlarmWindowController()

    /// One identifier for every alarm notification: a re-notify replaces the previous one instead of
    /// stacking a new banner every 2 minutes.
    static let notificationIdentifier = "parley-capture-alarm"

    private var panel: NSPanel?

    /// Whether the window is on screen: a crash-protection hand-over (an exit) waits while it is (L3).
    var isShowing: Bool { panel?.isVisible ?? false }
    /// "Later" (or the close button): the window stays closed until the snooze passes or a new kind arrives.
    private var lastDismissedAt: Date?

    /// `due`: the alarms the coordinator's notify floor lets present now. `userRequest`: the user clicked
    /// a menu row — open the window whatever the snooze, and post no notification (they are already looking).
    func present(_ due: [ActiveAlarm], newlyRaised: [AlarmKind], appState: AppState, userRequest: Bool = false) {
        if userRequest {
            if !Self.windowRows(appState.alarms.sorted).isEmpty { show(appState: appState) }
            return
        }
        let presentation = AlarmRealarmPolicy.presentation(
            due: due, newlyRaised: newlyRaised,
            repairWindowOpen: PermissionRepairWindowController.shared.isPanelOpen,
            lastDismissedAt: lastDismissedAt, now: Date()
        )
        if let alarm = presentation.notify {
            MenuView.postNotification(title: alarm.kind.headline, body: alarm.message,
                                      identifier: Self.notificationIdentifier)
        }
        // Otherwise snoozed; the sticky menu rows and the menu-bar icon still say it.
        if presentation.openWindow { show(appState: appState) }
    }

    /// The rows the window lists: every alarm, minus the permission ones while the repair window is up.
    static func windowRows(_ alarms: [ActiveAlarm]) -> [ActiveAlarm] {
        AlarmRealarmPolicy.windowRows(alarms, repairWindowOpen: PermissionRepairWindowController.shared.isPanelOpen)
    }

    private func show(appState: AppState) {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        closePanel()
        // Non-activating: pops up over the meeting WITHOUT taking focus from it (owner rule; push-to-talk
        // and chat keep working).
        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let content = CaptureAlarmPanelContent(
            appState: appState,
            onLater: { [weak self] in
                self?.lastDismissedAt = Date()
                self?.closePanel()
            },
            onEmpty: { [weak self] in self?.closePanel() }
        )
        newPanel.title = "Parley — Recording Problem"
        newPanel.contentView = NSHostingView(rootView: content)
        newPanel.delegate = self
        // Floats over the meeting app without taking it over, and never steals focus mid-call.
        newPanel.level = .floating
        // Also over a full-screen Zoom/Teams/Meet, on whichever Space the user is looking at.
        newPanel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.setContentSize(newPanel.contentView?.fittingSize ?? NSSize(width: CaptureAlarmView.preferredWidth, height: 240))
        newPanel.center()
        newPanel.orderFrontRegardless()
        panel = newPanel
        Logger.state.info("Capture alarm window shown")
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
        closed.contentView = nil
        if panel === closed { panel = nil }
    }
}

/// Reads the alarms live, so an acknowledged or cleared alarm leaves the open window at once, and
/// the window closes itself when nothing is left.
private struct CaptureAlarmPanelContent: View {
    let appState: AppState
    let onLater: () -> Void
    let onEmpty: () -> Void

    var body: some View {
        let rows = CaptureAlarmWindowController.windowRows(appState.alarms.sorted)
        CaptureAlarmView(alarms: rows, onLater: onLater, onAcknowledge: { appState.acknowledge($0) })
            .onChange(of: rows.isEmpty) { _, isEmpty in
                if isEmpty { onEmpty() }
            }
    }
}
