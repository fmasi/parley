import Foundation
import Testing
@testable import TranscriberCore

/// #333, the verdict side: silence is judged by what nobody can vouch for, and a drift that touched no speech is
/// recorded, not announced.
///
/// The incident (2026-10-13, a 66-minute call): nothing was lost — 3952 of 3952 s delivered — yet the summary opened
/// with "uncertain — 571 s were exact digital silence and Parley could not confirm the permission". The 571 s were
/// the call app rendering zeros while the other side was quiet, on a tap that had already delivered real audio; the
/// one anomaly was a rate drift at hang-up, cut short by Stop. Every value below is synthetic.
@Suite struct SilenceVerdictTests {
    private let base = Date(timeIntervalSinceReferenceDate: 4_000_000)

    private func event(_ t: TimeInterval, _ kind: CaptureEventKind, _ severity: CaptureEvent.Severity = .info,
                       _ detail: [String: String] = [:]) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(t), origin: .helper, kind: kind, severity: severity, detail: detail)
    }

    private func coverage(zeros: Double = 571, unproven: Double? = 2) -> TrackAccounting {
        var a = TrackAccounting()
        a.expectedSeconds = 3952; a.deliveredSeconds = 3952; a.exactZeroSeconds = zeros; a.exactZeroUnprovenSeconds = unproven
        return a
    }

    private func drift(_ t: TimeInterval) -> [CaptureEvent] {
        [event(t, .rateDrift, .anomaly, ["source": "system-tap", "declared": "48000", "actual": "44042", "onset_within_seconds": "3.0"]),
         event(t + 0.01, .restartInPlace, .warning, ["source": "system-tap", "reason": "rate drift remediation", "attempt": "1"])]
    }

    private func firstFrames(_ t: TimeInterval, _ track: String) -> CaptureEvent { event(t, .firstFrames, .info, ["track": track]) }

    /// One helper session: start, each track's first frames (`firstFramesAt`: mic, system; the earlier one is sample 0
    /// of the recording), the drift and its remediation at 3955 s, then the helper's own stop 0.3 s later — no system
    /// `firstFrames` after the rebuild.
    private func incident(coverage: TrackAccounting? = nil, firstFramesAt: (mic: TimeInterval, system: TimeInterval)? = (0.5, 0.6),
                          extra: [CaptureEvent] = []) -> [CaptureEvent] {
        let first = firstFramesAt.map { [firstFrames($0.mic, "mic"), firstFrames($0.system, "system")] } ?? []
        return [event(0, .captureStart, .info, ["system_source": "coreAudioTap"])] + first + drift(3955) + extra
            + [event(3955.3, .captureStop, .info, (coverage ?? self.coverage()).asDetail(prefix: "remote"))]
    }

    private func remote(endingAt end: Double, filtered: Bool = false) -> LabeledSegment {
        LabeledSegment(start: end - 2, end: end, speaker: "Remote A", text: "synthetic", source: "remote", filtered: filtered)
    }

    /// The microphone side talks on past the hang-up: its segments say nothing about the remote side's last speech.
    private var localTail: LabeledSegment {
        LabeledSegment(start: 3953, end: 3956, speaker: "Local A", text: "synthetic", source: "local")
    }

    /// What every reader of one transcript says about it.
    private struct Reading {
        var remote: [String: Any] = [:]
        var drift: [String: Any]? { (remote["rate_drift"] as? [[String: Any]])?.first }
        var provenance: [String: Any] = [:]
        var line: String?
        var banner: String?
        var title = ""
        var body = ""
        var noticeAnomalies = 0
    }

    /// Through the transcript file: assembled, written, and read back by the summary and by the completion notice.
    private func read(_ events: [CaptureEvent], segments: [LabeledSegment], gaps: [CaptureGap] = []) throws -> Reading {
        var d = CaptureDiagnostics()
        for e in events { d.record(e) }
        let json = TranscriptAssembler.assemble(
            segments: segments, audioPaths: [], outputFormat: "json", language: "en", numSpeakers: nil, diarization: false,
            dualStream: true, provenance: d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil),
            captureGaps: gaps)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try #require(json["metadata"] as? [String: Any])
        var r = Reading()
        r.remote = try #require((metadata["capture"] as? [String: Any])?["remote"] as? [String: Any])
        r.provenance = try #require(metadata["capture_provenance"] as? [String: Any])
        let (_, summary) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        r.line = SummaryPromptBuilder.captureLine(summary)
        r.banner = SummaryPromptBuilder.captureBanner(summary)
        r.noticeAnomalies = CaptureQualityNotice.anomalyCount(inTranscriptAt: url)
        (r.title, r.body) = notice(at: url, segments: segments.count)
        return r
    }

    /// The completion notice as `RecordingCoordinator` builds it: every reader on the same file.
    private func notice(at url: URL, segments: Int = 10) -> (title: String, body: String) {
        let anomalies = CaptureQualityNotice.anomalyCount(inTranscriptAt: url)
        let sides = CaptureQualityNotice.sideStatuses(inTranscriptAt: url)
        return (CaptureQualityNotice.completionTitle(anomalyCount: anomalies, problemChunkCount: 0, segmentCount: segments,
                                                     remoteStatus: sides?.remote, localStatus: sides?.local,
                                                     remoteUncertainSeconds: sides?.remoteUncertainSeconds),
                CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: anomalies, problemChunkCount: 0, segmentCount: segments,
                                                    remoteStatus: sides?.remote, localStatus: sides?.local,
                                                    remoteUncertainSeconds: sides?.remoteUncertainSeconds,
                                                    remoteUncertainIsLowerBound: sides?.remoteUncertainIsLowerBound ?? false))
    }

    /// The notice of a transcript holding just these two sides' coverage.
    private func notice(remote: [String: Any], local: [String: Any]? = nil, anomalies: Int = 0) throws -> (title: String, body: String) {
        var provenance: [String: Any] = ["quality_anomaly_count": anomalies, "remote_coverage": remote]
        provenance["local_coverage"] = local
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uncertain-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["metadata": ["capture_provenance": provenance], "segments": [] as [Any]]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return notice(at: url)
    }

    private func side(_ status: String, delivered: Double = 3000, zeros: Double? = 1900, unproven: Double? = 1700,
                      extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["status": status, "expected_seconds": delivered, "delivered_seconds": delivered]
        d["exact_zero_seconds"] = zeros
        d["exact_zero_unproven_seconds"] = unproven
        return d.merging(extra) { $1 }
    }

    private func meta(_ note: CaptureSideNote, local: CaptureSideNote? = nil) -> SummaryMetadata {
        SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["A"],
                        dualStream: true, remoteCapture: note, localCapture: local, coverageNotRecorded: false, gapCount: 0, gapSeconds: 0)
    }

    private let driftLine = "Remote audio: captured; up to 3 s recorded at the wrong rate before the recording stopped (1 capture anomaly recorded)"

    // MARK: - Acceptance: the incident's record

    /// The drift window (from 3952 s) overlaps the remote side's last words (to 3955 s): degraded, said mildly, and no
    /// word about the 571 s of silence on a tap whose grant was proven.
    @Test func theIncidentIsDegradedAndTheSilenceIsNotUncertain() throws {
        let r = try read(incident(), segments: [remote(endingAt: 3900), remote(endingAt: 3955), localTail])
        #expect(r.remote["status"] as? String == "degraded")
        #expect(r.remote["exact_zero_seconds"] as? Double == 571 && r.remote["exact_zero_unproven_seconds"] as? Double == 2)
        #expect(r.line == driftLine)
        #expect(r.line?.contains("uncertain") == false && r.line?.contains("permission") == false)
        #expect(r.banner?.contains("> \(driftLine)") == true)
        #expect(r.drift?["ended_by"] as? String == "stop" && r.drift?["healed"] as? Bool == false)
        #expect(r.drift?["after_last_speech"] as? Bool == false)
        #expect(r.title == "Transcription Complete — brief capture glitch")
        #expect(r.body.contains("remote audio briefly affected") && r.noticeAnomalies == 1)
    }

    /// The same record, the remote side's last word 12 s before the drift window: nothing is announced, everything is
    /// in the record.
    @Test func aDriftAfterTheLastRemoteWordIsRecordedNotAnnounced() throws {
        let r = try read(incident(), segments: [remote(endingAt: 3900), remote(endingAt: 3940), localTail])
        #expect(r.line == nil && r.banner == nil)
        #expect(r.title == "Transcription Complete" && r.body == "m.json")
        #expect(r.noticeAnomalies == 0)
        // The record: still degraded, the drift and its count still there, with how it ended and why it is quiet.
        #expect(r.remote["status"] as? String == "degraded")
        #expect((r.provenance["remote_coverage"] as? [String: Any])?["status"] as? String == "degraded")
        #expect(r.remote["content_anomaly_count"] as? Int == 1 && r.provenance["quality_anomaly_count"] as? Int == 1)
        #expect(r.drift?["ended_by"] as? String == "stop" && r.drift?["healed"] as? Bool == false)
        #expect(r.drift?["after_last_speech"] as? Bool == true)
        #expect(r.drift?["offset_seconds"] as? Double == 3952 && r.drift?["affected_seconds"] as? Double == 3.3)
    }

    /// A record made before `exact_zero_unproven_seconds`: judged on the total, worded as before.
    @Test func anOlderRecordKeepsTodaysWording() {
        let compromised = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3952, expectedSeconds: 3952,
                                               exactZeroSeconds: 571, anomalyCount: 1))
        #expect(SummaryPromptBuilder.captureLine(compromised)
                == "Remote audio: uncertain — 571 s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured")
        let healthy = meta(CaptureSideNote(status: "healthy", deliveredSeconds: 3000, expectedSeconds: 3000, exactZeroSeconds: 1700))
        #expect(SummaryPromptBuilder.captureLine(healthy) == nil)
        let degraded = meta(CaptureSideNote(status: "degraded", deliveredSeconds: 3000, expectedSeconds: 3000, exactZeroSeconds: 1700,
                                            anomalyCount: 1, wrongRateSeconds: 11.1))
        #expect(SummaryPromptBuilder.captureLine(degraded)
                == "Remote audio: captured; up to 11 s recorded at the wrong rate before Parley recovered (1 capture anomaly recorded)")
    }

    /// A healthy remote side, more than half of it zeros nobody can vouch for: uncertain, in the banner too.
    @Test func aHealthySideWithSignificantUnprovenSilenceIsUncertain() {
        let m = meta(CaptureSideNote(status: "healthy", deliveredSeconds: 3000, expectedSeconds: 3000, exactZeroSeconds: 1900,
                                     exactZeroUnprovenSeconds: 1700))
        let line = "Remote audio: uncertain — 1700 s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured"
        #expect(SummaryPromptBuilder.captureLine(m) == line)
        #expect(SummaryPromptBuilder.captureBanner(m)?.contains("> \(line)") == true)
    }

    // MARK: - R3: which zeros a verdict is judged on

    /// The same bar as a coverage deficit, on the unproven seconds: at least 15 s and at least 10 %.
    @Test func theBarIsFifteenSecondsAndTenPercentOfTheUnprovenZeros() {
        func line(unproven: Double, delivered: Double = 3000) -> String? {
            SummaryPromptBuilder.captureLine(meta(CaptureSideNote(status: "healthy", deliveredSeconds: delivered, expectedSeconds: delivered,
                                                                  exactZeroSeconds: delivered / 2, exactZeroUnprovenSeconds: unproven)))
        }
        #expect(line(unproven: 2) == nil, "the seconds before the first real audio")
        #expect(line(unproven: 299) == nil && line(unproven: 300)?.contains("uncertain") == true)
        #expect(line(unproven: 14, delivered: 100) == nil && line(unproven: 15, delivered: 100)?.contains("uncertain") == true)
    }

    /// The incident before #311 made it `degraded`: one content anomaly, 571 s of proven silence. Not uncertain.
    @Test func aCompromisedSideIsJudgedOnTheUnprovenZerosAndSaysThatNumber() {
        let proven = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3952, expectedSeconds: 3952, exactZeroSeconds: 571,
                                          anomalyCount: 1, exactZeroUnprovenSeconds: 2))
        #expect(SummaryPromptBuilder.captureLine(proven)
                == "Remote audio: captured, but compromised (1 capture anomaly recorded); 571 s of it was digital silence, 2 s of which could not be confirmed")
        let unproven = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3952, expectedSeconds: 3952, exactZeroSeconds: 900,
                                            anomalyCount: 1, exactZeroUnprovenSeconds: 600))
        #expect(SummaryPromptBuilder.captureLine(unproven)
                == "Remote audio: uncertain — 600 s were exact digital silence and Parley could not confirm the permission; the other side may have been muted, or not captured")
        // A shortfall still leads. What was delivered is said whole, and how much of it nobody can vouch for.
        let shortfall = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736, exactZeroSeconds: 400,
                                             exactZeroUnprovenSeconds: 30))
        #expect(SummaryPromptBuilder.captureLine(shortfall)
                == "Remote audio: partly captured (1000 s delivered of 2736 s expected); 400 s of it was digital silence, 30 s of which could not be confirmed")
        // A sum over measured and unmeasured sessions: the total is a lower bound and says so.
        let atLeast = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736, exactZeroSeconds: 400,
                                           exactZeroIsLowerBound: true, exactZeroUnprovenSeconds: 30))
        #expect(SummaryPromptBuilder.captureLine(atLeast)
                == "Remote audio: partly captured (1000 s delivered of 2736 s expected); at least 400 s of it was digital silence, 30 s of which could not be confirmed")
        // A record without the field: the sentence it always had.
        let older = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 1000, expectedSeconds: 2736, exactZeroSeconds: 400))
        #expect(SummaryPromptBuilder.captureLine(older)
                == "Remote audio: partly captured (1000 s delivered of 2736 s expected); 400 s of it was digital silence")
    }

    /// A confirmed denial withdraws the proof, so its zeros are the unproven ones: the same verdicts as before. A side
    /// lost part-way says the whole silence the record holds, then how much of it the denial can answer for. Whether
    /// real audio remains is still read off the total.
    @Test func aConfirmedDenialKeepsItsVerdictsAndSaysTheUnprovenSeconds() {
        let whole = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 2736, expectedSeconds: 2736, exactZeroSeconds: 2736,
                                         permissionDenied: true, exactZeroUnprovenSeconds: 2736))
        #expect(SummaryPromptBuilder.captureLine(whole)
                == "Remote audio: not captured — system audio permission was not granted; 2736 s of digital silence were recorded instead")
        // Lost part-way: 300 s of proven silence while it was granted, 1740 s after the revocation.
        let partWay = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3120, expectedSeconds: 3120, exactZeroSeconds: 2040,
                                           permissionDenied: true, anomalyCount: 1, exactZeroUnprovenSeconds: 1740))
        #expect(SummaryPromptBuilder.captureLine(partWay)
                == "Remote audio: partly captured — 2040 s of 3120 s was digital silence, 1740 s of it after the permission was lost; system audio permission was not granted for part of the call")
        // A sum over measured and unmeasured sessions: the total is a lower bound and says so.
        let atLeast = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3120, expectedSeconds: 3120, exactZeroSeconds: 2040,
                                           permissionDenied: true, anomalyCount: 1, exactZeroIsLowerBound: true, exactZeroUnprovenSeconds: 1740))
        #expect(SummaryPromptBuilder.captureLine(atLeast)
                == "Remote audio: partly captured — at least 2040 s of 3120 s was digital silence, 1740 s of it after the permission was lost; system audio permission was not granted for part of the call")
        // A record without the field: the sentence it always had.
        let older = meta(CaptureSideNote(status: "compromised", deliveredSeconds: 3120, expectedSeconds: 3120, exactZeroSeconds: 1740,
                                         permissionDenied: true, anomalyCount: 1))
        #expect(SummaryPromptBuilder.captureLine(older)
                == "Remote audio: partly captured — 1740 s of 3120 s was digital silence; system audio permission was not granted for part of the call")
    }

    /// Whether the WHOLE side was silence (the neutral muted-remote line) is still read off the total.
    @Test func theNeutralMutedRemoteLineStillUsesTheTotal() {
        let muted = meta(CaptureSideNote(status: "healthy", deliveredSeconds: 2736, expectedSeconds: 2736, exactZeroSeconds: 2736,
                                         permissionDenied: false, exactZeroUnprovenSeconds: 2736))
        #expect(SummaryPromptBuilder.captureLine(muted) == "Remote audio: only digital silence was received (the other side may have been muted)")
        #expect(SummaryPromptBuilder.captureBanner(muted) == nil)
    }

    /// The microphone's exact-zero wording does not read the field, whatever a record says.
    @Test func theMicrophoneSideIsJudgedOnTheTotalAlways() {
        let mic = CaptureSideNote(status: "compromised", deliveredSeconds: 3600, expectedSeconds: 3600, exactZeroSeconds: 3300,
                                  exactZeroUnprovenSeconds: 0)
        #expect(SummaryPromptBuilder.verdict(mic, isRemote: false) == .localPartialSilence)
        let m = SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["A"],
                                dualStream: true, remoteCapture: nil, localCapture: mic, coverageNotRecorded: false, gapCount: 0, gapSeconds: 0)
        #expect(SummaryPromptBuilder.captureLine(m) == "Your microphone: captured, but 3300 s of 3600 s was digital silence")
        let healthy = CaptureSideNote(status: "healthy", deliveredSeconds: 3600, expectedSeconds: 3600, exactZeroSeconds: 3300,
                                      exactZeroUnprovenSeconds: 3300)
        #expect(SummaryPromptBuilder.verdict(healthy, isRemote: false) == .healthy)
    }

    /// A drift does not hide silence nobody can vouch for — announced or not.
    @Test func aDegradedSideWithSignificantUnprovenSilenceIsUncertain() throws {
        let note = CaptureSideNote(status: "degraded", deliveredSeconds: 3000, expectedSeconds: 3000, exactZeroSeconds: 1900,
                                   anomalyCount: 1, wrongRateSeconds: 3.3, exactZeroUnprovenSeconds: 1700, driftEndedByStop: true,
                                   driftsUnannounced: true)
        #expect(SummaryPromptBuilder.verdict(note, isRemote: true) == .uncertainSilence)
        let r = try read(incident(coverage: coverage(zeros: 1900, unproven: 1700)), segments: [remote(endingAt: 3940)])
        #expect(r.line?.hasPrefix("Remote audio: uncertain — 1700 s were exact digital silence") == true)
        #expect(r.banner != nil)
        // The notice too, though the drift itself is quiet and left the count.
        #expect(r.title == "Transcription Complete — remote audio uncertain")
        #expect(r.body == "m.json — remote audio: 1700 s of silence could not be confirmed")
    }

    /// The transcript carries the field to the summary; a transcript without it reads nil, never 0.
    @Test func theSummaryReadsTheUnprovenSecondsFromTheTranscript() throws {
        func note(_ remote: [String: Any]) throws -> CaptureSideNote? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("unproven-\(UUID().uuidString).json")
            let json: [String: Any] = ["metadata": ["capture": ["remote": remote, "local": remote]], "segments": [] as [Any]]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
            #expect(meta.localCapture?.exactZeroUnprovenSeconds == nil, "never read for the microphone")
            return meta.remoteCapture
        }
        let side: [String: Any] = ["status": "healthy", "delivered_seconds": 3000.0, "expected_seconds": 3000.0, "exact_zero_seconds": 1900.0]
        #expect(try note(side)?.exactZeroUnprovenSeconds == nil)
        #expect(try note(side.merging(["exact_zero_unproven_seconds": 1700.0]) { $1 })?.exactZeroUnprovenSeconds == 1700)
        #expect(try note(side.merging(["exact_zero_unproven_seconds": -1.0]) { $1 })?.exactZeroUnprovenSeconds == nil)
    }

    // MARK: - R3 in the completion notice (review round 1): one rule, two readers

    /// The summary banner is not the only place: the notification says it, and a recording with no summary says it there.
    @Test func theNoticeSaysAHealthySideWithSignificantUnprovenSilenceIsUncertain() throws {
        let n = try notice(remote: side("healthy"))
        #expect(n.title == "Transcription Complete — remote audio uncertain")
        #expect(n.body == "m.json — remote audio: 1700 s of silence could not be confirmed")
    }

    /// The zeros of a measured and an unmeasured helper session summed: at least that much, as the summary says it.
    @Test func theNoticeSaysAtLeastForALowerBound() throws {
        let n = try notice(remote: side("healthy", extra: ["exact_zero_seconds_is_lower_bound": true]))
        #expect(n.title == "Transcription Complete — remote audio uncertain")
        #expect(n.body == "m.json — remote audio: at least 1700 s of silence could not be confirmed")
        let exact = try notice(remote: side("healthy", extra: ["exact_zero_seconds_is_lower_bound": false]))
        #expect(exact.body == "m.json — remote audio: 1700 s of silence could not be confirmed")
        // The mark alone, on a side that is not uncertain, says nothing.
        let quiet = try notice(remote: side("healthy", unproven: 2, extra: ["exact_zero_seconds_is_lower_bound": true]))
        #expect(quiet.title == "Transcription Complete" && quiet.body == "m.json")
    }

    /// A record made before the field: today's notice, exactly.
    @Test func anOlderRecordKeepsTodaysNotice() throws {
        let healthy = try notice(remote: side("healthy", unproven: nil))
        #expect(healthy.title == "Transcription Complete" && healthy.body == "m.json")
        let degraded = try notice(remote: side("degraded", unproven: nil), anomalies: 1)
        #expect(degraded.title == "Transcription Complete — brief capture glitch")
        #expect(degraded.body == "m.json — remote audio briefly affected; 1 capture anomaly recorded; audio may be affected")
        let compromised = try notice(remote: side("compromised", unproven: nil), anomalies: 1)
        #expect(compromised.title == "Transcription Complete — capture compromised")
        #expect(compromised.body == "m.json — remote audio partly captured; 1 capture anomaly recorded; audio may be affected")
    }

    /// Where it sits: below a side not or partly captured, above the brief glitch and the bare anomaly count.
    @Test func uncertainSitsBelowCompromisedAndAboveTheGlitch() throws {
        // A worse verdict of the remote side itself: its own words, not "uncertain".
        let compromised = try notice(remote: side("compromised"), anomalies: 1)
        #expect(compromised.title == "Transcription Complete — capture compromised")
        #expect(compromised.body == "m.json — remote audio partly captured; 1 capture anomaly recorded; audio may be affected")
        let never = try notice(remote: side("neverDelivered", delivered: 0, zeros: 0, unproven: 0))
        #expect(never.title == "Transcription Complete — the other side was not captured")
        // The microphone's worse verdict leads; the body still says both.
        let micLost = try notice(remote: side("healthy"), local: ["status": "compromised"])
        #expect(micLost.title == "Transcription Complete — capture compromised")
        #expect(micLost.body == "m.json — remote audio: 1700 s of silence could not be confirmed; microphone partly captured")
        // An announced drift on the same side: uncertain leads, the glitch stays in the body.
        let drifted = try notice(remote: side("degraded", extra: ["rate_drift": [["healed": true, "affected_seconds": 5.0]]]), anomalies: 1)
        #expect(drifted.title == "Transcription Complete — remote audio uncertain")
        #expect(drifted.body == "m.json — remote audio: 1700 s of silence could not be confirmed; remote audio briefly affected; 1 capture anomaly recorded; audio may be affected")
        // Above a bare anomaly count.
        let anomalies = try notice(remote: side("healthy"), anomalies: 2)
        #expect(anomalies.title == "Transcription Complete — remote audio uncertain")
        #expect(anomalies.body.contains("could not be confirmed; 2 capture anomalies recorded"))
    }

    /// The same bar, and the same exceptions, as the summary: the two readers share `TrackAccounting.uncertainSilenceSeconds`.
    @Test func theNoticeAndTheSummaryReadOneRule() throws {
        func both(_ status: String, delivered: Double = 3000, zeros: Double?, unproven: Double?) throws -> (notice: Bool, summary: Bool) {
            let n = try notice(remote: side(status, delivered: delivered, zeros: zeros, unproven: unproven))
            let line = SummaryPromptBuilder.captureLine(meta(CaptureSideNote(
                status: status, deliveredSeconds: delivered, expectedSeconds: delivered, exactZeroSeconds: zeros, anomalyCount: 1,
                exactZeroUnprovenSeconds: unproven)))
            return (n.title == "Transcription Complete — remote audio uncertain", line?.contains("uncertain") == true)
        }
        for status in ["healthy", "degraded"] {
            #expect(try both(status, zeros: 1900, unproven: 300) == (true, true))
            #expect(try both(status, zeros: 1900, unproven: 299) == (false, false), "under 10 %")
            #expect(try both(status, delivered: 100, zeros: 50, unproven: 14) == (false, false), "under 15 s")
            #expect(try both(status, zeros: 1900, unproven: nil) == (false, false), "no field: the total is not judged on such a side")
        }
        // The owner's muted-remote ruling stands: a healthy side that was ALL silence keeps its neutral line, and no notice.
        #expect(try both("healthy", zeros: 3000, unproven: 3000) == (false, false))
        #expect(TrackAccounting.uncertainSilenceSeconds(status: .healthy, deliveredSeconds: 3000, exactZeroSeconds: 1900, unprovenSeconds: 1700) == 1700)
        #expect(TrackAccounting.uncertainSilenceSeconds(status: .healthy, deliveredSeconds: 3000, exactZeroSeconds: 1000, unprovenSeconds: 1700) == 1000,
                "never more than the total")
        for status in [TrackAccounting.Status.idle, .neverDelivered, .compromised, nil] {
            #expect(TrackAccounting.uncertainSilenceSeconds(status: status, deliveredSeconds: 3000, exactZeroSeconds: 1900, unprovenSeconds: 1700) == nil)
        }
        // The microphone's dictionary is never read for it.
        let mic = try notice(remote: side("healthy", unproven: 0), local: side("healthy"))
        #expect(mic.title == "Transcription Complete" && mic.body == "m.json")
    }

    /// Corrupt numbers never make, or trap, a notice.
    @Test func corruptSecondsAreNotAnUncertainNotice() throws {
        for bad in [-1.0, 1e300] {
            let n = try notice(remote: side("healthy", unproven: bad))
            #expect(n.title == "Transcription Complete" && n.body == "m.json", "read as absent, as the summary reads it")
        }
        let text = try notice(remote: side("healthy", extra: ["exact_zero_unproven_seconds": "1700"]))
        #expect(text.title == "Transcription Complete")
    }

    // MARK: - R5: when a drift is quiet, and when it is not

    /// Every segment of the remote side counts — one hidden from the transcript's readers too: the wrong rate may be
    /// why it was filtered.
    @Test func aFlaggedRemoteSegmentInTheWindowKeepsItAnnounced() throws {
        let r = try read(incident(), segments: [remote(endingAt: 3940), remote(endingAt: 3954, filtered: true)])
        #expect(r.drift?["after_last_speech"] as? Bool == false)
        #expect(r.line == driftLine && r.noticeAnomalies == 1)
    }

    /// The window starts at 3952 s on the record's clock. The margin is one second plus the first-frame latency
    /// (0.5 s here): a segment's time counts from the recording's first buffer, the drift's from `captureStart`.
    @Test func theWindowMustStartMoreThanTheMarginAfterTheLastSpeech() throws {
        #expect(try read(incident(), segments: [remote(endingAt: 3950.4)]).drift?["after_last_speech"] as? Bool == true)
        #expect(try read(incident(), segments: [remote(endingAt: 3950.5)]).drift?["after_last_speech"] as? Bool == false)
    }

    /// Review round 1: the first buffer arrived 3 s after `captureStart`, so every transcript time is 3 s early. A last
    /// word that really ended at 3953.5 s — inside the window — reads 3950.5 s. It must not be quieted.
    @Test func aLastWordInsideTheWindowThatReadsEarlierByTheFirstFrameLatencyIsNotQuieted() throws {
        let late = incident(firstFramesAt: (mic: 3.2, system: 3))
        let inside = try read(late, segments: [remote(endingAt: 3950.5)])
        #expect(inside.drift?["after_last_speech"] as? Bool == false)
        #expect(inside.line == driftLine && inside.title == "Transcription Complete — brief capture glitch" && inside.noticeAnomalies == 1)
        // The margin is 1 s + 3 s: quiet only when the word reads more than 4 s before the window.
        #expect(try read(late, segments: [remote(endingAt: 3948)]).drift?["after_last_speech"] as? Bool == false)
        #expect(try read(late, segments: [remote(endingAt: 3947.9)]).drift?["after_last_speech"] as? Bool == true)
        // Sample 0 is the first buffer of EITHER track: the microphone's, when it came first.
        let micFirst = incident(firstFramesAt: (mic: 1, system: 3))
        #expect(try read(micFirst, segments: [remote(endingAt: 3949.9)]).drift?["after_last_speech"] as? Bool == true)
        #expect(try read(micFirst, segments: [remote(endingAt: 3950)]).drift?["after_last_speech"] as? Bool == false)
    }

    /// A record with no `firstFrames` cannot say how far apart the two clocks are: nothing is judged.
    @Test func withoutFirstFramesInTheRecordNothingIsJudged() throws {
        let r = try read(incident(firstFramesAt: nil), segments: [remote(endingAt: 3940)])
        #expect(r.drift?["ended_by"] as? String == "stop" && r.drift?["after_last_speech"] == nil)
        #expect(r.line == driftLine && r.title == "Transcription Complete — brief capture glitch" && r.noticeAnomalies == 1)
    }

    /// Drift offsets are wall-clock from the first capture start; transcript times are the audio timeline. They agree
    /// only within one helper session: with a second start, a gap or a recovery in the record, nothing is judged.
    @Test func timelinesThatMayDisagreeAreNotJudged() throws {
        let speech = [remote(endingAt: 3940)]
        let secondStart = try read([event(-600, .captureStart), event(-300, .captureStop, .info, ["helper_session": "h0"])] + incident(),
                                   segments: speech)
        let gap = try read(incident(), segments: speech,
                           gaps: [CaptureGap(start: base.addingTimeInterval(100), end: base.addingTimeInterval(130), reason: "sleep")])
        let recovered = try read(incident(extra: [event(10, .launchRecovery, .warning)]), segments: speech)
        // Review round 1: a helper that crashed before its `captureStart` was drained leaves a stand-in stop and no
        // start — one `captureStart` in the record, two helper sessions.
        let crashedFirst = try read(
            incident(extra: [event(-5, .captureStop, .info, ["helper_session": "h0", "from": CaptureDiagnostics.standInSource])]),
            segments: speech)
        for r in [secondStart, gap, recovered, crashedFirst] {
            #expect(r.drift?["ended_by"] as? String == "stop" && r.drift?["after_last_speech"] == nil)
            #expect(r.line?.contains("recorded at the wrong rate") == true)
            #expect(r.title == "Transcription Complete — brief capture glitch" && r.noticeAnomalies == 1)
        }
    }

    /// No remote segment at all, or one with no usable time: there is no "last speech" to be after.
    @Test func withoutAKnownLastRemoteSpeechNothingIsQuiet() throws {
        let none = try read(incident(), segments: [localTail])
        #expect(none.drift?["after_last_speech"] == nil && none.line == driftLine)
        let untimed = LabeledSegment(start: .nan, end: .nan, speaker: "Remote A", text: "synthetic", source: "remote")
        let unknown = try read(incident(), segments: [remote(endingAt: 3940), untimed])
        #expect(unknown.drift?["after_last_speech"] == nil && unknown.line?.hasPrefix(driftLine + "\n") == true)
    }

    /// A drift healed by its rebuild is announced as #311 does, wherever it sits; and it keeps a later, quiet-shaped
    /// one announced with it.
    @Test func onlyASideWhoseEveryDriftIsStopBoundedAfterSpeechIsQuiet() throws {
        let healedAfterSpeech = try read(
            [event(0, .captureStart)] + drift(3955) + [event(3956, .firstFrames, .info, ["track": "system"]),
                                                       event(3960, .captureStop, .info, coverage().asDetail(prefix: "remote"))],
            segments: [remote(endingAt: 3940)])
        #expect(healedAfterSpeech.drift?["healed"] as? Bool == true && healedAfterSpeech.drift?["after_last_speech"] == nil)
        #expect(healedAfterSpeech.line
                == "Remote audio: captured; up to 4 s recorded at the wrong rate before Parley recovered (1 capture anomaly recorded)")
        #expect(healedAfterSpeech.title == "Transcription Complete — brief capture glitch")

        // An earlier drift healed in 2 s (5 s with its onset), then the incident's: 8.3 s in all, still degraded.
        let both = try read(
            [event(0, .captureStart), firstFrames(0.5, "mic"), firstFrames(0.6, "system")] + drift(100) + [firstFrames(102, "system")] + drift(3955)
                + [event(3955.3, .captureStop, .info, coverage().asDetail(prefix: "remote"))],
            segments: [remote(endingAt: 3940)])
        let windows = both.remote["rate_drift"] as? [[String: Any]] ?? []
        #expect(both.remote["status"] as? String == "degraded" && windows.count == 2)
        #expect(windows.last?["ended_by"] as? String == "stop" && windows.last?["after_last_speech"] as? Bool == true)
        #expect(both.line
                == "Remote audio: captured; up to 8 s recorded at the wrong rate before the recording stopped (2 capture anomalies recorded)")
        #expect(both.title == "Transcription Complete — brief capture glitch" && both.noticeAnomalies == 2)
    }

    /// Another anomaly on the recording is still counted and said.
    @Test func aQuietDriftLeavesTheOtherAnomaliesInTheNotice() throws {
        let r = try read(incident(extra: [event(50, .excessivePadding, .anomaly, ["track": "mic"])]), segments: [remote(endingAt: 3940)])
        #expect(r.provenance["quality_anomaly_count"] as? Int == 2)
        #expect(r.noticeAnomalies == 1)
        #expect(r.title == "Transcription Complete — capture anomalies")
        #expect(r.body.contains("1 capture anomaly recorded") && !r.body.contains("briefly affected"))
    }

    /// The reader's rule, on the stamped dictionary: `degraded`, and every window ended at the Stop after the last speech.
    @Test func theQuietRuleNeedsEveryPart() {
        let quiet: [String: Any] = ["ended_by": "stop", "after_last_speech": true, "healed": false]
        func side(_ status: String, _ windows: [[String: Any]]) -> [String: Any] { ["status": status, "rate_drift": windows] }
        #expect(RateDriftWindow.unannounced(inSide: side("degraded", [quiet])) == 1)
        #expect(RateDriftWindow.unannounced(inSide: side("compromised", [quiet])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: side("healthy", [quiet])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: side("degraded", [])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: side("degraded", [quiet, ["healed": true, "after_last_speech": true]])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: side("degraded", [["ended_by": "stop", "after_last_speech": false]])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: side("degraded", [["ended_by": "stop"]])) == 0)
        #expect(RateDriftWindow.unannounced(inSide: ["status": "degraded"]) == 0)
        #expect(RateDriftWindow.unannounced(inSide: nil) == 0)
    }
}
