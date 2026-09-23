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

    /// System Audio Recording (`kTCCServiceAudioCapture`), which the Core Audio tap needs (#220).
    func checkSystemAudioRecording() async -> PermissionStatus
    /// Show the system prompt if never asked; otherwise return the stored answer.
    func requestSystemAudioRecording() async -> PermissionStatus
}

extension PermissionChecking {
    /// Default for checkers that predate the tap permission (and for tests that don't exercise it):
    /// report granted, so they keep behaving as they did.
    public func checkSystemAudioRecording() async -> PermissionStatus { .authorized }
    public func requestSystemAudioRecording() async -> PermissionStatus { .authorized }
}

@Observable
public final class PermissionManager {
    public var microphone: PermissionStatus = .notDetermined
    public var screenRecording: PermissionStatus = .notDetermined
    public var calendar: PermissionStatus = .notDetermined
    public var notifications: PermissionStatus = .notDetermined
    /// System Audio Recording, checked only while the tap is the configured source (#220).
    public var systemAudioRecording: PermissionStatus = .notDetermined

    /// Which system-audio capture method the requirements follow. Kept in sync with the config by the
    /// app; the tap needs System Audio Recording, ScreenCaptureKit needs Screen Recording.
    public var systemAudioSource: SystemAudioSource = .screenCaptureKit

    private let checker: PermissionChecking

    public init(checker: PermissionChecking) {
        self.checker = checker
        self.microphone = checker.checkMicrophone()
        self.screenRecording = .notDetermined
        self.calendar = checker.checkCalendar()
        self.notifications = .notDetermined
    }

    public func status(of permission: CapturePermission) -> PermissionStatus {
        switch permission {
        case .microphone: return microphone
        case .screenRecording: return screenRecording
        case .systemAudioRecording: return systemAudioRecording
        }
    }

    /// The permissions the configured source needs that are not granted.
    public var missingRequired: [CapturePermission] {
        CaptureReadiness.missing(for: systemAudioSource) { status(of: $0) }
    }

    public var allRequiredGranted: Bool { missingRequired.isEmpty }

    /// Re-check just the permissions a recording needs: cheap enough for record start and for the
    /// repair window's refresh while it is open.
    public func refreshRequired() async {
        microphone = checker.checkMicrophone()
        switch systemAudioSource {
        case .screenCaptureKit: screenRecording = await checker.checkScreenRecording()
        case .coreAudioTap: systemAudioRecording = await checker.checkSystemAudioRecording()
        }
    }

    public func request(_ permission: CapturePermission) async {
        switch permission {
        case .microphone: await requestMicrophone()
        case .screenRecording: await requestScreenRecording()
        case .systemAudioRecording: await requestSystemAudioRecording()
        }
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
        // Only the tap needs it, and checking means an XPC round-trip to the capture helper.
        if systemAudioSource == .coreAudioTap {
            systemAudioRecording = await checker.checkSystemAudioRecording()
        }
        Logger.permissions.info("Permissions — mic: \(String(describing: self.microphone), privacy: .public), screen: \(String(describing: self.screenRecording), privacy: .public), system audio: \(String(describing: self.systemAudioRecording), privacy: .public) (source \(self.systemAudioSource.rawValue, privacy: .public)), calendar: \(String(describing: self.calendar), privacy: .public), notifications: \(String(describing: self.notifications), privacy: .public)")
    }

    public func requestMicrophone() async {
        microphone = await checker.requestMicrophone()
        Logger.permissions.debug("Microphone permission: \(String(describing: self.microphone), privacy: .public)")
    }

    public func requestScreenRecording() async {
        screenRecording = await checker.requestScreenRecording()
        Logger.permissions.debug("Screen recording permission: \(String(describing: self.screenRecording), privacy: .public)")
    }

    public func requestSystemAudioRecording() async {
        systemAudioRecording = await checker.requestSystemAudioRecording()
        Logger.permissions.info("System Audio Recording permission: \(String(describing: self.systemAudioRecording), privacy: .public)")
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
