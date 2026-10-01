import AVFoundation
import CoreGraphics
import EventKit
import TranscriberCore
import UserNotifications
import os

struct SystemPermissionChecker: PermissionChecking {
    /// Asks the capture helper for the System Audio Recording status (#220). The app process can't
    /// answer this itself: TCC caches the answer per process, so the app would keep reporting its
    /// launch-time state after the user fixes (or loses) the permission.
    var helperSystemAudioStatus: @Sendable @MainActor () async -> PermissionStatus? = { nil }

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

    func checkSystemAudioRecording() async -> PermissionStatus {
        if let status = await helperSystemAudioStatus() { return status }
        // Unverifiable (private SPI missing, or the helper unreachable). Fail OPEN: nagging about a
        // permission we cannot check, with a fix we cannot confirm, would train the user to ignore
        // the window. The helper's exact-zero evidence path still catches a real denial mid-call.
        Logger.permissions.error("System Audio Recording permission unverifiable — assuming granted; relying on the tap's exact-zero evidence")
        return .authorized
    }

    func requestSystemAudioRecording() async -> PermissionStatus {
        // The prompt is attributed to the app, so it must be requested from the app process
        // (spike 2026-09-23). The request's own answer is authoritative, unlike a cached preflight.
        let answer = await SystemAudioRecordingPermission.request()
        if answer == .authorized { return .authorized }
        // Anything but a grant is ambiguous (denied, dismissed, or no prompt), so the helper's fresh
        // preflight has the last word. If it can't answer, fall back to this process's own (possibly
        // cached) view, and failing that to "never asked", which sends the user to System Settings.
        if let helper = await helperSystemAudioStatus() { return helper }
        return SystemAudioRecordingPermission.preflight() ?? .notDetermined
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
