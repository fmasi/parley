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
/// - Every event is also appended to `<session>.diag.live.jsonl` as it happens (queued: an app crash loses only
///   the lines still queued, and every exit flushes them first — L review 96); building the record merges it
///   back, deduplicated. It is deleted only when the session is COMMITTED, once its transcript exists (L review
///   97): a crash while the transcript is written is salvaged with all of it.
/// - Every status pull's coverage is kept per helper session (council A-I4 / C-I1). At finalize a helper
///   session's latest snapshot stands in for the `captureStop` a crashed helper never wrote; a
///   `captureStop` of that helper session, when there is one, supersedes it (never counted twice).
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
    /// Sessions whose `.diag.jsonl` could not be written: their live log is their only record, never committed away.
    private var unwrittenRecords: Set<String> = []
    /// The record files THIS process wrote, by path (L review 139). Whether a build may write over an existing record
    /// is decided by provenance, never by binding: only a file this process wrote is ever written again — a relaunch
    /// binds the session it salvages, and the recording's own `.diag.jsonl` (another process's) is still never touched.
    private var ownRecordFiles: Set<String> = []
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
    /// The bound on those reads, in awake seconds. Tests shorten it.
    var folderDeadline: Double = 5

    /// `maxEvents`: the ring's bound (tests shrink it).
    public init(maxEvents: Int = 5000, folderReads: FolderReads = .shared) {
        diagnostics = CaptureDiagnostics(maxEvents: maxEvents)
        self.folderReads = folderReads
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
        if liveLog == nil { liveLog = LiveDiagnosticsLog(directory: directory, sessionId: sessionId) }
        session = (Self.key(directory), sessionId)
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
    /// record built from the ring alone, which says so, and its live log is kept.
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
        let log = (bound ? liveLog : nil) ?? LiveDiagnosticsLog(directory: directory, sessionId: sessionId)
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
        let own = ownRecordFiles, taken = ring
        let built = await folderReads.read("evidence: build", folder: directory.path, key: recordKey + "#build", seconds: folderDeadline) {
            Self.build(ring: taken, log: log, sessionId: sessionId, directory: directory, ownFiles: own)
        }
        var merged: CaptureDiagnostics
        if let built {
            merged = built.record
            if let written = built.written {
                ownRecordFiles.insert(written)
                unwrittenRecords.remove(recordKey)
            } else if built.writeFailed {
                unwrittenRecords.insert(recordKey)
            }
        } else {
            // Nothing could be read or written: the ring alone, said — and its live log is its record, never committed.
            Logger.files.error("The recording folder did not answer the record's build — built from this process's events alone, its live log kept")
            merged = ring
            merged.record(CaptureEvent(timestamp: Date(), origin: .app, kind: .folderNotAnswering, severity: .anomaly,
                                       detail: ["during": "the diagnostic record's build"]))
            unwrittenRecords.insert(recordKey)
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
    nonisolated private static func build(ring: CaptureDiagnostics, log: LiveDiagnosticsLog, sessionId: String, directory: URL,
                                          ownFiles: Set<String>) -> Built {
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
                             detail: snapshot.facts.merging(["helper_session": helper, "from": "status pull"]) { _, new in new })
            }
        if !standIns.isEmpty { merged.merge(standIns) }
        guard merged.isAnomalous else { return Built(record: merged) }
        let url = recordURL(sessionId: sessionId, directory: directory, ownFiles: ownFiles)
        do {
            try merged.jsonlData().write(to: url, options: .atomic)
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

    /// Where the record goes (L review 139): `<session>.diag.jsonl`, unless it exists and this process did not write it;
    /// then `<session>.relaunch.diag.jsonl`, `-2`, `-3`… — the first that is this process's own or free. Never over a
    /// record another process wrote.
    nonisolated private static func recordURL(sessionId: String, directory: URL, ownFiles: Set<String>) -> URL {
        var candidates = [directory.appendingPathComponent("\(sessionId).diag.jsonl"),
                          directory.appendingPathComponent("\(sessionId).relaunch.diag.jsonl")]
        var n = 2
        while true {
            for url in candidates where ownFiles.contains(key(url)) || !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            candidates = [directory.appendingPathComponent("\(sessionId).relaunch-\(n).diag.jsonl")]
            n += 1
        }
    }

    nonisolated private static func recordKey(_ sessionId: String, _ directory: URL) -> String { key(directory) + "\u{0}" + sessionId }

    /// The session's transcript is on disk (L review 97): its live log and coverage go — unless its `.diag.jsonl`
    /// could not be written, when the live log is its only record and stays. The delete is queued behind the folder's
    /// writes: never a wait on the folder here (L review 158).
    public func commit(sessionId: String, directory: URL) {
        let recordKey = Self.recordKey(sessionId, directory)
        recordEpochs[recordKey, default: 0] += 1
        guard unwrittenRecords.remove(recordKey) == nil else {
            Logger.files.error("The session's diagnostics file could not be written — its live log is kept")
            return
        }
        LiveDiagnosticsLog(directory: directory, sessionId: sessionId).deleteQueued()
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
            Logger.state.info("\(events.count, privacy: .public) helper events name no helper session — not attributed")
            return
        }
        let epochs = recordEpochs
        let reads = folderReads, seconds = folderDeadline
        let known = await withTaskGroup(of: (Int, Set<String>?).self) { group in
            for (i, session) in sessions.enumerated() {
                group.addTask {
                    let key = Self.recordKey(session.sessionId, session.directory)
                    return (i, await reads.read("evidence: known helpers", folder: session.directory.path, key: key + "#known", seconds: seconds) {
                        let log = LiveDiagnosticsLog(directory: session.directory, sessionId: session.sessionId)
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
            Logger.state.info("\(events.count, privacy: .public) helper events of helper sessions no one pending recording wholly knows — not attributed")
            return
        }
        let ownerKey = Self.recordKey(owner.sessionId, owner.directory)
        guard recordEpochs[ownerKey] == epochs[ownerKey] else {
            Logger.state.error("\(events.count, privacy: .public) helper events were attributed after their recording's record was made — dropped")
            return
        }
        let log = LiveDiagnosticsLog(directory: owner.directory, sessionId: owner.sessionId)
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
