import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptAssemblerTests {

    @Test func assembleMinimalJSON() throws {
        let segments = [
            LabeledSegment(start: 0.5, end: 2.3, speaker: "Speaker 1", text: "hello", source: "remote"),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [URL(fileURLWithPath: "/tmp/system.wav")],
            outputFormat: "txt",
            language: "en",
            numSpeakers: 1,
            diarization: true,
            dualStream: false
        )

        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["language"] as? String == "en")
        #expect(metadata?["output_format"] as? String == "txt")
        #expect(metadata?["diarization"] as? Bool == true)
        #expect(metadata?["dual_stream"] as? Bool == false)
        #expect(metadata?["num_speakers"] as? Int == 1)

        let audioFiles = metadata?["audio_files"] as? [String]
        #expect(audioFiles == ["system.wav"])

        let audioPaths = metadata?["audio_paths"] as? [String]
        #expect(audioPaths == ["/tmp/system.wav"])

        let segs = json["segments"] as? [[String: Any]]
        #expect(segs?.count == 1)
        #expect(segs?[0]["start"] as? Double == 0.5)
        #expect(segs?[0]["end"] as? Double == 2.3)
        #expect(segs?[0]["speaker"] as? String == "Speaker 1")
        #expect(segs?[0]["text"] as? String == "hello")
        #expect(segs?[0]["source"] as? String == "remote")
    }

    @Test func assembleDualStreamJSON() throws {
        let segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "Remote Speaker 1", text: "hi", source: "remote"),
            LabeledSegment(start: 0.5, end: 1.5, speaker: "Local Speaker 1", text: "hey", source: "local"),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [
                URL(fileURLWithPath: "/tmp/system.wav"),
                URL(fileURLWithPath: "/tmp/mic.wav"),
            ],
            outputFormat: "json",
            language: "auto",
            numSpeakers: nil,
            diarization: true,
            dualStream: true
        )

        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["dual_stream"] as? Bool == true)
        #expect(metadata?["num_speakers"] as? String == "auto")

        let audioFiles = metadata?["audio_files"] as? [String]
        #expect(audioFiles == ["system.wav", "mic.wav"])
    }

    @Test func assembleAutoSpeakers() {
        let json = TranscriptAssembler.assemble(
            segments: [],
            audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
            outputFormat: "json",
            language: "en",
            numSpeakers: nil,
            diarization: true,
            dualStream: false
        )
        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["num_speakers"] as? String == "auto")
    }

    @Test func assembleIncludesSoftwareVersion() {
        let json = TranscriptAssembler.assemble(
            segments: [],
            audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
            outputFormat: "json",
            language: "en",
            numSpeakers: nil,
            diarization: true,
            dualStream: false
        )
        let metadata = json["metadata"] as? [String: Any]
        // In tests, Bundle.main won't have ATGitDescription, so falls back to "unknown"
        #expect(metadata?["software_version"] as? String != nil)
    }

    @Test func writeAndReadJSON() throws {
        let segments = [
            LabeledSegment(start: 1.0, end: 2.0, speaker: "Speaker 1", text: "test", source: ""),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
            outputFormat: "txt",
            language: "en",
            numSpeakers: 1,
            diarization: true,
            dualStream: false
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembler-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("test.json")
        try TranscriptAssembler.write(json, to: path)

        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["metadata"] != nil)
        #expect(parsed?["segments"] != nil)
    }

    /// Scan A113: gaps must land in metadata.capture even when no coverage was stamped (a fake or an
    /// old helper); the `capture` dictionary is created on demand.
    @Test func captureGapsLandInMetadataCaptureEvenWithoutCoverage() throws {
        let gap = CaptureGap(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 14), reason: "app relaunch")
        let json = TranscriptAssembler.assemble(
            segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
            diarization: false, dualStream: false, captureGaps: [gap])
        let capture = try #require((json["metadata"] as? [String: Any])?["capture"] as? [String: Any])
        let gaps = try #require(capture["gaps"] as? [[String: Any]])
        #expect(gaps.count == 1 && gaps[0]["reason"] as? String == "app relaunch" && gaps[0]["seconds"] as? Double == 4)
        #expect(gaps[0]["start"] as? String == "1970-01-01T00:00:10Z")
    }

    @Test func processingIssuesLandInMetadataWithCounts() throws {
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
            diarization: false, dualStream: false,
            processingIssues: [["chunk": 0, "code": "asr_failed", "track": "remote"], ["chunk": 0, "code": "stream_empty", "track": "local"], ["chunk": 2, "code": "asr_failed", "track": "remote"]])
        let m = try #require(json["metadata"] as? [String: Any])
        #expect((m["processing_issues"] as? [[String: Any]])?.count == 3)
        #expect(m["processing_issue_count"] as? Int == 2, "stream_empty does not affect content")
        #expect(m["processing_problem_chunks"] as? Int == 2)
    }

    @Test func coverageLandsInMetadataCapture() throws {
        var remote = TrackAccounting(); remote.expectedSeconds = 2736; remote.deliveredSeconds = 0
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, remoteCoverage: remote, remoteStatus: "neverDelivered")
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                diarization: false, dualStream: false, provenance: p)
        let capture = try #require((json["metadata"] as? [String: Any])?["capture"] as? [String: Any])
        let r = try #require(capture["remote"] as? [String: Any])
        #expect(r["status"] as? String == "neverDelivered" && r["expected_seconds"] as? Double == 2736)
        #expect(capture["local"] == nil)
    }

    /// Review round 1 item 7: a tracked session with no issues says so; an untracked path says nothing.
    @Test func trackedCleanSessionWritesEmptyProcessingIssues() throws {
        let tracked = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                   diarization: false, dualStream: false, processingIssues: [])
        let m = try #require(tracked["metadata"] as? [String: Any])
        #expect((m["processing_issues"] as? [Any])?.isEmpty == true)
        #expect(m["processing_issue_count"] as? Int == 0 && m["processing_problem_chunks"] as? Int == 0)

        let untracked = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                     diarization: false, dualStream: false)
        #expect((untracked["metadata"] as? [String: Any])?["processing_issues"] == nil)
    }

    @Test func aSessionLevelIssueCountsAsAProblem() throws {
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                diarization: false, dualStream: false,
                                                processingIssues: [["code": "session_write_failed"]])
        let m = try #require(json["metadata"] as? [String: Any])
        #expect(m["processing_issue_count"] as? Int == 1 && m["processing_problem_chunks"] as? Int == 1)
    }

    @Test func coverageAndGapsShareMetadataCapture() throws {
        var remote = TrackAccounting(); remote.expectedSeconds = 60; remote.deliveredSeconds = 60
        let p = CaptureProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil, routeChanges: 0, retries: 0,
                                  recovered: false, anomalyCount: 0, remoteCoverage: remote, remoteStatus: "healthy")
        let json = TranscriptAssembler.assemble(segments: [], audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil,
                                                diarization: false, dualStream: false, provenance: p,
                                                captureGaps: [CaptureGap(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 5), reason: "sleep")])
        let capture = try #require((json["metadata"] as? [String: Any])?["capture"] as? [String: Any])
        #expect(capture["remote"] != nil && (capture["gaps"] as? [Any])?.count == 1)
    }

    @Test func flagsAreWrittenOnlyWhenSet() throws {
        let json = TranscriptAssembler.assemble(
            segments: [LabeledSegment(start: 0, end: 1, speaker: "A", text: "plain", source: "remote"),
                       LabeledSegment(start: 1, end: 2, speaker: "A", text: "echo", source: "local", echo: true),
                       LabeledSegment(start: 2, end: 3, speaker: "Unknown", text: "noise", source: "remote", filtered: true),
                       LabeledSegment(start: 3, end: 4, speaker: "A", text: "again", source: "remote", duplicate: true)],
            audioPaths: [], outputFormat: "txt", language: "en", numSpeakers: nil, diarization: false, dualStream: true)
        let segs = try #require(json["segments"] as? [[String: Any]])
        #expect(segs[0]["filtered"] == nil && segs[0]["echo"] == nil && segs[0]["duplicate"] == nil)
        #expect(segs[1]["echo"] as? Bool == true && segs[1]["filtered"] == nil)
        #expect(segs[2]["filtered"] as? Bool == true)
        #expect(segs[3]["duplicate"] as? Bool == true)
    }

    /// C-M17: a non-finite time or confidence reached `JSONSerialization`, which raises an uncatchable
    /// Objective-C exception — every finalize (and every retry) of that session crashed. The segment
    /// and its words are kept; an unknown time is written as null (never an invented number), an
    /// unknown confidence is left out.
    @Test func nonFiniteSegmentNumbersAreWrittenAsUnknownNotCrashed() throws {
        let json = TranscriptAssembler.assemble(
            segments: [LabeledSegment(start: .nan, end: .infinity, speaker: "A", text: "kept words", source: "remote", confidence: .nan),
                       LabeledSegment(start: 1, end: 2, speaker: "A", text: "fine", source: "remote", confidence: 0.9)],
            audioPaths: [], outputFormat: "json", language: "en", numSpeakers: nil, diarization: false, dualStream: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assembler-nan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.json")
        try TranscriptAssembler.write(json, to: url)
        let back = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["segments"] as? [[String: Any]])
        #expect(back.count == 2 && back[0]["text"] as? String == "kept words")
        #expect(back[0]["start"] is NSNull && back[0]["end"] is NSNull && back[0]["confidence"] == nil)
        #expect(back[0]["time_unknown"] as? Bool == true && TranscriptAssembler.isFlagged(back[0]), "flagged: every reader skips it")
        #expect(back[1]["time_unknown"] == nil && !TranscriptAssembler.isFlagged(back[1]))
        #expect(back[1]["start"] as? Double == 1 && back[1]["confidence"] != nil)
    }
}
