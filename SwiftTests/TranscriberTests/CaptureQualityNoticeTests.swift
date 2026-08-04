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
}
