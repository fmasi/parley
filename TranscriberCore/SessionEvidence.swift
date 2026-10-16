import Darwin
import Foundation
import os

/// The app's capture evidence for the recording session in progress (§8.11): the diagnostic ring, the
/// live log beside the recording, and the latest coverage of every helper session. The XPC client owns
/// one for the app's lifetime.
///
/// - A NEW session resets everything (council A-C1 / C-C1): no later recording inherits an earlier one's
///   coverage, content anomalies, confirmed denial, retries or recoveries. A session is its folder AND its
///   id (L11 review 66): ids are `HHmmss-<name>` with no date, so a recurring meeting started at the same
///   second on another day has the same id in another day folder. The SAME session — an in-session restart,
///   or a relaunch that resumes it — keeps it all; a finalized one is never continued.
/// - Every event is also appended to `<session>.diag.live.jsonl` as it happens (queued: a crash or a force-quit loses
///   the lines still queued; an orderly exit flushes them first, bounded — L reviews 96, 141); building the record merges it
///   back, deduplicated. It is deleted only when the session is COMMITTED, once its transcript exists (L review
///   97): a crash while the transcript is written is salvaged with all of it.
/// - Every status pull's coverage is kept per helper session (council A-I4 / C-I1). At finalize a helper
///   session's latest snapshot stands in for the `captureStop` a crashed helper never wrote; a
///   `captureStop` of that helper session, when there is one, supersedes it (never counted twice) — also when it
///   arrives after a finalize that already counted the stand-in: it replaces it at the next one (#229).
/// - Nothing here waits on a recording folder on the main actor (L review 158): the record's build — its reads of the
///   live log and its write of `.diag.jsonl` — runs through `FolderReads`, bounded; appends, coverage writes and the
///   commit's delete are queued on the folder's own queue.

@MainActor
public final class SessionEvidence {
    public private(set) var diagnostics: CaptureDiagnostics
    /// The session bound now; nil before the first capture, and once a session is finalized or discarded.
    public var sessionId: String? { session?.id }
    private var session: (directory: String, id: String)?
    private var liveLog: LiveDiagnosticsLog?
    /// The last finalized session and its record: a second finalize of it (a salvage after its transcript
    /// failed) continues it; any other session never sees it (L11 review 66).
    private var finalized: (directory: String, id: String, record: CaptureDiagnostics)?
    /// Sessions whose `.diag.jsonl` could not be written: their live log is their only record, never committed away. The
    /// mark stays until a SUCCESSFUL write (L review 200) — a commit never removes it, so no later commit deletes the only
    /// copy. By record key, with the build that left it unwritten: a write of that build — or a later one — that lands late
    /// clears it (L review 246).
    private var unwrittenRecords: [String: Int] = [:]
    /// The record files THIS process wrote, by path (L review 139). Whether a build may write over an existing record
    /// is decided by provenance, never by binding: only a file this process wrote is ever written again — a relaunch
    /// binds the session it salvages, and the recording's own `.diag.jsonl` (another process's) is still never touched.
    /// Shared with the build off the main actor: a build that timed out and writes later still registers its file, so a
    /// later build of the session updates it — never a misleading `.relaunch` beside it (L review 204).
    private let ownRecordFiles = OwnRecords()

    /// The record files this process wrote: written from the build's queue, read by the next build. And, by record key, the
    /// latest build whose write landed — whenever it landed (L review 246).
    final class OwnRecords: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        private var landed: [String: Int] = [:]
        private var landedHandler: (@Sendable (String, Int) -> Void)?
        func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
        func insert(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        /// A write of `build` landed — however late: registered, and handed to the handler (L review 268).
        func noteWritten(_ recordKey: String, build: Int) {
            let handler = lock.withLock { () -> (@Sendable (String, Int) -> Void)? in
                landed[recordKey] = max(landed[recordKey] ?? build, build)
                return landedHandler
            }
            handler?(recordKey, build)
        }
        func writtenBuild(_ recordKey: String) -> Int? { lock.withLock { landed[recordKey] } }
        /// Told of every write that lands (L review 268).
        func onLanded(_ handler: @escaping @Sendable (String, Int) -> Void) { lock.withLock { landedHandler = handler } }
    }
    /// The live logs a commit kept because their record was not written yet (L review 268), by record key: a late write that
    /// lands after the commit lets them go then.
    private var keptLiveLogs: [String: (sessionId: String, directory: URL)] = [:]
    /// Bumped whenever a session's record is built or committed, by session (L review 142): an attribution that answers
    /// after that never appends to its live log.
    private var recordEpochs: [String: Int] = [:]
    /// Which session the evidence is bound to, as a tag: bumped whenever a NEW session binds, and when one
    /// ends. A helper call is tagged with it when made; what it records later for another binding is dropped
    /// (L9 review 52).
    public private(set) var epoch = 0
    /// Where the record's build and the attribution read the recording folders: off the main actor, bounded, on the
    /// folder's volume's queue (L reviews 158, 160).
    let folderReads: FolderReads
    /// The live logs' per-folder queues: the app's, or a test's own (L review 205).
    let logQueues: LiveDiagnosticsLog.Queues
    /// How a record file is looked at and created (L review 199). Tests inject a `stat` that errs.
    let recordFiles: RecordFiles
    /// The default bound on those reads: what a caller bounding a whole attribution adds to the drain's (L review 205).
    public nonisolated static let folderDeadlineSeconds: Double = 5
    /// The bound on those reads, in awake seconds. Tests shorten it.
    var folderDeadline: Double = SessionEvidence.folderDeadlineSeconds

    /// `maxEvents`: the ring's bound (tests shrink it).
    public init(maxEvents: Int = 5000, folderReads: FolderReads = .shared, logQueues: LiveDiagnosticsLog.Queues = .shared,
                recordFiles: RecordFiles = .live) {
        diagnostics = CaptureDiagnostics(maxEvents: maxEvents)
        self.folderReads = folderReads
        self.logQueues = logQueues
        self.recordFiles = recordFiles
        ownRecordFiles.onLanded { [weak self] key, build in
            Task { @MainActor in self?.recordLanded(key, build: build) }
        }
    }

    /// A record's write landed — perhaps long after its build timed out (L reviews 246, 268): the mark it left is cleared at
    /// once, and a live log a commit kept meanwhile, because it was then the only record, goes now.
    private func recordLanded(_ recordKey: String, build: Int) {
        guard let marked = unwrittenRecords[recordKey], build >= marked else { return }
        unwrittenRecords[recordKey] = nil
        guard let kept = keptLiveLogs.removeValue(forKey: recordKey) else { return }
        Logger.files.info("A diagnostics record landed after its session was committed — its live log goes now")
        LiveDiagnosticsLog(directory: kept.directory, sessionId: kept.sessionId, queues: logQueues).deleteQueued()
    }

    /// The file-system calls that decide where a record goes (L review 199).
    public struct RecordFiles: Sendable {
        /// `lstat`: 0 when there is something at the path, else its errno — ENOENT alone means "free".
        var stat: @Sendable (String) -> Int32
        /// `renamex_np(RENAME_EXCL)`: 0, or its errno (EEXIST: the name is taken; ENOTSUP/EINVAL: the volume cannot).
        var renameExclusively: @Sendable (String, String) -> Int32

        public static let live = RecordFiles(
            stat: { path in
                var st = Darwin.stat()
                return lstat(path, &st) == 0 ? 0 : errno
            },
            renameExclusively: { from, to in renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
        )
    }

    /// A drain of the helper's ring, as it came back (L reviews 142, 203).
    public enum HelperDrain: Sendable {
        case data(Data)
        /// No connection, or the helper had nothing: answered.
        case nothing
        /// The XPC call failed: the helper's events, if any, are still with it.
        case failed
        /// No answer within its bound.
        case timedOut
    }

    /// A drain into the ring: false when it timed out (the caller records that into the session it concerns). A drain that
    /// FAILED is on record — `helperDrainFailed` — never only a log line (L review 203).
    public func mergeDrain(_ drain: HelperDrain) -> Bool {
        switch drain {
        case .timedOut:
            return false
        case .failed:
            Logger.state.error("The capture helper's drainDiagnostics failed — its events stay with it; the record says so")
            record(CaptureEvent(timestamp: Date(), origin: .app, kind: .helperDrainFailed, severity: .anomaly, detail: ["call": "drainDiagnostics"]))
            return true
        case .nothing:
            return true
        case .data(let data):
            mergeHelperDrain(data)
            return true
        }
    }

    /// The folder half of a session's key: lexical (`standardized`), never a file-system lookup — a hung share must
    /// not be touched to compute it (L review 101). `/private` before the macOS firmlinked roots (`/var`, `/tmp`,
    /// `/etc`) is stripped as a string (L review 168): `/private/var/…` and `/var/…` are one folder, one session.
    nonisolated static func key(_ directory: URL) -> String {
        let path = directory.standardized.path
        for root in ["/var", "/tmp", "/etc"] where path == "/private" + root || path.hasPrefix("/private" + root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func isBound(to sessionId: String, in directory: URL) -> Bool {
        guard let session else { return false }
        let key = Self.key(directory)
        if session.id == sessionId, session.directory != key {
            // Two sessions of one name in two folders: never merged — said.
            Logger.state.error("A session id matches the bound one, but not its folder — kept apart")
        }
        return session.id == sessionId && session.directory == key
    }

    /// A capture starts, of `sessionId`, recording into `directory`.
    public func beginCapture(sessionId: String, directory: URL) {
        if !isBound(to: sessionId, in: directory) {
            diagnostics.resetSession()
            liveLog = nil
            finalized = nil
            epoch += 1
        }
        // The same session resumed by a relaunch finds the earlier process's live log and appends to it.
        if liveLog == nil { liveLog = LiveDiagnosticsLog(directory: directory, sessionId: sessionId, queues: logQueues) }
        session = (Self.key(directory), sessionId)
    }

    /// A capture starts, after the start's drain of the previous helper (L reviews 146, 203, 243): what the drain brought is
    /// merged BEFORE the session's reset — the previous helper's events — while a drain that FAILED is this start's news,
    /// recorded AFTER it, into the session starting: the reset never wipes it. False when the drain timed out (the caller
    /// records that, as its own).
    public func beginCapture(sessionId: String, directory: URL, after drain: HelperDrain) -> Bool {
        if case .failed = drain {
            beginCapture(sessionId: sessionId, directory: directory)
            return mergeDrain(drain)
        }
        let answered = mergeDrain(drain)
        beginCapture(sessionId: sessionId, directory: directory)
        return answered
    }

    /// An app-origin event: into the ring and, as it happens, the live log.
    public func record(_ event: CaptureEvent) {
        diagnostics.record(event)
        liveLog?.append(event)
    }

    /// An event of the call made in `epoch`: recorded only if that session is still the one bound — a late
    /// timeout of an earlier session's call never lands in the next recording's record (L9 review 52).
    public func record(_ event: CaptureEvent, madeIn epoch: Int) {
        guard epoch == self.epoch else {
            Logger.state.info("A \(event.kind.rawValue, privacy: .public) of an earlier session arrived late — not recorded")
            return
        }
        record(event)
    }

    /// A helper drain as it came off the wire (R2 item 8, L review 93): through `mergeDrained`, so an event this
    /// build cannot decode (a kind from a newer helper) is counted into `events_dropped`, never silently lost.
    /// The decoded events go to the live log too. The one way helper events come in (L review 153).
    public func mergeHelperDrain(_ data: Data) {
        diagnostics.mergeDrained(data)
        guard let liveLog else { return }
        for event in CaptureDiagnostics.events(from: data) { liveLog.append(event) }
    }

    /// A status pull: its coverage becomes that helper session's latest. Only a CAPTURING helper's: a pull
    /// that raced a stop reports the whole expected time with nothing delivered (L11 review 67).
    public func noteCoverage(_ snapshot: CaptureStatusSnapshot, at date: Date = Date()) {
        guard snapshot.isCapturing, let facts = snapshot.coverage, !facts.isEmpty, let liveLog else { return }
        liveLog.writeCoverage(helperSession: facts["helper_session"] ?? snapshot.helperSessionId, facts: facts, at: date)
    }

    /// BUILDS the session's record, for its provenance and `.diag.jsonl` (L review 97): the ring, the live log
    /// (this process's, or an earlier one's for a session salvaged or resumed after a crash), and the latest
    /// coverage of every helper session that wrote no `captureStop`. The live log is NOT deleted here: that is
    /// `commit`, once the transcript exists.
    ///
    /// When the session was anomalous, `<session>.diag.jsonl` is written, atomically; if it cannot be, the failure
    /// is on record and the live log is never committed away (L11 review 61). A record file another process wrote —
    /// the recording's own, or an earlier relaunch's — is never written over (L review 139): the record goes beside it
    /// as `<session>.relaunch.diag.jsonl` (then `-2`, `-3`…). The session then ends: nothing continues it (L11 review
    /// 66). A second finalize of the same session (a salvage after its transcript failed) still finds everything, and
    /// updates the file this process wrote.
    ///
    /// The folder is read and written off the main actor, bounded (L review 158): a folder that does not answer gets a
    /// record built from the ring alone, which says so — its coverage marked a lower bound (#229) — and its live log is kept.
    public func finalize(sessionId: String, directory: URL) async -> CaptureDiagnostics {
        let bound = isBound(to: sessionId, in: directory)
        // The ring is this session's when bound to it, or — nothing bound (a salvage at launch) — the events
        // recorded since, on top of this session's own record when it was finalized before. Never another
        // session's (L11 review 66).
        let ownsRing = bound || session == nil
        var ring = ownsRing ? diagnostics : CaptureDiagnostics(maxEvents: diagnostics.maxEvents)
        if !bound, ownsRing, let earlier = finalized, earlier.id == sessionId, earlier.directory == Self.key(directory) {
            var continued = earlier.record
            continued.merge(ring.events)
            ring = continued
        }
        let log = (bound ? liveLog : nil) ?? LiveDiagnosticsLog(directory: directory, sessionId: sessionId, queues: logQueues)
        // The session ends NOW, before the build's first await: nothing recorded meanwhile belongs to it, and nothing
        // the build does later touches a session bound meanwhile.
        if ownsRing { diagnostics = CaptureDiagnostics(maxEvents: diagnostics.maxEvents) }
        if bound {
            liveLog = nil
            session = nil
            epoch += 1
        }
        let recordKey = Self.recordKey(sessionId, directory)
        recordEpochs[recordKey, default: 0] += 1
        let build = recordEpochs[recordKey] ?? 0
        let own = ownRecordFiles, taken = ring, files = recordFiles
        let built = await folderReads.read("evidence: build", folder: directory.path, key: recordKey + "#build", seconds: folderDeadline) {
            Self.build(ring: taken, log: log, sessionId: sessionId, directory: directory, own: own, files: files,
                       registering: (recordKey, build))
        }
        var merged: CaptureDiagnostics
        if let built {
            merged = built.record
            merged.coverageIsLowerBound = false   // the folder was read: an earlier build's mark no longer holds
            if built.written != nil {
                unwrittenRecords[recordKey] = nil   // written: the record has a copy beside the live log now
            } else if built.writeFailed {
                unwrittenRecords[recordKey] = build
            }
        } else {
            // Nothing could be read or written: the ring alone, said — and its live log is its record, never committed.
            Logger.files.error("The recording folder did not answer the record's build — built from this process's events alone, its live log kept")
            merged = ring
            // The live log and the crashed helpers' coverage are in that folder: what the ring holds is part of the
            // session, never stamped as the whole of it (#229) — both sides' seconds are lower bounds.
            merged.coverageIsLowerBound = true
            merged.record(CaptureEvent(timestamp: Date(), origin: .app, kind: .folderNotAnswering, severity: .anomaly,
                                       detail: ["during": "the diagnostic record's build"]))
            unwrittenRecords[recordKey] = build   // until its write lands, if it ever does (L review 246)
        }
        // Kept aside for a second finalize of this session — unless another session was bound meanwhile.
        if ownsRing, session == nil { finalized = (Self.key(directory), sessionId, merged) }
        return merged
    }

    /// What the build made: the record, and the file it wrote (its lexical path) or whether that write failed.
    private struct Built: @unchecked Sendable {
        var record: CaptureDiagnostics
        var written: String?
        var writeFailed = false
    }

    /// The build itself: blocking file-system work, run only through `folderReads`.
    /// `registering`: the record key and this build's number — a write that lands, however late, registers there (L review
    /// 246).
    nonisolated private static func build(ring: CaptureDiagnostics, log: LiveDiagnosticsLog, sessionId: String, directory: URL,
                                          own: OwnRecords, files: RecordFiles, registering: (key: String, build: Int)) -> Built {
        let logged = log.events()
        // Same identity `CaptureDiagnostics` uses internally to make its counting idempotent (E2 fix round 1).
        var seen = Set(ring.events.map(CaptureEvent.dedupKey))
        var merged = ring
        merged.merge(logged.filter { seen.insert(CaptureEvent.dedupKey($0)).inserted })
        // Which helper sessions stopped: from the log and the ring's out-of-ring tally, never the evicting
        // ring alone (L11 review 67).
        let stopped = merged.stoppedHelperSessions
            .union(logged.filter { $0.kind == .captureStop }.compactMap { $0.detail["helper_session"] })
        let standIns = log.coverageSnapshots()
            .filter { !stopped.contains($0.key) }
            .map { helper, snapshot in
                CaptureEvent(timestamp: snapshot.at, origin: .helper, kind: .captureStop, severity: .info,
                             detail: snapshot.facts.merging(["helper_session": helper, "from": CaptureDiagnostics.standInSource]) { _, new in new })
            }
        if !standIns.isEmpty { merged.merge(standIns) }
        guard merged.isAnomalous else { return Built(record: merged) }
        do {
            let url = try writeRecord(merged.jsonlData(), sessionId: sessionId, directory: directory, own: own, files: files)
            // This process's own from now on — even when the build that wrote it timed out long before (L review 204) — and
            // written: an "unwritten" mark its timeout left is cleared by it (L review 246).
            own.insert(key(url))
            own.noteWritten(registering.key, build: registering.build)
            Logger.files.info("Flushed capture diagnostics: \(url.lastPathComponent, privacy: .sensitive) (\(merged.events.count) events)")
            return Built(record: merged, written: key(url))
        } catch {
            Logger.files.error("Failed to flush diagnostics — keeping the live log: \(error, privacy: .private)")
            let failure = CaptureEvent(timestamp: Date(), origin: .app, kind: .sessionWriteFailed, severity: .anomaly,
                                       detail: ["file": "diag.jsonl", "error": error.localizedDescription])
            merged.record(failure)
            log.append(failure)
            return Built(record: merged, writeFailed: true)
        }
    }

    /// How many record names a build tries before it gives up (a folder where every name errs): the write then fails, and
    /// the live log is kept as the record.
    nonisolated static let recordNameLimit = 100

    /// Serializes the check-then-rename of a volume without an exclusive rename (L review 199): every record this process
    /// writes goes through it, so two builds never both find one name free.
    nonisolated private static let placingLock = NSLock()

    /// Writes the record where it goes (L reviews 139, 199): `<session>.diag.jsonl`, unless it is there and this process did
    /// not write it; then `<session>.relaunch.diag.jsonl`, `-2`, `-3`… — the first that is this process's own (updated in
    /// place) or free. A name this process did not write is CREATED EXCLUSIVELY: a temporary file, then `renamex_np` with
    /// `RENAME_EXCL` — EEXIST takes the next name — so a `stat` that lies (a share's stale cache) never lets it replace a
    /// record another process wrote. A `stat` that errs with anything but ENOENT (EIO, ESTALE, ETIMEDOUT) is a name taken,
    /// never a free one. A volume without the exclusive rename (exFAT, SMB: ENOTSUP) checks, then renames, under a lock.
    /// A record's temporary (L reviews 245, 268): short — a long title never makes it too long to create — and its session's,
    /// `.<fitted id>.diag.<UUID>.tmp`, so the session's next record sweeps one a write that died left.
    nonisolated static func temporaryName(sessionId: String) -> String { DurableFile.temporaryName(for: "\(sessionId).diag") }

    nonisolated static func writeRecord(_ data: Data, sessionId: String, directory: URL, own: OwnRecords, files: RecordFiles) throws -> URL {
        // A temporary a write of this session's record left when it died (L review 268): the records are written one at a
        // time, on the folder's queue, so any one there now is stale.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where DurableFile.isTemporary(name, for: "\(sessionId).diag") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        for n in 0..<recordNameLimit {
            let name = n == 0 ? "\(sessionId).diag.jsonl" : n == 1 ? "\(sessionId).relaunch.diag.jsonl" : "\(sessionId).relaunch-\(n).diag.jsonl"
            let url = directory.appendingPathComponent(name)
            if own.contains(key(url)) {
                try data.write(to: url, options: .atomic)   // this process's own record: updated
                return url
            }
            let looked = files.stat(url.path)
            guard looked == ENOENT else {
                if looked != 0 { Logger.files.error("A record name could not be looked at (errno \(looked, privacy: .public)) — taken as used") }
                continue
            }
            // Short, and its session's (L reviews 245, 268): a long title's record name never makes its temporary one too long.
            let temporary = directory.appendingPathComponent(temporaryName(sessionId: sessionId))
            try data.write(to: temporary)
            switch files.renameExclusively(temporary.path, url.path) {
            case 0:
                return url
            case EEXIST:
                try? FileManager.default.removeItem(at: temporary)
                Logger.files.error("A record name a look called free is taken — never written over; the next name is used")
            case ENOTSUP, EINVAL:
                let placed = placingLock.withLock { files.stat(url.path) == ENOENT && rename(temporary.path, url.path) == 0 }
                if placed { return url }
                try? FileManager.default.removeItem(at: temporary)
            case let code:
                try? FileManager.default.removeItem(at: temporary)
                throw DurableFile.posixError(code)
            }
        }
        throw DurableFile.posixError(EEXIST)
    }

    nonisolated private static func recordKey(_ sessionId: String, _ directory: URL) -> String { key(directory) + "\u{0}" + sessionId }

    /// The session's transcript is on disk (L review 97): its live log and coverage go — unless its `.diag.jsonl`
    /// could not be written, when the live log is its only record and stays. The delete is queued behind the folder's
    /// writes: never a wait on the folder here (L review 158).
    public func commit(sessionId: String, directory: URL) {
        let recordKey = Self.recordKey(sessionId, directory)
        recordEpochs[recordKey, default: 0] += 1
        // A write that landed after its build timed out — of the build that left the mark, or a later one — clears it (L
        // review 246): the record is on disk.
        if let marked = unwrittenRecords[recordKey], let landed = ownRecordFiles.writtenBuild(recordKey), landed >= marked {
            unwrittenRecords[recordKey] = nil
        }
        guard unwrittenRecords[recordKey] == nil else {
            Logger.files.error("The session's diagnostics file could not be written — its live log is kept")
            keptLiveLogs[recordKey] = (sessionId, directory)   // until a late write lands (L review 268)
            return
        }
        keptLiveLogs[recordKey] = nil
        LiveDiagnosticsLog(directory: directory, sessionId: sessionId, queues: logQueues).deleteQueued()
    }

    /// A pending retry's drain of the helper it stopped (L review 98). The events belong to the pending session whose
    /// live log knows EVERY helper session the batch names (L review 143: a subset — an anomaly carries no helper
    /// session, so the batch is attributed whole) — a `captureStop` of it, or a status pull's coverage — and are
    /// appended to THAT session's live log, which its salvage merges. A batch no pending session knows wholly, or more
    /// than one does, or whose sessions' folders did not all answer, is attributed to none: logged, never recorded under
    /// the wrong session, and never left in a ring for whichever session is finalized next.
    ///
    /// The folders are read off the main actor, each on its volume's queue, bounded (L reviews 123, 158, 160). An
    /// attribution that answers after its owner's record was built or committed appends nothing (L review 142).
    public func attributeHelperDrain(_ data: Data, toOneOf sessions: [(sessionId: String, directory: URL)]) async {
        let events = CaptureDiagnostics.events(from: data)
        guard !events.isEmpty else { return }
        let helpers = Set(events.compactMap { $0.detail["helper_session"] })
        guard !helpers.isEmpty else {
            Logger.state.error("\(events.count, privacy: .public) helper events name no helper session — not attributed")
            return
        }
        let epochs = recordEpochs
        let reads = folderReads, seconds = folderDeadline, queues = logQueues
        let known = await withTaskGroup(of: (Int, Set<String>?).self) { group in
            for (i, session) in sessions.enumerated() {
                group.addTask {
                    let key = Self.recordKey(session.sessionId, session.directory)
                    return (i, await reads.read("evidence: known helpers", folder: session.directory.path, key: key + "#known", seconds: seconds) {
                        let log = LiveDiagnosticsLog(directory: session.directory, sessionId: session.sessionId, queues: queues)
                        return Set(log.coverageSnapshots().keys).union(log.events().compactMap { $0.detail["helper_session"] })
                    })
                }
            }
            var known: [Int: Set<String>?] = [:]
            for await (i, set) in group { known[i] = set }
            return known
        }
        guard known.values.allSatisfy({ $0 != nil }) else {
            Logger.state.error("\(events.count, privacy: .public) helper events: a pending session's folder did not answer — not attributed")
            return
        }
        let owners = sessions.indices.filter { helpers.isSubset(of: (known[$0] ?? nil) ?? []) }
        guard owners.count == 1, let owner = owners.first.map({ sessions[$0] }) else {
            Logger.state.error("\(events.count, privacy: .public) helper events of helper sessions no one pending recording wholly knows — not attributed")
            return
        }
        let ownerKey = Self.recordKey(owner.sessionId, owner.directory)
        guard recordEpochs[ownerKey] == epochs[ownerKey] else {
            Logger.state.error("\(events.count, privacy: .public) helper events were attributed after their recording's record was made — dropped")
            return
        }
        let log = LiveDiagnosticsLog(directory: owner.directory, sessionId: owner.sessionId, queues: logQueues)
        for event in events { log.append(event) }
    }

    /// A start that never became a recording (L11 review 68): its evidence is dropped and its live log
    /// deleted — no orphan `.diag.live.jsonl` beside a recording that does not exist.
    public func discard(sessionId: String, directory: URL) {
        guard isBound(to: sessionId, in: directory) else { return }
        liveLog?.deleteQueued()
        liveLog = nil
        session = nil
        finalized = nil
        diagnostics.resetSession()
        epoch += 1
    }
}
