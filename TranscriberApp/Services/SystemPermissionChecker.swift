import AVFoundation
import CoreGraphics
import EventKit
import TranscriberCore
import UserNotifications

struct SystemPermissionChecker: PermissionChecking {
    func checkMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func checkScreenRecording() async -> PermissionStatus {
        // CGPreflightScreenCaptureAccess checks without prompting the user
        CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
    }

    func checkCalendar() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func checkNotifications() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    func requestScreenRecording() async -> PermissionStatus {
        // CGRequestScreenCaptureAccess opens System Settings if not authorized
        CGRequestScreenCaptureAccess() ? .authorized : .notDetermined
    }

    func requestCalendar() async -> PermissionStatus {
        let store = EKEventStore()
        do {
            try await store.requestFullAccessToEvents()
            return .authorized
        } catch {
            return .denied
        }
    }

    func requestNotifications() async -> PermissionStatus {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }
}
