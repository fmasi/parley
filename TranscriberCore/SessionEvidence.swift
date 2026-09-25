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
    /// Which session the evidence is bound to, as a tag: bumped whenever a NEW session binds, and when one
    /// ends. A helper call is tagged with it when made; what it records later for another binding is dropped
    /// (L9 review 52).
    public private(set) var epoch = 0

    /// `maxEvents`: the ring's bound (tests shrink it).
    public init(maxEvents: Int = 5000) {
        diagnostics = CaptureDiagnostics(maxEvents: maxEvents)
    }

    /// The folder half of a session's key: lexical (`standardized`), never a file-system lookup — a hung share must
    /// not be touched to compute it (L review 101). Internal for tests.
    static func key(_ directory: URL) -> String { directory.standardized.path }

    private func isBound(to sessionId: String, in directory: URL) -> Bool {
        guard let session else { return false }
        let key = Self.key(directory)
        if session.id == sessionId, session.directory != key {
            // Two spellings of one folder, or two sessions of one name in two folders: never merged — said.
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

    /// Events drained from the helper: merged into the ring, and written to the live log so an app crash
    /// before finalize keeps them.
    public func mergeHelperEvents(_ events: [CaptureEvent]) {
        guard !events.isEmpty else { return }
        diagnostics.merge(events)
        for event in events { liveLog?.append(event) }
    }

    /// A helper drain as it came off the wire (R2 item 8, L review 93): through `mergeDrained`, so an event this
    /// build cannot decode (a kind from a newer helper) is counted into `events_dropped`, never silently lost.
    /// The decoded events go to the live log too.
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
    /// is on record and the live log is never committed away (L11 review 61). A relaunch's record — nothing of
    /// this session bound in this process — never overwrites the recording's own file: it goes beside it as
    /// `<session>.relaunch.diag.jsonl` (L review 119). The session then ends: nothing continues it (L11 review
    /// 66). A second finalize of the same session (a salvage after its transcript failed) still finds
    /// everything, and updates its own file.
    public func finalize(sessionId: String, directory: URL) -> CaptureDiagnostics {
        let bound = isBound(to: sessionId, in: directory)
        // The ring is this session's when bound to it, or — nothing bound (a salvage at launch) — the events
        // recorded since, on top of this session's own record when it was finalized before. Never another
        // session's (L11 review 66).
        let ownsRing = bound || session == nil
        var ring = ownsRing ? diagnostics : CaptureDiagnostics(maxEvents: diagnostics.maxEvents)
        var continuesOwnRecord = bound
        if !bound, ownsRing, let earlier = finalized, earlier.id == sessionId, earlier.directory == Self.key(directory) {
            var continued = earlier.record
            continued.merge(ring.events)
            ring = continued
            continuesOwnRecord = true
        }
        let log = (bound ? liveLog : nil) ?? LiveDiagnosticsLog(directory: directory, sessionId: sessionId)
        let logged = log.events()
        var merged = log.merged(into: ring)
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

        if merged.isAnomalous {
            var url = directory.appendingPathComponent("\(sessionId).diag.jsonl")
            if !continuesOwnRecord, FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(sessionId).relaunch.diag.jsonl")   // never over the richer original
            }
            do {
                try merged.jsonlData().write(to: url, options: .atomic)
                unwrittenRecords.remove(Self.recordKey(sessionId, directory))
                Logger.files.info("Flushed capture diagnostics: \(url.lastPathComponent, privacy: .sensitive) (\(merged.events.count) events)")
            } catch {
                Logger.files.error("Failed to flush diagnostics — keeping the live log: \(error, privacy: .private)")
                unwrittenRecords.insert(Self.recordKey(sessionId, directory))
                let failure = CaptureEvent(timestamp: Date(), origin: .app, kind: .sessionWriteFailed, severity: .anomaly,
                                           detail: ["file": "diag.jsonl", "error": error.localizedDescription])
                merged.record(failure)
                log.append(failure)
            }
        }
        if ownsRing {
            // Kept aside for a second finalize of this session; the ring starts afresh for whatever comes next.
            finalized = (Self.key(directory), sessionId, merged)
            diagnostics = CaptureDiagnostics(maxEvents: diagnostics.maxEvents)
        }
        if bound {
            liveLog = nil
            session = nil
            epoch += 1
        }
        return merged
    }

    private static func recordKey(_ sessionId: String, _ directory: URL) -> String { key(directory) + "\u{0}" + sessionId }

    /// The session's transcript is on disk (L review 97): its live log and coverage go — unless its `.diag.jsonl`
    /// could not be written, when the live log is its only record and stays.
    public func commit(sessionId: String, directory: URL) {
        guard unwrittenRecords.remove(Self.recordKey(sessionId, directory)) == nil else {
            Logger.files.error("The session's diagnostics file could not be written — its live log is kept")
            return
        }
        LiveDiagnosticsLog(directory: directory, sessionId: sessionId).delete()
    }

    /// A pending retry's drain of the helper it stopped (L review 98). The events belong to the pending session
    /// whose live log knows that helper session — a `captureStop` of it, or a status pull's coverage — and are
    /// appended to THAT session's live log, which its salvage merges. A helper session no pending session knows
    /// (or more than one claims) is attributed to none: logged, never recorded under the wrong session, and never
    /// left in a ring for whichever session is finalized next. Reads the sessions' folders: never on the main actor.
    nonisolated public static func attributeHelperDrain(_ data: Data, toOneOf sessions: [(sessionId: String, directory: URL)]) {
        let events = CaptureDiagnostics.events(from: data)
        guard !events.isEmpty else { return }
        let helpers = Set(events.compactMap { $0.detail["helper_session"] })
        let owners = sessions.filter { session in
            let log = LiveDiagnosticsLog(directory: session.directory, sessionId: session.sessionId)
            let known = Set(log.coverageSnapshots().keys).union(log.events().compactMap { $0.detail["helper_session"] })
            return !known.isDisjoint(with: helpers)
        }
        guard owners.count == 1, let owner = owners.first else {
            Logger.state.info("\(events.count, privacy: .public) helper events of a helper session no pending recording can claim — not attributed")
            return
        }
        let log = LiveDiagnosticsLog(directory: owner.directory, sessionId: owner.sessionId)
        for event in events { log.append(event) }
    }

    /// A start that never became a recording (L11 review 68): its evidence is dropped and its live log
    /// deleted — no orphan `.diag.live.jsonl` beside a recording that does not exist.
    public func discard(sessionId: String, directory: URL) {
        guard isBound(to: sessionId, in: directory) else { return }
        liveLog?.delete()
        liveLog = nil
        session = nil
        finalized = nil
        diagnostics.resetSession()
        epoch += 1
    }
}
