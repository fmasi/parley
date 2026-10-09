import Foundation

/// The tap's healing ladder (§5). Pure: fed triggers, rung results and heartbeat timing; answers
/// with the one thing to do next. The helper's `TapHealer` runs the rungs and the timers.
///
/// Every `.run` carries a token; `SystemTapSession.rebuild(rung:token:reason:)` echoes it back in
/// `onRebuildResult`, so a rebuild the ladder did not order (output-device change, rate drift —
/// token 0) can never be mistaken for a rung's result. Those still count against the budget through
/// `noteExternalRebuild`. `.awaitHeartbeat` carries the rung's token too, and the deadline is matched
/// on it, so a deadline timer left over from a replaced rung cannot cut a newer rung's window short.
///
/// Never loop forever, never give up silently (owner rules, fix round 1):
/// - A heartbeat ends the silence, not the episode. The budget comes back only after
///   `sustainedHealthSeconds` of health; a stall sooner continues the episode up the ladder.
/// - The gate closing over a tap that was still dead is remembered: the reopen gets one tap rung and
///   then re-alarms, instead of a fresh four-rung episode per gate blip.
public struct TapRecoveryLadder: Equatable, Sendable {
    public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }

    public enum Trigger: Equatable, Sendable {
        case stalled, neverDelivered, listenerStopped, wake, rebuildFailed
        case serviceRestarted, permissionGrant, permissionInsurance
    }

    /// Why a rung was ordered, for the record (#317): the trigger that started it, or the ladder's own next step
    /// after a rung's heartbeat window passed in silence, or the slow retry. `tapRecoveryRung` carries it as `trigger`.
    public enum Cause: Equatable, Sendable {
        case trigger(Trigger)
        case heartbeatMissed
        case slowRetry

        /// The `trigger` value in the record.
        public var recordValue: String {
            switch self {
            case .trigger(let t): return "\(t)"
            case .heartbeatMissed: return "heartbeatMissed"
            case .slowRetry: return "slowRetry"
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        case run(Rung, token: Int, afterSeconds: Double)
        case awaitHeartbeat(seconds: Double, token: Int)
        case giveUp(retryAfterSeconds: Double)
    }

    public static let backoff: [Double] = [0.25, 0.5, 1, 2]
    public static let fastWindowSeconds: Double = 15
    public static let heartbeatDeadlineSeconds: Double = 3
    public static let slowRetrySeconds: Double = 60
    public static let rungBudget = 2
    /// How long a heal must hold before the episode ends and its budget is refunded.
    public static let sustainedHealthSeconds: Double = 30

    /// What the next failure trigger does after the gate closed over a dead tap.
    private enum Reopen: Equatable, Sendable {
        /// Nothing remembered: the normal ladder.
        case fresh
        /// One immediate tap rung; its failure gives up.
        case lastChance
        /// The last chance's rung never got its verdict before the gate closed again: it failed.
        case giveUp
    }

    /// Start of the episode's current fast window (restarted when a healed episode goes silent
    /// again); `nil` = no episode.
    private var episodeStartedAt: Double?
    /// Attempts per rung this episode: ladder runs AND external rebuilds (the budget).
    private var attempts: [Rung: Int] = [:]
    /// Ladder runs this episode (the backoff index).
    private var ladderRuns = 0
    /// This episode is a reopen's last chance: its next failure gives up.
    private var lastChance = false
    /// When a heartbeat first ended the episode's current silence; `nil` = silent since the last trouble.
    private var healedAt: Double?
    private var onReopen: Reopen = .fresh
    /// A grant that arrived while a rung was in flight: it runs when that rung's result lands (final review
    /// H-I3). A gate close keeps it (the rung is forgotten, not the grant); `forgetEverything` does not,
    /// so `TapHealer` reads it before the reset at sleep and runs the grant at the wake (#235).
    public private(set) var grantPending = false
    /// The rung whose heartbeat the ladder is waiting for; `nil` = none.
    public private(set) var awaitedToken: Int?
    private var nextToken = 1
    public private(set) var inFlight: Rung?
    public private(set) var inFlightToken: Int?
    /// What ordered the rung in flight (#317); `nil` = nothing in flight.
    public private(set) var inFlightCause: Cause?
    /// The cause the next launched rung is recorded under: set by every entry point that can order one, before it does
    /// (`trigger`, `heartbeatDeadlineMissed`, `slowRetryDue`), so the initial value is never what a rung records.
    private var cause: Cause = .slowRetry
    public var awaitingHeartbeat: Bool { awaitedToken != nil }
    public private(set) var exhausted = false
    public private(set) var totalRebuilds = 0

    public init() {}

    public mutating func trigger(_ t: Trigger, now: Double) -> Action {
        cause = .trigger(t)
        switch t {
        case .wake:
            // §5, §8.8: wake is "re-arm + heartbeat check", and the re-armed liveness monitor IS the
            // check. The helper cancelled every timer on sleep, so whatever the ladder was waiting for
            // (a deadline, a slow retry) is gone: forget it rather than stay stuck. Never rebuild blind.
            forgetEverything()
            return .none
        case .serviceRestarted:
            forgetEverything()
            episodeStartedAt = now
            return start(.rebuildTap, delay: 0)
        case .permissionGrant:
            // The rung in flight may have built its aggregate before the grant (it then delivers zeros, and
            // the permission guard already counted the grant as answered): keep it for that rung's result.
            if inFlight != nil { grantPending = true; return .none }
            grantPending = false
            refundIfHealthHeld(now: now)
            if episodeStartedAt == nil { episodeStartedAt = now }
            awaitedToken = nil
            return start(.rebuildAggregate, delay: 0)
        case .permissionInsurance:
            refundIfHealthHeld(now: now)
            guard inFlight == nil, awaitedToken == nil, !exhausted, episodeStartedAt == nil, onReopen == .fresh else { return .none }
            episodeStartedAt = now
            return start(.rebuildAggregate, delay: 0)
        case .stalled, .neverDelivered, .listenerStopped, .rebuildFailed:
            if inFlight != nil || awaitedToken != nil { return .none }
            if onReopen != .fresh { return reopenOverADeadTap(now: now) }
            if exhausted { return t == .rebuildFailed ? .giveUp(retryAfterSeconds: Self.slowRetrySeconds) : .none }
            refundIfHealthHeld(now: now)
            // A new episode, or a healed one going silent again: either way a new fast window. A
            // continued episode keeps its budget and backoff position.
            if episodeStartedAt == nil || healedAt != nil { episodeStartedAt = now }
            healedAt = nil
            return nextRung(now: now)
        }
    }

    /// The result of the rung the ladder ordered with `token`. Any other token (a stale rung from
    /// before a reset, or 0 for a rebuild the ladder did not order) completes nothing — but a grant that
    /// waited for it runs now, if nothing else is in flight. A grant that waited for THIS rung runs
    /// whatever the rung's result: the rung may have built its aggregate before the grant.
    public mutating func rungCompleted(token: Int, succeeded: Bool, now: Double) -> Action {
        guard inFlightToken == token else {
            return grantPending && inFlight == nil ? trigger(.permissionGrant, now: now) : .none
        }
        inFlight = nil
        inFlightToken = nil
        inFlightCause = nil
        if grantPending { return trigger(.permissionGrant, now: now) }
        if succeeded {
            awaitedToken = token
            return .awaitHeartbeat(seconds: Self.heartbeatDeadlineSeconds, token: token)
        }
        return trigger(.rebuildFailed, now: now)
    }

    /// A rebuild the ladder did not order finished (output-device change, rate drift, permission
    /// grant from the app). It reports into the same budget (§5) but never completes a rung.
    public mutating func noteExternalRebuild(now: Double) -> Action {
        totalRebuilds += 1
        refundIfHealthHeld(now: now)
        if episodeStartedAt != nil { attempts[.rebuildAggregate, default: 0] += 1 }
        return .none
    }

    /// A heartbeat arrived (the monitor's `.firstFrames` or `.cleared(.heartbeat)`). It ends the
    /// silence, not the episode: nothing is in flight or awaited any more and the tap is not dead,
    /// but the budget comes back only once this health has held for `sustainedHealthSeconds`.
    public mutating func heartbeatObserved(now: Double) -> Action {
        cancelWork()
        exhausted = false
        onReopen = .fresh
        if episodeStartedAt != nil, healedAt == nil { healedAt = now }
        return .none
    }

    /// Rung `token`'s heartbeat window passed with no heartbeat. `gateOpen`: whether the track was expected
    /// at the deadline. With the gate closed nothing was expected, so the rung cannot be judged — not failed
    /// (final review H-I1): the episode ends as at a gate close, a tap still silent is remembered (the
    /// reopen gets one tap rung, then the alarm), and nothing climbs. A stale token is judged not at all.
    public mutating func heartbeatDeadlineMissed(token: Int, now: Double, gateOpen: Bool) -> Action {
        guard awaitedToken == token else { return .none }
        awaitedToken = nil
        guard gateOpen else { return gateClosed() }
        cause = .heartbeatMissed
        return nextRung(now: now)
    }

    /// One tap rebuild on an exhausted ladder, outside the fast budget. Nothing while a rung is in
    /// flight or its heartbeat is still pending (a grant rung, or the previous slow retry): that
    /// rung's deadline decides, and its miss hands back the next slow retry.
    public mutating func slowRetryDue(now: Double) -> Action {
        guard exhausted, inFlight == nil, awaitedToken == nil else { return .none }
        cause = .slowRetry
        return .run(.rebuildTap, token: launch(.rebuildTap), afterSeconds: 0)
    }

    /// The track is no longer expected (§4.3): nothing may run or wait, and the slow retry stops.
    /// An episode the tap had not healed from (silent or exhausted) is remembered as dead, so the
    /// reopen gets one tap rung instead of a fresh budget per gate blip (fix round 1, amending the
    /// scan-C10 reset). A healed episode keeps its budget until the heal has held.
    public mutating func gateClosed() -> Action {
        guard episodeStartedAt != nil, healedAt == nil else { return .none }
        // A last chance still in flight or awaiting its heartbeat never got its verdict: it failed.
        onReopen = lastChance && !exhausted ? .giveUp : .lastChance
        endEpisode()
        return .none
    }

    private mutating func reopenOverADeadTap(now: Double) -> Action {
        let plan = onReopen
        onReopen = .fresh
        episodeStartedAt = now
        lastChance = true
        return plan == .giveUp ? giveUp() : start(.rebuildTap, delay: 0)
    }

    private mutating func refundIfHealthHeld(now: Double) {
        if let healed = healedAt, now - healed >= Self.sustainedHealthSeconds { endEpisode() }
    }

    private mutating func nextRung(now: Double) -> Action {
        if lastChance { return giveUp() }
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
    /// so a result from before a reset can never complete a later rung. A rebuild is trouble again:
    /// any heal it follows is over, and it supersedes a remembered dead gate.
    private mutating func launch(_ rung: Rung) -> Int {
        let token = nextToken
        nextToken += 1
        inFlight = rung
        inFlightToken = token
        inFlightCause = cause
        healedAt = nil
        onReopen = .fresh
        totalRebuilds += 1
        return token
    }

    private mutating func giveUp() -> Action {
        cancelWork()
        exhausted = true
        return .giveUp(retryAfterSeconds: Self.slowRetrySeconds)
    }

    private mutating func cancelWork() {
        inFlight = nil
        inFlightToken = nil
        inFlightCause = nil
        awaitedToken = nil
    }

    /// End the episode: budget, window, heal clock, and whatever was in flight or awaited.
    private mutating func endEpisode() {
        episodeStartedAt = nil
        attempts = [:]
        ladderRuns = 0
        lastChance = false
        healedAt = nil
        cancelWork()
        exhausted = false
    }

    /// Wake, `srst`, a new session: a pending grant goes too. After `srst` or in a new session the next
    /// tap is built with the permission as it is now; a wake builds nothing, so `TapHealer` carries the
    /// grant across the sleep itself (#235).
    private mutating func forgetEverything() {
        endEpisode()
        onReopen = .fresh
        grantPending = false
    }
}
