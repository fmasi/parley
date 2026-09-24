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
}
