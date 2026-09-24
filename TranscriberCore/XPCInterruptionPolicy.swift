import Foundation

/// Decides what an XPC interruption or invalidation means, armed per capture generation.
///
/// Why a generation and not a Bool (L-N1): launchd idle-exits the embedded helper ~10 min after
/// its last message. The client's old `crashHandlerFired` latch treated that as "crash handled"
/// and was reset only in `connect()`, which never ran again — so every later real crash was
/// ignored. Arming happens in `captureStarted()` and every decision fires at most once per
/// generation; outside a capture nothing is pinged, latched or spawned.
public struct XPCInterruptionPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Not capturing (an idle-exit), or this generation already escalated: do nothing.
        case ignoreIdle
        /// No crash report: ask the helper whether it is still capturing, then call `onVerified`.
        case verifyCapture
        /// The helper is still capturing — a connection blip, keep recording.
        case briefInterruption
        /// Run crash recovery. Fires at most once per generation.
        case crash
    }

    public private(set) var captureGeneration = 0
    public private(set) var expectingCapture = false
    private var firedGeneration: Int?

    public init() {}

    public mutating func captureStarted() {
        captureGeneration += 1
        expectingCapture = true
    }

    public mutating func captureStopped() {
        expectingCapture = false
    }

    private var alreadyFired: Bool { firedGeneration == captureGeneration }

    public mutating func onInterruption(classification: CrashClassification) -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        if classification == .likelyCrash {
            firedGeneration = captureGeneration
            return .crash
        }
        return .verifyCapture
    }

    public mutating func onVerified(stillCapturing: Bool, generation: Int) -> Decision {
        guard expectingCapture, generation == captureGeneration, !alreadyFired else { return .ignoreIdle }
        if stillCapturing { return .briefInterruption }
        firedGeneration = captureGeneration
        return .crash
    }

    public mutating func onInvalidation() -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        firedGeneration = captureGeneration
        return .crash
    }
}
