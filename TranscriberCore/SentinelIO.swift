import Foundation

/// The recovery file's and the pending list's I/O (L review 217): ONE serial queue, so every read sees every write queued
/// before it — a rotation's liveness write never lands after a delete, never races a keeping. The hot paths — a start's
/// write, a stop's read, mark and delete, a crash's read and rewrite, every rotation's liveness write — run on it OFF the
/// main actor (`run`, `enqueue`). The callers that must stay synchronous — a termination's mark, the pending list's
/// bookkeeping — run on the same queue, in order (`sync`).
final class SentinelIO: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Runs on the queue before each operation, with its label. Tests hang or observe the I/O through it.
    let beforeEach: (@Sendable (String) -> Void)?

    init(label: String = "eu.fmasi.parley.sentinel-io", beforeEach: (@Sendable (String) -> Void)? = nil) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.beforeEach = beforeEach
    }

    /// `work`, in order with everything queued before it; the caller waits.
    func sync<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        try queue.sync {
            beforeEach?(label)
            return try work()
        }
    }

    /// `work` off the caller, bounded by `seconds` of awake time: nil when it did not answer (it runs on; its answer is then
    /// dropped).
    func run<T>(_ label: String, seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        let hook = beforeEach
        let answer: Result<Answer<T>, Error> = await boundedReply(label, seconds: seconds) { done in
            self.queue.async {
                hook?(label)
                done(.success(Answer(work())))
            }
        }
        guard case .success(let value) = answer else { return nil }
        return value.value
    }

    /// `work` queued, never waited for.
    func enqueue(_ label: String, _ work: @escaping @Sendable () -> Void) {
        let hook = beforeEach
        queue.async {
            hook?(label)
            work()
        }
    }

    /// A value built on the queue and handed back whole.
    private struct Answer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
