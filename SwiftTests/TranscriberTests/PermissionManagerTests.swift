import Testing
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
