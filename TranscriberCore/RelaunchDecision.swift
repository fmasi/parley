import Foundation

/// What to do with a recording sentinel at launch (§8.3, §8.9). Pure; the coordinator supplies the
/// facts and applies the decision.
public enum RelaunchDecision: Equatable, Sendable {
    case reattach
    case resumeSameSession(gapStart: Date)
    case salvageAndStop(reason: Reason)
    case salvageStale
    case waitForFolder

    public enum Reason: Equatable, Sendable { case tooOld(seconds: TimeInterval), noLiveness, wasStopping }

    /// The sentinel's `lastAliveAt` is refreshed every 60 s and at every rotation; a relaunch within
    /// this window resumes the SAME session (the gap is recorded), later ones salvage and say STOPPED.
    public static let resumeWindow: TimeInterval = 180

    public static func decide(lastAliveAt: Date?, bootSessionUUID: String?, wasStopping: Bool, now: Date,
                              helperCapturing: Bool, currentBootSessionUUID: String?, folderReachable: Bool) -> RelaunchDecision {
        if helperCapturing { return .reattach }
        if !folderReachable { return .waitForFolder }
        if let recorded = bootSessionUUID, let current = currentBootSessionUUID, recorded != current { return .salvageStale }
        if wasStopping { return .salvageAndStop(reason: .wasStopping) }
        guard let lastAliveAt else { return .salvageAndStop(reason: .noLiveness) }
        let age = now.timeIntervalSince(lastAliveAt)
        if age <= resumeWindow { return .resumeSameSession(gapStart: lastAliveAt) }
        return .salvageAndStop(reason: .tooOld(seconds: age))
    }
}
