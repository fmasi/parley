import Foundation
import Testing
@testable import TranscriberCore

// #315: the mic follow must not land on the built-in mic while the lid is closed when the user has another
// input to hand. The helper only knows the inputs the user chose by hand if the app remembers them and passes
// them with the start. The fake client and the harness are RecordingCoordinatorTests.swift's; `roundFTearDown`
// is RecordingCoordinatorRoundFTests.swift's.

@MainActor
@Suite(.serialized) struct RecordingCoordinatorMicChoiceTests {

    @Test func aStartOnAChosenMicRemembersItAndPassesTheChoicesToTheHelper() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.config.update { $0.recentMicrophoneDeviceIds = ["usb-cam"] }

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "airpods")

        #expect(h.appState.isRecording)
        #expect(h.config.config.recentMicrophoneDeviceIds == ["airpods", "usb-cam"])
        // The earlier choices; the helper adds the mic it starts on to its own list.
        #expect(h.client.startCalls.first?.options.userMicrophoneChoices == ["usb-cam"])
        // Persisted: the next launch still knows them.
        #expect(ConfigManager(configDir: h.tmp).config.recentMicrophoneDeviceIds == ["airpods", "usb-cam"])
        await h.coordinator.stopRecording()
    }

    @Test func aStartOnTheSystemDefaultRemembersNothingNew() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.config.update { $0.recentMicrophoneDeviceIds = ["usb-cam"] }

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: nil)

        #expect(h.config.config.recentMicrophoneDeviceIds == ["usb-cam"])
        #expect(h.client.startCalls.first?.options.userMicrophoneChoices == ["usb-cam"])
        await h.coordinator.stopRecording()
    }

    @Test func aStartTheHelperRefusedIsNotRemembered() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.client.startError = FakeCaptureError()

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "airpods")

        #expect(h.appState.isIdle)
        #expect((h.config.config.recentMicrophoneDeviceIds ?? []).isEmpty)
    }

    @Test func aMidRecordingSwitchIsRememberedForTheNextStart() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")

        try await h.coordinator.switchMicrophone(to: "usb-cam")

        #expect(h.config.config.recentMicrophoneDeviceIds == ["usb-cam"])
    }

    @Test func aSwitchTheHelperRefusedIsNotRemembered() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) { try await h.coordinator.switchMicrophone(to: "usb-cam") }

        #expect((h.config.config.recentMicrophoneDeviceIds ?? []).isEmpty)
    }
}
