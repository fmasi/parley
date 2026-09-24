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
