import Testing
import Foundation
@testable import TranscriberCore

struct CrashReportScannerTests {
    let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let tokens = ["audio-capture-helper", "parley", "jetsamevent"]

    @Test func freshHelperReportIsLikelyCrash() {
        let reports = [(name: "audio-capture-helper-xpc-2026-06-25-112444.ips", modified: now.addingTimeInterval(-10))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .likelyCrash)
    }

    @Test func staleReportIsBenign() {
        let reports = [(name: "audio-capture-helper-xpc.ips", modified: now.addingTimeInterval(-3600))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .transientBlip)
    }

    @Test func noReportsIsBenign() {
        #expect(CrashReportScanner.classify(reports: [], processTokens: tokens, now: now, window: 90) == .transientBlip)
    }

    @Test func unrelatedProcessIsBenign() {
        let reports = [(name: "Safari-2026-06-25-112444.ips", modified: now.addingTimeInterval(-1))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .transientBlip)
    }

    @Test func jetsamEventIsLikelyCrash() {
        let reports = [(name: "JetsamEvent-2026-06-25-112444.ips", modified: now.addingTimeInterval(-5))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .likelyCrash)
    }

    @Test func tokenMatchIsCaseInsensitive() {
        let reports = [(name: "Audio-Capture-Helper-XPC.ips", modified: now.addingTimeInterval(-5))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .likelyCrash)
    }

    @Test func futureTimestampDoesNotMatch() {
        // A report dated after `now` (clock skew) must not be treated as a crash.
        let reports = [(name: "audio-capture-helper.ips", modified: now.addingTimeInterval(120))]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .transientBlip)
    }

    @Test func picksMatchAmongMixedReports() {
        let reports = [
            (name: "Safari.ips", modified: now.addingTimeInterval(-2)),
            (name: "parley-2026-06-25.ips", modified: now.addingTimeInterval(-2)),
        ]
        #expect(CrashReportScanner.classify(reports: reports, processTokens: tokens, now: now, window: 90) == .likelyCrash)
    }
}
