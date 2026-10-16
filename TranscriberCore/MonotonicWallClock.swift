import Foundation

/// Wall-clock time derived from the monotonic clock: anchored once, then advanced by
/// `ContinuousClock` elapsed time (§8.12). Display uses the wall clock; timelines use this.
public struct MonotonicWallClock: Sendable {
    public let anchorWall: Date
    public let anchorMonotonic: ContinuousClock.Instant

    public init(anchorWall: Date, anchorMonotonic: ContinuousClock.Instant) {
        self.anchorWall = anchorWall
        self.anchorMonotonic = anchorMonotonic
    }

    public static func start(now: Date = Date()) -> MonotonicWallClock {
        MonotonicWallClock(anchorWall: now, anchorMonotonic: .now)
    }

    public func now(monotonic: ContinuousClock.Instant = .now) -> Date {
        let d = anchorMonotonic.duration(to: monotonic).components
        return anchorWall.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }
}
