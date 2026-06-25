import Testing
import Foundation
@testable import TranscriberCore

struct XPCRetryPolicyTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func firstCrashCountsOne() {
        let d = XPCRetryPolicy.register(priorCount: 0, lastCrashAt: nil, now: t0)
        #expect(d.retryCount == 1)
        #expect(d.shouldGiveUp == false)
    }

    @Test func secondCloseCrashEscalates() {
        let d = XPCRetryPolicy.register(priorCount: 1, lastCrashAt: t0.addingTimeInterval(-60), now: t0)
        #expect(d.retryCount == 2)
        #expect(d.shouldGiveUp == false)
    }

    @Test func thirdCloseCrashGivesUp() {
        let d = XPCRetryPolicy.register(priorCount: 2, lastCrashAt: t0.addingTimeInterval(-60), now: t0)
        #expect(d.retryCount == 3)
        #expect(d.shouldGiveUp == true)
    }

    @Test func wellSeparatedCrashDecaysToOne() {
        let d = XPCRetryPolicy.register(priorCount: 2, lastCrashAt: t0.addingTimeInterval(-700), now: t0)
        #expect(d.retryCount == 1)
        #expect(d.shouldGiveUp == false)
    }

    @Test func decayBoundaryIsExclusive() {
        // Exactly the decay interval → NOT decayed (streak continues, trips the cap).
        let atBoundary = XPCRetryPolicy.register(priorCount: 2, lastCrashAt: t0.addingTimeInterval(-600), now: t0)
        #expect(atBoundary.retryCount == 3)
        #expect(atBoundary.shouldGiveUp == true)
        // One second past → decayed (fresh streak).
        let pastBoundary = XPCRetryPolicy.register(priorCount: 2, lastCrashAt: t0.addingTimeInterval(-601), now: t0)
        #expect(pastBoundary.retryCount == 1)
        #expect(pastBoundary.shouldGiveUp == false)
    }

    @Test func nilLastCrashNeverDecays() {
        let d = XPCRetryPolicy.register(priorCount: 2, lastCrashAt: nil, now: t0)
        #expect(d.retryCount == 3)
        #expect(d.shouldGiveUp == true)
    }

    @Test func longHealthySessionNeverGivesUp() {
        // 10 interruptions an hour apart, every one individually recovered.
        var count = 0
        var last: Date?
        var now = t0
        for _ in 0..<10 {
            let d = XPCRetryPolicy.register(priorCount: count, lastCrashAt: last, now: now)
            #expect(d.shouldGiveUp == false)
            count = d.retryCount
            last = now
            now = now.addingTimeInterval(3600)
        }
    }

    @Test func tightLoopGivesUpOnThird() {
        var count = 0
        var last: Date?
        var now = t0
        var gaveUpAt: Int?
        for i in 1...5 {
            let d = XPCRetryPolicy.register(priorCount: count, lastCrashAt: last, now: now)
            if d.shouldGiveUp { gaveUpAt = i; break }
            count = d.retryCount
            last = now
            now = now.addingTimeInterval(0.05)  // 50 ms apart — a crash loop
        }
        #expect(gaveUpAt == 3)
    }
}
