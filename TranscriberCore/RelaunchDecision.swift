import Foundation

/// What to do with a recording sentinel at launch (§8.3, §8.9). Pure; the coordinator supplies the
/// facts and applies the decision.
public enum RelaunchDecision: Equatable, Sendable {
    case reattach
    case resumeSameSession(gapStart: Date)
    case salvageAndStop(reason: Reason)
    case salvageStale
    case waitForFolder

    public enum Reason: Equatable, Sendable {
        case tooOld(seconds: TimeInterval)
        case noLiveness
        /// The sentinel was marked `stopping` before post-Stop finalize (L7) began. This wins over
        /// `helperCapturing` (a stop-in-flight race never resumes) — the coordinator (L7) is
        /// responsible for stopping the helper itself; this decision only ever says "don't
        /// reattach, don't resume". It does NOT win over `folderReachable`: an unreachable folder
        /// (e.g. an unmounted external drive) still waits rather than salvaging, even mid-stop —
        /// see `decide`. (Fix round 1, item 7; corrected by fix round 2, item 4 — a regression.)
        case wasStopping
    }

    /// The sentinel's `lastAliveAt` is refreshed every 60 s and at every rotation; a relaunch
    /// strictly within this window (§8.3: "< 180 s") resumes the SAME session (the gap is
    /// recorded) — the boundary itself, and anything older, salvages and says STOPPED.
    public static let resumeWindow: TimeInterval = 180

    /// A Stop was asked for and its stopping mark never landed (L review 236): `stopRequestedAt` — kept apart from the
    /// sentinel — no earlier than the recording was last known alive means nothing recorded since. That recording is
    /// stopping: never resumed, never re-attached.
    public static func stopWasRequested(lastAliveAt: Date?, stopRequestedAt: Date?) -> Bool {
        guard let stopRequestedAt else { return false }
        return stopRequestedAt >= (lastAliveAt ?? .distantPast)
    }

    public static func decide(lastAliveAt: Date?, bootSessionUUID: String?, wasStopping: Bool, now: Date,
                              helperCapturing: Bool, currentBootSessionUUID: String?, folderReachable: Bool,
                              stopRequestedAt: Date? = nil) -> RelaunchDecision {
        // `wasStopping` is checked first, ahead of `helperCapturing` (fix round 1, item 7) — but
        // NOT ahead of `folderReachable`: salvaging off a folder we can't reach (e.g. an unmounted
        // external drive) would delete the sentinel out from under data we can't currently see,
        // breaking "never deletes". An unreachable folder still waits, even mid-stop. (Fix round 2,
        // item 4 — a regression introduced by round 1's fix.) A Stop kept apart counts as the mark (L review 236).
        let wasStopping = wasStopping || stopWasRequested(lastAliveAt: lastAliveAt, stopRequestedAt: stopRequestedAt)
        if wasStopping { return folderReachable ? .salvageAndStop(reason: .wasStopping) : .waitForFolder }
        if helperCapturing { return .reattach }
        if !folderReachable { return .waitForFolder }
        if let recorded = bootSessionUUID, let current = currentBootSessionUUID, recorded != current { return .salvageStale }
        guard let lastAliveAt else { return .salvageAndStop(reason: .noLiveness) }
        let age = now.timeIntervalSince(lastAliveAt)
        // A negative age means the wall clock moved backwards after `lastAliveAt` was written —
        // exactly as untrustworthy as having no liveness timestamp at all. (Fix round 1, item 9.)
        if age < 0 { return .salvageAndStop(reason: .noLiveness) }
        if age < resumeWindow { return .resumeSameSession(gapStart: lastAliveAt) }
        return .salvageAndStop(reason: .tooOld(seconds: age))
    }
}
