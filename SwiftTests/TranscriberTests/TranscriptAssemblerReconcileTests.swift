import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptAssemblerReconcileTests {

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
}
