import Foundation

public enum DeadlineError: Error, Equatable {
    case timedOut(String)
}

// Every §8.8 deadline runs on `SuspendingClock` — awake time (L10 review 56). A Stop or a Start that
// straddles a lid close must not time out at wake for the hours the Mac slept: that is a false "the helper
// did not respond", and a salvage of a recording that was fine. The clock is a parameter only so tests can
// drive it.

/// `body`, or `DeadlineError.timedOut(label)` once `seconds` of the clock's time have passed. The body runs
/// on after a timeout (a stop that finishes late still seals its files), but its result is dropped. A body
/// that finishes first cancels the deadline, so no wakeup is left pending (H2 round 2, council B-M13).
public func withDeadline<T: Sendable, C: Clock>(
    seconds: Double, label: String, clock: C = SuspendingClock(),
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T where C.Duration == Duration {
    let outcome: Result<T, any Error> = await withCheckedContinuation { cont in
        let once = ResumeOnce(cont)
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(seconds))
                once.resume(.failure(DeadlineError.timedOut(label)))
            } catch {}   // cancelled: the body finished first
        }
        Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
            deadline.cancel()
        }
    }
    return try outcome.get()
}

/// One XPC call with a reply, bounded (§8.8): the reply, the XPC error handler and the deadline race through
/// `ResumeOnce`, so whichever comes first wins — a late reply is ignored, a continuation is never resumed
/// twice or leaked. `send` gets the one completion the reply AND the error handler call. A timeout is
/// `CaptureCallTimeout`; recording it is the caller's (it knows the session the call was made for).
public func boundedReply<T: Sendable, C: Clock>(
    _ call: String, seconds: Double, clock: C = SuspendingClock(),
    _ send: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
) async -> Result<T, Error> where C.Duration == Duration {
    await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>, Never>) in
        let once = ResumeOnce(cont)
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(seconds))
                once.resume(.failure(CaptureCallTimeout(call: call, seconds: seconds)))
            } catch {}   // cancelled: the call was answered first
        }
        send { result in
            once.resume(result)
            deadline.cancel()
        }
    }
}
