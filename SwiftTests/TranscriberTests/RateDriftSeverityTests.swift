import Foundation
import Testing
@testable import TranscriberCore

/// #308: a rate drift the helper healed in seconds is `degraded`, not `compromised`, and the record says how long
/// audio was at the wrong rate and where. The real case (0.9.0, a 61-min call): at hang-up the output changed rate
/// under the tap (declared 48000, ~44042 delivered); `rateDrift`, its remediation `restartInPlace` and the rebuild's
/// `firstFrames` within ~3 s, 4 s before Stop. The record said `compromised` — the verdict of a whole call at the
/// wrong rate.
@Suite struct RateDriftSeverityTests {
    private let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    private func coverage(expected: Double = 3657, delivered: Double = 3657) -> TrackAccounting {
        var a = TrackAccounting(); a.expectedSeconds = expected; a.deliveredSeconds = delivered; a.exactZeroSeconds = 0
        return a
    }

    private func drift(_ t: TimeInterval, onsetWithin: String? = "8.1") -> CaptureEvent {
        var detail = ["source": "system-tap", "reason": "rate drift — output device changed rate under the tap",
                      "declared": "48000", "actual": "44042"]
        detail["onset_within_seconds"] = onsetWithin
        return CaptureEvent(timestamp: at(t), origin: .helper, kind: .rateDrift, severity: .anomaly, detail: detail)
    }

    private func remediation(_ t: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: at(t), origin: .helper, kind: .restartInPlace, severity: .warning,
                     detail: ["source": "system-tap", "reason": "rate drift remediation", "attempt": "1"])
    }

    /// The rebuild's own success event: same reason, `rung` instead of `attempt` (`SystemTapSession.rebuild`).
    private func rebuildDone(_ t: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: at(t), origin: .helper, kind: .restartInPlace, severity: .warning,
                     detail: ["source": "system-tap", "reason": "rate drift remediation", "rung": "rebuildAggregate"])
    }

    private func firstFrames(_ t: TimeInterval, track: String = "system") -> CaptureEvent {
        CaptureEvent(timestamp: at(t), origin: .helper, kind: .firstFrames, severity: .info, detail: ["track": track])
    }

    private func start() -> CaptureEvent {
        CaptureEvent(timestamp: base, origin: .helper, kind: .captureStart, severity: .info, detail: ["system_source": "coreAudioTap"])
    }

    private func stop(_ t: TimeInterval, remote: TrackAccounting) -> CaptureEvent {
        CaptureEvent(timestamp: at(t), origin: .helper, kind: .captureStop, severity: .info, detail: remote.asDetail(prefix: "remote"))
    }

    private func provenance(_ events: [CaptureEvent]) -> CaptureProvenance {
        var d = CaptureDiagnostics()
        for e in events { d.record(e) }
        return d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
    }

    private func remoteSide(_ p: CaptureProvenance) -> [String: Any]? {
        p.asMetadataDictionary()["remote_coverage"] as? [String: Any]
    }

    private func driftEntries(_ p: CaptureProvenance) -> [[String: Any]] {
        remoteSide(p)?["rate_drift"] as? [[String: Any]] ?? []
    }

    /// The #308 shape: drift at 3650 s (onset at most 8.1 s earlier), remediation, first frames 3 s later, stop at 3657.
    private var realCase: [CaptureEvent] {
        [start(), drift(3650), remediation(3650.01), firstFrames(3653), stop(3657, remote: coverage())]
    }

    // MARK: - Status

    @Test func aDriftHealedInSecondsIsDegradedNotCompromised() {
        let p = provenance(realCase)
        #expect(p.remoteStatus == "degraded")
        #expect(remoteSide(p)?["status"] as? String == "degraded")
    }

    @Test func theAnomalyStaysInTheCounts() {
        let p = provenance(realCase)
        #expect(p.remoteContentAnomalyCount == 1)
        #expect(p.qualityAnomalyCount == 1)
        #expect(remoteSide(p)?["content_anomaly_count"] as? Int == 1)
    }

    @Test func theRecordSaysHowLongAndWhere() throws {
        let entry = try #require(driftEntries(provenance(realCase)).first)
        #expect(entry["healed"] as? Bool == true)
        #expect(entry["detected_offset_seconds"] as? Double == 3650)
        #expect(entry["offset_seconds"] as? Double == 3641.9)
        #expect(entry["healed_after_seconds"] as? Double == 3)
        #expect(entry["affected_seconds"] as? Double == 11.1)
        #expect(entry["affected_seconds_is_upper_bound"] as? Bool == true)
    }

    @Test func aDriftThatNeverHealedStaysCompromised() throws {
        let p = provenance([start(), drift(3650), remediation(3650.01), stop(3657, remote: coverage())])
        #expect(p.remoteStatus == "compromised")
        let entry = try #require(driftEntries(p).first)
        #expect(entry["healed"] as? Bool == false)
        #expect(entry["affected_seconds"] == nil)
    }

    /// No remediation (the budget was spent): a later first frames of another rebuild does not heal it.
    @Test func firstFramesWithoutTheRemediationRebuildDoNotHeal() {
        let p = provenance([start(), drift(100), firstFrames(103), stop(200, remote: coverage(expected: 200, delivered: 200))])
        #expect(p.remoteStatus == "compromised")
    }

    @Test func micFirstFramesDoNotHealTheRemoteSide() {
        let p = provenance([start(), drift(100), remediation(100), firstFrames(103, track: "mic"),
                            stop(200, remote: coverage(expected: 200, delivered: 200))])
        #expect(p.remoteStatus == "compromised")
    }

    @Test func aLongWrongRateWindowStaysCompromisedAndSaysHowLong() throws {
        let p = provenance([start(), drift(100, onsetWithin: "8.0"), remediation(100), firstFrames(110),
                            stop(200, remote: coverage(expected: 200, delivered: 200))])
        #expect(p.remoteStatus == "compromised")
        #expect(try #require(driftEntries(p).first)["affected_seconds"] as? Double == 18)
    }

    @Test func theBoundIsTheCoverageDeficitFloor() {
        #expect(RateDriftWindow.healedBoundSeconds == TrackAccounting.minimumDeficitSeconds)
        #expect(RateDriftWindow.healedWithinBound([RateDriftWindow(onsetWithinSeconds: 10, healedAfterSeconds: 5)]) == 1)
        #expect(RateDriftWindow.healedWithinBound([RateDriftWindow(onsetWithinSeconds: 10, healedAfterSeconds: 5.1)]) == 0)
    }

    /// An event with no onset measurement (setup-time drift, an older helper): the record says the onset is unknown
    /// and claims no window, so the side stays compromised.
    @Test func anUnknownOnsetIsSaidAndStaysCompromised() throws {
        let p = provenance([start(), drift(3650, onsetWithin: nil), remediation(3650.01), firstFrames(3653),
                            stop(3657, remote: coverage())])
        #expect(p.remoteStatus == "compromised")
        let entry = try #require(driftEntries(p).first)
        #expect(entry["onset"] as? String == "unknown")
        #expect(entry["offset_seconds"] == nil && entry["affected_seconds"] == nil)
        #expect(entry["healed"] as? Bool == true)
    }

    @Test func aHealedDriftWithASignificantDeficitStaysCompromised() {
        let p = provenance([start(), drift(100), remediation(100), firstFrames(103),
                            stop(200, remote: coverage(expected: 200, delivered: 150))])
        #expect(p.remoteStatus == "compromised")
    }

    @Test func aHealedDriftNextToAnUnhealedOneStaysCompromised() {
        let p = provenance([start(), drift(100), remediation(100), firstFrames(103), drift(300),
                            stop(400, remote: coverage(expected: 400, delivered: 400))])
        #expect(p.remoteStatus == "compromised")
        #expect(p.remoteContentAnomalyCount == 2)
    }

    /// #311 review: each remediation posts TWO `restartInPlace` with its reason — the start (`attempt`) and the
    /// rebuild's success (`rung`), later. A second drift detected before drift 1's rebuild finished, and never
    /// remediated itself, must not take that success event as its own remediation.
    @Test func aSecondUnremediatedDriftIsNotHealedByTheFirstOnesRebuild() throws {
        let p = provenance([start(), drift(100, onsetWithin: "5.0"), remediation(100.01), drift(100.5, onsetWithin: "2.0"),
                            rebuildDone(101), firstFrames(102), stop(200, remote: coverage(expected: 200, delivered: 200))])
        let entries = driftEntries(p)
        #expect(entries.count == 2)
        #expect(entries.first?["healed"] as? Bool == true)
        #expect(entries.last?["healed"] as? Bool == false)
        #expect(p.remoteStatus == "compromised")
    }

    /// #311 review: the bound is on the side's total wrong-rate audio, not on each drift.
    @Test func threeHealedSevenSecondDriftsAreCompromised() {
        var events = [start()]
        for t in [100.0, 600, 1100] {
            events += [drift(t, onsetWithin: "4.0"), remediation(t + 0.01), rebuildDone(t + 2), firstFrames(t + 3)]
        }
        events.append(stop(1500, remote: coverage(expected: 1500, delivered: 1500)))
        let p = provenance(events)
        #expect(driftEntries(p).allSatisfy { $0["healed"] as? Bool == true && $0["affected_seconds"] as? Double == 7 })
        #expect(p.remoteStatus == "compromised")
        #expect(p.remoteContentAnomalyCount == 3)
    }

    @Test func twoHealedDriftsWithinTheBoundTogetherAreDegraded() {
        var events = [start()]
        for t in [100.0, 600] {
            events += [drift(t, onsetWithin: "4.0"), remediation(t + 0.01), rebuildDone(t + 2), firstFrames(t + 3)]
        }
        events.append(stop(1000, remote: coverage(expected: 1000, delivered: 1000)))
        #expect(provenance(events).remoteStatus == "degraded")
    }

    /// Merges present events in any order (a drain split across two pulls, the live log at finalize).
    @Test func pairingDoesNotDependOnTheOrderEventsArrive() {
        var d = CaptureDiagnostics()
        for e in [stop(3657, remote: coverage()), firstFrames(3653), start()] { d.record(e) }
        d.merge([remediation(3650.01), drift(3650)])
        #expect(d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil).remoteStatus == "degraded")
    }

    @Test func provenanceRoundTripsTheWindowsAndRecomputesDegraded() throws {
        let p = provenance(realCase)
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: JSONEncoder().encode(p))
        #expect(back.remoteRateDrift == p.remoteRateDrift)
        // A stored status that is missing is recomputed from the coverage, the count and the windows.
        let unstamped = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 1, retries: 0,
                                          recovered: false, anomalyCount: 1, remoteCoverage: p.remoteCoverage, remoteStatus: nil,
                                          remoteContentAnomalyCount: 1, remoteRateDrift: p.remoteRateDrift)
        #expect((unstamped.asMetadataDictionary()["remote_coverage"] as? [String: Any])?["status"] as? String == "degraded")
    }

    @Test func degradedStatusFromCoverage() {
        let a = coverage()
        #expect(a.status(isTap: true, contentAnomalies: 1, healedDrifts: 1) == .degraded)
        #expect(a.status(isTap: true, contentAnomalies: 2, healedDrifts: 1) == .compromised)
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy)
    }

    // MARK: - The helper's onset bound

    private func nanos(_ s: Double) -> UInt64 { UInt64(s * 1_000_000_000) }

    /// 6 s healthy, then 44042 Hz: the reported onset bound covers the true onset and stays within the two windows.
    @Test func theMonitorReportsHowLongBeforeTheVerdictTheDriftCanHaveBegun() throws {
        var m = RateDriftMonitor()
        var t = 0.0, onset: Double?, verdictAt = 0.0
        while t < 30 {
            t += 0.01
            let frames = t <= 6 ? 480 : 440   // 48000 Hz, then 44000 Hz
            if case .drift = m.record(frames: frames, declaredRate: 48000, hostNanos: nanos(t)) {
                onset = m.onsetWithinSeconds; verdictAt = t; break
            }
        }
        let within = try #require(onset)
        #expect(within >= verdictAt - 6, "the true onset must be inside the reported window")
        #expect(within <= 10.1, "never more than the judged window plus the one before it")
    }

    @Test func aDriftFromTheFirstCallbackHasOnlyTheJudgedWindow() throws {
        var m = RateDriftMonitor()
        var t = 0.0
        while t < 30 {
            t += 0.01
            if case .drift = m.record(frames: 240, declaredRate: 48000, hostNanos: nanos(t)) { break }
        }
        let within = try #require(m.onsetWithinSeconds)
        #expect(abs(within - 5) < 0.05)
        m.reset()
        #expect(m.onsetWithinSeconds == nil)
    }

    // MARK: - What the user reads

    @Test func theNoticeFollowsTheStatus() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1, problemChunkCount: 0, segmentCount: 10, remoteStatus: "degraded")
                == "Transcription Complete — brief capture glitch")
        let body = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1, problemChunkCount: 0, segmentCount: 10,
                                                       remoteStatus: "degraded")
        #expect(body.contains("remote audio briefly affected"))
        #expect(!body.contains("partly captured"))
        #expect(body.contains("1 capture anomaly"), "the count is still said")
        // A compromised side still leads.
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 2, problemChunkCount: 0, segmentCount: 10,
                                                     remoteStatus: "degraded", localStatus: "compromised")
                == "Transcription Complete — capture compromised")
    }

    @Test func theSummaryBannerSaysHowLong() {
        let m = SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["A"],
                                dualStream: true,
                                remoteCapture: CaptureSideNote(status: "degraded", deliveredSeconds: 3657, expectedSeconds: 3657,
                                                               exactZeroSeconds: 0, anomalyCount: 1, wrongRateSeconds: 11.1),
                                localCapture: nil, coverageNotRecorded: false, gapCount: 0, gapSeconds: 0)
        #expect(SummaryPromptBuilder.captureLine(m)
                == "Remote audio: captured; up to 11 s recorded at the wrong rate before Parley recovered (1 capture anomaly recorded)")
    }

    /// End to end through the transcript: the stamped record reads back as degraded for the notice and the summary.
    @Test func theTranscriptCarriesItToTheNoticeAndTheSummary() throws {
        let json = TranscriptAssembler.assemble(
            segments: [LabeledSegment(start: 1, end: 2, speaker: "Remote A", text: "hello", source: "remote")],
            audioPaths: [], outputFormat: "json", language: "en", numSpeakers: nil, diarization: false, dualStream: true,
            provenance: provenance(realCase))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drift-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.sideStatuses(inTranscriptAt: url)?.remote == "degraded")
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(meta.remoteCapture?.wrongRateSeconds == 11.1)
    }
}
