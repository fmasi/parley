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
/// - Every event is also appended to `<session>.diag.live.jsonl` as it happens, so an app crash loses at
///   most the line in flight; finalize merges it back, deduplicated.
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
    /// Which session the evidence is bound to, as a tag: bumped whenever a NEW session binds, and when one
    /// ends. A helper call is tagged with it when made; what it records later for another binding is dropped
    /// (L9 review 52).
    public private(set) var epoch = 0

    /// `maxEvents`: the ring's bound (tests shrink it).
    public init(maxEvents: Int = 5000) {
        diagnostics = CaptureDiagnostics(maxEvents: maxEvents)
    }

    private static func key(_ directory: URL) -> String { directory.standardizedFileURL.path }

    private func isBound(to sessionId: String, in directory: URL) -> Bool {
        session.map { $0.id == sessionId && $0.directory == Self.key(directory) } ?? false
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

    /// A status pull: its coverage becomes that helper session's latest. Only a CAPTURING helper's: a pull
    /// that raced a stop reports the whole expected time with nothing delivered (L11 review 67).
    public func noteCoverage(_ snapshot: CaptureStatusSnapshot, at date: Date = Date()) {
        guard snapshot.isCapturing, let facts = snapshot.coverage, !facts.isEmpty, let liveLog else { return }
        liveLog.writeCoverage(helperSession: facts["helper_session"] ?? snapshot.helperSessionId, facts: facts, at: date)
    }

    /// Everything the session recorded, for its provenance and `.diag.jsonl`: the ring, the live log (this
    /// process's, or an earlier one's for a session salvaged or resumed after a crash), and the latest
    /// coverage of every helper session that wrote no `captureStop`.
    ///
    /// When the session was anomalous, `<session>.diag.jsonl` is written — atomically — BEFORE the live log is
    /// deleted (L11 review 61); if it cannot be written, the live log is kept and the failure is on record.
    /// The session then ends: nothing continues it (L11 review 66). A second finalize of the same session (a
    /// salvage after its transcript failed) still finds everything.
    public func finalize(sessionId: String, directory: URL) -> CaptureDiagnostics {
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

        var keepLiveLog = false
        if merged.isAnomalous {
            let url = directory.appendingPathComponent("\(sessionId).diag.jsonl")
            do {
                try merged.jsonlData().write(to: url, options: .atomic)
                Logger.files.info("Flushed capture diagnostics: \(url.lastPathComponent, privacy: .sensitive) (\(merged.events.count) events)")
            } catch {
                Logger.files.error("Failed to flush diagnostics — keeping the live log: \(error, privacy: .private)")
                keepLiveLog = true
                let failure = CaptureEvent(timestamp: Date(), origin: .app, kind: .sessionWriteFailed, severity: .anomaly,
                                           detail: ["file": "diag.jsonl", "error": error.localizedDescription])
                merged.record(failure)
                log.append(failure)
            }
        }
        if !keepLiveLog { log.delete() }
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
