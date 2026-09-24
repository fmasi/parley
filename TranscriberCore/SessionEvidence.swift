import Foundation
import os

/// The app's capture evidence for the recording session in progress (§8.11): the diagnostic ring, the
/// live log beside the recording, and the latest coverage of every helper session. The XPC client owns
/// one for the app's lifetime.
///
/// - A NEW session id resets everything (council A-C1 / C-C1): no later recording inherits an earlier
///   one's coverage, content anomalies, confirmed denial, retries or recoveries. The SAME id — an
///   in-session restart, or a relaunch that resumes the session — keeps it all.
/// - Every event is also appended to `<session>.diag.live.jsonl` as it happens, so an app crash loses at
///   most the line in flight; finalize merges it back, deduplicated.
/// - Every status pull's coverage is kept per helper session (council A-I4 / C-I1). At finalize a helper
///   session's latest snapshot stands in for the `captureStop` a crashed helper never wrote; a
///   `captureStop` of that helper session, when there is one, supersedes it (never counted twice).
@MainActor
public final class SessionEvidence {
    public private(set) var diagnostics = CaptureDiagnostics()
    public private(set) var sessionId: String?
    private var liveLog: LiveDiagnosticsLog?
    /// Which session the evidence is bound to, as a tag: bumped whenever a NEW session binds. A helper call
    /// is tagged with it when made; what it records later for another binding is dropped (L9 review 52).
    public private(set) var epoch = 0

    public init() {}

    /// A capture starts, of `sessionId`, recording into `directory`.
    public func beginCapture(sessionId: String, directory: URL) {
        if sessionId != self.sessionId {
            diagnostics.resetSession()
            liveLog = nil
            epoch += 1
        }
        // The same session resumed by a relaunch finds the earlier process's live log and appends to it.
        if liveLog == nil { liveLog = LiveDiagnosticsLog(directory: directory, sessionId: sessionId) }
        self.sessionId = sessionId
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

    /// A status pull: its coverage becomes that helper session's latest.
    public func noteCoverage(_ snapshot: CaptureStatusSnapshot, at date: Date = Date()) {
        guard let facts = snapshot.coverage, !facts.isEmpty, let liveLog else { return }
        liveLog.writeCoverage(helperSession: facts["helper_session"] ?? snapshot.helperSessionId, facts: facts, at: date)
    }

    /// Everything the session recorded, for its provenance and `.diag.jsonl`: the ring, the live log (this
    /// process's, or an earlier one's for a session salvaged or resumed after a crash), and the latest
    /// coverage of every helper session that wrote no `captureStop`. The live log is then deleted.
    public func finalize(sessionId: String, directory: URL) -> CaptureDiagnostics {
        let log = (self.sessionId == sessionId ? liveLog : nil) ?? LiveDiagnosticsLog(directory: directory, sessionId: sessionId)
        let logged = log.events()
        var merged = log.merged(into: diagnostics)
        let stopped = Set((logged + merged.events).filter { $0.kind == .captureStop }.compactMap { $0.detail["helper_session"] })
        let standIns = log.coverageSnapshots()
            .filter { !stopped.contains($0.key) }
            .map { helper, snapshot in
                CaptureEvent(timestamp: snapshot.at, origin: .helper, kind: .captureStop, severity: .info,
                             detail: snapshot.facts.merging(["helper_session": helper, "from": "status pull"]) { _, new in new })
            }
        if !standIns.isEmpty { merged.merge(standIns) }
        log.delete()
        if self.sessionId == sessionId { liveLog = nil }
        diagnostics = merged
        return merged
    }
}
