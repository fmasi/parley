import Testing
import Foundation
@testable import TranscriberCore

struct PermissionManagerTests {

    // MARK: - PermissionStatus

    @Test func authorizedIsGranted() {
        #expect(PermissionStatus.authorized.isGranted == true)
    }

    @Test func notDeterminedIsNotGranted() {
        #expect(PermissionStatus.notDetermined.isGranted == false)
    }

    @Test func deniedIsNotGranted() {
        #expect(PermissionStatus.denied.isGranted == false)
    }

    // MARK: - allRequiredGranted
    // These tests are async because screenRecording and notifications
    // require async checks — init leaves them as .notDetermined.

    @Test func allRequiredGrantedWhenBothAuthorized() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .authorized,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == true)
    }

    @Test func allRequiredNotGrantedWhenMicMissing() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .authorized,
            calendar: .authorized,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }

    @Test func allRequiredNotGrantedWhenScreenRecordingMissing() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .denied,
            calendar: .authorized,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }

    @Test func allRequiredNotGrantedWhenBothMissing() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .notDetermined,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }

    // MARK: - checkAll

    @Test func checkAllUpdatesAllStatuses() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .authorized,
            calendar: .denied,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()

        #expect(manager.microphone == .authorized)
        #expect(manager.screenRecording == .authorized)
        #expect(manager.calendar == .denied)
        #expect(manager.notifications == .authorized)
    }

    @Test func checkAllWithNothingGranted() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .notDetermined,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()

        #expect(manager.microphone == .notDetermined)
        #expect(manager.screenRecording == .notDetermined)
        #expect(manager.calendar == .notDetermined)
        #expect(manager.notifications == .notDetermined)
        #expect(manager.allRequiredGranted == false)
    }

    // MARK: - #220: requirements follow the system-audio source

    @Test func tapSourceRequiresSystemAudioNotScreenRecording() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        manager.systemAudioSource = .coreAudioTap
        await manager.checkAll()
        #expect(manager.systemAudioRecording == .notDetermined)
        #expect(manager.missingRequired == [.systemAudioRecording])
        #expect(manager.allRequiredGranted == false)
    }

    @Test func tapSourceIsReadyWithoutScreenRecording() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .notDetermined, systemAudio: .authorized
        )
        let manager = PermissionManager(checker: checker)
        manager.systemAudioSource = .coreAudioTap
        await manager.checkAll()
        #expect(manager.allRequiredGranted == true)
    }

    @Test func sckSourceIgnoresSystemAudioRecording() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .denied
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()   // default source is SCK
        #expect(manager.missingRequired.isEmpty)
    }

    /// The SCK path never needs the helper round-trip for System Audio Recording.
    @Test func sckSourceDoesNotQuerySystemAudio() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .denied
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(checker.systemAudioQueries.value == 0)
    }

    // MARK: - PR #222 review: refresh what a window lists, without touching the configured source

    @Test func refreshingSpecificPermissionsChecksOnlyThose() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .denied
        )
        let manager = PermissionManager(checker: checker)
        await manager.refresh([.systemAudioRecording])
        #expect(manager.systemAudioRecording == .denied)
        #expect(checker.systemAudioQueries.value == 1)
        #expect(manager.screenRecording == .notDetermined)   // not asked, so untouched
    }

    /// A repair window for the running tap must not repoint the Settings/Setup rows at the tap.
    @Test func refreshingDoesNotChangeTheConfiguredSource() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .authorized
        )
        let manager = PermissionManager(checker: checker)
        manager.systemAudioSource = .screenCaptureKit
        await manager.refresh([.microphone, .systemAudioRecording])
        #expect(manager.systemAudioSource == .screenCaptureKit)
        #expect(manager.status(of: .systemAudioRecording) == .authorized)
    }

    @Test func requestSystemAudioUpdatesStatus() async {
        let checker = SourceAwareMockChecker(
            microphone: .authorized, screenRecording: .authorized, systemAudio: .authorized
        )
        let manager = PermissionManager(checker: checker)
        manager.systemAudioSource = .coreAudioTap
        await manager.requestSystemAudioRecording()
        #expect(manager.systemAudioRecording == .authorized)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}

struct SourceAwareMockChecker: PermissionChecking {
    var microphone: PermissionStatus
    var screenRecording: PermissionStatus
    var systemAudio: PermissionStatus
    let systemAudioQueries = Counter()

    func checkMicrophone() -> PermissionStatus { microphone }
    func checkScreenRecording() async -> PermissionStatus { screenRecording }
    func checkCalendar() -> PermissionStatus { .notDetermined }
    func checkNotifications() async -> PermissionStatus { .notDetermined }
    func checkSystemAudioRecording() async -> PermissionStatus {
        systemAudioQueries.increment()
        return systemAudio
    }

    func requestMicrophone() async -> PermissionStatus { microphone }
    func requestScreenRecording() async -> PermissionStatus { screenRecording }
    func requestCalendar() async -> PermissionStatus { .notDetermined }
    func requestNotifications() async -> PermissionStatus { .notDetermined }
    func requestSystemAudioRecording() async -> PermissionStatus { systemAudio }
}

// MARK: - Mock

struct MockPermissionChecker: PermissionChecking {
    var microphone: PermissionStatus
    var screenRecording: PermissionStatus
    var calendar: PermissionStatus
    var notifications: PermissionStatus

    func checkMicrophone() -> PermissionStatus { microphone }
    func checkScreenRecording() async -> PermissionStatus { screenRecording }
    func checkCalendar() -> PermissionStatus { calendar }
    func checkNotifications() async -> PermissionStatus { notifications }

    func requestMicrophone() async -> PermissionStatus { microphone }
    func requestScreenRecording() async -> PermissionStatus { screenRecording }
    func requestCalendar() async -> PermissionStatus { calendar }
    func requestNotifications() async -> PermissionStatus { notifications }
}
