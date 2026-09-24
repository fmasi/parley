import Foundation
import Testing
@testable import TranscriberCore

/// L11 (§8.11) and council A-C1/C-C1, A-I4/C-I1: the app's capture evidence belongs to ONE recording
/// session, survives an in-session restart and an app relaunch that resumes it, and keeps a crashed
/// helper's coverage.
@MainActor
@Suite struct SessionEvidenceTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `remote_*`/`local_*` coverage as the helper reports it, with its helper session.
    private func facts(remote: Double, local: Double, helper: String) -> [String: String] {
        var r = TrackAccounting(); r.expectedSeconds = remote; r.deliveredSeconds = remote
        var l = TrackAccounting(); l.expectedSeconds = local; l.deliveredSeconds = local
        return r.asDetail(prefix: "remote").merging(l.asDetail(prefix: "local")) { a, _ in a }
            .merging(["helper_session": helper]) { a, _ in a }
    }

    private func captureStop(remote: Double, local: Double, helper: String, at t: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSince1970: t), origin: .helper, kind: .captureStop, severity: .info,
                     detail: facts(remote: remote, local: local, helper: helper))
    }

    private func statusPull(remote: Double, local: Double, helper: String) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: helper, sequence: 1, isCapturing: true, alarms: [], tracks: [],
                              coverage: facts(remote: remote, local: local, helper: helper))
    }

    private func provenance(_ d: CaptureDiagnostics) -> CaptureProvenance {
        d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
    }

    /// CRITICAL (council A-C1 / C-C1): two recordings in one app run. The second record holds only its
    /// own facts — never the first one's coverage, confirmed denial, retries or recovery.
    @Test func aSecondRecordingCarriesOnlyItsOwnFacts() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "first", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]))
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 2), origin: .app, kind: .launchRecovery, severity: .warning))
        evidence.mergeHelperEvents([
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 3), origin: .helper, kind: .systemAudioPermissionDenied, severity: .anomaly,
                         detail: ["status": "denied"]),
            captureStop(remote: 3600, local: 3600, helper: "1000-0", at: 4),
        ])
        let first = provenance(evidence.finalize(sessionId: "first", directory: d))
        #expect(first.remoteCoverage?.deliveredSeconds == 3600 && first.retries == 1 && first.recovered && first.systemPermissionDeniedConfirmed)

        evidence.beginCapture(sessionId: "second", directory: d)
        evidence.mergeHelperEvents([captureStop(remote: 10, local: 10, helper: "1000-1", at: 10)])
        let second = provenance(evidence.finalize(sessionId: "second", directory: d))
        #expect(second.remoteCoverage?.deliveredSeconds == 10, "only its own coverage")
        #expect(second.retries == 0 && !second.recovered && !second.systemPermissionDeniedConfirmed)
    }

    /// The SAME session id (an in-session restart) keeps everything the session already recorded.
    @Test func anInSessionRestartKeepsTheSessionsEvidence() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]))
        evidence.beginCapture(sessionId: "s", directory: d)
        #expect(provenance(evidence.finalize(sessionId: "s", directory: d)).retries == 1)
    }

    /// Council A-I4 / C-I1: a helper that crashes mid-call writes no `captureStop`. Its coverage from the
    /// last status pull stands in for it; the restarted helper's own `captureStop` supersedes that
    /// helper's snapshot (never counted twice).
    @Test func aHelperCrashKeepsThatHelpersCoverageFromItsLastStatusPull() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 50, local: 50, helper: "1000-0"))
        evidence.noteCoverage(statusPull(remote: 60, local: 60, helper: "1000-0"))   // the last pull before the crash
        evidence.beginCapture(sessionId: "s", directory: d)                             // the crash restart
        evidence.noteCoverage(statusPull(remote: 25, local: 25, helper: "2000-0"))
        evidence.mergeHelperEvents([captureStop(remote: 30, local: 30, helper: "2000-0", at: 100)])   // the stop
        let p = provenance(evidence.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 90, "60 s from the crashed helper's last pull + 30 s from the stop")
        #expect(p.localCoverage?.deliveredSeconds == 90)
    }

    /// The ledger's L11 ruling: crash → relaunch → the merged coverage includes the pre-crash seconds.
    /// The first process's evidence reaches the relaunched one through the live log on disk.
    @Test func coverageFromBeforeAnAppCrashSurvivesTheRelaunch() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {   // process A: a helper session that stopped (its captureStop drained), another still pulling
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.mergeHelperEvents([captureStop(remote: 40, local: 40, helper: "1000-0", at: 40)])
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-1"))
        }   // … and A crashes: nothing finalized
        let b = SessionEvidence()   // process B resumes the SAME session
        b.beginCapture(sessionId: "s", directory: d)
        b.mergeHelperEvents([captureStop(remote: 30, local: 30, helper: "3000-0", at: 200)])
        let p = provenance(b.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 90, "40 s stopped + 20 s pulled before the crash + 30 s after")
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "finalized: the live log is gone")
    }

    /// A helper that survived the app's crash seals its session on disconnect: that `captureStop`, drained
    /// by the relaunched app, supersedes the same helper session's pre-crash snapshot.
    @Test func aDrainedCaptureStopSupersedesThePreCrashSnapshotOfItsHelperSession() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        b.beginCapture(sessionId: "s", directory: d)
        b.mergeHelperEvents([captureStop(remote: 25, local: 25, helper: "1000-0", at: 50)])   // sealed on disconnect
        #expect(provenance(b.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 25)
    }

    /// L follow-up 43: the relaunch adopts the session first, then drains: the sealed `captureStop` survives
    /// the resume's own start (the same session id resets nothing).
    @Test func anAdoptedSessionKeepsTheDrainedCaptureStopThroughItsStart() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        b.beginCapture(sessionId: "s", directory: d)                                            // adopt
        b.mergeHelperEvents([captureStop(remote: 25, local: 25, helper: "1000-0", at: 50)])    // the drain
        b.beginCapture(sessionId: "s", directory: d)                                            // the resume's start
        b.mergeHelperEvents([captureStop(remote: 5, local: 5, helper: "2000-0", at: 90)])
        #expect(provenance(b.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 30)
    }

    /// A relaunch that salvages (no capture started in this process) still finds the crashed process's
    /// live log for that session.
    @Test func aSalvageFinalizesTheLiveLogOfTheCrashedProcess() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        let merged = b.finalize(sessionId: "s", directory: d)
        #expect(merged.events.contains { $0.kind == .xpcInterruption })
        #expect(provenance(merged).remoteCoverage?.deliveredSeconds == 20)
    }
}
