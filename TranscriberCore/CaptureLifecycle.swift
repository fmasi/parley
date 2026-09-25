import Dispatch
import Foundation
import os

/// The helper's capture-session claim (H2 council: B-I1, B-I2, B-I3; round 2 items 1, 4, 9, 10). Pure;
/// the service keeps one under its `stateLock`. `StopReply` is whatever answers a stop (the XPC reply
/// block in the helper, a string in the tests).
///
/// - A start RESERVES the session before it builds anything, under a TOKEN. A second start is refused
///   while the first is still coming up (before, the guard was only a check, and a second start
///   orphaned the first session's mic, tap and writers).
/// - A stop or disconnect during a start ABORTS it: every later step of that start sees it
///   (`startMayProceed` false, `isStopping` true), the commit fails, and the start tears down what it
///   built. A stop that arrived meanwhile waits in here and comes back from `startEnded` — only once the
///   teardown is done. No capture is ever left running without a client.
/// - A start that hangs in the OS is abandoned at its own deadline: exactly one of the deadline and the
///   start's own failure path wins `beginEndingStart`, tears down, and replies. The stale start can
///   never commit into, or end, a later session.
/// - A stop always ends `idle`, whatever its sources did, so the next Record is never refused.
/// - A dropped connection stops only the capture (or start) it OWNS (round 5 item 5): the app drops a
///   connection on a stop timeout and starts again on a new one, and the old one's late invalidation
///   must not stop that. An explicit stop is the app's, from whatever connection it has, and always acts.
/// - A rotation during a start or a stop is refused with a reply that is NOT "No capture in progress",
///   which the app treats as a dead capture (§8.7), and a rotation is checked against its own session.
public struct CaptureLifecycle<StopReply> {
    public enum Phase: String, Equatable, Sendable { case idle, starting, capturing, stopping }

    public enum StopDecision: Equatable, Sendable {
        /// A committed capture: tear it down.
        case stop
        /// A start is in flight: it aborts; this stop is answered by `startEnded`.
        case abortStart
        /// A stop is already tearing it down.
        case alreadyStopping
        case notCapturing
        /// A dropped connection that does not own the current capture: nothing to do.
        case notOwner
    }

    public enum RotationGate: Equatable, Sendable { case allowed, refusedStopping, notCapturing }

    /// How long Stop waits for the sources (mic and tap, concurrently) before abandoning them (B-I1).
    public static var sourceStopTimeoutSeconds: Double { 3 }
    /// How long a start may take before the helper abandons it (round 2 item 1): longer than the app's
    /// own 15 s start deadline, so the app gives up first and this only frees a start nobody waits for.
    public static var startTimeoutSeconds: Double { 20 }

    public private(set) var phase: Phase = .idle
    /// The token of the current (or last) start; each claim takes a new one.
    public private(set) var session = 0
    /// A stop or disconnect arrived while starting.
    public private(set) var startAborted = false
    /// A failure or the deadline has begun tearing the start down.
    private var startEnding = false
    private var pendingStops: [StopReply] = []
    /// The connection whose start claimed the session; nil = unknown (not started over XPC).
    private var owner: ObjectIdentifier?

    public init() {}

    /// `startCapture`: claim the session for `owner` (the calling connection). nil = a start or a
    /// capture is already in flight.
    public mutating func claimStart(owner: ObjectIdentifier? = nil) -> Int? {
        guard phase == .idle else { return nil }
        self.owner = owner
        phase = .starting
        session += 1
        startAborted = false
        startEnding = false
        return session
    }

    /// A stop because `connection` was invalidated: acts only when that connection owns the current
    /// capture or start (an unknown owner is anyone's). A start in flight is aborted, never committed.
    public mutating func requestStop(_ reply: StopReply, disconnectOf connection: ObjectIdentifier) -> StopDecision {
        if phase != .idle, let owner, owner != connection { return .notOwner }
        return requestStop(reply)
    }

    /// A `.abortStart` keeps `reply` until the start has torn down (`startEnded`).
    public mutating func requestStop(_ reply: StopReply) -> StopDecision {
        switch phase {
        case .capturing:
            phase = .stopping
            return .stop
        case .starting:
            startAborted = true
            pendingStops.append(reply)
            return .abortStart
        case .stopping:
            return .alreadyStopping
        case .idle:
            return .notCapturing
        }
    }

    /// `token` names the newest start (whatever its phase): a stale start must not delete files by path,
    /// since a newer one may be writing the same paths (round 3 C).
    public func isCurrentStart(_ token: Int) -> Bool { session == token }

    /// Whether start `token` may take its next step (open the mic, start the system source, register
    /// what it opened). False once it is aborted, ending, or no longer the current start.
    public func startMayProceed(_ token: Int) -> Bool {
        phase == .starting && session == token && !startAborted && !startEnding
    }

    /// Start `token` built everything. False when it may not proceed: it must tear down.
    public mutating func commitStart(_ token: Int) -> Bool {
        guard startMayProceed(token) else { return false }
        phase = .capturing
        return true
    }

    /// Start `token` failed, was aborted, or hit its deadline: true for exactly ONE caller, which tears
    /// down what the start built and replies. False for the other (and for a stale token).
    public mutating func beginEndingStart(_ token: Int) -> Bool {
        guard phase == .starting, session == token, !startEnding else { return false }
        startEnding = true
        return true
    }

    /// Start `token` has torn down: the session is free, and the stops that arrived during it are
    /// returned, to be answered now. Empty (and a no-op) for a stale token.
    public mutating func startEnded(_ token: Int) -> [StopReply] {
        guard phase == .starting, session == token else { return [] }
        phase = .idle
        startAborted = false
        startEnding = false
        defer { pendingStops = [] }
        return pendingStops
    }

    /// The stop sealed the files and released (or abandoned) the sources.
    public mutating func stopEnded() {
        guard phase == .stopping else { return }
        phase = .idle
    }

    /// A stop (or an abort, or a start's teardown) owns teardown now: what every commit-or-abort guard
    /// and the in-place restart check.
    public var isStopping: Bool { phase == .stopping || (phase == .starting && (startAborted || startEnding)) }
    /// `status` and the snapshot: a stop in progress is still capturing until its files are sealed.
    public var isCapturing: Bool { phase == .capturing || phase == .stopping }
    /// Live-session work (the watchdog, the tap-guard timer, power events, mic switches).
    public var isLive: Bool { phase == .capturing }

    public var rotationGate: RotationGate {
        switch phase {
        case .capturing: return .allowed
        case .starting, .stopping: return .refusedStopping
        case .idle: return .notCapturing
        }
    }

    /// The rotate's re-check at the swap: still capturing, and still the session it began in (a stop
    /// and a new start in between leave the phase `capturing` again, in another session).
    public func allowsRotation(of token: Int) -> Bool { phase == .capturing && session == token }
}

extension CaptureLifecycle: Sendable where StopReply: Sendable {}

/// The headline ordering of a stop (B-I1, round 2 item 4; round 3 E): SEAL the files (bounded), then stop
/// the sources — concurrently, under ONE bound — then END the session whatever the seal and the sources
/// did. A seal on a wedged audio queue (a disk stall), or a source whose teardown blocks (a rung stuck on
/// the tap's config queue, `AudioDeviceStop` on a paused context, `stopRunning` on a HAL lock, gotcha
/// #68), is abandoned: it keeps running on its own thread, and the caller drops what it writes late.
public enum StopSequence {
    public struct Outcome: Equatable, Sendable {
        /// The seal did not return within its bound: the caller must drop any late write.
        public let sealAbandoned: Bool
        public let micAbandoned: Bool
        public let tapAbandoned: Bool
        public init(sealAbandoned: Bool = false, micAbandoned: Bool, tapAbandoned: Bool) {
            self.sealAbandoned = sealAbandoned; self.micAbandoned = micAbandoned; self.tapAbandoned = tapAbandoned
        }
    }

    /// Blocks up to 2 × `timeout` (the seal's bound, then the sources'), plus `end`: never call it on a
    /// queue the seal or a stop needs.
    @discardableResult
    public static func run(
        seal: @escaping () -> Void,
        stopMic: (() -> Void)?,
        stopTap: (() -> Void)?,
        timeout: Double,
        end: () -> Void
    ) -> Outcome {
        run(sealing: seal, stopMic: stopMic, stopTap: stopTap, timeout: timeout, end: { _ in end() }).outcome
    }

    /// As `run(seal:…)`, and the seal hands back what it read in the same audio-queue block — Stop's
    /// coverage (round 4 N2), so Stop never needs an `audioQueue.sync` of its own. `read` is nil when the
    /// seal did not return within its bound: the caller falls back to a cached reading. `end` gets it
    /// too, so the caller records it while the session is still the current one (round 5 item 4).
    public static func run<Read>(
        sealing seal: @escaping () -> Read,
        stopMic: (() -> Void)?,
        stopTap: (() -> Void)?,
        timeout: Double,
        end: (Read?) -> Void
    ) -> (outcome: Outcome, read: Read?) {
        let sealed = DispatchSemaphore(value: 0)
        let box = ReadBox<Read>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = seal()
            sealed.signal()
        }
        let sealAbandoned = sealed.wait(timeout: .now() + timeout) == .timedOut
        let read = sealAbandoned ? nil : box.value
        let group = DispatchGroup()
        let finished = OSAllocatedUnfairLock(initialState: (mic: stopMic == nil, tap: stopTap == nil))
        if let stopMic {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stopMic()
                finished.withLock { $0.mic = true }
                group.leave()
            }
        }
        if let stopTap {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stopTap()
                finished.withLock { $0.tap = true }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        let done = finished.withLock { $0 }
        end(read)
        return (Outcome(sealAbandoned: sealAbandoned, micAbandoned: !done.mic, tapAbandoned: !done.tap), read)
    }

    /// The seal's result, written on the seal's thread before the semaphore signals and read after the
    /// wait succeeds (happens-before via the semaphore); never read when the seal was abandoned.
    private final class ReadBox<Read>: @unchecked Sendable {
        var value: Read?
    }
}

/// True for exactly one caller (round 2 item 1): an XPC reply block must be called once, whichever of
/// a start's deadline and its own late completion gets there first.
public final class OnceFlag: @unchecked Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func claim() -> Bool {
        fired.withLock { wasFired in
            defer { wasFired = true }
            return !wasFired
        }
    }
}

/// One step on a queue that may be stalled — a rotation's writer swap on the audio queue (round 5 item 1):
/// it runs within `timeout`, or it is ABANDONED and never runs at all, so nothing applies late. A step
/// that started just as the bound passed is waited for (it is running, so the queue moved) for one more
/// bound; past that it is `overran`: it may still complete.
public enum AbandonableStep {
    public enum Outcome<T: Equatable>: Equatable {
        case done(T)
        /// Never ran, and never will.
        case abandoned
        /// Started, but did not finish within a second bound.
        case overran
    }

    public static let rotationTimeoutSeconds: Double = 3

    /// Blocks up to 2 × `timeout`: never call it on `queue`.
    public static func run<T: Equatable>(timeout: Double, on queue: DispatchQueue, _ step: @escaping () -> T) -> Outcome<T> {
        let claim = OnceFlag()
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        queue.async {
            guard claim.claim() else { return }   // abandoned before it could start
            box.value = step()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .success, let value = box.value { return .done(value) }
        if claim.claim() { return .abandoned }   // it had not started: now it never will
        if done.wait(timeout: .now() + timeout) == .success, let value = box.value { return .done(value) }
        return .overran
    }

    /// Written before the semaphore signals, read after a successful wait.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

/// A value that belongs to one capture session (round 5 item 3): the coverage counts cached on each tick.
/// A refresh for another session — queued before a stall, landing after the next start — is ignored, and
/// the value is only ever handed to its own session.
public struct SessionScopedCache<Value> {
    private var session: Int?
    private var value: Value?

    public init() {}

    /// A new session: forget the previous one's value.
    public mutating func reset(session: Int) {
        self.session = session
        value = nil
    }

    public mutating func update(session: Int, value: Value) {
        guard session == self.session else { return }
        self.value = value
    }

    public func value(for session: Int) -> Value? {
        session == self.session ? value : nil
    }
}

extension SessionScopedCache: Sendable where Value: Sendable {}
