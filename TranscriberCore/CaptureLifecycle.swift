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

    public init() {}

    /// `startCapture`: claim the session. nil = a start or a capture is already in flight.
    public mutating func claimStart() -> Int? {
        guard phase == .idle else { return nil }
        phase = .starting
        session += 1
        startAborted = false
        startEnding = false
        return session
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

/// The headline ordering of a stop (B-I1, round 2 item 4): SEAL the files, then stop the sources —
/// concurrently, under ONE bound — then END the session whatever the sources did. A source whose
/// teardown blocks (a rung stuck on the tap's config queue, `AudioDeviceStop` on a paused context,
/// `stopRunning` on a HAL lock, gotcha #68) is abandoned: it keeps running on its own thread.
public enum StopSequence {
    public struct Outcome: Equatable, Sendable {
        public let micAbandoned: Bool
        public let tapAbandoned: Bool
        public init(micAbandoned: Bool, tapAbandoned: Bool) {
            self.micAbandoned = micAbandoned; self.tapAbandoned = tapAbandoned
        }
    }

    /// Blocks up to `timeout` (plus `seal` and `end`): never call it on a queue a stop needs.
    @discardableResult
    public static func run(
        seal: () -> Void,
        stopMic: (() -> Void)?,
        stopTap: (() -> Void)?,
        timeout: Double,
        end: () -> Void
    ) -> Outcome {
        seal()
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
        end()
        return Outcome(micAbandoned: !done.mic, tapAbandoned: !done.tap)
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
