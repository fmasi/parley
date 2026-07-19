import Foundation
import Observation
import os

public enum PermissionStatus: Sendable {
    case authorized
    case notDetermined
    case denied

    public var isGranted: Bool { self == .authorized }
}

/// The ongoing "notifications are disabled" signal (#150).
///
/// Notification permission is optional — it never gates recording. But when it is off,
/// every notification the app relies on ("Transcription Complete", "Recording Failed",
/// "Recording Resumed", "Summary Failed") silently vanishes, and macOS never tells the
/// user. This maps the raw authorization status to the warning the UI should surface,
/// kept out of the views so the decision is unit-testable without a real
/// UNUserNotificationCenter.
public enum NotificationWarning: Equatable, Sendable {
    /// Notifications are authorized — no signal needed.
    case none
    /// Never asked, or reset by a reinstall — the system permission prompt can still
    /// be shown, so the corrective action is a direct authorization request.
    case canRequest
    /// Denied, or turned off later in System Settings — macOS will not re-prompt, so
    /// the only corrective action is deep-linking the Notifications settings pane.
    case openSettings

    public init(status: PermissionStatus) {
        switch status {
        case .authorized: self = .none
        case .notDetermined: self = .canRequest
        case .denied: self = .openSettings
        }
    }

    public var shouldWarn: Bool { self != .none }

    /// User-facing one-liner for the menu panel; nil when no warning is due.
    public var message: String? {
        shouldWarn
            ? "Notifications are off — you won't be alerted if a recording or summary fails."
            : nil
    }

    /// Title for the corrective action: request the permission while a system prompt
    /// is still possible; send the user to System Settings once it isn't.
    public var actionTitle: String? {
        switch self {
        case .none: return nil
        case .canRequest: return "Turn On"
        case .openSettings: return "Open Settings"
        }
    }
}

public protocol PermissionChecking: Sendable {
    func checkMicrophone() -> PermissionStatus
    func checkScreenRecording() async -> PermissionStatus
    func checkCalendar() -> PermissionStatus
    func checkNotifications() async -> PermissionStatus

    func requestMicrophone() async -> PermissionStatus
    func requestScreenRecording() async -> PermissionStatus
    func requestCalendar() async -> PermissionStatus
    func requestNotifications() async -> PermissionStatus
}

@Observable
public final class PermissionManager {
    public var microphone: PermissionStatus = .notDetermined
    public var screenRecording: PermissionStatus = .notDetermined
    public var calendar: PermissionStatus = .notDetermined
    public var notifications: PermissionStatus = .notDetermined

    private let checker: PermissionChecking

    public init(checker: PermissionChecking) {
        self.checker = checker
        self.microphone = checker.checkMicrophone()
        self.screenRecording = .notDetermined
        self.calendar = checker.checkCalendar()
        self.notifications = .notDetermined
    }

    public var allRequiredGranted: Bool {
        microphone.isGranted && screenRecording.isGranted
    }

    /// The ongoing notifications-disabled signal derived from the current status (#150).
    /// Observable: any view reading this re-renders when `notifications` changes.
    public var notificationWarning: NotificationWarning {
        NotificationWarning(status: notifications)
    }

    /// Re-checks only the notification status — cheap enough to run every time the
    /// menu panel opens, so the warning tracks changes the user makes in System
    /// Settings mid-session (the state #150 shipped blind to).
    public func refreshNotifications() async {
        notifications = await checker.checkNotifications()
    }

    public func checkAll() async {
        microphone = checker.checkMicrophone()
        screenRecording = await checker.checkScreenRecording()
        calendar = checker.checkCalendar()
        notifications = await checker.checkNotifications()
        Logger.permissions.info("Permissions — mic: \(String(describing: self.microphone), privacy: .public), screen: \(String(describing: self.screenRecording), privacy: .public), calendar: \(String(describing: self.calendar), privacy: .public), notifications: \(String(describing: self.notifications), privacy: .public)")
    }

    public func requestMicrophone() async {
        microphone = await checker.requestMicrophone()
        Logger.permissions.debug("Microphone permission: \(String(describing: self.microphone), privacy: .public)")
    }

    public func requestScreenRecording() async {
        screenRecording = await checker.requestScreenRecording()
        Logger.permissions.debug("Screen recording permission: \(String(describing: self.screenRecording), privacy: .public)")
    }

    public func requestCalendar() async {
        calendar = await checker.requestCalendar()
        Logger.permissions.debug("Calendar permission: \(String(describing: self.calendar), privacy: .public)")
    }

    public func requestNotifications() async {
        notifications = await checker.requestNotifications()
        Logger.permissions.debug("Notifications permission: \(String(describing: self.notifications), privacy: .public)")
    }
}
