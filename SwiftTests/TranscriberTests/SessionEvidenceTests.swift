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

    /// Events as a helper drain carries them over the wire (L review 153: `mergeHelperDrain` is the one way in).
    private func wire(_ events: [CaptureEvent]) -> Data {
        var ring = CaptureDiagnostics()
        for event in events { ring.record(event) }
        return ring.snapshotData()
    }

    private func provenance(_ d: CaptureDiagnostics) -> CaptureProvenance {
        d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
    }

    /// L review 93 (R2 item 8): a helper drain goes through `mergeDrained`, so an event this build cannot
    /// decode (a kind from a newer helper) is admitted in `events_dropped` — never silently missing.
    @Test func anUndecodableDrainedEventIsCountedAsDropped() async throws {
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
        let record = await evidence.finalize(sessionId: "s", directory: d)
        #expect(record.droppedCount == 1, "the undecodable event is admitted")
        #expect(record.events.contains { $0.kind == .rateDrift }, "the rest of the drain is kept")
    }

    /// L review 99 (a pin of the `!ownsRing` branch): finalizing ANOTHER session while one is bound builds that
    /// session from its own live log only — never the bound session's ring — and leaves the bound one bound.
    @Test func finalizingAnotherSessionNeverTouchesTheBoundOne() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {   // an earlier process's session "b": its live log holds a retry
            let earlier = SessionEvidence()
            earlier.beginCapture(sessionId: "b", directory: d)
            earlier.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning))
        }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "a", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 2), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        let b = await evidence.finalize(sessionId: "b", directory: d)
        #expect(provenance(b).retries == 1, "b's own facts")
        #expect(!b.events.contains { $0.kind == .xpcInterruption }, "never the bound session's")
        #expect(evidence.sessionId == "a", "a is still bound")
        let a = await evidence.finalize(sessionId: "a", directory: d)
        #expect(a.events.contains { $0.kind == .xpcInterruption } && provenance(a).retries == 0, "a's ring untouched")
    }

    /// L review 101: the (folder, id) key is lexical — `standardized`, no file-system lookup (a hung share must
    /// never be touched to compute it). L review 168: `/private` is stripped, as a string, before the macOS firmlinked
    /// roots (`/var`, `/tmp`, `/etc`): both spellings of one folder are one key. Any other `/private/…` is left alone.
    @Test func theSessionKeyIsLexicalNeverTheFileSystems() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        #expect(d.path.hasPrefix("/var/"), "the temporary folder is under /var: \(d.path)")
        let spelled = URL(fileURLWithPath: "/private" + d.path + "/x/..")
        #expect(SessionEvidence.key(spelled) == d.path, "\(SessionEvidence.key(spelled))")
        #expect(SessionEvidence.key(URL(fileURLWithPath: "/private/tmp/a")) == "/tmp/a")
        #expect(SessionEvidence.key(URL(fileURLWithPath: "/private/etc")) == "/etc")
        #expect(SessionEvidence.key(URL(fileURLWithPath: "/private/other/a")) == "/private/other/a")
        #expect(SessionEvidence.key(URL(fileURLWithPath: "/private/variable/a")) == "/private/variable/a", "a root, not a prefix")
    }

    /// L review 168: `/private/var/…` and `/var/…` are ONE session — never two sessions, never an overwritten record.
    @Test func bothSpellingsOfAFirmlinkedFolderAreOneSession() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: URL(fileURLWithPath: "/private" + d.path))
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]))
        let record = await evidence.finalize(sessionId: "s", directory: d)
        #expect(provenance(record).retries == 1, "the bound session's own ring")
        #expect(evidence.sessionId == nil, "and it ended")
    }

    /// CRITICAL (council A-C1 / C-C1): two recordings in one app run. The second record holds only its
    /// own facts — never the first one's coverage, confirmed denial, retries or recovery.
    @Test func aSecondRecordingCarriesOnlyItsOwnFacts() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "first", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]))
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 2), origin: .app, kind: .launchRecovery, severity: .warning))
        evidence.mergeHelperDrain(wire([
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 3), origin: .helper, kind: .systemAudioPermissionDenied, severity: .anomaly,
                         detail: ["status": "denied"]),
            captureStop(remote: 3600, local: 3600, helper: "1000-0", at: 4),
        ]))
        let first = provenance(await evidence.finalize(sessionId: "first", directory: d))
        #expect(first.remoteCoverage?.deliveredSeconds == 3600 && first.retries == 1 && first.recovered && first.systemPermissionDeniedConfirmed)

        evidence.beginCapture(sessionId: "second", directory: d)
        evidence.mergeHelperDrain(wire([captureStop(remote: 10, local: 10, helper: "1000-1", at: 10)]))
        let second = provenance(await evidence.finalize(sessionId: "second", directory: d))
        #expect(second.remoteCoverage?.deliveredSeconds == 10, "only its own coverage")
        #expect(second.retries == 0 && !second.recovered && !second.systemPermissionDeniedConfirmed)
    }

    /// The SAME session id (an in-session restart) keeps everything the session already recorded.
    @Test func anInSessionRestartKeepsTheSessionsEvidence() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]))
        evidence.beginCapture(sessionId: "s", directory: d)
        #expect(provenance(await evidence.finalize(sessionId: "s", directory: d)).retries == 1)
    }

    /// Council A-I4 / C-I1: a helper that crashes mid-call writes no `captureStop`. Its coverage from the
    /// last status pull stands in for it; the restarted helper's own `captureStop` supersedes that
    /// helper's snapshot (never counted twice).
    @Test func aHelperCrashKeepsThatHelpersCoverageFromItsLastStatusPull() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 50, local: 50, helper: "1000-0"))
        evidence.noteCoverage(statusPull(remote: 60, local: 60, helper: "1000-0"))   // the last pull before the crash
        evidence.beginCapture(sessionId: "s", directory: d)                             // the crash restart
        evidence.noteCoverage(statusPull(remote: 25, local: 25, helper: "2000-0"))
        evidence.mergeHelperDrain(wire([captureStop(remote: 30, local: 30, helper: "2000-0", at: 100)]))   // the stop
        let p = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 90, "60 s from the crashed helper's last pull + 30 s from the stop")
        #expect(p.localCoverage?.deliveredSeconds == 90)
    }

    /// The ledger's L11 ruling: crash → relaunch → the merged coverage includes the pre-crash seconds.
    /// The first process's evidence reaches the relaunched one through the live log on disk.
    @Test func coverageFromBeforeAnAppCrashSurvivesTheRelaunch() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {   // process A: a helper session that stopped (its captureStop drained), another still pulling
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.mergeHelperDrain(wire([captureStop(remote: 40, local: 40, helper: "1000-0", at: 40)]))
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-1"))
        }   // … and A crashes: nothing finalized
        let b = SessionEvidence()   // process B resumes the SAME session
        b.beginCapture(sessionId: "s", directory: d)
        b.mergeHelperDrain(wire([captureStop(remote: 30, local: 30, helper: "3000-0", at: 200)]))
        let p = provenance(await b.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 90, "40 s stopped + 20 s pulled before the crash + 30 s after")
        b.commit(sessionId: "s", directory: d)
        LiveDiagnosticsLog.flushAll()   // the delete is queued behind the folder's writes
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "committed: the live log is gone")
    }

    /// A helper that survived the app's crash seals its session on disconnect: that `captureStop`, drained
    /// by the relaunched app, supersedes the same helper session's pre-crash snapshot. In production order
    /// (L11 review 68): a relaunch that salvages drains BEFORE anything binds the evidence, then finalizes.
    @Test func aDrainedCaptureStopSupersedesThePreCrashSnapshotOfItsHelperSession() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        b.mergeHelperDrain(wire([captureStop(remote: 25, local: 25, helper: "1000-0", at: 50)]))   // the drain: sealed on disconnect
        #expect(provenance(await b.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 25)
    }

    /// L follow-up 43: the relaunch adopts the session first, then drains: the sealed `captureStop` survives
    /// the resume's own start (the same session id resets nothing).
    @Test func anAdoptedSessionKeepsTheDrainedCaptureStopThroughItsStart() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        b.beginCapture(sessionId: "s", directory: d)                                            // adopt
        b.mergeHelperDrain(wire([captureStop(remote: 25, local: 25, helper: "1000-0", at: 50)]))    // the drain
        b.beginCapture(sessionId: "s", directory: d)                                            // the resume's start
        b.mergeHelperDrain(wire([captureStop(remote: 5, local: 5, helper: "2000-0", at: 90)]))
        #expect(provenance(await b.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 30)
    }

    /// A relaunch that salvages (no capture started in this process) still finds the crashed process's
    /// live log for that session.
    @Test func aSalvageFinalizesTheLiveLogOfTheCrashedProcess() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
            a.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
            a.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        }
        let b = SessionEvidence()
        let merged = await b.finalize(sessionId: "s", directory: d)
        #expect(merged.events.contains { $0.kind == .xpcInterruption })
        #expect(provenance(merged).remoteCoverage?.deliveredSeconds == 20)
    }

    /// L11 review 61: the anomaly-gated `.diag.jsonl` is written — atomically — BEFORE the live log goes.
    @Test func theDiagnosticsFileIsWrittenBeforeTheLiveLogGoes() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = await evidence.finalize(sessionId: "s", directory: d)
        let written = try String(contentsOf: d.appendingPathComponent("s.diag.jsonl"), encoding: .utf8)
        #expect(written.contains("xpcInterruption"))
        evidence.commit(sessionId: "s", directory: d)
        LiveDiagnosticsLog.flushAll()   // the delete is queued behind the folder's writes
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
    }

    /// L review 97: the record is BUILT before the transcript and COMMITTED after it. Until the commit the live
    /// log (and its coverage) stays: a crash while the transcript is being written is salvaged with everything.
    @Test func theLiveLogOutlivesTheBuildUntilTheCommit() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .retry, severity: .warning))
        evidence.noteCoverage(statusPull(remote: 30, local: 30, helper: "1000-0"))
        _ = await evidence.finalize(sessionId: "s", directory: d)
        LiveDiagnosticsLog.flushAll()
        let live = d.appendingPathComponent("s.diag.live.jsonl"), coverage = d.appendingPathComponent("s.diag.coverage.json")
        #expect(FileManager.default.fileExists(atPath: live.path) && FileManager.default.fileExists(atPath: coverage.path),
                "a clean session keeps its live log until its transcript exists")
        // The transcript failed; the salvage builds the record again from what is still on disk.
        let again = await SessionEvidence().finalize(sessionId: "s", directory: d)
        #expect(provenance(again).remoteCoverage?.deliveredSeconds == 30 && provenance(again).retries == 1)
        evidence.commit(sessionId: "s", directory: d)
        LiveDiagnosticsLog.flushAll()   // the delete is queued behind the folder's writes
        #expect(!FileManager.default.fileExists(atPath: live.path) && !FileManager.default.fileExists(atPath: coverage.path))
    }

    /// L review 119: a relaunch's record (a rebuild, a salvage) never overwrites the recording's own
    /// `.diag.jsonl`: it is written beside it as `<id>.relaunch.diag.jsonl`.
    @Test func aRelaunchNeverOverwritesTheRecordingsDiagnosticsFile() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let evidence = SessionEvidence()   // the relaunched app: nothing bound
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = await evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original)
        let relaunch = try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8)
        #expect(relaunch.contains("xpcInterruption"))
    }

    /// … while a second build of the SAME session in this process (the transcript failed, the salvage builds
    /// again) continues its own record — a superset — and updates its own file.
    @Test func aSecondBuildOfTheSameSessionUpdatesItsOwnFile() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = await evidence.finalize(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 6), origin: .app, kind: .retry, severity: .warning))
        _ = await evidence.finalize(sessionId: "s", directory: d)
        let written = try String(contentsOf: d.appendingPathComponent("s.diag.jsonl"), encoding: .utf8)
        #expect(written.contains("xpcInterruption") && written.contains("retry"))
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.relaunch.diag.jsonl").path))
    }

    /// L review 98: a pending retry stops a stray helper and drains it ONCE, before any salvage. Its events go
    /// to the pending session whose live log knows that helper session — never to whichever session is
    /// salvaged first. Here pending = [older P, held H]; the helper was H's.
    @Test func aStrayHelpersEventsGoToThePendingSessionThatKnowsIt() async throws {
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
        await evidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("p", d), ("h", d)])
        let p = provenance(await evidence.finalize(sessionId: "p", directory: d))
        let h = provenance(await evidence.finalize(sessionId: "h", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 10, "P's own coverage only")
        #expect(h.remoteCoverage?.deliveredSeconds == 25, "H's captureStop supersedes its last pull")
    }

    /// … and a helper session no pending session knows is attributed to none of them.
    @Test func aStrayHelpersEventsNobodyKnowsAreNotAttributed() async throws {
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
        await evidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("p", d)])
        let record = await evidence.finalize(sessionId: "p", directory: d)
        #expect(provenance(record).remoteCoverage?.deliveredSeconds == 10)
        #expect(!record.events.contains { $0.kind == .rateDrift }, "never under the wrong session")
    }

    /// … and when it cannot be written, the live log is KEPT and the failure is on record. (Its own file, written once,
    /// then unwritable: a record file another process wrote is never the target at all — L review 139.)
    @Test func aFailedDiagnosticsWriteKeepsTheLiveLogAndSaysSo() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        _ = await evidence.finalize(sessionId: "s", directory: d)   // this process's own s.diag.jsonl…
        let own = d.appendingPathComponent("s.diag.jsonl")
        try FileManager.default.removeItem(at: own)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)   // …now unwritable
        let merged = await evidence.finalize(sessionId: "s", directory: d)
        evidence.commit(sessionId: "s", directory: d)
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "the live log is kept")
        // L review 103: and the kept log itself says so — read back, after its queued writes.
        LiveDiagnosticsLog.flushAll()
        let kept = LiveDiagnosticsLog(directory: d, sessionId: "s").events()
        #expect(kept.contains { $0.kind == .sessionWriteFailed && $0.detail["file"] == "diag.jsonl" }, "the failure is in the kept log")
        #expect(merged.events.contains { $0.kind == .sessionWriteFailed && $0.detail["file"] == "diag.jsonl" })
    }

    /// L11 review 62 (pinned; L follow-up 43 made the resume adopt first): an app crash leaves a confirmed
    /// denial undrained in the helper. The resume binds the session, drains it, and its own start resets
    /// nothing: the record carries the denial.
    @Test func aResumeKeepsTheCrashedAppsUndrainedHelperEvents() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "s", directory: d)
        }   // the app crashes; the helper still holds its events
        let b = SessionEvidence()
        b.beginCapture(sessionId: "s", directory: d)   // adopt
        b.mergeHelperDrain(wire([   // the drain
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 3), origin: .helper, kind: .systemAudioPermissionDenied, severity: .anomaly,
                         detail: ["status": "denied"]),
            CaptureEvent(timestamp: Date(timeIntervalSince1970: 4), origin: .helper, kind: .neverDelivered, severity: .anomaly, detail: ["track": "system"]),
        ]))
        b.beginCapture(sessionId: "s", directory: d)   // the resume's start
        let merged = await b.finalize(sessionId: "s", directory: d)
        #expect(provenance(merged).systemPermissionDeniedConfirmed)
        #expect(merged.events.contains { $0.kind == .neverDelivered })
    }

    /// L11 review 66: a finished session is never inherited. Ids are `HHmmss-<name>` with no date: a recurring
    /// meeting started at the same second another day has the same id — in another day folder.
    @Test func aFinishedSessionIsNeverInheritedByOneWithTheSameName() async throws {
        let day1 = try dir(), day2 = try dir()
        defer { try? FileManager.default.removeItem(at: day1); try? FileManager.default.removeItem(at: day2) }
        let retry = CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"])
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "090000-standup", directory: day1)
        evidence.record(retry)
        _ = await evidence.finalize(sessionId: "090000-standup", directory: day1)
        #expect(evidence.sessionId == nil, "finalize ends the binding")
        evidence.beginCapture(sessionId: "090000-standup", directory: day2)
        #expect(provenance(await evidence.finalize(sessionId: "090000-standup", directory: day2)).retries == 0)

        // Unfinished (a crash), then the same id in another folder: still another session.
        evidence.beginCapture(sessionId: "090000-standup", directory: day1)
        evidence.record(retry)
        evidence.beginCapture(sessionId: "090000-standup", directory: day2)
        #expect(provenance(await evidence.finalize(sessionId: "090000-standup", directory: day2)).retries == 0)
    }

    /// L11 review 66: two crashed sessions salvaged one after the other (the pending list, L follow-up 24),
    /// with nothing bound: the second record carries none of the first one's facts. A second finalize of the
    /// SAME session (its transcript failed, then the salvage) still carries them all.
    @Test func consecutiveSalvagesNeverShareTheirFacts() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let a = SessionEvidence()
            a.beginCapture(sessionId: "x", directory: d)
            a.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
            a.mergeHelperDrain(wire([captureStop(remote: 40, local: 40, helper: "1000-0", at: 40)]))
        }
        let b = SessionEvidence()
        let x = await b.finalize(sessionId: "x", directory: d)
        #expect(provenance(x).remoteCoverage?.deliveredSeconds == 40 && x.isAnomalous)
        #expect(provenance(await b.finalize(sessionId: "x", directory: d)).remoteCoverage?.deliveredSeconds == 40, "the same session again")
        let y = await b.finalize(sessionId: "y", directory: d)
        #expect(provenance(y).remoteCoverage == nil && !y.isAnomalous, "never the other session's facts")
    }

    /// L11 review 67: a pull that raced a stop (the helper no longer capturing: full expected time, nothing
    /// delivered) is not coverage — the helper session keeps its last capturing snapshot.
    @Test func aPullFromAHelperThatIsNotCapturingIsIgnored() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        var r = TrackAccounting(); r.expectedSeconds = 30; r.deliveredSeconds = 0
        let bogus = CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: 2, isCapturing: false, alarms: [], tracks: [],
                                          coverage: r.asDetail(prefix: "remote").merging(["helper_session": "1000-0"]) { a, _ in a })
        evidence.noteCoverage(bogus)
        let p = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(p.remoteCoverage?.deliveredSeconds == 20 && p.remoteCoverage?.expectedSeconds == 20)
    }

    /// L11 review 67: which helper sessions stopped is kept OUT of the bounded ring: a `captureStop` evicted
    /// from the ring (and, here, never reaching a live log that cannot be written) still supersedes its
    /// helper session's snapshot — never counted twice.
    @Test func aStopEvictedFromTheRingStillSupersedesItsSnapshot() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("s.diag.live.jsonl"), withIntermediateDirectories: true)   // unwritable
        let evidence = SessionEvidence(maxEvents: 3)
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 20, local: 20, helper: "1000-0"))
        evidence.mergeHelperDrain(wire([captureStop(remote: 30, local: 30, helper: "1000-0", at: 10)]))
        for i in 0..<5 {
            evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 20 + Double(i)), origin: .app, kind: .restartInPlace, severity: .warning))
        }
        #expect(!evidence.diagnostics.events.contains { $0.kind == .captureStop }, "evicted")
        #expect(provenance(await evidence.finalize(sessionId: "s", directory: d)).remoteCoverage?.deliveredSeconds == 30)
    }

    // MARK: - Coverage honesty (#229)

    /// #229: a helper dies, and its last status pull stands in for it at the first finalize. Its real `captureStop`,
    /// drained afterwards, reaches a SECOND finalize of the same session (the transcript failed; the salvage builds
    /// again): it REPLACES that helper's stand-in. The record never says stand-in + stop.
    @Test func aRealStopAtASecondFinalizeReplacesItsHelpersStandIn() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.mergeHelperDrain(wire([captureStop(remote: 40, local: 40, helper: "1000-0", at: 40)]))   // a helper that stopped
        evidence.noteCoverage(statusPull(remote: 60, local: 60, helper: "2000-0"))                        // one that died: its last pull
        let first = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(first.remoteCoverage?.deliveredSeconds == 100, "40 s stopped + the 60 s stand-in")
        // The dead helper's own stop turns up after all, with nothing bound: into the ring.
        evidence.mergeHelperDrain(wire([captureStop(remote: 65, local: 65, helper: "2000-0", at: 70)]))
        let second = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(second.remoteCoverage?.deliveredSeconds == 105, "40 s + the real stop's 65 s — never 40 + 60 + 65")
        #expect(second.remoteCoverage?.expectedSeconds == 105)
        #expect(second.localCoverage?.deliveredSeconds == 105 && second.localCoverage?.expectedSeconds == 105)
        #expect(second.remoteCoverage?.coverageIncomplete == false, "a whole record: no lower-bound mark")
        // A third build changes nothing: neither the stand-in nor the stop is counted again.
        let third = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(third.remoteCoverage?.deliveredSeconds == 105 && third.localCoverage?.deliveredSeconds == 105)
    }

    /// … and the same when the late stop comes through a pending retry's attribution: appended to the session's
    /// live log, which the second build merges.
    @Test func aRealStopAttributedAfterTheFirstFinalizeReplacesItsHelpersStandIn() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.noteCoverage(statusPull(remote: 60, local: 60, helper: "2000-0"))
        let first = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(first.remoteCoverage?.deliveredSeconds == 60, "the stand-in")
        await evidence.attributeHelperDrain(wire([captureStop(remote: 65, local: 65, helper: "2000-0", at: 70)]), toOneOf: [("s", d)])
        let second = provenance(await evidence.finalize(sessionId: "s", directory: d))
        #expect(second.remoteCoverage?.deliveredSeconds == 65, "the real stop's — never 60 + 65")
        #expect(second.localCoverage?.deliveredSeconds == 65)
    }

    /// L11 review 68: a start that never became a recording leaves no orphan `.diag.live.jsonl` behind.
    @Test func aDiscardedSessionLeavesNoLiveLog() async throws {
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
    @Test func aLateTimeoutIsRecordedOnlyIntoItsOwnSession() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let timeout = CaptureEvent(timestamp: Date(timeIntervalSince1970: 50), origin: .app, kind: .xpcTimeout, severity: .anomaly,
                                   detail: ["call": "stop"])
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "first", directory: d)
        let firstTag = evidence.epoch
        _ = await evidence.finalize(sessionId: "first", directory: d)
        evidence.beginCapture(sessionId: "second", directory: d)
        evidence.record(timeout, madeIn: firstTag)
        let second = await evidence.finalize(sessionId: "second", directory: d)
        #expect(!second.events.contains { $0.kind == .xpcTimeout })

        evidence.beginCapture(sessionId: "third", directory: d)
        evidence.record(timeout, madeIn: evidence.epoch)
        let third = await evidence.finalize(sessionId: "third", directory: d)
        #expect(third.events.contains { $0.kind == .xpcTimeout })
    }

    // MARK: - L round C (139, 142, 143, 158)

    /// L review 139, CRITICAL: the decision is PROVENANCE, not binding. In production order a relaunch salvage BINDS the
    /// session (`beginCapture`, the adopt) before it builds — and the recording's own `.diag.jsonl`, written by another
    /// process, is still never overwritten: the relaunch's record goes beside it. A later relaunch never overwrites the
    /// first relaunch's record either.
    @Test func aBoundBuildNeverOverwritesARecordThisProcessDidNotWrite() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let anomaly = CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly)
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)   // the adopt binds it
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original, "the original is kept")
        #expect(try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
        // Another relaunch (another process): the first relaunch's record is not its own either.
        let later = SessionEvidence()
        later.beginCapture(sessionId: "s", directory: d)
        later.record(anomaly)
        _ = await later.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original)
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.relaunch-2.diag.jsonl").path))
    }

    /// L review 143: attribution is by batch. Every helper session the batch names must be known to the owner (a
    /// subset) — one it shares a helper session with, while another is unknown to it, is not its owner.
    @Test func aBatchNamingAHelperSessionTheOwnerNeverSawIsNotAttributed() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let held = SessionEvidence(); held.beginCapture(sessionId: "h", directory: d)
            held.noteCoverage(statusPull(remote: 20, local: 20, helper: "2000-0"))
        }
        var helperRing = CaptureDiagnostics()
        helperRing.record(captureStop(remote: 25, local: 25, helper: "2000-0", at: 50))
        helperRing.record(captureStop(remote: 99, local: 99, helper: "9999-9", at: 60))   // a helper session h never saw
        let evidence = SessionEvidence()
        await evidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("h", d)])
        let h = provenance(await evidence.finalize(sessionId: "h", directory: d))
        #expect(h.remoteCoverage?.deliveredSeconds == 20, "the batch is not h's: only its own pull")
    }

    /// L review 142: an attribution whose folder reads answer late never appends after its owner's record was built or
    /// committed — its events are dropped then, never written into a live log whose record is already being made.
    @Test func aLateAttributionNeverAppendsAfterItsOwnersBuild() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            let p = SessionEvidence(); p.beginCapture(sessionId: "p", directory: d)
            p.noteCoverage(statusPull(remote: 10, local: 10, helper: "1000-0"))
        }
        LiveDiagnosticsLog.flushAll()
        let known = HungRead("evidence: known helpers")
        defer { known.release() }
        let evidence = SessionEvidence(folderReads: FolderReads(label: "evidence-hung-\(UUID().uuidString)",
                                                                beforeEachRead: { known.hangIfNamed($0) }))
        var helperRing = CaptureDiagnostics()
        helperRing.record(captureStop(remote: 30, local: 30, helper: "1000-0", at: 50))
        let attributing = Task { await evidence.attributeHelperDrain(helperRing.snapshotData(), toOneOf: [("p", d)]) }
        await Harness.until { known.reached }   // L review 205: awaited, never a fixed sleep
        // The owner's salvage went ahead: its build BEGINS while the attribution's read is still out. Waited for by what
        // the build does first — `began` is set and `finalize` entered in one main-actor turn, and `finalize` marks the
        // record as being made before its first await: once this test sees `began`, the mark is made. The build's own read
        // cannot be waited for here: it is queued behind the hung one, on the folder's queue, and runs once that is let go —
        // waiting for it only ran the wait out, past the build's bound on a slow machine.
        let began = Harness.Box(false)
        let building = Task {
            began.value = true
            return await evidence.finalize(sessionId: "p", directory: d)
        }
        await Harness.until { began.value }
        try #require(began.value, "the owner's build began before the attribution's read answered")
        known.release()
        await attributing.value
        let record = await building.value
        LiveDiagnosticsLog.flushAll()
        #expect(provenance(record).remoteCoverage?.deliveredSeconds == 10)
        #expect(!LiveDiagnosticsLog(directory: d, sessionId: "p").events().contains { $0.kind == .captureStop },
                "nothing appended once the build began")
    }

    /// L review 158: the record's build reads the live log off the main actor, bounded — never behind a write that hangs
    /// on its folder. It is then built from the ring alone and says so; its live log is never committed away. Another
    /// folder's build is not held up by it.
    @Test func aBuildWhoseFolderDoesNotAnswerIsBoundedAndSaysSo() async throws {
        let d = try dir(), elsewhere = try dir()
        defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: elsewhere) }
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        // Its own live-log queues (L review 205): the hung one is never walked by another test's `flushAll`.
        let queues = LiveDiagnosticsLog.Queues()
        let writer = LiveDiagnosticsLog(directory: d, sessionId: "other", queues: queues)
        writer.writeObserver = { _ = stuck.wait(timeout: .now() + 10) }   // a write that hangs on the folder
        writer.append(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning))
        let evidence = SessionEvidence(folderReads: FolderReads(label: "evidence-\(UUID().uuidString)", volumeOf: { $0 }), logQueues: queues)
        evidence.folderDeadline = 0.3
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        let began = ContinuousClock.now
        let record = await evidence.finalize(sessionId: "s", directory: d)
        #expect(ContinuousClock.now - began < .seconds(2), "bounded")
        #expect(record.events.contains { $0.kind == .xpcInterruption }, "the ring")
        #expect(record.events.contains { $0.kind == .folderNotAnswering }, "said")
        // Another folder: its own io queue and its own read queue — built at once.
        evidence.beginCapture(sessionId: "e", directory: elsewhere)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 6), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        let other = await evidence.finalize(sessionId: "e", directory: elsewhere)
        #expect(!other.events.contains { $0.kind == .folderNotAnswering })
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("e.diag.jsonl").path))
        stuck.signal()
        queues.flushAll()
        evidence.commit(sessionId: "s", directory: d)
        queues.flushAll()
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "never committed away")
    }

    // MARK: - L round E (199, 200, 203, 204)

    private let anomaly = CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly)

    /// Record files as production looks at them, except `stat` answers `errno` for the names in `lying`.
    private func files(stat lying: [String: Int32] = [:], exclusive: Int32? = nil) -> SessionEvidence.RecordFiles {
        let live = SessionEvidence.RecordFiles.live
        return SessionEvidence.RecordFiles(
            stat: { path in lying[URL(fileURLWithPath: path).lastPathComponent] ?? live.stat(path) },
            renameExclusively: { from, to in exclusive ?? live.renameExclusively(from, to) })
    }

    /// L review 199: a `stat` that ERRS (EIO, ESTALE, ETIMEDOUT on a share) is not "no such file": the name is taken. The
    /// recording's own `.diag.jsonl` is never written over — the relaunch's record goes beside it.
    @Test func aRecordWhoseStatErrsIsTakenNeverOverwritten() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let evidence = SessionEvidence(recordFiles: files(stat: ["s.diag.jsonl": EIO]))
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original, "never written over")
        #expect(try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
    }

    /// … and a name a `stat` wrongly calls free (a share's stale attribute cache) is created EXCLUSIVELY: the rename that
    /// would replace the original fails with EEXIST, and the next name is taken.
    @Test func aRecordIsCreatedExclusivelyEvenWhenAStatSaysItIsFree() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let evidence = SessionEvidence(recordFiles: files(stat: ["s.diag.jsonl": ENOENT]))
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original, "never written over")
        #expect(try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).allSatisfy { !$0.hasSuffix(".tmp") }, "no temporary left")
    }

    /// … and on a volume with no exclusive rename (exFAT, SMB: ENOTSUP), a check-then-rename under a lock: still never
    /// over a record that is there, and a free name is written.
    @Test func aVolumeWithoutAnExclusiveRenameStillNeverOverwrites() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: d.appendingPathComponent("s.diag.jsonl"))
        let evidence = SessionEvidence(recordFiles: files(exclusive: ENOTSUP))
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)
        #expect(try Data(contentsOf: d.appendingPathComponent("s.diag.jsonl")) == original)
        #expect(try String(contentsOf: d.appendingPathComponent("s.relaunch.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
        let fresh = try dir(); defer { try? FileManager.default.removeItem(at: fresh) }
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "f", directory: fresh)
        #expect(try String(contentsOf: fresh.appendingPathComponent("f.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
    }

    /// L review 200: the "unwritten" mark stays until a SUCCESSFUL write — a first commit keeps the live log, and so does
    /// every later one: the live log is the record's only copy.
    @Test func everyCommitKeepsTheLiveLogUntilTheRecordIsWritten() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let evidence = SessionEvidence()
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)
        let own = d.appendingPathComponent("s.diag.jsonl")
        try FileManager.default.removeItem(at: own)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)   // unwritable now
        _ = await evidence.finalize(sessionId: "s", directory: d)
        evidence.commit(sessionId: "s", directory: d)
        evidence.commit(sessionId: "s", directory: d)   // a second commit (the next pass's gate)
        LiveDiagnosticsLog.flushAll()
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path), "the only copy is kept")
    }

    /// L review 203: a drain that FAILED (its XPC call errored) leaves a trace in the record — never only a log line.
    @Test func aFailedDrainIsOnRecord() {
        let evidence = SessionEvidence()
        #expect(evidence.mergeDrain(.failed), "answered: not a timeout")
        #expect(evidence.diagnostics.events.contains { $0.kind == .helperDrainFailed && $0.severity == .anomaly })
        #expect(!evidence.mergeDrain(.timedOut))
    }

    /// L review 204: a build that timed out and writes LATER wrote this process's own record: a second build of the same
    /// session updates it, never a misleading `.relaunch` beside it.
    @Test func aTimedOutBuildThatLandsLaterIsThisProcesssOwnRecord() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let hung = HungRead("evidence: build"), once = Harness.Box(true)
        defer { hung.release() }
        let evidence = SessionEvidence(folderReads: FolderReads(label: "evidence-\(UUID().uuidString)", beforeEachRead: { name in
            guard once.value, name == hung.label else { return }
            once.value = false   // only the first build hangs
            hung.hangIfNamed(name)
        }))
        evidence.folderDeadline = 0.2
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(anomaly)
        _ = await evidence.finalize(sessionId: "s", directory: d)   // timed out: built from the ring alone
        hung.release()
        await Harness.until { FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.jsonl").path) }
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.jsonl").path), "the late write landed")
        // The late build has finished on its queue (a read behind it answered) before the next build is asked.
        _ = await evidence.folderReads.read("settle", folder: d.path, seconds: 5) { 0 }
        evidence.folderDeadline = 5
        _ = await evidence.finalize(sessionId: "s", directory: d)   // the salvage builds it again
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("s.relaunch.diag.jsonl").path), "its own file, updated")
    }
}
