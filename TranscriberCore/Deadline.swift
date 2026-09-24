import Foundation

public enum DeadlineError: Error, Equatable {
    case timedOut(String)
}

public func withDeadline<T: Sendable>(seconds: Double, label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let outcome: Result<T, any Error> = await withCheckedContinuation { cont in
        let once = ResumeOnce(cont)
        Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(DeadlineError.timedOut(label)))
        }
    }
    return try outcome.get()
}
