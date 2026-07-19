import Testing
@testable import TranscriberCore

struct NotificationWarningTests {

    @Test func authorizedProducesNoWarning() {
        let w = NotificationWarning(status: .authorized)
        #expect(w == .none)
        #expect(w.shouldWarn == false)
        #expect(w.message == nil)
        #expect(w.actionTitle == nil)
    }

    // Never asked / reset by reinstall: a system prompt is still possible → offer to request it.
    @Test func notDeterminedWarnsAndCanRequest() {
        let w = NotificationWarning(status: .notDetermined)
        #expect(w == .canRequest)
        #expect(w.shouldWarn == true)
        #expect(w.message != nil)
        #expect(w.actionTitle == "Turn On")
    }

    // Denied / turned off in System Settings: macOS won't re-prompt → must deep-link Settings.
    @Test func deniedWarnsAndOpensSettings() {
        let w = NotificationWarning(status: .denied)
        #expect(w == .openSettings)
        #expect(w.shouldWarn == true)
        #expect(w.message != nil)
        #expect(w.actionTitle == "Open Settings")
    }
}
