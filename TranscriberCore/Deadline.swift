import Foundation

public enum DeadlineError: Error, Equatable {
    case timedOut(String)
}

/// Runs `body` and gives up on it after `seconds`. The loser does not linger where it can stop (H2
/// round 2, council B-M13): a body that wins cancels the sleeper, so no wakeup is left pending up to
/// `seconds` later. A body that loses keeps running — its caller has moved on, and a stop that finishes
/// late still seals its files — but its result is dropped.
public func withDeadline<T: Sendable>(seconds: Double, label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withDeadline(seconds: seconds, label: label, sleeper: { try? await Task.sleep(for: .seconds($0)) }, body)
}

/// `sleeper`: waits `seconds` unless cancelled (the test seam).
func withDeadline<T: Sendable>(
    seconds: Double, label: String, sleeper: @escaping @Sendable (Double) async -> Void,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome: Result<T, any Error> = await withCheckedContinuation { cont in
        let once = ResumeOnce(cont)
        let timer = Task {
            await sleeper(seconds)
            guard !Task.isCancelled else { return }
            once.resume(.failure(DeadlineError.timedOut(label)))
        }
        Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
            timer.cancel()
        }
    }
    return try outcome.get()
}
