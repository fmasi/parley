import Testing
@testable import TranscriberCore

struct SystemFormatTrackerTests {
    let f48m = AudioStreamFormat(sampleRate: 48000, channelCount: 1, isFloat: true, bitsPerChannel: 32)
    let f16m = AudioStreamFormat(sampleRate: 16000, channelCount: 1, isFloat: true, bitsPerChannel: 32)
    let f48s = AudioStreamFormat(sampleRate: 48000, channelCount: 2, isFloat: true, bitsPerChannel: 32)

    @Test func firstObservationReportsFirst() {
        let t = SystemFormatTracker()
        #expect(t.observe(f48m) == .first(f48m))
        #expect(t.current == f48m)
    }

    @Test func sameFormatIsUnchanged() {
        let t = SystemFormatTracker()
        _ = t.observe(f48m)
        #expect(t.observe(f48m) == .unchanged)
    }

    @Test func sampleRateChangeIsReported() {
        let t = SystemFormatTracker()
        _ = t.observe(f48m)
        #expect(t.observe(f16m) == .changed(from: f48m, to: f16m))
        #expect(t.current == f16m)
    }

    @Test func channelCountChangeIsReported() {
        let t = SystemFormatTracker()
        _ = t.observe(f48m)
        #expect(t.observe(f48s) == .changed(from: f48m, to: f48s))
    }

    @Test func floatFlagDifferenceIsIgnored() {
        // Storage flag changes do not require a writer rotation (samples normalize to Int16).
        let t = SystemFormatTracker()
        let intSameDims = AudioStreamFormat(sampleRate: 48000, channelCount: 1, isFloat: false, bitsPerChannel: 16)
        _ = t.observe(f48m)
        #expect(t.observe(intSameDims) == .unchanged)
    }

    @Test func bitDepthDifferenceIsIgnored() {
        let t = SystemFormatTracker()
        let a = AudioStreamFormat(sampleRate: 48000, channelCount: 1, isFloat: false, bitsPerChannel: 16)
        let b = AudioStreamFormat(sampleRate: 48000, channelCount: 1, isFloat: false, bitsPerChannel: 32)
        _ = t.observe(a)
        #expect(t.observe(b) == .unchanged)
    }

    @Test func alternatingFormatsReportEachTransition() {
        let t = SystemFormatTracker()
        #expect(t.observe(f48m) == .first(f48m))
        #expect(t.observe(f16m) == .changed(from: f48m, to: f16m))
        #expect(t.observe(f16m) == .unchanged)
        #expect(t.observe(f48m) == .changed(from: f16m, to: f48m))
    }
}
