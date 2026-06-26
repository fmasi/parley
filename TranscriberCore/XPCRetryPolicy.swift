import Foundation

/// Decides whether an XPC capture-service crash should be retried or give up.
///
/// The retry counter is a *consecutive-failure streak*, not a lifetime count: a crash that
/// arrives strictly more than `decayInterval` after the previous one starts a fresh streak.
/// This lets a long recording absorb sporadic, individually-recovered interruptions (#61),
/// while a tight crash loop — `maxRetries + 1` failures inside the window — still trips the cap.
public enum XPCRetryPolicy {

    public struct Decision: Equatable {
        /// The new consecutive-failure count after registering this crash.
        public let retryCount: Int
        /// True when the streak has exhausted the retry budget and recovery should stop.
        public let shouldGiveUp: Bool
    }

    /// Streak length tolerated before giving up.
    public static let defaultMaxRetries = 2
    /// A crash strictly more than this after the previous one starts a fresh streak.
    public static let defaultDecayInterval: TimeInterval = 600  // 10 minutes

    /// Register a crash and decide whether to keep retrying.
    ///
    /// - Parameters:
    ///   - priorCount: the consecutive-failure count before this crash (0 for the first).
    ///   - lastCrashAt: when the previous crash in the streak occurred (nil if none).
    ///   - now: the time of the crash being registered.
    ///   - maxRetries: streak length tolerated before giving up (default 2).
    ///   - decayInterval: a crash strictly later than this after `lastCrashAt` starts a fresh streak.
    public static func register(
        priorCount: Int,
        lastCrashAt: Date?,
        now: Date,
        maxRetries: Int = defaultMaxRetries,
        decayInterval: TimeInterval = defaultDecayInterval
    ) -> Decision {
        let decayed: Bool
        if let last = lastCrashAt {
            decayed = now.timeIntervalSince(last) > decayInterval
        } else {
            decayed = false
        }
        let retryCount = (decayed ? 0 : priorCount) + 1
        return Decision(retryCount: retryCount, shouldGiveUp: retryCount > maxRetries)
    }
}
