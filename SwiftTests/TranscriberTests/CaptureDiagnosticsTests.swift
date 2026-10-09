import Testing
import Foundation
@testable import TranscriberCore

struct CaptureDiagnosticsTests {
    let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func event(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        at offset: TimeInterval,
        origin: CaptureEvent.Origin = .app
    ) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: origin, kind: kind, severity: severity)
    }

    @Test func recordsInOrder() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1))
        #expect(d.events.count == 2)
        #expect(d.events.first?.kind == .captureStart)
        #expect(d.events.last?.kind == .formatChanged)
    }

    @Test func eventCapEvictsOldest() {
        var d = CaptureDiagnostics(maxEvents: 3, maxBytes: 1_000_000)
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        #expect(d.events.count == 3)
        #expect(d.droppedCount == 2)
        #expect(d.events.first?.timestamp == base.addingTimeInterval(2))  // oldest two dropped
    }

    @Test func byteCapEvictsToNewest() {
        var d = CaptureDiagnostics(maxEvents: 5000, maxBytes: 10)  // smaller than a single event
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        #expect(d.events.count == 1)            // guard always keeps the newest
        #expect(d.droppedCount == 4)
        #expect(d.events.first?.timestamp == base.addingTimeInterval(4))
    }

    @Test func isAnomalousOnlyWithAnomalyEvent() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.systemFormatDetected, .info, at: 1))
        #expect(d.isAnomalous == false)
        d.record(event(.streamStopError, .anomaly, at: 2))
        #expect(d.isAnomalous == true)
    }

    // MARK: - #220: System Audio Recording permission denial

    /// A tap denied by TCC records 100% digital zeros that look structurally perfect. That is the
    /// definition of compromised content, so it must count against the recording's quality.
    @Test func permissionDenialIsQualityCompromising() {
        #expect(CaptureEventKind.qualityCompromising.contains(.systemAudioPermissionDenied))
        #expect(!CaptureEventKind.qualityCompromising.contains(.systemAudioPermissionRestored))
    }

    /// The 2026-09-23 incident's provenance said `system_audio_unrecovered: false` for a recording
    /// with no remote audio at all. A denial that was never restored must set it.
    @Test func unrestoredPermissionDenialMarksSystemAudioUnrecovered() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0, origin: .helper))
        d.record(event(.systemAudioPermissionDenied, .anomaly, at: 1, origin: .helper))
        #expect(d.systemAudioUnrecovered == true)
    }

    @Test func restoredPermissionDenialDoesNotMarkSystemAudioUnrecovered() {
        var d = CaptureDiagnostics()
        d.record(event(.systemAudioPermissionDenied, .anomaly, at: 1, origin: .helper))
        d.record(event(.systemAudioPermissionRestored, .info, at: 2, origin: .helper))
        #expect(d.systemAudioUnrecovered == false)
        // The lost stretch still compromises the recording even though capture came back.
        #expect(d.qualityAnomalyCount == 1)
    }

    @Test func denialAfterARestoreMarksSystemAudioUnrecoveredAgain() {
        var d = CaptureDiagnostics()
        d.record(event(.systemAudioPermissionDenied, .anomaly, at: 1, origin: .helper))
        d.record(event(.systemAudioPermissionRestored, .info, at: 2, origin: .helper))
        d.record(event(.systemAudioPermissionDenied, .anomaly, at: 3, origin: .helper))
        #expect(d.systemAudioUnrecovered == true)
    }

    /// The permission-independent fact (#220): how much of the tap track was exact digital zero.
    @Test func provenanceCarriesTapTrackExactZeroSeconds() {
        var d = CaptureDiagnostics()
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .captureStop, severity: .info,
                              detail: ["system_delivered_seconds": "3000", "system_exact_zero_seconds": "2990"]))
        // A crash-recovered recording has one captureStop per helper session: summed.
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info,
                              detail: ["system_delivered_seconds": "100", "system_exact_zero_seconds": "10"]))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.systemDeliveredSeconds == 3100)
        #expect(p.systemExactZeroSeconds == 3000)
        #expect(p.asMetadataDictionary()["system_exact_zero_seconds"] as? Int == 3000)
    }

    @Test func provenanceOmitsTapTrackFactsWithoutTheTap() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStop, .info, at: 0, origin: .helper))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.systemExactZeroSeconds == nil)
        #expect(p.asMetadataDictionary()["system_exact_zero_seconds"] == nil)
    }

    @Test func oldProvenanceWithoutTapFactsStillDecodes() throws {
        let json = #"{"engine":"e","route_changes":0,"retries":0,"recovered":false,"anomaly_count":0}"#
        let p = try JSONDecoder().decode(CaptureProvenance.self, from: Data(json.utf8))
        #expect(p.systemExactZeroSeconds == nil)
    }

    @Test func countersReflectKinds() {
        // Mirrors real severities: restartInPlace/retry/launchRecovery are warnings; the route
        // disruption itself (streamStopError) is the anomaly. routeChangeCount counts the handled
        // restarts (council F5), not the never-emitted .formatChanged.
        var d = CaptureDiagnostics()
        d.record(event(.restartInPlace, .warning, at: 0))
        d.record(event(.restartInPlace, .warning, at: 1))
        d.record(event(.retry, .warning, at: 2))
        d.record(event(.launchRecovery, .warning, at: 3))
        d.record(event(.streamStopError, .anomaly, at: 4))
        d.record(event(.streamStopError, .anomaly, at: 5))
        #expect(d.routeChangeCount == 2)   // counts .restartInPlace
        #expect(d.retryCount == 1)
        #expect(d.didRecover == true)
        #expect(d.anomalyCount == 2)       // the two .anomaly-severity events
    }

    @Test func mergeInterleavesByTime() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.captureStop, .info, at: 4))
        d.merge([event(.micSwitch, .info, at: 2, origin: .helper)])
        #expect(d.events.map { $0.timestamp } == [0, 2, 4].map { base.addingTimeInterval($0) })
    }

    @Test func jsonlRoundTrips() throws {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1, origin: .helper))
        let lines = d.jsonlData().split(separator: 0x0A).map { Data($0) }
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(CaptureEvent.self, from: $0) }
        #expect(decoded == d.events)
    }

    @Test func snapshotRoundTripsAcrossXPC() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.retry, .anomaly, at: 1))
        let restored = CaptureDiagnostics.events(from: d.snapshotData())
        #expect(restored == d.events)
    }

    @Test func cleanRunProvenanceIsZeroed() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.systemFormatDetected, .info, at: 1))
        let p = d.makeProvenance(engine: "fluid_audio", systemFormat: "48000Hz/1ch", micFormat: "48000Hz/1ch", micDevice: "AirPods")
        #expect(d.isAnomalous == false)
        #expect(p.routeChanges == 0)
        #expect(p.retries == 0)
        #expect(p.recovered == false)
        #expect(p.anomalyCount == 0)
        #expect(p.engine == "fluid_audio")
    }

    // Fix round 1 item 4: renamed from `clearResetsRing` — clear() empties the EVENTS but keeps the
    // out-of-ring counters (droppedCount included); only resetSession() zeroes them.
    @Test func clearEmptiesEventsButKeepsDroppedCount() {
        var d = CaptureDiagnostics(maxEvents: 2)
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        d.clear()
        #expect(d.events.isEmpty)
        // droppedCount now lives outside the ring and survives clear() (an in-session restart) —
        // see clearKeepsTheOutOfRingCountersAndResetSessionZeroesThem below.
        #expect(d.droppedCount == 3)
    }

    // #101 per-session reset, restated for v2 (L4/L14): `clear()` is an IN-SESSION restart and keeps the
    // counters that live outside the ring; `resetSession()` is the new-session reset that zeroes them.
    @Test func clearKeepsTheOutOfRingCountersAndResetSessionZeroesThem() {
        var d = CaptureDiagnostics()
        d.record(event(.restartInPlace, .warning, at: 0))
        d.record(event(.restartInPlace, .warning, at: 1))
        d.record(event(.retry, .warning, at: 2))
        d.record(event(.launchRecovery, .warning, at: 3))
        d.record(event(.streamStopError, .anomaly, at: 4))
        let dirty = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(dirty.routeChanges == 2 && dirty.anomalyCount == 1 && dirty.retries == 1 && dirty.recovered)

        d.clear()
        d.record(event(.captureStart, .info, at: 10))
        let restarted = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(restarted.systemAudioUnrecovered == false)
        #expect(restarted.retries == 1 && restarted.recovered == true, "the restart is part of this session's story")
        // R2b item 8: out of ring too, so `anomaly_count` never drops below `quality_anomaly_count`.
        #expect(restarted.routeChanges == 2 && restarted.anomalyCount == 1, "the route changes and the anomaly still happened")

        d.resetSession()
        d.record(event(.captureStart, .info, at: 20))
        let fresh = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(fresh.retries == 0 && fresh.recovered == false && fresh.eventsDropped == 0)
        #expect(fresh.routeChanges == 0 && fresh.anomalyCount == 0)
    }

    @Test func countersSurviveEvictionAndClear() {
        var d = CaptureDiagnostics(maxEvents: 2)
        d.record(event(.retry, .warning, at: 0))
        d.record(event(.retry, .warning, at: 1))
        d.record(event(.retry, .warning, at: 2))
        #expect(d.events.count == 2 && d.droppedCount == 1)
        #expect(d.retryCount == 3, "the evicted retry still counts")
        d.clear()
        #expect(d.retryCount == 3 && d.droppedCount == 1)
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).eventsDropped == 1)
        // Fix round 1 item 4: this assertion was previously untestable (nothing exercised it failing).
        d.resetSession()
        #expect(d.droppedCount == 0)
    }

    /// Scan B P3.6(2): `merge()` re-records the ring's own events; that must not count them twice.
    @Test func mergeDoesNotDoubleCountTheCounters() {
        var d = CaptureDiagnostics()
        d.record(event(.retry, .warning, at: 0))
        d.merge([event(.retry, .warning, at: 1, origin: .helper)])
        #expect(d.events.count == 2 && d.retryCount == 2)
        d.merge([])
        #expect(d.retryCount == 2)
    }

    @Test func eventsDroppedRoundTripsInProvenance() throws {
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, eventsDropped: 7)
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(back.eventsDropped == 7 && p.asMetadataDictionary()["events_dropped"] as? Int == 7)
        let legacy = Data(#"{"engine":"e","route_changes":0,"retries":0,"recovered":false,"anomaly_count":0}"#.utf8)
        #expect(try JSONDecoder().decode(CaptureProvenance.self, from: legacy).eventsDropped == 0)
    }

    // #86: a system-stream-unrecovered event must surface in provenance + metadata.
    @Test func systemAudioUnrecoveredFlagsProvenance() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        #expect(d.systemAudioUnrecovered == false)
        d.record(event(.systemAudioUnrecovered, .anomaly, at: 1))
        #expect(d.systemAudioUnrecovered == true)

        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.systemAudioUnrecovered == true)
        #expect(p.anomalyCount == 1)
        #expect(p.asMetadataDictionary()["system_audio_unrecovered"] as? Bool == true)
    }

    @Test func cleanRunMetadataHasUnrecoveredFalse() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.asMetadataDictionary()["system_audio_unrecovered"] as? Bool == false)
    }

    /// v2 F1: the overhaul's event vocabulary lands first so every stream compiles against it.
    /// The severity CLASS is the contract: a kind in `qualityCompromising` changes the completion
    /// notice and the per-track status; the others are evidence only.
    @Test func overhaulEventKindsCarryTheirSeverityClass() {
        let compromising: [CaptureEventKind] = [.neverDelivered, .tapRecoveryGivenUp, .recoveryStuck, .captureGap, .rotationFailed]
        for k in compromising {
            #expect(CaptureEventKind.qualityCompromising.contains(k), "\(k.rawValue) must count against the record")
        }
        let evidenceOnly: [CaptureEventKind] = [
            .helperIdleExit, .livenessRecovered, .firstFrames, .alarmRaised, .alarmCleared, .aggregateIOStopped,
            .tapRecoveryRung, .serviceRestarted, .trackCoverage, .sessionWriteFailed, .diskLow, .xpcTimeout,
            .systemSleep, .systemWake,
        ]
        for k in evidenceOnly {
            #expect(!CaptureEventKind.qualityCompromising.contains(k), "\(k.rawValue) must not taint the record")
        }
    }

    /// A crash-recovered recording has several helper sessions, each with its own captureStop.
    @Test func provenanceSumsCoverageAcrossHelperSessions() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 100
        var b = TrackAccounting(); b.expectedSeconds = 50; b.deliveredSeconds = 0
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info, detail: b.asDetail(prefix: "remote")))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteCoverage?.expectedSeconds == 150)
        #expect(p.remoteCoverage?.deliveredSeconds == 100)
        #expect(p.remoteStatus == "compromised")
        #expect(p.systemDeliveredSeconds == 100, "legacy field derived from coverage")
        #expect(p.localCoverage == nil && p.localStatus == nil)
        let meta = p.asMetadataDictionary()
        #expect((meta["remote_coverage"] as? [String: Any])?["status"] as? String == "compromised")
        #expect(meta["local_coverage"] == nil)
    }

    /// A `captureStop` as a helper session reports it; `standIn` = made from that helper's last status pull.
    private func stop(_ seconds: Double, helper: String, at offset: TimeInterval, standIn: Bool = false) -> CaptureEvent {
        var a = TrackAccounting(); a.expectedSeconds = seconds; a.deliveredSeconds = seconds
        var detail = a.asDetail(prefix: "remote").merging(a.asDetail(prefix: "local")) { x, _ in x }
        detail["helper_session"] = helper
        if standIn { detail["from"] = "status pull" }
        return CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: .helper, kind: .captureStop, severity: .info, detail: detail)
    }

    /// #229: coverage is tallied per helper session. A helper's real `captureStop` REPLACES the stand-in made from its
    /// last status pull — whichever arrives first — and the helper sessions are then summed.
    @Test func aRealStopReplacesItsHelperSessionsStandIn() {
        var d = CaptureDiagnostics()
        d.record(stop(40, helper: "1000-0", at: 0))
        d.record(stop(60, helper: "2000-0", at: 1, standIn: true))
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 100, "a stand-in counts while its helper has no stop")
        d.record(stop(65, helper: "2000-0", at: 2))
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 105, "40 + 65: the stop replaced the stand-in")
        #expect(provenance(d).remoteCoverage?.expectedSeconds == 105 && provenance(d).localCoverage?.deliveredSeconds == 105)
        d.record(stop(64, helper: "2000-0", at: 3, standIn: true))
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 105, "a stand-in never counts once its helper stopped")
    }

    /// … a later status pull of the same helper is the same counters, further on: the latest stands in, never their sum.
    @Test func aHelperSessionsLatestStandInIsTheOneThatCounts() {
        var d = CaptureDiagnostics()
        d.record(stop(60, helper: "2000-0", at: 5, standIn: true))
        d.record(stop(50, helper: "2000-0", at: 1, standIn: true))   // an older pull, seen later
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 60)
        d.record(stop(70, helper: "2000-0", at: 9, standIn: true))
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 70)
    }

    /// … and the per-helper tally lives outside the ring, like the sum it replaced: a stand-in evicted from the ring is
    /// still replaced by its helper's stop, and a re-merge of the same events counts nothing twice.
    @Test func theStandInIsReplacedEvenAfterItLeftTheRing() {
        var d = CaptureDiagnostics(maxEvents: 2)
        d.record(stop(60, helper: "2000-0", at: 0, standIn: true))
        d.record(event(.captureStart, .info, at: 1))
        d.record(event(.captureStart, .info, at: 2))
        #expect(!d.events.contains { $0.kind == .captureStop }, "evicted")
        let real = stop(65, helper: "2000-0", at: 3)
        d.record(real)
        d.merge([real, stop(60, helper: "2000-0", at: 0, standIn: true)])
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 65)
    }

    /// #229: a record that holds only part of its session marks BOTH sides' coverage as a lower bound, changes no
    /// number, invents no coverage where there is none, and a new session starts unmarked.
    @Test func aPartialRecordMarksBothSidesCoverageAsALowerBound() {
        var d = CaptureDiagnostics()
        d.coverageIsLowerBound = true
        #expect(provenance(d).remoteCoverage == nil && provenance(d).localCoverage == nil, "no coverage is not marked coverage")
        d.record(stop(30, helper: "1000-0", at: 0))
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == true && provenance(d).localCoverage?.coverageIncomplete == true)
        #expect(provenance(d).remoteCoverage?.deliveredSeconds == 30 && provenance(d).remoteStatus == "healthy")
        d.coverageIsLowerBound = false
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == false && provenance(d).localCoverage?.coverageIncomplete == false)
        d.coverageIsLowerBound = true
        d.resetSession()
        d.record(stop(10, helper: "3000-0", at: 5))
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == false, "the next session's record is its own")
    }

    /// #295 item 2: a stand-in is the helper's last status pull, which can trail what it captured. Both sides it
    /// covers are marked as lower bounds (`coverage_incomplete`) with no number changed, and the helper's real stop,
    /// when it arrives, takes the mark away with the stand-in.
    @Test func aStandInMarksItsCoverageAsALowerBound() throws {
        var d = CaptureDiagnostics()
        d.record(stop(40, helper: "1000-0", at: 0))
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == false, "a real stop is exact")
        d.record(stop(60, helper: "2000-0", at: 1, standIn: true))
        let p = provenance(d)
        #expect(p.remoteCoverage?.coverageIncomplete == true && p.localCoverage?.coverageIncomplete == true)
        #expect(p.remoteCoverage?.deliveredSeconds == 100 && p.remoteStatus == "healthy", "the mark changes no number")
        let remote = try #require(p.asMetadataDictionary()["remote_coverage"] as? [String: Any])
        #expect(remote["coverage_incomplete"] as? Bool == true)
        d.record(stop(65, helper: "2000-0", at: 2))
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == false && provenance(d).localCoverage?.coverageIncomplete == false,
                "the real stop replaced the stand-in, and its mark with it")
    }

    /// … and a stand-in alone (the only helper crashed) is a lower bound too.
    @Test func aRecordOfStandInsAloneIsALowerBound() {
        var d = CaptureDiagnostics()
        d.record(stop(60, helper: "2000-0", at: 1, standIn: true))
        #expect(provenance(d).remoteCoverage?.coverageIncomplete == true && provenance(d).localCoverage?.coverageIncomplete == true)
    }

    private func captureStart(build: String?, at offset: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: .helper, kind: .captureStart, severity: .info,
                     detail: build.map { ["build": $0] } ?? [:])
    }

    /// #295 item 1: `captureStart`'s build stamp (#271) reaches the provenance, so a clean recording — which keeps no
    /// `.diag.jsonl` — still says which kind of build made it. Out of ring: an evicted start still counts.
    @Test func theCaptureStartsBuildIsInTheProvenance() {
        var d = CaptureDiagnostics(maxEvents: 1)
        #expect(provenance(d).build == nil, "no start, no claim")
        d.record(captureStart(build: "release", at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1))
        #expect(!d.events.contains { $0.kind == .captureStart }, "evicted")
        #expect(provenance(d).build == "release")
        #expect(provenance(d).asMetadataDictionary()["build"] as? String == "release")
        d.resetSession()
        #expect(provenance(d).build == nil, "the next session's stamp is its own")
    }

    /// Helper sessions of different builds (an update between a crash and its recovery) are both named, never one of
    /// them alone; a start from a helper that predates the stamp claims nothing.
    @Test func helperSessionsOfDifferentBuildsAreBothNamed() {
        var d = CaptureDiagnostics()
        d.record(captureStart(build: nil, at: 0))
        #expect(provenance(d).build == nil)
        #expect(provenance(d).asMetadataDictionary()["build"] == nil, "an unknown build is left out, never guessed")
        d.record(captureStart(build: "release", at: 1))
        d.record(captureStart(build: "debug", at: 2))
        d.record(captureStart(build: "release", at: 3))
        #expect(provenance(d).build == "debug,release")
    }

    /// The stamp persists in `session.json`: it round-trips, and a stamp written before it existed still decodes.
    @Test func theBuildRoundTripsAndOlderStampsStillDecode() throws {
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, build: "release")
        let decoded = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(decoded.build == "release" && decoded == p)
        let older = #"{"engine":"e","route_changes":0,"retries":0,"recovered":false,"anomaly_count":0}"#
        #expect(try JSONDecoder().decode(CaptureProvenance.self, from: Data(older.utf8)).build == nil)
    }

    private func provenance(_ d: CaptureDiagnostics) -> CaptureProvenance {
        d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
    }

    /// Spec §7.1 (scan C12): only CONTENT-compromising kinds mark a side compromised. A stall that
    /// healed is evidence in the ring, not a verdict on the record.
    @Test func aHealedStallDoesNotCompromiseTheTrackButRateDriftDoes() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 99
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .livenessGap, severity: .anomaly, detail: ["track": "system", "seconds": "3"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .livenessRecovered, severity: .info, detail: ["track": "system"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(2), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "healthy")
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(3), origin: .helper, kind: .rateDrift, severity: .anomaly, detail: ["source": "system-tap"]))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "compromised")
        #expect(d.contentAnomalyCount(track: "mic") == 0)
    }

    @Test func micContentKindsCountForTheLocalSideOnly() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 60; a.deliveredSeconds = 60
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .exactZeroMic, severity: .anomaly))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info,
                              detail: a.asDetail(prefix: "local").merging(a.asDetail(prefix: "remote")) { x, _ in x }))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.localStatus == "compromised" && p.remoteStatus == "healthy")
    }

    @Test func coverageRoundTripsThroughCodable() throws {
        var a = TrackAccounting(); a.expectedSeconds = 10; a.deliveredSeconds = 9
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, remoteCoverage: a, remoteStatus: "healthy")
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(back.remoteCoverage == a && back.remoteStatus == "healthy" && back.localCoverage == nil)
    }

    /// C6 round 1: a side that captured NOTHING is `neverDelivered`, never merely `compromised` —
    /// R1 must not print "partly captured (0 s delivered…)" for it, whatever else went wrong.
    @Test func aSideThatDeliveredNothingIsNeverDeliveredEvenWithAContentAnomaly() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 0
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .rateDrift, severity: .anomaly, detail: ["source": "system-tap"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "neverDelivered")
    }

    /// Fix round 1 item 5: the same precedence pinned for the tap side must hold for the mic side too.
    @Test func micSideNeverDeliveredBeatsAContentAnomalyToo() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 60; a.deliveredSeconds = 0
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .exactZeroMic, severity: .anomaly))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "local")))
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).localStatus == "neverDelivered")
    }

    /// Fix round 1 item 2: the status inputs (content-anomaly tallies, per-prefix coverage sums) must
    /// be out-of-ring, like the counters — a side's verdict cannot change just because ITS OWN evidence
    /// aged out of the bounded ring.
    @Test func statusTalliesSurviveEvictionOfTheirEvidence() {
        var d = CaptureDiagnostics(maxEvents: 2)
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 100
        d.record(CaptureEvent(timestamp: base, origin: .helper, kind: .rateDrift, severity: .anomaly, detail: ["source": "system-tap"]))
        d.record(CaptureEvent(timestamp: base.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        // Two more events push both the rateDrift and the captureStop out of the bounded ring.
        d.record(event(.captureStart, .info, at: 2))
        d.record(event(.captureStart, .info, at: 3))
        #expect(d.events.count == 2)
        #expect(!d.events.contains { $0.kind == .rateDrift || $0.kind == .captureStop }, "the evidence itself aged out of the ring")
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteStatus == "compromised", "the content-anomaly tally must survive eviction of the rateDrift event")
        #expect(p.remoteCoverage?.expectedSeconds == 100, "the coverage tally must survive eviction of the captureStop event")
    }

    /// Fix round 1 item 3: a missing or unparseable status must never silently read as "healthy" —
    /// it is recomputed from the coverage that is actually present.
    @Test func metadataNeverDefaultsAnUnknownStatusToHealthy() {
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 0  // unambiguously neverDelivered
        let missing = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                        recovered: false, anomalyCount: 0, remoteCoverage: a, remoteStatus: nil)
        #expect((missing.asMetadataDictionary()["remote_coverage"] as? [String: Any])?["status"] as? String == "neverDelivered")

        let garbage = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                        recovered: false, anomalyCount: 0, remoteCoverage: a, remoteStatus: "not_a_real_status")
        #expect((garbage.asMetadataDictionary()["remote_coverage"] as? [String: Any])?["status"] as? String == "neverDelivered")
    }
}

struct CaptureProvenanceTests {
    @Test func encodesSnakeCaseKeysAndRoundTrips() throws {
        let p = CaptureProvenance(
            engine: "fluid_audio", systemFormat: "48000Hz/1ch", micFormat: nil, micDevice: "AirPods",
            routeChanges: 1, retries: 2, recovered: true, anomalyCount: 3
        )
        let data = try JSONEncoder().encode(p)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("route_changes"))
        #expect(str.contains("anomaly_count"))
        #expect(str.contains("mic_device"))
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: data)
        #expect(back == p)
    }

    @Test func metadataDictionaryOmitsNilOptionals() {
        let p = CaptureProvenance(
            engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil,
            routeChanges: 0, retries: 0, recovered: false, anomalyCount: 0
        )
        let dict = p.asMetadataDictionary()
        #expect(dict["system_format"] == nil)
        #expect(dict["mic_device"] == nil)
        #expect(dict["engine"] as? String == "e")
        #expect(dict["route_changes"] as? Int == 0)
    }

    // MARK: - Confirmed permission denial (round 3 item 6)

    private func provenance(_ events: [CaptureEvent]) -> CaptureProvenance {
        var d = CaptureDiagnostics()
        for e in events { d.record(e) }
        return d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
    }

    private func denied(_ status: String, at offset: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSinceReferenceDate: 3_000_000 + offset), origin: .helper,
                     kind: .systemAudioPermissionDenied, severity: .anomaly, detail: ["status": status])
    }

    private func helperEvent(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, at offset: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSinceReferenceDate: 3_000_000 + offset), origin: .helper, kind: kind, severity: severity)
    }

    @Test func onlyAConfirmedDenialSetsTheConfirmedFlag() {
        #expect(provenance([denied("denied", at: 1)]).systemPermissionDeniedConfirmed)
        #expect(!provenance([denied("unconfirmed", at: 1)]).systemPermissionDeniedConfirmed)
        let restartFailed = provenance([helperEvent(.systemAudioUnrecovered, .anomaly, at: 1)])
        #expect(restartFailed.systemAudioUnrecovered && !restartFailed.systemPermissionDeniedConfirmed,
                "a failed restart alone is not a permission denial")
        #expect(!provenance([denied("denied", at: 1), helperEvent(.systemAudioPermissionRestored, .info, at: 2)]).systemPermissionDeniedConfirmed)
    }

    @Test func theConfirmedFlagIsStampedAndDecodedTolerantly() throws {
        let p = provenance([denied("denied", at: 1)])
        #expect(p.asMetadataDictionary()["system_permission_denied_confirmed"] as? Bool == true)
        let legacy = Data(#"{"engine":"e","route_changes":0,"retries":0,"recovered":false,"anomaly_count":0}"#.utf8)
        #expect(try !JSONDecoder().decode(CaptureProvenance.self, from: legacy).systemPermissionDeniedConfirmed)
    }

    /// Round 4: each side's coverage carries ITS content-anomaly count, not the session's.
    @Test func coverageCarriesThePerSideContentAnomalyCount() throws {
        var d = CaptureDiagnostics()
        let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
        d.record(CaptureEvent(timestamp: t0, origin: .helper, kind: .rateDrift, severity: .anomaly, detail: ["track": "system"]))
        d.record(CaptureEvent(timestamp: t0.addingTimeInterval(1), origin: .helper, kind: .captureStop, severity: .info,
                              detail: TrackAccounting().asDetail(prefix: "remote").merging(TrackAccounting().asDetail(prefix: "local")) { a, _ in a }))
        let dict = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).asMetadataDictionary()
        #expect((dict["remote_coverage"] as? [String: Any])?["content_anomaly_count"] as? Int == 1)
        #expect((dict["local_coverage"] as? [String: Any])?["content_anomaly_count"] as? Int == 0)
    }
}

// MARK: - R2 council (XI bug 2): the notice's two fields survive eviction

struct CaptureDiagnosticsOutOfRingTests {
    let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func event(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, at offset: TimeInterval,
                       origin: CaptureEvent.Origin = .app) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: origin, kind: kind, severity: severity)
    }

    /// `quality_anomaly_count` and `system_audio_unrecovered` were scanned from the evicting ring:
    /// once their evidence aged out, a compromised recording read "Transcription Complete". They are
    /// counted out of ring, once per event (a re-merge is not a new anomaly), like the side tallies.
    @Test func qualityCountAndUnrecoveredSurviveEvictionAndReMerge() {
        var d = CaptureDiagnostics(maxEvents: 3)
        let evidence = [
            event(.rateDrift, .anomaly, at: 1, origin: .helper),
            event(.systemAudioUnrecovered, .anomaly, at: 2, origin: .helper),
        ]
        evidence.forEach { d.record($0) }
        for i in 0..<10 { d.record(event(.restartInPlace, .warning, at: 10 + Double(i))) }
        #expect(!d.events.contains { CaptureEventKind.qualityCompromising.contains($0.kind) }, "the evidence has left the ring")
        #expect(d.qualityAnomalyCount == 2)
        #expect(d.systemAudioUnrecovered)
        d.merge(evidence)   // the live log re-presents the evicted events at finalize
        #expect(d.qualityAnomalyCount == 2, "the same event seen again is not a second anomaly")
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.qualityAnomalyCount == 2 && p.systemAudioUnrecovered)
    }

    /// An in-session restart (`clear()`) keeps them — they are this session's story; a new session
    /// (`resetSession()`) zeroes them.
    @Test func qualityCountAndUnrecoveredFollowTheSessionNotTheRing() {
        var d = CaptureDiagnostics()
        d.record(event(.livenessGap, .anomaly, at: 1, origin: .helper))
        d.record(event(.systemAudioPermissionDenied, .anomaly, at: 2, origin: .helper))
        d.clear()
        #expect(d.qualityAnomalyCount == 2 && d.systemAudioUnrecovered)
        d.record(event(.systemAudioPermissionRestored, .info, at: 3, origin: .helper))
        #expect(!d.systemAudioUnrecovered, "a later restore still clears a denial after the ring was cleared")
        #expect(d.qualityAnomalyCount == 2, "the lost stretch still compromised the recording")
        d.resetSession()
        #expect(d.qualityAnomalyCount == 0 && !d.systemAudioUnrecovered)
    }

    /// C-M7: one event of a kind this build doesn't know (a newer helper) failed the WHOLE drain, so
    /// every event of the session was lost. Unknown events are skipped; the rest arrive.
    @Test func anUnknownEventKindDoesNotLoseTheWholeDrain() throws {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0, origin: .helper))
        d.record(event(.rateDrift, .anomaly, at: 1, origin: .helper))
        var array = try #require(JSONSerialization.jsonObject(with: d.snapshotData()) as? [[String: Any]])
        var future = array[0]; future["kind"] = "fromTheFuture"
        array.insert(future, at: 1)
        let restored = CaptureDiagnostics.events(from: try JSONSerialization.data(withJSONObject: array))
        #expect(restored.map(\.kind) == [.captureStart, .rateDrift])
        #expect(CaptureDiagnostics.events(from: Data("garbage".utf8)).isEmpty)
    }
}

// MARK: - R2b item 8: record consistency

struct CaptureDiagnosticsConsistencyTests {
    let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func event(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, at offset: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: .helper, kind: kind, severity: severity)
    }

    /// `anomaly_count` (every anomaly) is the superset of `quality_anomaly_count`; scanned from the
    /// ring while the subset was out of ring, eviction made the superset the smaller number.
    @Test func theAnomalySupersetNeverDropsBelowTheSubsetAfterEviction() {
        var d = CaptureDiagnostics(maxEvents: 2)
        d.record(event(.rateDrift, .anomaly, at: 1))
        d.record(event(.restartInPlace, .warning, at: 2))
        d.record(event(.streamStopError, .anomaly, at: 3))
        for i in 0..<5 { d.record(event(.tapRecoveryRung, .warning, at: 10 + Double(i))) }
        d.merge([event(.rateDrift, .anomaly, at: 1)])   // re-presented: not a second anomaly
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.anomalyCount == 2 && p.qualityAnomalyCount == 1 && p.routeChanges == 1)
    }

    /// An event this build could not decode was skipped silently; it is counted into `events_dropped`.
    @Test func undecodableDrainedEventsCountAsDropped() throws {
        var helper = CaptureDiagnostics()
        helper.record(event(.captureStart, .info, at: 0))
        helper.record(event(.rateDrift, .anomaly, at: 1))
        var array = try #require(JSONSerialization.jsonObject(with: helper.snapshotData()) as? [[String: Any]])
        var future = array[0]; future["kind"] = "fromTheFuture"
        array.append(future)
        var app = CaptureDiagnostics()
        app.mergeDrained(try JSONSerialization.data(withJSONObject: array))
        #expect(app.events.map(\.kind) == [.captureStart, .rateDrift])
        #expect(app.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).eventsDropped == 1)
    }
}

/// Round 3 item 6: `isAnomalous` decides whether `<session>.diag.jsonl` is written. Scanned from the
/// ring, a session whose anomalies were evicted wrote nothing.
struct CaptureDiagnosticsIsAnomalousTests {
    @Test func anEvictedAnomalyStillMakesTheSessionAnomalous() {
        var d = CaptureDiagnostics(maxEvents: 2)
        let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
        d.record(CaptureEvent(timestamp: t0, origin: .helper, kind: .rateDrift, severity: .anomaly))
        for i in 1...5 { d.record(CaptureEvent(timestamp: t0.addingTimeInterval(Double(i)), origin: .helper, kind: .restartInPlace, severity: .warning)) }
        #expect(!d.events.contains { $0.severity == .anomaly }, "the anomaly has left the ring")
        #expect(d.isAnomalous)
        d.resetSession()
        #expect(!d.isAnomalous)
    }
}
