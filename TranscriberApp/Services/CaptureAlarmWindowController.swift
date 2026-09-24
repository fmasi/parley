import AppKit
import SwiftUI
import TranscriberCore
import os

/// Presents capture alarms (§6.3): a floating panel listing every active alarm, and a time-sensitive
/// notification. The coordinator decides WHEN (the per-kind notify floor); this decides whether the
/// window opens: at once for a newly raised kind, otherwise only once "Later" is older than the snooze.
/// The permission alarms keep their own repair window: while it is open, their rows are left to it.
@MainActor
final class CaptureAlarmWindowController: NSObject, NSWindowDelegate {
    static let shared = CaptureAlarmWindowController()

    private var panel: NSPanel?
    /// "Later" (or the close button): the window stays closed until the snooze passes or a new kind arrives.
    private var lastDismissedAt: Date?

    /// `userRequest`: the user clicked a menu row — open the window whatever the snooze, and post no
    /// notification (they are already looking).
    func present(_ alarms: [ActiveAlarm], newlyRaised: [AlarmKind], appState: AppState, userRequest: Bool = false) {
        guard !alarms.isEmpty else { return }
        if !userRequest {
            // Once per call: the coordinator calls only when something is due.
            let lead = alarms.first { newlyRaised.contains($0.kind) } ?? alarms[0]
            MenuView.postNotification(title: "Parley isn’t recording everything", body: lead.message)
        }
        guard !Self.windowRows(alarms).isEmpty else { return }   // only rows the repair window already shows
        guard userRequest || !newlyRaised.isEmpty
                || AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: lastDismissedAt, now: Date())
        else { return }   // snoozed; the sticky menu rows and the menu-bar icon still say it
        show(appState: appState)
    }

    /// The rows the window lists: every alarm, minus the permission ones while the repair window is up.
    static func windowRows(_ alarms: [ActiveAlarm]) -> [ActiveAlarm] {
        guard PermissionRepairWindowController.shared.isPanelOpen else { return alarms }
        return alarms.filter { $0.kind != .remotePermissionDenied && $0.kind != .remoteCantConfirm }
    }

    private func show(appState: AppState) {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        closePanel()
        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
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
