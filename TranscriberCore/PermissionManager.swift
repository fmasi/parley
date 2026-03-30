import Foundation
import Observation

public enum PermissionStatus: Sendable {
    case authorized
    case notDetermined
    case denied

    public var isGranted: Bool { self == .authorized }
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

    public func checkAll() async {
        microphone = checker.checkMicrophone()
        screenRecording = await checker.checkScreenRecording()
        calendar = checker.checkCalendar()
        notifications = await checker.checkNotifications()
    }

    public func requestMicrophone() async {
        microphone = await checker.requestMicrophone()
    }

    public func requestScreenRecording() async {
        screenRecording = await checker.requestScreenRecording()
    }

    public func requestCalendar() async {
        calendar = await checker.requestCalendar()
    }

    public func requestNotifications() async {
        notifications = await checker.requestNotifications()
    }
}
