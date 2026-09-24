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
        /// every other input, including a helper that still reports `helperCapturing` (a
        /// stop-in-flight race) — the coordinator (L7) is responsible for stopping the helper
        /// itself; this decision only ever says "don't reattach, don't resume". (Fix round 1, item 7.)
        case wasStopping
    }

    /// The sentinel's `lastAliveAt` is refreshed every 60 s and at every rotation; a relaunch
    /// strictly within this window (§8.3: "< 180 s") resumes the SAME session (the gap is
    /// recorded) — the boundary itself, and anything older, salvages and says STOPPED.
    public static let resumeWindow: TimeInterval = 180

    public static func decide(lastAliveAt: Date?, bootSessionUUID: String?, wasStopping: Bool, now: Date,
                              helperCapturing: Bool, currentBootSessionUUID: String?, folderReachable: Bool) -> RelaunchDecision {
        // `wasStopping` is checked first, ahead of everything else including `helperCapturing`:
        // see `Reason.wasStopping` above (fix round 1, item 7).
        if wasStopping { return .salvageAndStop(reason: .wasStopping) }
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
