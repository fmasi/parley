import Testing
import Foundation
@testable import TranscriberCore

/// Minimal fake engine: returns one canned segment regardless of audio content. `ChunkProcessor`
/// only decodes the WAV itself for AAC archiving (real AVFoundation, works fine on the fixture's
/// silent-but-valid WAV) — ASR happens entirely through this injected engine.
///
/// Not `private` — reused by `ChunkProcessorTests` so the pipeline has one shared test double
/// instead of two near-identical copies.
struct FakeEngine: TranscriptionEngine {
    let name = "Fake"

    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 5, text: "hello", language: "en")]
    }

    func isReady() -> Bool { true }
    func prepare() async throws {}
}

/// Minimal fake diarizer: one speaker, one segment. Shared with `ChunkProcessorTests`.
struct FakeDiarizer: DiarizationProvider {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
        DiarizationResult(
            segments: [DiarizedSegment(start: 0, end: 5, speaker: "S1")],
            speakerDatabase: ["S1": [0, 0, 0]]
        )
    }
}

struct ChunkedSessionRecoveryTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkedSessionRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func recoversTranscriptFromSessionJSONWhenBaseWavDeleted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1]
        )
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2_mic.wav"), seconds: 1)

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        )

        let unwrapped = try #require(result)
        #expect(FileManager.default.fileExists(atPath: unwrapped.jsonPath.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path))
    }

    @Test func returnsNilWhenNothingToRecover() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        )

        #expect(result == nil)
    }
}
