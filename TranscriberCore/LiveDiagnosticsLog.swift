import Foundation
import os

/// Append-as-you-go anomaly log (§8.11): `<session>.diag.live.jsonl` next to the recording. Written line by line,
/// queued (below): an app crash, a force-quit or a kill loses the lines still queued — normally none, each write takes a
/// moment. An orderly exit flushes them first, bounded (L reviews 96, 141): the Quit and the termination preparation,
/// every `NSApp.terminate` (`applicationWillTerminate`), and the crash-protection hand-over's `exit(0)`; a folder that
/// does not answer within the bound keeps its queued lines, and they go with the process. Merged into the ring when the
/// record is built, and deleted only once the session's transcript exists (L review 97).
///
/// Beside it, `<session>.diag.coverage.json` keeps the LATEST coverage of each helper session (council
/// A-I4 / C-I1): coverage otherwise lives only in `captureStop`, which a crashed helper never writes. One
/// small file, rewritten atomically on every status pull, whatever the length of the call.
///
/// Every file operation runs on a serial background queue (L11 review 65): the app appends and pulls coverage on the
/// main actor, and a slow disk must never stall it. Writes are queued; reads and blocking deletes wait for the writes
/// queued before them. ONE queue per folder (L review 158): every log of a folder shares it — a second instance for the
/// same session (a salvage, a relaunch's resume) sees what the first one queued — while a write that hangs on one folder
/// (a dead share) never holds up another folder's reads. The reads block: callers run them off the main actor, bounded.
public final class LiveDiagnosticsLog: @unchecked Sendable {
    public let url: URL
    public let coverageURL: URL
    /// Guards `coverageCache` and `writeObserver`.
    private let lock = NSLock()
    /// This log's folder's queue.
    private let io: DispatchQueue

    /// One serial queue per folder, by its lexical key (`/private` stripped before the firmlinked roots, L review 168). The
    /// app's logs share `shared`, which the exit's flush walks; a test that hangs a folder's queue uses its own set, so it
    /// never holds up another test's flush (L review 205).
    public final class Queues: @unchecked Sendable {
        /// The app's.
        public static let shared = Queues()
        private let lock = NSLock()
        private var queues: [String: DispatchQueue] = [:]

        public init() {}

        func queue(for directory: URL) -> DispatchQueue {
            let key = SessionEvidence.key(directory)
            return lock.withLock {
                if let queue = queues[key] { return queue }
                let queue = DispatchQueue(label: "eu.fmasi.parley.live-diagnostics.\(queues.count)", qos: .utility)
                queues[key] = queue
                return queue
            }
        }

        /// Returns once every write queued on these queues — by any log, in any folder — is on disk. Blocks: the caller
        /// bounds it (an exit runs it off the main actor under a deadline, L review 96).
        public func flushAll() {
            for queue in lock.withLock({ Array(queues.values) }) { queue.sync {} }
        }

        /// `flushAll`, bounded (L review 141): true when everything queued reached the disk within `seconds`; false when a
        /// folder did not answer — its queued lines are then lost with the process.
        @discardableResult
        public func flushAll(within seconds: Double) -> Bool {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                self.flushAll()
                done.signal()
            }
            return done.wait(timeout: .now() + seconds) == .success
        }
    }
    /// Runs on the write queue before each write. Internal for tests.
    var writeObserver: (@Sendable () -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }
    private var observer: (@Sendable () -> Void)?

    /// One helper session's coverage (`remote_*` / `local_*` detail keys) as last pulled.
    public struct CoverageSnapshot: Codable, Equatable, Sendable {
        public let at: Date
        public let facts: [String: String]
        public init(at: Date, facts: [String: String]) { self.at = at; self.facts = facts }
    }
    /// Loaded from disk on first use (an earlier process may have written it), then kept in memory. Only ever loaded
    /// and updated on the folder's queue.
    private var coverageCache: [String: CoverageSnapshot]?

    // `.iso8601` (JSONEncoder's built-in strategy) drops sub-second precision, so a disk round-trip
    // and an in-memory ring event for the SAME anomaly would decode to different timestamps and
    // dedup would never match. Encode/decode with millisecond precision instead.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LiveDiagnosticsLog.dateFormatter.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = LiveDiagnosticsLog.dateFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date with fractional seconds: \(s)")
            }
            return date
        }
        return d
    }()

    /// `queues`: the set of per-folder queues this log's io runs on — the app's (`Queues.shared`), or a test's own.
    public init(directory: URL, sessionId: String, queues: Queues = .shared) {
        url = directory.appendingPathComponent("\(sessionId).diag.live.jsonl")
        coverageURL = directory.appendingPathComponent("\(sessionId).diag.coverage.json")
        io = queues.queue(for: directory)
    }

    /// Coverage evidence is `.info`, yet it is what the record's per-track coverage is built from: kept
    /// whatever its severity, or a crash loses every second of coverage before it (L11 ruling).
    static let coverageKinds: Set<CaptureEventKind> = [.captureStop, .trackCoverage]

    public func append(_ event: CaptureEvent) {
        guard event.severity != .info || Self.coverageKinds.contains(event.kind) else { return }
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        let url = url, observer = writeObserver
        io.async {
            observer?()
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else if (try? line.write(to: url, options: .atomic)) == nil {
                Logger.files.error("LiveDiagnosticsLog: could not write \(url.lastPathComponent, privacy: .sensitive)")
            }
        }
    }

    /// Returns once every write the app's logs queued — in any folder — is on disk. Blocks: the caller bounds it (an exit
    /// runs it off the main actor under a deadline, L review 96).
    public static func flushAll() { Queues.shared.flushAll() }

    /// `flushAll`, bounded, for the process's last moments (L review 141): `applicationWillTerminate` and the
    /// crash-protection hand-over's `exit(0)` call it on the main thread, where nothing may wait on a hung folder for
    /// long. True when everything queued reached the disk within `seconds`; false when a folder did not answer — its
    /// queued lines are then lost with the process.
    @discardableResult
    public static func flushAll(within seconds: Double) -> Bool { Queues.shared.flushAll(within: seconds) }

    /// Returns once every write queued before it — in this log's folder — is on disk.
    public func flush() {
        io.sync {}
    }

    /// Blocks until the folder's queued writes are done: never on the main actor (L review 158).
    public func events() -> [CaptureEvent] {
        let url = url
        guard let data = io.sync(execute: { try? Data(contentsOf: url) }) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(CaptureEvent.self, from: $0) }
    }

    public func merged(into ring: CaptureDiagnostics) -> CaptureDiagnostics {
        // Same identity `CaptureDiagnostics` uses internally to make its own counting idempotent
        // (E2 fix round 1) — one definition, so the two can never drift apart.
        var seen = Set<String>()
        var result = ring
        var extra: [CaptureEvent] = []
        for e in ring.events { seen.insert(CaptureEvent.dedupKey(e)) }
        for e in events() where seen.insert(CaptureEvent.dedupKey(e)).inserted { extra.append(e) }
        result.merge(extra)
        return result
    }

    /// Keep `facts` as `helperSession`'s latest coverage. Never blocks the caller (L review 158): the map is read —
    /// an earlier process's, once — updated and written on the folder's queue, in the order the writes were made, so
    /// an older map is never the last one on disk (L review 102).
    public func writeCoverage(helperSession: String, facts: [String: String], at date: Date) {
        let snapshot = CoverageSnapshot(at: date, facts: facts)
        let coverageURL = coverageURL, observer = writeObserver
        io.async { [self] in
            observer?()
            let all = lock.withLock { () -> [String: CoverageSnapshot] in
                var all = coverageCache ?? Self.readCoverage(coverageURL)
                all[helperSession] = snapshot
                coverageCache = all
                return all
            }
            guard let data = try? Self.encoder.encode(all) else { return }
            if (try? data.write(to: coverageURL, options: .atomic)) == nil {
                Logger.files.error("LiveDiagnosticsLog: could not write \(coverageURL.lastPathComponent, privacy: .sensitive)")
            }
        }
    }

    /// The latest coverage of every helper session of this recording session, by helper session id, after the writes
    /// queued before it (an earlier instance's included). Blocks: never on the main actor.
    public func coverageSnapshots() -> [String: CoverageSnapshot] {
        let coverageURL = coverageURL
        return io.sync { lock.withLock { coverageCache ?? Self.readCoverage(coverageURL) } }
    }

    private static func readCoverage(_ url: URL) -> [String: CoverageSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([String: CoverageSnapshot].self, from: data)) ?? [:]
    }

    /// Deletes the log and its coverage, after the writes queued before it. Blocks: never on the main actor.
    public func delete() {
        io.sync { removeFiles() }
    }

    /// `delete`, queued behind the folder's writes — the caller never waits on the folder (L review 158).
    public func deleteQueued() {
        io.async { [self] in removeFiles() }
    }

    private func removeFiles() {
        lock.withLock { coverageCache = nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: coverageURL)
    }
}
