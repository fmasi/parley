import Foundation
import Testing
@testable import TranscriberCore

/// L15 (§8.12): chunk start times come from the monotonic clock anchored once to the wall clock,
/// so an NTP step mid-recording cannot shift the transcript's timeline.
@Suite struct MonotonicWallClockTests {
    @Test func advancesWithTheMonotonicClockNotTheWallClock() {
        let t = ContinuousClock.now
        let c = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: t)
        #expect(c.now(monotonic: t.advanced(by: .seconds(60))) == Date(timeIntervalSince1970: 60))
        #expect(c.now(monotonic: t.advanced(by: .milliseconds(1500))).timeIntervalSince1970 == 1.5)
    }
    @Test func startAnchorsToTheGivenWallTime() {
        let wall = Date(timeIntervalSince1970: 1_000)
        let c = MonotonicWallClock.start(now: wall)
        let later = c.now()
        #expect(later >= wall && later.timeIntervalSince(wall) < 5)
    }
}
