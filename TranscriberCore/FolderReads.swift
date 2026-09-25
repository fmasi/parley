import Foundation
import os

/// Every blocking read of a recording folder (L review 123): a status, a scan, a free-space or `statfs`-class call.
/// They run HERE — one at a time, on ONE dedicated serial dispatch queue — behind a continuation and a deadline on
/// awake time, never on the Swift cooperative pool: a dead network share or a dying drive hangs such a read, and
/// every hung read used to hold one of the pool's few threads (8 on the M1 Air) until every deadline in the app
/// stalled. A hung read now holds this queue only: later folder reads wait behind it and time out.
///
/// At most one read per folder is outstanding: a read of a folder whose earlier read has not answered yet is not
/// queued behind it (it could only pile up there) — it answers nothing at once, like a read that timed out.
public final class FolderReads: @unchecked Sendable {
    /// The app's one reader.
    public static let shared = FolderReads()

    private let queue: DispatchQueue
    /// Guards `outstanding`.
    private let lock = NSLock()
    /// Folders with a read queued or running: coalesced.
    private var outstanding: Set<String> = []
    /// Runs on the read queue before each read, with its label. Tests hang or observe reads through it.
    let beforeEachRead: (@Sendable (String) -> Void)?

    init(label: String = "eu.fmasi.parley.folder-reads", beforeEachRead: (@Sendable (String) -> Void)? = nil) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.beforeEachRead = beforeEachRead
    }

    /// `read`'s answer, or nil when it did not answer within `seconds` of awake time — or when `folder` still has
    /// an earlier read outstanding. The read runs on after a timeout; its answer is then dropped.
    func read<T>(_ label: String, folder: String, seconds: Double, _ read: @escaping @Sendable () -> T) async -> T? {
        guard lock.withLock({ outstanding.insert(folder).inserted }) else {
            Logger.state.error("A folder read was skipped: an earlier read of that folder has not answered (\(label, privacy: .public))")
            return nil
        }
        let hook = beforeEachRead
        let answer: Result<Answer<T>, Error> = await boundedReply(label, seconds: seconds) { done in
            queue.async { [self] in
                hook?(label)
                let value = Answer(read())
                lock.withLock { _ = outstanding.remove(folder) }
                done(.success(value))
            }
        }
        guard case .success(let value) = answer else {
            Logger.state.error("A folder read did not answer within \(seconds, privacy: .public) s (\(label, privacy: .public))")
            return nil
        }
        return value.value
    }

    /// A value read on the queue and handed back whole: the reads return value types — statuses, `SessionState`,
    /// orphan lists — built there and never touched there again.
    private struct Answer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
