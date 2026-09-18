import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct TranscriptAssemblerReconcileTests {

    /// A short silent mono WAV with a known, measurable duration.
    private func makeWav(at url: URL, durationSeconds: Double = 0.5, sampleRate: Double = 8000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func metadata(in jsonPath: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: jsonPath)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(obj?["metadata"] as? [String: Any])
    }

    private func makeJSON(at jsonPath: URL, sourceWavs: [URL]) throws {
        let json = TranscriptAssembler.assemble(
            segments: [],
            audioPaths: sourceWavs,
            outputFormat: "srt",
            language: "auto",
            numSpeakers: nil,
            diarization: true,
            dualStream: true
        )
        try TranscriptAssembler.write(json, to: jsonPath)
    }

    private func audioFiles(in jsonPath: URL) throws -> [String] {
        let data = try Data(contentsOf: jsonPath)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let meta = obj?["metadata"] as? [String: Any]
        return (meta?["audio_files"] as? [String]) ?? []
    }

    @Test func reconcileListsEverySource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = dir.appendingPathComponent("session.json")
        // Assembled with the four placeholder source WAVs.
        try makeJSON(at: jsonPath, sourceWavs: [
            dir.appendingPathComponent("a-0.wav"),
            dir.appendingPathComponent("a-0_mic.wav"),
            dir.appendingPathComponent("a-1.wav"),
            dir.appendingPathComponent("a-1_mic.wav"),
        ])

        TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: [
            dir.appendingPathComponent("a-0.m4a"),
            dir.appendingPathComponent("a-1.m4a"),
        ])

        #expect(try audioFiles(in: jsonPath) == ["a-0.m4a", "a-1.m4a"])
    }

    @Test func reconcilePreservesCountForN() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = dir.appendingPathComponent("session.json")
        try makeJSON(at: jsonPath, sourceWavs: [dir.appendingPathComponent("x.wav")])

        let archives = (0..<5).map { dir.appendingPathComponent("seg-\($0).m4a") }
        TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: archives)

        #expect(try audioFiles(in: jsonPath).count == 5)
    }

    @Test func reconcileIsNoOpForMissingFile() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        // Directory intentionally not created.
        let jsonPath = dir.appendingPathComponent("nope.json")
        // Must not crash or throw.
        TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: [dir.appendingPathComponent("a.m4a")])
        #expect(!FileManager.default.fileExists(atPath: jsonPath.path))
    }

    /// #204: `chunk_durations` is stamped once here, at archive time, so the rename dialog's
    /// O(chunks) `AVAudioFile` opens are needed only if this cache is ever missing or wrong.
    @Test func reconcileStampsChunkDurations() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = dir.appendingPathComponent("session.json")
        try makeJSON(at: jsonPath, sourceWavs: [dir.appendingPathComponent("a-0.wav")])

        let wavA = dir.appendingPathComponent("a-0.wav")
        let wavB = dir.appendingPathComponent("a-1.wav")
        try makeWav(at: wavA, durationSeconds: 0.5)
        try makeWav(at: wavB, durationSeconds: 1.0)

        TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: [wavA, wavB])

        let durations = try #require(try metadata(in: jsonPath)["chunk_durations"] as? [Double])
        #expect(durations.count == 2)
        #expect(abs(durations[0] - 0.5) < 0.01)
        #expect(abs(durations[1] - 1.0) < 0.01)
    }

    /// A chunk whose duration cannot be read (missing/corrupt file) gets the `0` sentinel rather
    /// than dropping the whole array or crashing — `SpeakerSampleLocator.durations(for:cached:)`
    /// is what treats that sentinel as "distrust the cache".
    @Test func reconcileStampsZeroForUnreadableChunk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = dir.appendingPathComponent("session.json")
        try makeJSON(at: jsonPath, sourceWavs: [dir.appendingPathComponent("a-0.wav")])

        // Never created on disk.
        let missing = dir.appendingPathComponent("missing.m4a")
        TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: [missing])

        let durations = try #require(try metadata(in: jsonPath)["chunk_durations"] as? [Double])
        #expect(durations == [0])
    }
}
