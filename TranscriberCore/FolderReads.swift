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
/// read at once. Which volume a folder is on is found without the caller ever touching a file system (L review 209): only
/// the RECORDING ROOT is canonicalised — once, its symbolic links on local volumes substituted — and every folder under
/// it is derived from it LEXICALLY (L review 237); a folder under no root noted is its own root. The canonicalisations run
/// off the pool, on a queue of their own — concurrent, so one that hangs never delays another, and never shared with a
/// read — under the read's own bound, and are cached; each read then matches its path LEXICALLY against the kernel's
/// mount table as it stands (`MNT_NOWAIT`), its firmlinked and case-insensitive spellings included (L reviews 214, 238). A
/// folder whose root's canonicalisation has not answered reads on that root's own fallback queue.
///
/// At most one read per key (by default, the folder) is outstanding: a read whose key has an earlier read still
/// unanswered is never queued behind it (it could only pile up there). It JOINS it (L review 210): it waits for that read
/// to answer, within its OWN bound, then asks its own. Only its own bound running out is "not answering" — never "no answer
/// yet" taken for "not reachable".
public final class FolderReads: @unchecked Sendable {
    /// The app's one reader.
    public static let shared = FolderReads()

    /// What a bounded read came back with.
    public enum Outcome<T> {
        case answered(T)
        /// It did not answer within its bound — waiting for an earlier read of its key included: the folder is not
        /// answering (L reviews 164, 210).
        case timedOut

        public var value: T? { if case .answered(let value) = self { return value } else { return nil } }
    }

    private let label: String
    /// Guards `queues`, `mutationQueues`, `outstanding`, `roots`, `resolved` and `resolving`.
    private let lock = NSLock()
    /// One serial queue per volume, made on first use.
    private var queues: [String: DispatchQueue] = [:]
    /// One serial, low-priority queue per volume for the mutations nothing waits for (L review 241): never ahead of a read.
    private var mutationQueues: [String: DispatchQueue] = [:]
    /// The recording roots noted (L review 237): each canonicalised once, the folders under it derived from it lexically.
    private var roots: Set<String> = []
    /// Where the roots are canonicalised (L review 237): a queue of their own, concurrent — never a read's.
    private let resolveQueue: DispatchQueue
    /// Keys with a read queued or running: what a later read of the key joins.
    private var outstanding: [String: InFlight] = [:]
    /// Folders already resolved (L review 209): the canonical path — or, with an injected `volumeOf`, the volume.
    private var resolved: [String: String] = [:]
    /// Folders whose resolution is out: a second one is never queued behind it.
    private var resolving: Set<String> = []
    /// Runs on the read queue before each read, with its label. Tests hang or observe reads through it.
    let beforeEachRead: (@Sendable (String) -> Void)?
    /// Tests: a folder's volume, whole — resolved as production's canonicalisation is (off the pool, bounded, cached).
    let volumeOf: (@Sendable (String) -> String)?

    init(label: String = "eu.fmasi.parley.folder-reads",
         volumeOf: (@Sendable (String) -> String)? = nil,
         beforeEachRead: (@Sendable (String) -> Void)? = nil) {
        self.label = label
        self.volumeOf = volumeOf
        self.beforeEachRead = beforeEachRead
        resolveQueue = DispatchQueue(label: "\(label).resolve", qos: .userInitiated, attributes: .concurrent)
    }

    /// `root` is a recording root (L review 237): it alone is canonicalised; every folder under it is derived from it.
    public func noteRecordingRoot(_ root: String) {
        let root = Self.normalised(root)
        lock.withLock { _ = roots.insert(root) }
    }

    /// `path`, its `.` and `..` removed — lexically, never a file-system call (a directory URL: `fileURLWithPath:` alone would
    /// look whether the path is a directory).
    private static func normalised(_ path: String) -> String { URL(fileURLWithPath: path, isDirectory: true).standardized.path }

    /// The root `folder` is derived from (L review 237): the deepest recording root it lies in — or, under none, itself.
    private func root(of folder: String) -> String {
        let folder = Self.normalised(folder)
        let root = lock.withLock { roots.filter { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }.max { $0.count < $1.count } }
        return root ?? folder
    }

    /// `read`'s answer, or nil when it did not answer within `seconds` of awake time — waiting for an earlier read of its
    /// key (by default the folder) included. The read runs on after a timeout; its answer is then dropped.
    public func read<T>(_ label: String, folder: String, key: String? = nil, seconds: Double,
                        _ read: @escaping @Sendable () -> T) async -> T? {
        await outcome(label, folder: folder, key: key, seconds: seconds, read).value
    }

    /// `read`, as an outcome.
    public func outcome<T>(_ label: String, folder: String, key: String? = nil, seconds: Double,
                           _ read: @escaping @Sendable () -> T) async -> Outcome<T> {
        let key = key ?? folder
        let deadline = SuspendingClock.now + .milliseconds(Int64(max(0, seconds) * 1000))
        while true {
            let (mine, earlier) = lock.withLock { () -> (InFlight?, InFlight?) in
                if let earlier = outstanding[key] { return (nil, earlier) }
                let mine = InFlight()
                outstanding[key] = mine
                return (mine, nil)
            }
            if let earlier {
                // Joined (L review 210): never queued behind it — its answer is awaited within THIS read's bound.
                Logger.state.info("A folder read waits for an earlier read of that folder (\(label, privacy: .public))")
                let joined: Result<Bool, Error> = await boundedReply(label, seconds: Self.remaining(deadline)) { done in
                    earlier.whenFinished { done(.success(true)) }
                }
                guard case .success = joined else {
                    Logger.state.error("A folder read did not answer within \(seconds, privacy: .public) s — an earlier read of that folder had not answered (\(label, privacy: .public))")
                    return .timedOut
                }
                continue
            }
            guard let mine else { return .timedOut }
            let queue = queue(forVolume: await volume(of: folder, by: deadline))
            let hook = beforeEachRead
            let answer: Result<Answer<T>, Error> = await boundedReply(label, seconds: Self.remaining(deadline)) { done in
                queue.async { [self] in
                    hook?(label)
                    let value = Answer(read())
                    lock.withLock { if outstanding[key] === mine { outstanding[key] = nil } }
                    mine.finish()
                    done(.success(value))
                }
            }
            guard case .success(let value) = answer else {
                Logger.state.error("A folder read did not answer within \(seconds, privacy: .public) s (\(label, privacy: .public))")
                return .timedOut
            }
            return .answered(value.value)
        }
    }

    /// `work` on the folder's volume's MUTATION queue, never waited for (L reviews 215, 241): a mutation — a cleanup's deletes
    /// — that must never hold a bounded read, so a slow healthy share is never called "not answering" for it. Its own
    /// low-priority queue per volume: never queued ahead of a read, a Start's included.
    func enqueue(_ label: String, folder: String, _ work: @escaping @Sendable () -> Void) {
        let hook = beforeEachRead
        Task {
            let queue = self.mutationQueue(forVolume: await self.volume(of: folder, by: SuspendingClock.now + .seconds(5)))
            queue.async {
                hook?(label)
                work()
            }
        }
    }

    private func queue(forVolume volume: String) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[volume] { return queue }
            let queue = DispatchQueue(label: "\(label).\(queues.count)", qos: .userInitiated)
            queues[volume] = queue
            return queue
        }
    }

    private func mutationQueue(forVolume volume: String) -> DispatchQueue {
        lock.withLock {
            if let queue = mutationQueues[volume] { return queue }
            let queue = DispatchQueue(label: "\(label).mutations.\(mutationQueues.count)", qos: .utility)
            mutationQueues[volume] = queue
            return queue
        }
    }

    /// What is left until `deadline`, in seconds (never zero: a spent deadline still times out at once).
    private static func remaining(_ deadline: SuspendingClock.Instant) -> Double {
        let c = (deadline - .now).components
        return max(0.001, Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    /// A value read on the queue and handed back whole: the reads return value types — statuses, `SessionState`,
    /// orphan lists — built there and never touched there again.
    private struct Answer<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// A read queued or running (L review 210): the reads that joined it wait for it to finish.
    private final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var waiters: [@Sendable () -> Void] = []

        func whenFinished(_ waiter: @escaping @Sendable () -> Void) {
            let now = lock.withLock { () -> Bool in
                if finished { return true }
                waiters.append(waiter)
                return false
            }
            if now { waiter() }
        }

        func finish() {
            let waiting = lock.withLock { () -> [@Sendable () -> Void] in
                finished = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in waiting { waiter() }
        }
    }

    // MARK: - Which volume (L reviews 160, 209, 214)

    /// The volume `folder` is on, without the caller ever waiting on a file system (L reviews 209, 237): its root's canonical
    /// path — resolved once, off the pool, on the resolution queue, within what is left of the read's bound, and cached —
    /// with the rest of the folder's path appended lexically, matched against the mount table as it stands. While its
    /// root's resolution has not answered, or is still out, the root's own fallback queue: never a second resolution queued
    /// behind a hung one, and never a queue another root's reads use.
    private func volume(of folder: String, by deadline: SuspendingClock.Instant) async -> String {
        let injected = volumeOf
        let root = root(of: folder), fallback = "unknown:" + root
        func volume(canonicalRoot: String) -> String {
            guard injected == nil else { return canonicalRoot }   // a test's resolver answers the volume whole
            let path = Self.derivedPath(of: folder, root: root, canonicalRoot: canonicalRoot)
            return Self.lexicalVolume(of: path, mounts: Self.mountTable(), caseInsensitive: Self.bootCaseInsensitive)
        }
        if let cached = lock.withLock({ resolved[root] }) { return volume(canonicalRoot: cached) }
        guard lock.withLock({ resolving.insert(root).inserted }) else { return fallback }
        let answer: Result<String?, Error> = await boundedReply("folder volume", seconds: Self.remaining(deadline)) { done in
            self.resolveQueue.async { [self] in
                let value = injected.map { $0(root) } ?? Self.canonicalPath(of: root)
                lock.withLock {
                    if let value { resolved[root] = value }
                    resolving.remove(root)
                }
                done(.success(value))
            }
        }
        guard case .success(let value) = answer else {
            Logger.state.error("Which volume a recording folder is on did not answer in time — its read goes on its root's own queue")
            return fallback
        }
        guard let value else { return fallback }   // a link cycle
        return volume(canonicalRoot: value)
    }

    /// `folder`, under `root`, spelled from the root's canonical path (L reviews 237, 268): the rest of its path appended
    /// LEXICALLY — with its leading slash, a root of `/` included.
    static func derivedPath(of folder: String, root: String, canonicalRoot: String) -> String {
        let folder = normalised(folder)
        let rest = root == "/" ? (folder == "/" ? "" : folder) : String(folder.dropFirst(root.count))   // "" or "/…"
        guard canonicalRoot != "/" else { return rest.isEmpty ? "/" : rest }
        return canonicalRoot + rest
    }

    /// A mounted file system as the kernel last knew it: where it is mounted, and whether it is local.
    struct Mount: Equatable, Sendable {
        let path: String
        let isLocal: Bool
    }

    /// The volume `folder` is on — its mount point — or "unknown", as the mount table stands now. Reads the links of a LOCAL
    /// volume only (never on a share): blocking file-system work — the reader runs it off the pool, bounded.
    static func volume(of folder: String) -> String {
        volume(of: folder, mounts: mountTable(), readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
               caseInsensitive: bootCaseInsensitive)
    }

    /// `volume(of:)`, pure: `mounts` the mount table, `readLink` a link's destination (nil: not a link).
    static func volume(of folder: String, mounts: [Mount], readLink: (String) -> String?, caseInsensitive: Bool = false) -> String {
        guard !mounts.isEmpty,
              let path = canonicalPath(of: folder, mounts: mounts, readLink: readLink, caseInsensitive: caseInsensitive) else { return "unknown" }
        return lexicalVolume(of: path, mounts: mounts, caseInsensitive: caseInsensitive)
    }

    /// `folder`'s canonical path (L review 209): the production resolution, run only off the pool, bounded. It learns the boot
    /// volume's case sensitivity once, too — and matches the mount points with it (L review 238).
    static func canonicalPath(of folder: String) -> String? {
        learnBootCaseSensitivity()
        return canonicalPath(of: folder, mounts: mountTable(), readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                             caseInsensitive: bootCaseInsensitive)
    }

    /// `folder` with every symbolic link in its path substituted while the path so far lies on a LOCAL volume — nothing on a
    /// share is ever read (L review 160), whatever the spelling it is reached by: the Data volume's firmlinked one, or another
    /// case of its mount point on a case-insensitive boot volume (L review 238). nil for a link cycle (40 links).
    static func canonicalPath(of folder: String, mounts: [Mount], readLink: (String) -> String?, caseInsensitive: Bool = false) -> String? {
        var remaining = folder.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { _ = resolved.popLast(); continue }
            let next = "/" + (resolved + [part]).joined(separator: "/")
            // On a share (or any volume that is not local) nothing more is read: the rest of the path stands as it is.
            guard let here = lexicalMount(of: next, mounts: mounts, caseInsensitive: caseInsensitive), here.isLocal else {
                return "/" + (resolved + [part] + remaining).joined(separator: "/")
            }
            guard let destination = readLink(next) else {
                resolved.append(part)
                continue
            }
            links += 1
            guard links <= 40 else { return nil }   // a link cycle
            if destination.hasPrefix("/") { resolved = [] }
            remaining = destination.split(separator: "/").map(String.init) + remaining
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Where the Data volume is mounted: its folders are firmlinked at `/` (`/System/Volumes/Data/Users` is `/Users`).
    static let dataVolume = "/System/Volumes/Data"

    /// The mount `path` is on — LEXICALLY, no file-system call (L reviews 209, 214): the longest mount point it lies under,
    /// the Data volume's firmlinked spelling as `/`, and — on a case-insensitive boot volume — whatever the case of the
    /// mount point's spelling. "unknown" with no mount table.
    static func lexicalVolume(of path: String, mounts: [Mount], caseInsensitive: Bool) -> String {
        guard !mounts.isEmpty else { return "unknown" }
        return lexicalMount(of: path, mounts: mounts, caseInsensitive: caseInsensitive)?.path ?? "unknown"
    }

    /// The mount `path` lies on, lexically (L reviews 214, 238, 241): both the path and every mount point are read in their
    /// firmlinked spelling — the Data volume's folders at `/`, an automount the table spells under the Data volume
    /// (`/System/Volumes/Data/home`) at `/home` — the Data volume itself standing for `/`, and case-insensitively when asked.
    static func lexicalMount(of path: String, mounts: [Mount], caseInsensitive: Bool) -> Mount? {
        let spell = { (p: String) in caseInsensitive ? firmlinked(p, caseInsensitive: true).lowercased() : firmlinked(p, caseInsensitive: false) }
        let target = spell(path)
        return mounts.filter { $0.path != dataVolume }.map { (mount: $0, point: spell($0.path)) }
            .filter { $0.point == "/" || target == $0.point || target.hasPrefix($0.point + "/") }
            .max { $0.point.count < $1.point.count }?.mount
    }

    /// `path` as the firmlinks spell it: `/System/Volumes/Data/…` is `/…`.
    private static func firmlinked(_ path: String, caseInsensitive: Bool) -> String {
        let spelled = caseInsensitive ? path.lowercased() : path, data = caseInsensitive ? dataVolume.lowercased() : dataVolume
        return spelled == data ? "/" : spelled.hasPrefix(data + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }

    /// Whether the boot volume — where mount points live — is case-insensitive: learned once, by the bounded resolution;
    /// case-sensitive (exact) until then.
    static var bootCaseInsensitive: Bool { caseLock.withLock { bootCaseInsensitiveValue ?? false } }
    private static let caseLock = NSLock()
    nonisolated(unsafe) private static var bootCaseInsensitiveValue: Bool?
    private static func learnBootCaseSensitivity() {
        guard caseLock.withLock({ bootCaseInsensitiveValue == nil }) else { return }
        let sensitive = pathconf("/", _PC_CASE_SENSITIVE)
        caseLock.withLock { bootCaseInsensitiveValue = sensitive == 0 }
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
