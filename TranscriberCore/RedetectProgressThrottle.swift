import Foundation
import os

/// Which re-detect progress reports reach the rename dialog (#341). The diarizer reports after every
/// segmentation chunk — on an hour of audio, thousands of times — from its own threads, and each
/// report the dialog takes is a hop to the main actor. A phase change, the start or end of a fraction
/// and a fraction of 1 always pass; otherwise at most one report per `interval`, and never the same
/// report twice in a row. Pure: the clock is passed in.
public struct RedetectProgressThrottle: Sendable {
    /// Ten updates a second: smooth for a bar 50 points wide, nothing for the main actor.
    public static let interval: Duration = .milliseconds(100)

    private var last: (progress: TranscriptRediarizer.Progress, at: ContinuousClock.Instant)?

    public init() {}

    /// Whether `progress`, reported at `now`, goes through.
    public mutating func admit(_ progress: TranscriptRediarizer.Progress, at now: ContinuousClock.Instant) -> Bool {
        if let last {
            if progress == last.progress { return false }
            let always = progress.phase != last.progress.phase
                || (progress.fraction == nil) != (last.progress.fraction == nil)
                || progress.fraction == 1
            if !always, now - last.at < Self.interval { return false }
        }
        last = (progress, now)
        return true
    }

    /// A progress callback that passes on to `sink` only what the throttle admits. Callable from any
    /// thread; `sink` runs on the reporting thread, so it must hop to the main actor itself.
    public static func gate(
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        _ sink: @escaping @Sendable (TranscriptRediarizer.Progress) -> Void
    ) -> @Sendable (TranscriptRediarizer.Progress) -> Void {
        let state = OSAllocatedUnfairLock(initialState: RedetectProgressThrottle())
        return { progress in
            let now = clock()
            if state.withLock({ $0.admit(progress, at: now) }) { sink(progress) }
        }
    }
}
