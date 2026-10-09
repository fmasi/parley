import Foundation
import Testing
@testable import TranscriberCore

// Round K: the lid-closed banner's lifecycle and its record (#314). The fake client and the harness are
// RecordingCoordinatorTests.swift's.

@MainActor
@Suite struct RecordingCoordinatorRoundKTests {
    /// "builtin" is the Mac's own mic; anything else is not. The lid is closed throughout.
    private func lidClosed(_ h: Harness) {
        h.coordinator.preflight = { id in (true, id == "builtin") }
        h.coordinator.preflightTransport = { id in id == "builtin" ? "builtIn" : "bluetooth" }
    }

    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    private func preflights(_ h: Harness) -> [[String: String]] {
        h.client.recordedEvents.filter { $0.kind == .clamshellPreflight }.map(\.detail)
    }

    @Test func aStartOnTheBuiltInMicWithTheLidClosedWarnsAndRecordsWhatItSaw() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "builtin")
        #expect(h.appState.isRecording)
        #expect(h.appState.interruptionWarning == ClamshellMicGuard.warningMessage)
        let event = try #require(h.client.recordedEvents.first { $0.kind == .clamshellPreflight })
        #expect(event.severity == .info)
        #expect(event.detail == ["lid": "closed", "device": "builtin", "transport": "builtIn", "builtIn": "true",
                                 "verdict": "warn", "reason": "start"])
    }

    /// The case behind #314: the banner stayed from an earlier start while the recording ran on a headset.
    @Test func aBannerLeftFromAnEarlierRecordingIsGoneAtTheNextStart() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        h.appState.interruptionWarning = ClamshellMicGuard.warningMessage   // never dismissed
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "headset-1")
        #expect(h.appState.isRecording)
        #expect(h.appState.interruptionWarning == nil)
        #expect(preflights(h).map { $0["verdict"] } == ["none"])
        #expect(preflights(h).first?["transport"] == "bluetooth")
    }

    @Test func aSwitchToAMicTheGuardWouldNotWarnAboutTakesTheBannerDown() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "builtin")
        #expect(h.appState.interruptionWarning == ClamshellMicGuard.warningMessage)
        try await h.coordinator.switchMicrophone(to: "headset-1")
        await Harness.until { h.appState.interruptionWarning == nil }
        #expect(h.appState.interruptionWarning == nil)
        let switched = try #require(preflights(h).last)
        #expect(switched["reason"] == "micSwitch" && switched["device"] == "headset-1" && switched["verdict"] == "none")
    }

    @Test func theHelpersFollowToAnotherMicTakesTheBannerDown() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "builtin")
        h.client.onMicDeviceChanged?("headset-1")
        await Harness.until { h.appState.interruptionWarning == nil }
        #expect(h.appState.interruptionWarning == nil)
        #expect(preflights(h).last?["reason"] == "micFollow")
    }

    /// Still on a built-in mic with the lid closed: the warning still holds, and the re-check is recorded.
    @Test func aSwitchToAMicTheGuardStillWarnsAboutKeepsTheBanner() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        h.coordinator.preflight = { id in (true, id == "builtin" || id == nil) }
        h.coordinator.preflightTransport = { _ in "builtIn" }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "builtin")
        try await h.coordinator.switchMicrophone(to: nil)   // the system default: the built-in mic again
        await Harness.until { preflights(h).count == 2 }
        #expect(preflights(h).last?["verdict"] == "warn" && preflights(h).last?["device"] == "default")
        #expect(h.appState.interruptionWarning == ClamshellMicGuard.warningMessage)
    }

    /// Only the lid-closed banner is about a microphone: a switch leaves any other banner alone.
    @Test func aSwitchLeavesAnyOtherBannerAlone() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "headset-1")
        h.appState.interruptionWarning = "Recording restarted — waiting for audio…"
        try await h.coordinator.switchMicrophone(to: "headset-2")
        h.client.onMicDeviceChanged?("headset-3")
        await Harness.until { h.recordingMic.current == .some("headset-3") }
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
        #expect(preflights(h).count == 1, "only the start's pre-flight: no re-check without the lid-closed banner")
    }

    /// A switch the helper refused leaves the recording on the built-in mic: the banner stays, nothing is re-checked.
    @Test func aFailedSwitchKeepsTheBanner() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        lidClosed(h)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "builtin")
        h.client.updateMicError = FakeCaptureError()
        await #expect(throws: (any Error).self) { try await h.coordinator.switchMicrophone(to: "headset-1") }
        await Harness.until(within: 0.3) { preflights(h).count > 1 }   // a re-check, had one been started, lands here
        #expect(h.recordingMic.current == .some("builtin"))
        #expect(h.appState.interruptionWarning == ClamshellMicGuard.warningMessage)
        #expect(preflights(h).count == 1, "only the start's pre-flight")
    }
}
