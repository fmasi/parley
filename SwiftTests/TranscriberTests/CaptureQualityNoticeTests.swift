import Testing
import Foundation
@testable import TranscriberCore

/// A recording the system knows is compromised must not present as clean.
///
/// The 2026-08-04 failure was detected by the capture layer at t≈5s, stamped into
/// `capture_provenance`, and then announced with an unconditional "Transcription Complete".
@Suite struct CaptureQualityNoticeTests {

    @Test func cleanCaptureKeepsTheNormalTitle() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 1) == "Transcription Complete")
        #expect(CaptureQualityNotice.completionBody(fileName: "meeting.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 1)
                == "meeting.json")
    }

    @Test func anomaliesChangeTheTitle() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1, problemChunkCount: 0, segmentCount: 1)
                == "Transcription Complete — capture anomalies")
    }

    @Test func bodyNamesTheCountAndPluralisesProperly() {
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 1, problemChunkCount: 0, segmentCount: 1)
                .contains("1 capture anomaly"))
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 3, problemChunkCount: 0, segmentCount: 1)
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
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: count, problemChunkCount: 0, segmentCount: 1)
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
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: 1) == "Transcription Complete")
    }

    /// R2 follow-up 2: a transcript that can't be re-read was reported as plain "Transcription
    /// Complete" — every reader answered "nothing wrong" (0, 0, 1) for a file it never read. Not an
    /// alarm about the audio, but never a clean bill either: the notice says it could not check.
    @Test func anUnreadableTranscriptIsNeverPlainComplete() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        for url in [missing, garbage] {
            let (a, p, s) = (CaptureQualityNotice.anomalyCount(inTranscriptAt: url), CaptureQualityNotice.problemChunkCount(inTranscriptAt: url),
                             CaptureQualityNotice.segmentCount(inTranscriptAt: url))
            #expect(a == CaptureQualityNotice.unreadable && p == CaptureQualityNotice.unreadable && s == CaptureQualityNotice.unreadable)
            #expect(CaptureQualityNotice.completionTitle(anomalyCount: a, problemChunkCount: p, segmentCount: s)
                    == "Transcription finished — Parley couldn't re-read the transcript to check it")
            #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: a, problemChunkCount: p, segmentCount: s)
                    == "m.json — Parley couldn't re-read the transcript to check it")
        }
        // Any one reader failing is enough (the file can change between reads): never plain "Complete".
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, problemChunkCount: 0, segmentCount: CaptureQualityNotice.unreadable)
                == "Transcription finished — Parley couldn't re-read the transcript to check it")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: CaptureQualityNotice.unreadable, problemChunkCount: 0, segmentCount: 5)
                != "Transcription Complete")
    }

    /// A readable transcript that simply predates a field is still read as "nothing recorded" — the
    /// unreadable answer is for a file that could not be read at all.
    @Test func aReadableTranscriptWithoutTheFieldsIsNotUnreadable() throws {
        let url = try writeTranscript(["metadata": ["engine": "fluid_audio"], "segments": [["start": 0, "end": 1, "text": "x", "speaker": "S"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.anomalyCount(inTranscriptAt: url) == 0)
        #expect(CaptureQualityNotice.problemChunkCount(inTranscriptAt: url) == 0)
        #expect(CaptureQualityNotice.segmentCount(inTranscriptAt: url) == 1)
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

    /// P10/P11: flagged segments stay in the JSON but are hidden everywhere a person reads the
    /// transcript, so they are not "speech that was transcribed".
    @Test func segmentCountIgnoresFlaggedSegments() throws {
        let url = try writeTranscript(["metadata": [:] as [String: Any], "segments": [
            ["start": 0, "end": 1, "text": "noise", "speaker": "Unknown", "filtered": true],
            ["start": 1, "end": 2, "text": "bleed", "speaker": "Local Speaker 1", "echo": true],
        ]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.segmentCount(inTranscriptAt: url) == 0)
    }

    /// Review round 1 item 8: the count comes from the issues themselves, never a stored summary key
    /// that could disagree with them (or be missing).
    @Test func problemChunkCountIsComputedFromTheIssues() throws {
        let url = try writeTranscript(["metadata": ["processing_issues": [
            ["chunk": 1, "code": "asr_failed", "track": "remote"],
            ["chunk": 4, "code": "stream_empty", "track": "local"],
        ], "processing_problem_chunks": 5], "segments": [] as [Any]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CaptureQualityNotice.problemChunkCount(inTranscriptAt: url) == 1)
    }
}
