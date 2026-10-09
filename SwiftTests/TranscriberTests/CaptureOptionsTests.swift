import Foundation
import Testing
@testable import TranscriberCore

/// M-B: `TapAutoStart` decides whether "no callbacks" is ambiguous. It becomes a diagnostic knob
/// so the device test can A/B it without a rebuild; the default flips only on a measured pass.
@Suite struct CaptureOptionsTests {
    @Test func defaultsMatchTheShippedBehaviour() {
        let o = CaptureOptions()
        #expect(o.tapAutoStart == true)
        #expect(o.remoteExactZeroSoftAlarmSeconds == nil)
        #expect(o.debugDropTapFrames == false)
        #expect(o.debugSkipWavSync == false)
    }
    @Test func builtFromConfig() {
        var c = Config.default
        c.tapAutoStart = false
        c.remoteExactZeroSoftAlarmSeconds = 300
        c.debugDropTapFrames = true
        let o = CaptureOptions(config: c)
        #expect(o == CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 300, debugDropTapFrames: true))
        #expect(CaptureOptions(config: Config.default) == CaptureOptions())
    }
    /// #247: `debug_skip_wav_sync` reaches the helper the way `debug_drop_tap_frames` does, and is
    /// off unless the config says `true`.
    @Test func skipWavSyncIsBuiltFromConfigAndOffByDefault() {
        var c = Config.default
        #expect(CaptureOptions(config: c).debugSkipWavSync == false, "absent from config.json")
        c.debugSkipWavSync = false
        #expect(CaptureOptions(config: c).debugSkipWavSync == false)
        c.debugSkipWavSync = true
        #expect(CaptureOptions(config: c).debugSkipWavSync == true)
        #expect(CaptureOptions(config: c) == CaptureOptions(debugSkipWavSync: true), "and it changes nothing else")
    }
    @Test func skipWavSyncDecodesWhenPresent() throws {
        let on = Data(#"{"tapAutoStart":true,"debugDropTapFrames":false,"debugSkipWavSync":true}"#.utf8)
        #expect(try #require(CaptureOptions.decodeStrict(on)).debugSkipWavSync == true)
        #expect(CaptureOptions.decode(on) == CaptureOptions(debugSkipWavSync: true))
    }
    @Test func skipWavSyncDecodesFalse() throws {
        let off = Data(#"{"tapAutoStart":true,"debugDropTapFrames":false,"debugSkipWavSync":false}"#.utf8)
        #expect(try #require(CaptureOptions.decodeStrict(off)).debugSkipWavSync == false)
        #expect(CaptureOptions.decode(off) == CaptureOptions())
    }
    /// A payload without the key comes from a helper/app pair that does not match. As for every other
    /// option it is "not understood" (the helper says so and keeps its defaults): the fsync is never
    /// skipped by a payload that did not ask for it.
    @Test func skipWavSyncAbsentIsNotUnderstoodAndNeverSkips() {
        let absent = Data(#"{"tapAutoStart":true,"debugDropTapFrames":false}"#.utf8)
        #expect(CaptureOptions.decodeStrict(absent) == nil)
        #expect(CaptureOptions.decode(absent).debugSkipWavSync == false)
        #expect(CaptureOptions.decode(nil).debugSkipWavSync == false)
    }
    @Test func skipWavSyncRoundTrips() {
        let o = CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 120, debugDropTapFrames: false, debugSkipWavSync: true)
        #expect(CaptureOptions.decodeStrict(o.encoded()) == o)
    }
    /// #315: the inputs the user chose by hand reach the helper with the start, so a follow away from a
    /// removed mic while the lid is closed can land on one of them instead of the dead built-in mic.
    @Test func userMicrophoneChoicesAreBuiltFromConfig() {
        var c = Config.default
        #expect(CaptureOptions(config: c).userMicrophoneChoices == [], "none recorded yet")
        c.recentMicrophoneDeviceIds = ["usb-cam", "airpods"]
        #expect(CaptureOptions(config: c).userMicrophoneChoices == ["usb-cam", "airpods"])
        #expect(CaptureOptions(config: c) == CaptureOptions(userMicrophoneChoices: ["usb-cam", "airpods"]), "and nothing else")
    }
    @Test func userMicrophoneChoicesRoundTripAndAreOptionalOnTheWire() throws {
        let o = CaptureOptions(userMicrophoneChoices: ["usb-cam"])
        #expect(CaptureOptions.decodeStrict(o.encoded()) == o)
        let without = Data(#"{"tapAutoStart":true,"debugDropTapFrames":false,"debugSkipWavSync":false}"#.utf8)
        #expect(try #require(CaptureOptions.decodeStrict(without)).userMicrophoneChoices == [])
    }
    @Test func roundTripsAndFailsSoft() {
        let o = CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 120, debugDropTapFrames: false)
        #expect(CaptureOptions.decode(o.encoded()) == o)
        #expect(CaptureOptions.decode(nil) == CaptureOptions())
        #expect(CaptureOptions.decode(Data("nope".utf8)) == CaptureOptions())
    }
    /// F4 fix: the helper replies "not understood" to options it cannot read, instead of silently
    /// recording with defaults the app did not ask for.
    @Test func strictDecodeRejectsWhatItCannotRead() {
        let o = CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 300, debugDropTapFrames: true)
        #expect(CaptureOptions.decodeStrict(o.encoded()) == o)
        #expect(CaptureOptions.decodeStrict(Data("nope".utf8)) == nil)
        #expect(CaptureOptions.decodeStrict(Data()) == nil)
        #expect(CaptureOptions.decodeStrict(Data(#"{"tapAutoStart":false}"#.utf8)) == nil, "a partial payload is not understood either")
    }
}
