import Foundation
import os

/// Where `TapHealer` runs: one serial context, a monotonic clock, and cancellable delayed work. The
/// helper uses `DispatchHealerScheduler`; the tests drive a manual one with virtual time.
public protocol HealerScheduler: AnyObject {
    /// Seconds on a monotonic clock.
    var now: Double { get }
    /// Run `work` in the scheduler's serial context.
    func async(_ work: @escaping () -> Void)
    /// Run `work` in the serial context after `seconds`, unless the returned timer is cancelled first.
    func after(_ seconds: Double, _ work: @escaping () -> Void) -> HealerTimer
}

public protocol HealerTimer: AnyObject {
    func cancel()
}

/// What the healer rebuilds: `SystemTapSession` in the helper. The result comes back through
/// `TapHealer.rebuildResult(rung:token:succeeded:)` with the same token.
public protocol TapRebuilding: AnyObject {
    func rebuild(rung: TapRecoveryLadder.Rung, token: Int, reason: String)
}

/// The production scheduler: one serial `DispatchQueue`, uptime-based clock.
public final class DispatchHealerScheduler: HealerScheduler {
    private let queue: DispatchQueue
    private let epoch = DispatchTime.now().uptimeNanoseconds

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public var now: Double { Double(DispatchTime.now().uptimeNanoseconds - epoch) / 1e9 }

    public func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    public func after(_ seconds: Double, _ work: @escaping () -> Void) -> HealerTimer {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

extension DispatchWorkItem: HealerTimer {}

/// Runs `TapRecoveryLadder`'s actions (§5): dispatches rungs to the tap with their token, arms the
/// heartbeat deadline, the stuck watchdog and the slow retry. Every entry point hops onto the
/// scheduler's serial context; no decisions of its own beyond the timers.
///
/// ONE timer of each kind (pending rung, heartbeat deadline, stuck watchdog, slow retry): a new one
/// replaces the previous one, never stacked (C4 note). `endSession()` (stop) and `cancelAll()` (sleep)
/// forget the ladder and SUSPEND the healer: no rung runs and no callback fires — so nothing from a
/// stopped session can raise an alarm into the next one, and no rung runs while the machine sleeps
/// with the monitors paused (H review round 1). A stopped healer resumes only at `startSession(tap:)`.
/// A sleeping one resumes at `trigger(.wake)`, or at the first liveness verdict: monitors are paused
/// during sleep and only armed monitors give verdicts, so a verdict proves the machine is awake and
/// the wake message was lost — dropping it would silence the tap for the rest of the session (round 2).
/// A coreaudiod restart or a permission grant that arrives while asleep — or a grant still waiting on a
/// rung in flight when sleep came (#235) — is kept and runs at the wake (H2 council, B-M1): dropped, it left the tap's objects and listeners dead until a liveness episode
/// escalated to a tap rung.
public final class TapHealer {
    public static let stuckSeconds: Double = 5

    private let scheduler: HealerScheduler
    private var ladder = TapRecoveryLadder()
    /// No session yet, stopped, or asleep.
    private var suspended = true
    private weak var tap: TapRebuilding?
    private var pendingRun: HealerTimer?
    private var heartbeatDeadline: HealerTimer?
    private var stuckWatchdog: HealerTimer?
    /// The token the stuck watchdog guards: a result for any OTHER token must not cancel it (C4 note).
    private var stuckToken: Int?
    private var slowRetry: HealerTimer?
    /// A rebuild threw since the tap last delivered: a give-up then also means "could not restart".
    private var rebuildFailedSinceHeartbeat = false
    /// A `.serviceRestarted` / `.permissionGrant` that arrived while asleep, or a grant still parked in
    /// the ladder when sleep came: run at the wake. A restart wins over a grant (its new tap starts with
    /// the new permission). Forgotten by a stop or a new session.
    private var pendingWhileAsleep: TapRecoveryLadder.Trigger?

    public var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?
    /// The ladder gave up (fast budget exhausted, or a rung failed on an exhausted ladder). `rebuildFailed`:
    /// a rebuild threw since the tap last delivered. An intermediate failed rung never calls this:
    /// heal first, then alarm (H review round 1).
    public var onGiveUp: ((_ rebuildFailed: Bool) -> Void)?
    /// A heartbeat arrived while the ladder was healing (or had given up).
    public var onRecovered: (() -> Void)?
    /// A rung has not returned within `stuckSeconds`.
    public var onStuck: (() -> Void)?
    /// A rebuild (ladder-ordered or external) succeeded.
    public var onRungSucceeded: (() -> Void)?
    /// Whether the track is expected now: the helper's last gate reading (lock-only). Read on the serial
    /// context at a rung's heartbeat deadline, the one judgement the monitor's gate verdicts do not reach
    /// (final review H-I1).
    public var gateOpen: () -> Bool = { true }

    public init(scheduler: HealerScheduler) {
        self.scheduler = scheduler
    }

    /// The alarms a give-up raises (§6.1), in order. `remoteNotDelivering` says the other side isn't
    /// reaching Parley "although audio is playing", and clears only on a heartbeat or a gate verdict. So a
    /// give-up from rebuilds that THREW while nothing plays (an `srst` at pre-call idle) raises only
    /// `remoteRecoveryFailed` — true, and cleared by the next rebuild that works; not-delivering waits for a
    /// give-up with audio playing (final review HF-9). A give-up with nothing thrown always says
    /// not-delivering, whatever the gate: never silent.
    public static func giveUpAlarms(rebuildFailed: Bool, gateOpen: Bool) -> [AlarmKind] {
        guard rebuildFailed else { return [.remoteNotDelivering] }
        return gateOpen ? [.remoteNotDelivering, .remoteRecoveryFailed] : [.remoteRecoveryFailed]
    }

    /// A new tap session: forget whatever the previous one left, then target `tap` — in ONE step on
    /// the serial context, so a rung scheduled for the old session can never rebuild the new tap.
    public func startSession(tap: TapRebuilding) {
        scheduler.async {
            self.reset()
            self.pendingWhileAsleep = nil
            self.tap = tap
            self.suspended = false
        }
    }

    /// `.wake` is the pair of `cancelAll()` (sleep): the ladder forgets its episode, the healer
    /// resumes (if a session is running), and the re-armed monitor is the heartbeat check (C4 ruling 3).
    /// Every other trigger runs the ladder as is; a liveness verdict while asleep wakes it first.
    public func trigger(_ t: TapRecoveryLadder.Trigger) {
        scheduler.async {
            if t == .wake {
                self.wake()
                return
            }
            if t == .stalled || t == .neverDelivered { self.wakeIfAsleep(on: "\(t)") }
            guard !self.suspended else {
                self.keepForTheWake(t)
                return
            }
            self.apply(self.ladder.trigger(t, now: self.scheduler.now))
        }
    }

    /// The system monitor's `.firstFrames` AND `.cleared(.heartbeat)`. Ends the silence, not the
    /// episode: the ladder refunds its budget only after 30 s of sustained health (C4 round 1).
    public func heartbeatObserved() {
        scheduler.async {
            self.wakeIfAsleep(on: "heartbeat")
            guard !self.suspended else { return }
            let wasHealing = self.ladder.inFlight != nil || self.ladder.awaitingHeartbeat || self.ladder.exhausted
            self.cancel(&self.pendingRun)
            self.cancel(&self.heartbeatDeadline)
            self.cancel(&self.slowRetry)
            self.rebuildFailedSinceHeartbeat = false
            _ = self.ladder.heartbeatObserved(now: self.scheduler.now)
            if wasHealing { self.onRecovered?() }
        }
    }

    /// The track is no longer expected: the ladder ends (or remembers) the episode; the slow retry stops (§5).
    /// Not a wake signal: a paused monitor still delivers the `.cleared(.gateClosed)` it owes.
    public func gateClosed() {
        scheduler.async {
            guard !self.suspended else { return }
            self.cancel(&self.pendingRun)
            self.cancel(&self.heartbeatDeadline)
            self.cancel(&self.slowRetry)
            self.rebuildFailedSinceHeartbeat = false
            _ = self.ladder.gateClosed()
        }
    }

    public func rebuildResult(rung: TapRecoveryLadder.Rung, token: Int, succeeded: Bool) {
        scheduler.async {
            guard !self.suspended else { return }
            if succeeded {
                // Any rebuild that worked: a later give-up means "not delivering", not "could not
                // restart" (round 2: a successful slow retry no longer leaves a stale flag behind).
                self.rebuildFailedSinceHeartbeat = false
                self.onRungSucceeded?()
            } else if token == 0 || self.ladder.inFlightToken == token {
                // Only the rung in flight (or an external rebuild) is this episode's failure.
                self.rebuildFailedSinceHeartbeat = true
            }
            if token == 0 {
                self.apply(self.ladder.noteExternalRebuild(now: self.scheduler.now))
                return
            }
            // Only the guarded rung's own result cancels its watchdog; a stale result leaves the
            // current rung's watchdog running (C4 note).
            if self.stuckToken == token {
                self.cancel(&self.stuckWatchdog)
                self.stuckToken = nil
            }
            self.apply(self.ladder.rungCompleted(token: token, succeeded: succeeded, now: self.scheduler.now))
        }
    }

    /// Sleep: every timer goes, the ladder forgets its episode (so no token in flight or awaited
    /// survives), and the healer is suspended until `trigger(.wake)` or the next liveness verdict.
    /// A grant the ladder had parked behind a rung in flight is kept for the wake as one that arrived
    /// while asleep (#235): the reset forgets it, and nothing else would rebuild the tap for it.
    public func cancelAll() {
        scheduler.async {
            if self.ladder.grantPending { self.keepForTheWake(.permissionGrant) }
            self.reset()
            self.suspended = true
        }
    }

    /// Stop: as `cancelAll()`, and the tap is forgotten, so nothing but `startSession(tap:)` resumes
    /// the healer — not even a verdict still in flight from the stopped session.
    public func endSession() {
        scheduler.async {
            self.reset()
            self.pendingWhileAsleep = nil
            self.suspended = true
            self.tap = nil
        }
    }

    private func wake() {
        reset()
        suspended = tap == nil
        guard !suspended, let pending = pendingWhileAsleep else { return }
        pendingWhileAsleep = nil
        Logger.audio.info("Tap healer: running the \("\(pending)", privacy: .public) that arrived while asleep")
        apply(ladder.trigger(pending, now: scheduler.now))
    }

    /// Asleep with a session running: a restart or a grant can't wait for a liveness verdict (the tap
    /// may deliver zeros with a healthy heartbeat, and after `srst` its listeners are dead) — keep it.
    private func keepForTheWake(_ t: TapRecoveryLadder.Trigger) {
        guard tap != nil, t == .serviceRestarted || t == .permissionGrant else { return }
        if pendingWhileAsleep != .serviceRestarted { pendingWhileAsleep = t }
    }

    /// Asleep with a session running, and a verdict arrived: the wake was missed. Resume first.
    private func wakeIfAsleep(on verdict: String) {
        guard suspended, tap != nil else { return }
        Logger.audio.info("Tap healer: liveness verdict (\(verdict, privacy: .public)) while asleep — the wake was missed; resuming")
        wake()
    }

    private func reset() {
        cancel(&pendingRun)
        cancel(&heartbeatDeadline)
        cancel(&stuckWatchdog)
        stuckToken = nil
        cancel(&slowRetry)
        rebuildFailedSinceHeartbeat = false
        // `.wake` is the ladder's reset: the episode, its budget and the dead-gate memory go; tokens
        // stay monotonic, so a late result from before the reset completes nothing.
        _ = ladder.trigger(.wake, now: scheduler.now)
    }

    private func cancel(_ timer: inout HealerTimer?) {
        timer?.cancel()
        timer = nil
    }

    private func apply(_ action: TapRecoveryLadder.Action) {
        switch action {
        case .none:
            break
        case .run(let rung, let token, let delay):
            cancel(&pendingRun)
            pendingRun = scheduler.after(delay) { [weak self] in
                guard let self else { return }
                self.pendingRun = nil
                // The ladder may have been reset during the backoff (heartbeat, gate close, srst,
                // wake): a rung whose token is no longer in flight must not run (C4 note).
                guard !self.suspended, self.ladder.inFlightToken == token else { return }
                // Recorded when it runs, not when it was scheduled: a cancelled rung is no rebuild. `trigger`: what ordered
                // it (#317) — without it, the permission guard's insurance rebuild read as an unexplained rung.
                self.onEvent?(.tapRecoveryRung, .warning, [
                    "rung": rung.rawValue, "token": "\(token)", "delay": "\(delay)", "total": "\(self.ladder.totalRebuilds)",
                    "trigger": self.ladder.inFlightCause?.recordValue ?? "unknown",
                ])
                self.cancel(&self.stuckWatchdog)
                self.stuckToken = token
                self.stuckWatchdog = self.scheduler.after(Self.stuckSeconds) { [weak self] in
                    guard let self, !self.suspended, self.stuckToken == token else { return }
                    self.stuckWatchdog = nil
                    self.stuckToken = nil
                    self.onEvent?(.recoveryStuck, .anomaly, ["rung": rung.rawValue, "token": "\(token)"])
                    self.onStuck?()
                }
                self.tap?.rebuild(rung: rung, token: token, reason: "healing ladder")
            }
        case .awaitHeartbeat(let seconds, let token):
            cancel(&heartbeatDeadline)
            heartbeatDeadline = scheduler.after(seconds) { [weak self] in
                guard let self, !self.suspended else { return }
                self.heartbeatDeadline = nil
                // Nothing expected at the deadline: the ladder ends the episode as at a gate close, and the
                // healer drops that episode's work as `gateClosed()` does (final review H-I1) — only for the
                // awaited rung's own deadline: a stale one ends nothing, so it must cancel nothing either.
                let open = self.gateOpen()
                if !open, self.ladder.awaitedToken == token {
                    self.cancel(&self.pendingRun)
                    self.cancel(&self.slowRetry)
                    self.rebuildFailedSinceHeartbeat = false
                }
                self.apply(self.ladder.heartbeatDeadlineMissed(token: token, now: self.scheduler.now, gateOpen: open))
            }
        case .giveUp(let retryAfter):
            onEvent?(.tapRecoveryGivenUp, .anomaly, ["rebuilds": "\(ladder.totalRebuilds)"])
            onGiveUp?(rebuildFailedSinceHeartbeat)
            // Already exhausted with a slow retry pending (a grant rung failed on an exhausted
            // ladder): keep that timer, don't push the retry back (C4 note).
            guard slowRetry == nil else { return }
            slowRetry = scheduler.after(retryAfter) { [weak self] in
                guard let self, !self.suspended else { return }
                self.slowRetry = nil
                self.apply(self.ladder.slowRetryDue(now: self.scheduler.now))
            }
        }
    }
}
