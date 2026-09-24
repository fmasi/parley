import Foundation

/// The tap's healing ladder (§5). Pure: fed triggers, rung results and heartbeat timing; answers
/// with the one thing to do next. The helper's `TapHealer` runs the rungs and the timers.
///
/// Every `.run` carries a token; `SystemTapSession.rebuild(rung:token:reason:)` echoes it back in
/// `onRebuildResult`, so a rebuild the ladder did not order (output-device change, rate drift —
/// token 0) can never be mistaken for a rung's result. Those still count against the budget through
/// `noteExternalRebuild`.
public struct TapRecoveryLadder: Equatable, Sendable {
    public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }

    public enum Trigger: Equatable, Sendable {
        case stalled, neverDelivered, listenerStopped, wake, rebuildFailed
        case serviceRestarted, permissionGrant, permissionInsurance
    }

    public enum Action: Equatable, Sendable {
        case none
        case run(Rung, token: Int, afterSeconds: Double)
        case awaitHeartbeat(seconds: Double)
        case giveUp(retryAfterSeconds: Double)
    }

    public static let backoff: [Double] = [0.25, 0.5, 1, 2]
    public static let fastWindowSeconds: Double = 15
    public static let heartbeatDeadlineSeconds: Double = 3
    public static let slowRetrySeconds: Double = 60
    public static let rungBudget = 2

    private var episodeStartedAt: Double?
    /// Attempts per rung this episode: ladder runs AND external rebuilds (the budget).
    private var attempts: [Rung: Int] = [:]
    /// Ladder runs this episode (the backoff index).
    private var ladderRuns = 0
    private var nextToken = 1
    public private(set) var inFlight: Rung?
    public private(set) var inFlightToken: Int?
    public private(set) var awaitingHeartbeat = false
    public private(set) var exhausted = false
    public private(set) var totalRebuilds = 0

    public init() {}

    public mutating func trigger(_ t: Trigger, now: Double) -> Action {
        switch t {
        case .serviceRestarted:
            reset()
            episodeStartedAt = now
            return start(.rebuildTap, delay: 0)
        case .permissionGrant:
            if inFlight != nil { return .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            awaitingHeartbeat = false
            return start(.rebuildAggregate, delay: 0)
        case .permissionInsurance:
            guard inFlight == nil, !awaitingHeartbeat, !exhausted, episodeStartedAt == nil else { return .none }
            episodeStartedAt = now
            return start(.rebuildAggregate, delay: 0)
        case .stalled, .neverDelivered, .listenerStopped, .wake, .rebuildFailed:
            if inFlight != nil || awaitingHeartbeat { return .none }
            if exhausted { return t == .rebuildFailed ? .giveUp(retryAfterSeconds: Self.slowRetrySeconds) : .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            return nextRung(now: now)
        }
    }

    /// The result of the rung the ladder ordered with `token`. Any other token (a stale rung from
    /// before a reset, or 0 for a rebuild the ladder did not order) completes nothing.
    public mutating func rungCompleted(token: Int, succeeded: Bool, now: Double) -> Action {
        guard inFlightToken == token else { return .none }
        inFlight = nil
        inFlightToken = nil
        if succeeded {
            awaitingHeartbeat = true
            return .awaitHeartbeat(seconds: Self.heartbeatDeadlineSeconds)
        }
        return trigger(.rebuildFailed, now: now)
    }

    /// A rebuild the ladder did not order finished (output-device change, rate drift, permission
    /// grant from the app). It reports into the same budget (§5) but never completes a rung.
    public mutating func noteExternalRebuild(now: Double) -> Action {
        totalRebuilds += 1
        if episodeStartedAt != nil { attempts[.rebuildAggregate, default: 0] += 1 }
        return .none
    }

    public mutating func heartbeatObserved() -> Action {
        reset()
        return .none
    }

    public mutating func heartbeatDeadlineMissed(now: Double) -> Action {
        guard awaitingHeartbeat else { return .none }
        awaitingHeartbeat = false
        return nextRung(now: now)
    }

    /// One tap rebuild on an exhausted ladder, outside the fast budget. Nothing while a rung is in
    /// flight or its heartbeat is still pending (a grant rung, or the previous slow retry): that
    /// rung's deadline decides, and its miss hands back the next slow retry.
    public mutating func slowRetryDue(now: Double) -> Action {
        guard exhausted, inFlight == nil, !awaitingHeartbeat else { return .none }
        return .run(.rebuildTap, token: launch(.rebuildTap), afterSeconds: 0)
    }

    /// The track is no longer expected (§4.3): the episode ends. An exhausted ladder is
    /// un-exhausted so a still-dead tap gets a fresh fast episode when the gate reopens (scan C10).
    public mutating func gateClosed() -> Action {
        reset()
        return .none
    }

    private mutating func nextRung(now: Double) -> Action {
        if ladderRuns > 0, now - (episodeStartedAt ?? now) > Self.fastWindowSeconds { return giveUp() }
        let rung: Rung
        if (attempts[.rebuildAggregate] ?? 0) < Self.rungBudget { rung = .rebuildAggregate }
        else if (attempts[.rebuildTap] ?? 0) < Self.rungBudget { rung = .rebuildTap }
        else { return giveUp() }
        let delay = ladderRuns == 0 ? 0 : Self.backoff[min(ladderRuns - 1, Self.backoff.count - 1)]
        return start(rung, delay: delay)
    }

    /// A budgeted ladder run.
    private mutating func start(_ rung: Rung, delay: Double) -> Action {
        attempts[rung, default: 0] += 1
        ladderRuns += 1
        return .run(rung, token: launch(rung), afterSeconds: delay)
    }

    /// Put `rung` in flight under a fresh token. Tokens are never reused, not even across episodes,
    /// so a result from before a reset can never complete a later rung.
    private mutating func launch(_ rung: Rung) -> Int {
        let token = nextToken
        nextToken += 1
        inFlight = rung
        inFlightToken = token
        totalRebuilds += 1
        return token
    }

    private mutating func giveUp() -> Action {
        inFlight = nil
        inFlightToken = nil
        awaitingHeartbeat = false
        exhausted = true
        return .giveUp(retryAfterSeconds: Self.slowRetrySeconds)
    }

    private mutating func reset() {
        episodeStartedAt = nil
        attempts = [:]
        ladderRuns = 0
        inFlight = nil
        inFlightToken = nil
        awaitingHeartbeat = false
        exhausted = false
    }
}
