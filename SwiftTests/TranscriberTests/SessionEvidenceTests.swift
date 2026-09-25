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
    /// L review 93 (R2 item 8): a helper drain goes through `mergeDrained`, so an event this build cannot
    /// decode (a kind from a newer helper) is admitted in `events_dropped` — never silently missing.
    @Test func anUndecodableDrainedEventIsCountedAsDropped() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        var helperRing = CaptureDiagnostics()
        helperRing.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .helper, kind: .rateDrift, severity: .anomaly,
                                       detail: ["source": "system-tap"]))
        var wire = try #require(try JSONSerialization.jsonObject(with: helperRing.snapshotData()) as? [[String: Any]])
        var newer = wire[0]
        newer["kind"] = "aKindFromANewerHelper"
        wire.append(newer)
        evidence.mergeHelperDrain(try JSONSerialization.data(withJSONObject: wire))
        let record = evidence.finalize(sessionId: "s", directory: d)
        #expect(record.droppedCount == 1, "the undecodable event is admitted")
        #expect(record.events.contains { $0.kind == .rateDrift }, "the rest of the drain is kept")
    }

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
        b.commit(sessionId: "s", directory: d)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "committed: the live log is gone")
    }

    /// A helper that survived the app's crash seals its session on disconnect: that `captureStop`, drained
    /// by the relaunched app, supersedes the same helper session's pre-crash snapshot. In production order
    /// (L11 review 68): a relaunch that salvages drains BEFORE anything binds the evidence, then finalizes.
    @Test func aDrainedCaptureStopSupersedesThePreCrashSnapshotOfItsHelperSession() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        b.mergeHelperEvents([captureStop(remote: 25, local: 25, helper: "1000-0", at: 50)])   // the drain: sealed on disconnect
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

    /// L11 review 61: the anomaly-gated `.diag.jsonl` is written — atomically — BEFORE the live log goes.
    @Test func theDiagnosticsFileIsWrittenBeforeTheLiveLogGoes() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = evidence.finalize(sessionId: "s", directory: d)
        let written = try String(contentsOf: d.appendingPathComponent("s.diag.jsonl"), encoding: .utf8)
        #expect(written.contains("xpcInterruption"))
        evidence.commit(sessionId: "s", directory: d)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
    }

    /// L review 97: the record is BUILT before the transcript and COMMITTED after it. Until the commit the live
    /// log (and its coverage) stays: a crash while the transcript is being written is salvaged with everything.
    @Test func theLiveLogOutlivesTheBuildUntilTheCommit() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .retry, severity: .warning))
        evidence.noteCoverage(statusPull(remote: 30, local: 30, helper: "1000-0"))
        _ = evidence.finalize(sessionId: "s", directory: d)
        LiveDiagnosticsLog.flushAll()
        let live = d.appendingPathComponent("s.diag.live.jsonl"), coverage = d.appendingPathComponent("s.diag.coverage.json")
        #expect(FileManager.default.fileExists(atPath: live.path) && FileManager.default.fileExists(atPath: coverage.path),
                "a clean session keeps its live log until its transcript exists")
        // The transcript failed; the salvage builds the record again from what is still on disk.
        let again = SessionEvidence().finalize(sessionId: "s", directory: d)
        #expect(provenance(again).remoteCoverage?.deliveredSeconds == 30 && provenance(again).retries == 1)
        evidence.commit(sessionId: "s", directory: d)
        #expect(!FileManager.default.fileExists(atPath: live.path) && !FileManager.default.fileExists(atPath: coverage.path))
    }

    /// L review 119: a relaunch's record (a rebuild, a salvage) never overwrites the recording's own
    /// `.diag.jsonl`: it is written beside it as `<id>.relaunch.diag.jsonl`.
    @Test func aRelaunchNeverOverwritesTheRecordingsDiagnosticsFile() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let evidence = SessionEvidence()   // the relaunched app: nothing bound
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original)
        let relaunch = try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8)
        #expect(relaunch.contains("xpcInterruption"))
    }

    /// … while a second build of the SAME session in this process (the transcript failed, the salvage builds
    /// again) continues its own record — a superset — and updates its own file.
    @Test func aSecondBuildOfTheSameSessionUpdatesItsOwnFile() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = evidence.finalize(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 6), origin: .app, kind: .retry, severity: .warning))
        _ = evidence.finalize(sessionId: "s", directory: d)
        let written = try String(contentsOf: d.appendingPathComponent("s.diag.jsonl"), encoding: .utf8)
        #expect(written.contains("xpcInterruption") && written.contains("retry"))
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.relaunch.diag.jsonl").path))
    }

    /// L review 98: a pending retry stops a stray helper and drains it ONCE, before any salvage. Its events go
    /// to the pending session whose live log knows that helper session — never to whichever session is
    /// salvaged first. Here pending = [older P, held H]; the helper was H's.
    @Test func aStrayHelpersEventsGoToThePendingSessionThatKnowsIt() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {   // the crashed processes' evidence: P recorded on helper 1000-0, H on helper 2000-0
            let p = SessionEvidence(); p.beginCapture(sessionId: "p", directory: d)
            p.noteCoverage(statusPull(remote: 10, local: 10, helper: "1000-0"))
            let held = SessionEvidence(); held.beginCapture(sessionId: "h", directory: d)
            held.noteCoverage(statusPull(remote: 20, local: 20, helper: "2000-0"))
        }
        var helperRing = CaptureDiagnostics()
        helperRing.record(captureStop(remote: 25, local: 25, helper: "2000-0", at: 50))   // sealed by the retry's stop
        let evidence = SessionEvidence()
        SessionEvidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("p", d), ("h", d)])
        let p = provenance(evidence.finalize(sessionId: "p", directory: d))
        let h = provenance(evidence.finalize(sessionId: "h", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 10, "P's own coverage only")
        #expect(h.remoteCoverage?.deliveredSeconds == 25, "H's captureStop supersedes its last pull")
    }

    /// … and a helper session no pending session knows is attributed to none of them.
    @Test func aStrayHelpersEventsNobodyKnowsAreNotAttributed() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let p = SessionEvidence(); p.beginCapture(sessionId: "p", directory: d)
            p.noteCoverage(statusPull(remote: 10, local: 10, helper: "1000-0"))
        }
        var helperRing = CaptureDiagnostics()
        helperRing.record(captureStop(remote: 99, local: 99, helper: "3000-0", at: 50))
        helperRing.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 51), origin: .helper, kind: .rateDrift, severity: .anomaly,
                                       detail: ["source": "system-tap"]))
        let evidence = SessionEvidence()
        SessionEvidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("p", d)])
        let record = evidence.finalize(sessionId: "p", directory: d)
        #expect(provenance(record).remoteCoverage?.deliveredSeconds == 10)
        #expect(!record.events.contains { $0.kind == .rateDrift }, "never under the wrong session")
    }

    /// … and when it cannot be written, the live log is KEPT and the failure is on record.
    @Test func aFailedDiagnosticsWriteKeepsTheLiveLogAndSaysSo() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("s.diag.jsonl"), withIntermediateDirectories: true)   // unwritable
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        let merged = evidence.finalize(sessionId: "s", directory: d)
        evidence.commit(sessionId: "s", directory: d)
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "the live log is kept")
        #expect(merged.events.contains { $0.kind == .sessionWriteFailed && $0.detail["file"] == "diag.jsonl" })
    }

    /// L11 review 62 (pinned; L follow-up 43 made the resume adopt first): an app crash leaves a confirmed
    /// denial undrained in the helper. The resume binds the session, drains it, and its own start resets
    /// nothing: the record carries the denial.
    @Test func aResumeKeepsTheCrashedAppsUndrainedHelperEvents() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
        }   // the app crashes; the helper still holds its events
        let b = SessionEvidence()
        b.beginCapture(sessionId: "s", directory: d)   // adopt
        b.mergeHelperEvents([   // the drain
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 3), origin: .helper, kind: .systemAudioPermissionDenied, severity: .anomaly,
                         detail: ["status": "denied"]),
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 4), origin: .helper, kind: .neverDelivered, severity: .anomaly, detail: ["track": "system"]),
        ])
        b.beginCapture(sessionId: "s", directory: d)   // the resume's start
        let merged = b.finalize(sessionId: "s", directory: d)
        #expect(provenance(merged).systemPermissionDeniedConfirmed)
        #expect(merged.events.contains { $0.kind == .neverDelivered })
    }

    /// L11 review 66: a finished session is never inherited. Ids are `HHmmss-<name>` with no date: a recurring
    /// meeting started at the same second another day has the same id — in another day folder.
    @Test func aFinishedSessionIsNeverInheritedByOneWithTheSameName() throws {
        let day1 = try dir(), day2 = try dir()
        defer { try? FileManager.default.removeItem(at: day1); try? FileManager.default.removeItem(at: day2) }
        let retry = CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"])
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "090000-standup", directory: day1)
        evidence.record(retry)
        _ = evidence.finalize(sessionId: "090000-standup", directory: day1)
        #expect(evidence.sessionId == nil, "finalize ends the binding")
        evidence.beginCapture(sessionId: "090000-standup", directory: day2)
        #expect(provenance(evidence.finalize(sessionId: "090000-standup", directory: day2)).retries == 0)

        // Unfinished (a crash), then the same id in another folder: still another session.
        evidence.beginCapture(sessionId: "090000-standup", directory: day1)
        evidence.record(retry)
        evidence.beginCapture(sessionId: "090000-standup", directory: day2)
        #expect(provenance(evidence.finalize(sessionId: "090000-standup", directory: day2)).retries == 0)
    }

    /// L11 review 66: two crashed sessions salvaged one after the other (the pending list, L follow-up 24),
    /// with nothing bound: the second record carries none of the first one's facts. A second finalize of the
    /// SAME session (its transcript failed, then the salvage) still carries them all.
    @Test func consecutiveSalvagesNeverShareTheirFacts() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "x", directory: d)
            a.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
            a.mergeHelperEvents([captureStop(remote: 40, local: 40, helper: "1000-0", at: 40)])
        }
        let b = SessionEvidence()
        let x = b.finalize(sessionId: "x", directory: d)
        #expect(provenance(x).remoteCoverage?.deliveredSeconds == 40 && x.isAnomalous)
        #expect(provenance(b.finalize(sessionId: "x", directory: d)).remoteCoverage?.deliveredSeconds == 40, "the same session again")
        let y = b.finalize(sessionId: "y", directory: d)
        #expect(provenance(y).remoteCoverage == nil && !y.isAnomalous, "never the other session's facts")
    }

    /// L11 review 67: a pull that raced a stop (the helper no longer capturing: full expected time, nothing
    /// delivered) is not coverage — the helper session keeps its last capturing snapshot.
    @Test func aPullFromAHelperThatIsNotCapturingIsIgnored() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        var r = TrackAccounting(); r.expectedSeconds = 30; r.deliveredSeconds = 0
        let bogus = CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: 2, isCapturing: false, alarms: [], tracks: [],
                                          coverage: r.asDetail(prefix: "remote").merging(["helper_session": "1000-0"]) { a, _ in a })
        evidence.noteCoverage(bogus)
        let p = provenance(evidence.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 20 && p.remoteCoverage?.expectedSeconds == 20)
    }

    /// L11 review 67: which helper sessions stopped is kept OUT of the bounded ring: a `captureStop` evicted
    /// from the ring (and, here, never reaching a live log that cannot be written) still supersedes its
    /// helper session's snapshot — never counted twice.
    @Test func aStopEvictedFromTheRingStillSupersedesItsSnapshot() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("s.diag.live.jsonl"), withIntermediateDirectories: true)   // unwritable
        let evidence = SessionEvidence(maxEvents: 3)
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        evidence.mergeHelperEvents([captureStop(remote: 30, local: 30, helper: "1000-0", at: 10)])
        for i in 0..<5 {
            evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 20 + Double(i)), origin: .app, kind: .restartInPlace, severity: .warning))
        }
        #expect(!evidence.diagnostics.events.contains { $0.kind == .captureStop }, "evicted")
        #expect(provenance(evidence.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 30)
    }

    /// L11 review 68: a start that never became a recording leaves no orphan `.diag.live.jsonl` behind.
    @Test func aDiscardedSessionLeavesNoLiveLog() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        let epoch = evidence.epoch
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcTimeout, severity: .anomaly))
        evidence.discard(sessionId: "s", directory: d)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
        #expect(evidence.sessionId == nil && evidence.epoch != epoch)
    }

    /// L9 review 52: a helper call is tagged with the session it was made for. Its timeout, landing after
    /// that session ended and the next one began, is dropped — never another recording's anomaly.
    @Test func aLateTimeoutIsRecordedOnlyIntoItsOwnSession() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let timeout = CaptureEvent(timestamp: Date(timeIntervalSince1970: 50), origin: .app, kind: .xpcTimeout, severity: .anomaly,
                                   detail: ["call": "stop"])
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "first", directory: d)
        let firstTag = evidence.epoch
        _ = evidence.finalize(sessionId: "first", directory: d)
        evidence.beginCapture(sessionId: "second", directory: d)
        evidence.record(timeout, madeIn: firstTag)
        #expect(!evidence.finalize(sessionId: "second", directory: d).events.contains { $0.kind == .xpcTimeout })

        evidence.beginCapture(sessionId: "third", directory: d)
        evidence.record(timeout, madeIn: evidence.epoch)
        #expect(evidence.finalize(sessionId: "third", directory: d).events.contains { $0.kind == .xpcTimeout })
    }
}
