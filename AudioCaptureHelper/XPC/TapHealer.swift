import Foundation
import os
import TranscriberCore

/// Runs `TapRecoveryLadder`'s actions: dispatches rungs to `SystemTapSession` with their token, arms
/// the heartbeat deadline, the stuck watchdog and the slow retry. Single serial queue; no decisions
/// of its own. ONE timer of each kind: a new deadline / slow retry / stuck watchdog replaces the
/// previous one (C4 note) — never stacked.
final class TapHealer {
    private let queue = DispatchQueue(label: "audio-capture.tap-healer")
    private var ladder = TapRecoveryLadder()
    private let epoch = DispatchTime.now().uptimeNanoseconds
    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - epoch) / 1e9 }
    private var heartbeatDeadline: DispatchWorkItem?
    private var stuckWatchdog: DispatchWorkItem?
    /// The token the stuck watchdog guards: a result for any OTHER token must not cancel it (C4 note).
    private var stuckToken: Int?
    private var slowRetry: DispatchWorkItem?
    static let stuckSeconds: Double = 5

    weak var tap: SystemTapSession?
    var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?
    var onGiveUp: (() -> Void)?
    var onRecovered: (() -> Void)?
    var onStuck: (() -> Void)?
    var onRungFailed: ((TapRecoveryLadder.Rung) -> Void)?
    var onRungSucceeded: (() -> Void)?
    var totalRebuilds: Int { queue.sync { ladder.totalRebuilds } }

    /// `.wake` is the pair of `cancelAll()` (sleep): the ladder forgets its episode and the re-armed
    /// monitor is the heartbeat check (C4 ruling 3). Every other trigger runs the ladder as is.
    func trigger(_ t: TapRecoveryLadder.Trigger) {
        queue.async {
            if t == .wake { self.cancelTimersLocked() }
            self.apply(self.ladder.trigger(t, now: self.now))
        }
    }

    /// The system monitor's `.firstFrames` AND `.cleared(.heartbeat)`. Ends the silence, not the
    /// episode: the ladder refunds its budget only after 30 s of sustained health (C4 round 1).
    func heartbeatObserved() {
        queue.async {
            let wasHealing = self.ladder.inFlight != nil || self.ladder.awaitingHeartbeat || self.ladder.exhausted
            self.heartbeatDeadline?.cancel(); self.heartbeatDeadline = nil
            self.slowRetry?.cancel(); self.slowRetry = nil
            _ = self.ladder.heartbeatObserved(now: self.now)
            if wasHealing { self.onRecovered?() }
        }
    }

    /// The track is no longer expected: the ladder ends (or remembers) the episode; the slow retry stops (§5).
    func gateClosed() {
        queue.async {
            self.heartbeatDeadline?.cancel(); self.heartbeatDeadline = nil
            self.slowRetry?.cancel(); self.slowRetry = nil
            _ = self.ladder.gateClosed()
        }
    }

    func rebuildResult(rung: TapRecoveryLadder.Rung, token: Int, succeeded: Bool) {
        queue.async {
            if succeeded { self.onRungSucceeded?() } else { self.onRungFailed?(rung) }
            if token == 0 {
                self.apply(self.ladder.noteExternalRebuild(now: self.now))
                return
            }
            // Only the guarded rung's own result cancels its watchdog; a stale result leaves the
            // current rung's watchdog running (C4 note).
            if self.stuckToken == token {
                self.stuckWatchdog?.cancel(); self.stuckWatchdog = nil; self.stuckToken = nil
            }
            self.apply(self.ladder.rungCompleted(token: token, succeeded: succeeded, now: self.now))
        }
    }

    /// Sleep: every timer goes. MUST be paired with `trigger(.wake)` on wake, or a ladder that was
    /// awaiting a deadline stays stuck forever (C4 note).
    func cancelAll() { queue.async { self.cancelTimersLocked() } }

    private func cancelTimersLocked() {
        heartbeatDeadline?.cancel(); heartbeatDeadline = nil
        stuckWatchdog?.cancel(); stuckWatchdog = nil; stuckToken = nil
        slowRetry?.cancel(); slowRetry = nil
    }

    private func apply(_ action: TapRecoveryLadder.Action) {
        switch action {
        case .none:
            break
        case .run(let rung, let token, let delay):
            onEvent?(.tapRecoveryRung, .warning, ["rung": rung.rawValue, "token": "\(token)", "delay": "\(delay)", "total": "\(ladder.totalRebuilds)"])
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // The ladder may have been reset during the backoff (heartbeat, gate close, srst,
                // wake): a rung whose token is no longer in flight must not run (C4 note).
                guard self.ladder.inFlightToken == token else { return }
                let stuck = DispatchWorkItem { [weak self] in
                    guard let self, self.stuckToken == token else { return }
                    self.onEvent?(.recoveryStuck, .anomaly, ["rung": rung.rawValue, "token": "\(token)"])
                    self.onStuck?()
                }
                self.stuckWatchdog?.cancel()
                self.stuckWatchdog = stuck
                self.stuckToken = token
                self.queue.asyncAfter(deadline: .now() + Self.stuckSeconds, execute: stuck)
                self.tap?.rebuild(rung: rung, token: token, reason: "healing ladder")
            }
        case .awaitHeartbeat(let seconds, let token):
            heartbeatDeadline?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply(self.ladder.heartbeatDeadlineMissed(token: token, now: self.now))
            }
            heartbeatDeadline = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        case .giveUp(let retryAfter):
            onEvent?(.tapRecoveryGivenUp, .anomaly, ["rebuilds": "\(ladder.totalRebuilds)"])
            onGiveUp?()
            // Already exhausted with a slow retry pending (a grant rung failed on an exhausted
            // ladder): keep that timer, don't push the retry back (C4 note).
            guard slowRetry == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.slowRetry = nil
                self.apply(self.ladder.slowRetryDue(now: self.now))
            }
            slowRetry = item
            queue.asyncAfter(deadline: .now() + retryAfter, execute: item)
        }
    }
}
