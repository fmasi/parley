import CoreAudio
import Testing
@testable import TranscriberCore

/// #193's pre-flight check, and its record (#314). The pure parts are unit-tested here (`shouldWarn`, `transportName`,
/// `preflightRecord`); `isLidClosed()`, `isBuiltInMicSelected(deviceId:)` and `inputTransport(deviceId:)` call
/// IOKit/CoreAudio and need real hardware — they are exercised only by a device test (checklist K-01..K-03).
@Suite struct ClamshellMicGuardTests {

    @Test func warnsOnlyWhenBothLidClosedAndBuiltInMicSelected() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: true, isBuiltInMic: true) == true)
    }

    @Test func lidOpenNeverWarnsEvenOnBuiltInMic() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: false, isBuiltInMic: true) == false)
    }

    @Test func closedLidOnAnExternalMicNeverWarns() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: true, isBuiltInMic: false) == false)
    }

    @Test func openLidAndExternalMicNeverWarns() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: false, isBuiltInMic: false) == false)
    }

    /// The banner text is shared by the one call site so the wording can't silently drift between
    /// the guard and `RecordingCoordinator`.
    @Test func warningMessageIsNonEmpty() {
        #expect(!ClamshellMicGuard.warningMessage.isEmpty)
    }

    // MARK: - #314: the record says what the pre-flight saw

    /// The transport the event names, from the SDK's own constants: a Bluetooth headset must read `bluetooth`, so a
    /// banner shown over one is visibly a misread or a stale banner.
    @Test func transportNamesFollowCoreAudio() {
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeBuiltIn) == "builtIn")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeBluetoothLE) == "bluetooth")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeUSB) == "usb")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeVirtual) == "virtual")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeAggregate) == "aggregate")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeContinuityCaptureWireless) == "continuity")
        #expect(ClamshellMicGuard.transportName(kAudioDeviceTransportTypeHDMI) == "other")
        #expect(ClamshellMicGuard.transportName(nil) == "unknown", "a UID that did not resolve")
    }

    @Test func thePreflightRecordCarriesItsInputsAndVerdict() {
        let warned = ClamshellMicGuard.preflightRecord(
            lidClosed: true, isBuiltInMic: true, device: nil, transport: "builtIn", reason: "start")
        #expect(warned == ["lid": "closed", "device": "default", "transport": "builtIn", "builtIn": "true",
                           "verdict": "warn", "reason": "start"])
        let headset = ClamshellMicGuard.preflightRecord(
            lidClosed: true, isBuiltInMic: false, device: "headset-1", transport: "bluetooth", reason: "micSwitch")
        #expect(headset["device"] == "headset-1" && headset["verdict"] == "none" && headset["lid"] == "closed")
        let open = ClamshellMicGuard.preflightRecord(
            lidClosed: false, isBuiltInMic: true, device: "builtin", transport: "builtIn", reason: "micFollow")
        #expect(open["lid"] == "open" && open["verdict"] == "none" && open["reason"] == "micFollow")
    }
}
