import Dispatch
import Foundation

/// The helper's capture-session claim (H2 council: B-I1, B-I2, B-I3). Pure; the service keeps one
/// under its `stateLock`.
///
/// - A start RESERVES the session before it builds anything, so a second start is refused while the
///   first is still coming up (before, the guard was only a check, and a second start orphaned the
///   first session's mic, tap and writers).
/// - A stop or disconnect during a start ABORTS it: the start's commit-or-abort guards see
///   `isStopping`, the commit fails, and the start tears down everything it built. No capture is
///   ever left running without a client.
/// - A stop always ends `idle`, whatever its sources did (a stuck one is abandoned), so the next
///   Record is never refused with "Capture already in progress".
/// - A rotation during a start or a stop is refused with a reply that is NOT "No capture in
///   progress", which the app treats as a dead capture (§8.7).
public struct CaptureLifecycle: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable { case idle, starting, capturing, stopping }

    public enum StopDecision: Equatable, Sendable {
        /// A committed capture: tear it down.
        case stop
        /// A start is in flight: it aborts and tears down what it built.
        case abortStart
        /// A stop is already tearing it down.
        case alreadyStopping
        case notCapturing
    }

    public enum RotationGate: Equatable, Sendable { case allowed, refusedStopping, notCapturing }

    /// How long Stop waits for one source (mic, tap) to stop before abandoning it (B-I1).
    public static let sourceStopTimeoutSeconds: Double = 3

    public private(set) var phase: Phase = .idle
    /// A stop or disconnect arrived while starting.
    public private(set) var startAborted = false

    public init() {}

    /// `startCapture`: claim the session. False = a start or a capture is already in flight.
    public mutating func claimStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        startAborted = false
        return true
    }

    public mutating func requestStop() -> StopDecision {
        switch phase {
        case .capturing:
            phase = .stopping
            return .stop
        case .starting:
            startAborted = true
            return .abortStart
        case .stopping:
            return .alreadyStopping
        case .idle:
            return .notCapturing
        }
    }

    /// The start built everything. False when a stop aborted it: the start must tear down.
    public mutating func commitStart() -> Bool {
        guard phase == .starting, !startAborted else { return false }
        phase = .capturing
        return true
    }

    /// The start failed or was aborted, and has torn down what it built.
    public mutating func startEnded() {
        guard phase == .starting else { return }
        phase = .idle
        startAborted = false
    }

    /// The stop sealed the files and released (or abandoned) the sources.
    public mutating func stopEnded() {
        guard phase == .stopping else { return }
        phase = .idle
    }

    /// A stop owns teardown now: what every commit-or-abort guard and the in-place restart check.
    public var isStopping: Bool { phase == .stopping || (phase == .starting && startAborted) }
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
}

/// Runs work that may never return — a HAL or AVFoundation teardown (M-C, gotcha #68) — with a
/// deadline on the caller's side (B-I1).
public enum BoundedWait {
    /// Runs `work` on a background queue and waits at most `seconds` for it. True = it returned in
    /// time. On false the work keeps running on its own thread and the caller moves on without it.
    public static func run(seconds: Double, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }
}
