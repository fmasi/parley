import Testing
import Foundation
@testable import TranscriberCore

/// A recording the system knows is compromised must not present as clean.
///
/// The 2026-08-04 failure was detected by the capture layer at t≈5s, stamped into
/// `capture_provenance`, and then announced with an unconditional "Transcription Complete".
@Suite struct CaptureQualityNoticeTests {

    @Test func cleanCaptureKeepsTheNormalTitle() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0) == "Transcription Complete")
        #expect(CaptureQualityNotice.completionBody(fileName: "meeting.json", anomalyCount: 0)
                == "meeting.json")
    }

    @Test func anomaliesChangeTheTitle() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1)
                == "Transcription Complete — capture anomalies")
    }

    @Test func bodyNamesTheCountAndPluralisesProperly() {
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1)
                .contains("1 capture anomaly"))
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 3)
                .contains("3 capture anomalies"))
    }

    // MARK: - Reading it back off the artifact

    private func writeTranscript(_ json: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    @Test func readsAnomalyCountFromProvenance() throws {
        let url = try writeTranscript([
            "metadata": ["capture_provenance": ["quality_anomaly_count": 2]],
            "segments": [],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.anomalyCount(inTranscriptAt: url) == 2)
    }

    /// The real 2026-08-04 shape: one rateDrift anomaly in an otherwise ordinary transcript.
    @Test func readsTheIncidentShape() throws {
        let url = try writeTranscript([
            "metadata": [
                "engine": "fluid_audio",
                "capture_provenance": [
                    "anomaly_count": 1,
                    "quality_anomaly_count": 1,
                    "system_format": "24000Hz/2ch",
                ],
            ],
            "segments": [],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let count = CaptureQualityNotice.anomalyCount(inTranscriptAt: url)
        #expect(count == 1)
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: count)
                == "Transcription Complete — capture anomalies")
    }

    // MARK: - Never invent an alarm

    @Test func missingProvenanceIsNotAnAlarm() throws {
        let url = try writeTranscript(["metadata": ["engine": "fluid_audio"], "segments": []])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.anomalyCount(inTranscriptAt: url) == 0)
    }

    /// The calibration that keeps the label meaningful: a benign Bluetooth route change is recorded
    /// as an anomaly and fully recovered. It fires on nearly every recording made on the default
    /// source with wireless headphones, so counting it would brand healthy recordings as suspect.
    @Test func recoveredRouteChangeAnomaliesDoNotTaintTheRecording() throws {
        let url = try writeTranscript([
            "metadata": ["capture_provenance": [
                "anomaly_count": 2,          // two benign stream stops, both recovered
                "quality_anomaly_count": 0,
                "route_changes": 2,
                "recovered": true,
            ]],
            "segments": [],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.anomalyCount(inTranscriptAt: url) == 0)
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0) == "Transcription Complete")
    }

    @Test func unreadableFileIsNotAnAlarm() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(CaptureQualityNotice.anomalyCount(inTranscriptAt: missing) == 0)
    }

    // MARK: - Processing problems and empty transcripts (§7.3)

    /// §7.3 precedence: no speech > capture anomalies > processing problems > complete.
    @Test func processingIssuesGetTheirOwnTitleWithPrecedence() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 2, segmentCount: 40) == "Transcription Complete — 2 chunks had processing problems")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 1, segmentCount: 40) == "Transcription Complete — 1 chunk had processing problems")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 0) == "Transcription Complete — no speech was transcribed")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1, problemChunkCount: 1, segmentCount: 40) == "Transcription Complete — capture anomalies")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 40) == "Transcription Complete")
        let body = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1, problemChunkCount: 2, segmentCount: 40)
        #expect(body.contains("1 capture anomaly") && body.contains("2 chunks had processing problems"))
    }

    @Test func problemChunkCountReadsDistinctChunksWithContentIssues() throws {
        let url = try writeTranscript(["metadata": ["processing_issues": [
            ["chunk": 0, "code": "asr_failed", "track": "remote"],
            ["chunk": 0, "code": "diarization_failed", "track": "local"],
            ["chunk": 3, "code": "stream_empty", "track": "remote"],
        ], "processing_problem_chunks": 1], "segments": [["start": 0, "end": 1, "text": "x", "speaker": "S"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.problemChunkCount(inTranscriptAt: url) == 1)
        #expect(CaptureQualityNotice.segmentCount(inTranscriptAt: url) == 1)
    }
}
