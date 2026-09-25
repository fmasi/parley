import Darwin
import Foundation
import os

/// Every blocking read of a recording folder (L review 123): a status, a scan, a free-space or `statfs`-class call.
/// They run HERE — behind a continuation and a deadline on awake time, never on the Swift cooperative pool: a dead
/// network share or a dying drive hangs such a read, and every hung read used to hold one of the pool's few threads (8
/// on the M1 Air) until every deadline in the app stalled.
///
/// One serial dispatch queue PER VOLUME (L review 160): a hung read holds its own volume's queue only — later reads of
/// that volume wait behind it and time out, while a folder on another volume (the healthy one a Start writes to) is
/// read at once. The volume is found lexically, from the kernel's mount table as it stands (`MNT_NOWAIT`): computing
/// it never touches the folder. A folder whose volume cannot be told reads on one shared "unknown" queue.
///
/// At most one read per key (by default, the folder) is outstanding: a read whose key has an earlier read still
/// unanswered is not queued behind it (it could only pile up there). It answers at once: `.busy` — "no answer yet", never
/// "not answering" — while that earlier read is within its deadline; `.timedOut` once it is overdue (L review 164).
public final class FolderReads: @unchecked Sendable {
    /// The app's one reader.
    public static let shared = FolderReads()

    /// What a bounded read came back with.
    public enum Outcome<T> {
        case answered(T)
        /// It did not answer within its bound: the folder is not answering.
        case timedOut
        /// An earlier read of the same key has not answered yet: nothing was asked — no answer YET (L review 164).
        case busy

        public var value: T? { if case .answered(let value) = self { return value } else { return nil } }
    }

    private let label: String
    /// Guards `queues` and `outstanding`.
    private let lock = NSLock()
    /// One serial queue per volume, made on first use.
    private var queues: [String: DispatchQueue] = [:]
    /// Keys with a read queued or running — coalesced — and whether that read is past its deadline. The token tells
    /// a read's own entry from a later read's under the same key.
    private var outstanding: [String: (token: UUID, overdue: Bool)] = [:]
    /// Runs on the read queue before each read, with its label. Tests hang or observe reads through it.
    let beforeEachRead: (@Sendable (String) -> Void)?
    /// The volume a folder is on: which queue reads it. Tests inject their own volumes.
    let volumeOf: @Sendable (String) -> String

    init(label: String = "eu.fmasi.parley.folder-reads",
         volumeOf: @escaping @Sendable (String) -> String = { FolderReads.volume(of: $0) },
         beforeEachRead: (@Sendable (String) -> Void)? = nil) {
        self.label = label
        self.volumeOf = volumeOf
        self.beforeEachRead = beforeEachRead
    }

    /// `read`'s answer, or nil when it did not answer within `seconds` of awake time — or when `key` (by default the
    /// folder) still has an earlier read outstanding. The read runs on after a timeout; its answer is then dropped.
    public func read<T>(_ label: String, folder: String, key: String? = nil, seconds: Double,
                        _ read: @escaping @Sendable () -> T) async -> T? {
        await outcome(label, folder: folder, key: key, seconds: seconds, read).value
    }

    /// `read`, telling a read that timed out apart from one that was never asked because an earlier read of its key
    /// has not answered yet (L review 164).
    public func outcome<T>(_ label: String, folder: String, key: String? = nil, seconds: Double,
                           _ read: @escaping @Sendable () -> T) async -> Outcome<T> {
        let key = key ?? folder
        let token = UUID()
        let earlier: Bool? = lock.withLock {
            if let entry = outstanding[key] { return entry.overdue }
            outstanding[key] = (token, false)
            return nil
        }
        if let overdue = earlier {
            Logger.state.info("A folder read was not asked: an earlier read of that folder has not answered\(overdue ? " within its deadline" : " yet", privacy: .public) (\(label, privacy: .public))")
            return overdue ? .timedOut : .busy
        }
        let queue = self.queue(forVolume: volumeOf(folder))
        let hook = beforeEachRead
        let answer: Result<Answer<T>, Error> = await boundedReply(label, seconds: seconds) { done in
            queue.async { [self] in
                hook?(label)
                let value = Answer(read())
                lock.withLock { if outstanding[key]?.token == token { outstanding[key] = nil } }
                done(.success(value))
            }
        }
        guard case .success(let value) = answer else {
            lock.withLock { if outstanding[key]?.token == token { outstanding[key]?.overdue = true } }
            Logger.state.error("A folder read did not answer within \(seconds, privacy: .public) s (\(label, privacy: .public))")
            return .timedOut
        }
        return .answered(value.value)
    }

    private func queue(forVolume volume: String) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[volume] { return queue }
            let queue = DispatchQueue(label: "\(label).\(queues.count)", qos: .userInitiated)
            queues[volume] = queue
            return queue
        }
    }

    /// A value read on the queue and handed back whole: the reads return value types — statuses, `SessionState`,
    /// orphan lists — built there and never touched there again.
    private struct Answer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Which volume (L review 160)

    /// A mounted file system as the kernel last knew it: where it is mounted, and whether it is local.
    struct Mount: Equatable, Sendable {
        let path: String
        let isLocal: Bool
    }

    /// The volume `folder` is on — its mount point — or "unknown". Never touches the folder: the mount table is the
    /// kernel's cached copy (`getfsstat` with `MNT_NOWAIT`, which never waits on a file system that does not answer),
    /// and a symbolic link in its path is read only while the path so far lies on a LOCAL volume, never on a share.
    static func volume(of folder: String) -> String {
        volume(of: folder, mounts: mountTable(), readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) })
    }

    /// `volume(of:)`, pure: `mounts` the mount table, `readLink` a link's destination (nil: not a link).
    static func volume(of folder: String, mounts: [Mount], readLink: (String) -> String?) -> String {
        guard !mounts.isEmpty else { return "unknown" }
        func mount(of path: String) -> Mount? {
            mounts.filter { $0.path == "/" || path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        }
        var remaining = folder.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { _ = resolved.popLast(); continue }
            let next = "/" + (resolved + [part]).joined(separator: "/")
            // On a share (or any volume that is not local) nothing more is read: that volume is the answer.
            guard let here = mount(of: next) else { return "unknown" }
            if !here.isLocal { return here.path }
            guard let destination = readLink(next) else {
                resolved.append(part)
                continue
            }
            links += 1
            guard links <= 40 else { return "unknown" }   // a link cycle
            if destination.hasPrefix("/") { resolved = [] }
            remaining = destination.split(separator: "/").map(String.init) + remaining
        }
        return mount(of: "/" + resolved.joined(separator: "/"))?.path ?? "unknown"
    }

    /// The kernel's mount table as it stands — `MNT_NOWAIT`: never a wait on a file system that does not answer.
    static func mountTable() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { table.deallocate() }
        let filled = getfsstat(table, Int32(MemoryLayout<statfs>.stride * Int(count)), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled)).map { i in
            var name = table[i].f_mntonname
            let path = withUnsafePointer(to: &name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            return Mount(path: path, isLocal: table[i].f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }
}

extension FolderReads.Outcome: Sendable where T: Sendable {}
