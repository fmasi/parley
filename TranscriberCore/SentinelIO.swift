import Foundation

/// The recovery file's and the pending list's I/O (L review 217): ONE serial queue, so every read sees every write queued
/// before it — a rotation's liveness write never lands after a delete, never races a keeping. The hot paths — a start's
/// write, a stop's read, mark and delete, a crash's read and rewrite, every rotation's liveness write — run on it OFF the
/// main actor (`run`, `enqueue`). The pending list's bookkeeping runs on the same queue, in order (`sync`); the marks an
/// exit makes synchronously — the process may end in that very turn — wait for it only within a bound (`waitBounded`, L
/// review 235).
final class SentinelIO: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Runs on the queue before each operation, with its label. Tests hang or observe the I/O through it.
    let beforeEach: (@Sendable (String) -> Void)?
    /// Guards `overdue`.
    private let lock = NSLock()
    /// Operations that did not answer within their bound and have not run to their end yet (L review 235).
    private var overdue = 0

    /// The queue is stuck behind an operation past its bound (L review 235): nothing queued now runs before it ends, so an
    /// exit's mark is only queued — never waited for.
    var isStalled: Bool { lock.withLock { overdue > 0 } }

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
        let hook = beforeEach, operation = Operation(self)
        let answer: Result<Answer<T>, Error> = await boundedReply(label, seconds: seconds) { done in
            self.queue.async {
                hook?(label)
                let value = Answer(work())
                operation.ended()
                done(.success(value))
            }
        }
        guard case .success(let value) = answer else {
            operation.timedOut()
            return nil
        }
        return value.value
    }

    /// `work`, in order with everything queued before it; the caller waits — never past `seconds` (L review 235): nil when
    /// it did not answer (it runs on). For a mark a process that may end in this very turn makes synchronously. Never
    /// called on the queue itself.
    func waitBounded<T>(_ label: String, seconds: Double, _ work: @escaping @Sendable () -> T) -> T? {
        let hook = beforeEach, operation = Operation(self), answered = DispatchSemaphore(value: 0)
        let result = Slot<T>()
        queue.async {
            hook?(label)
            result.value = work()
            operation.ended()
            answered.signal()
        }
        guard answered.wait(timeout: .now() + max(0, seconds)) == .success else {
            operation.timedOut()
            return nil
        }
        return result.value
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

    /// The value `waitBounded` hands back: written on the queue, read once the semaphore says it was.
    private final class Slot<T>: @unchecked Sendable {
        var value: T?
    }

    /// One bounded operation: counted overdue from its timeout until it has run to its end (L review 235).
    private final class Operation: @unchecked Sendable {
        private weak var io: SentinelIO?
        private let lock = NSLock()
        private var finished = false, late = false
        init(_ io: SentinelIO) { self.io = io }

        /// Its caller stopped waiting: overdue, unless it already ran.
        func timedOut() {
            let nowOverdue = lock.withLock { () -> Bool in
                guard !finished, !late else { return false }
                late = true
                return true
            }
            if nowOverdue, let io { io.lock.withLock { io.overdue += 1 } }
        }

        /// It ran to its end: no longer overdue.
        func ended() {
            let wasOverdue = lock.withLock { () -> Bool in
                finished = true
                return late
            }
            if wasOverdue, let io { io.lock.withLock { io.overdue -= 1 } }
        }
    }
}
