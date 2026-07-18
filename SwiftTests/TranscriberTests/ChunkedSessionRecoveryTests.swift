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
            // Non-degenerate embedding: an all-zero vector has ‖v‖ = 0, so SpeakerReconciler's
            // cosine matching would divide by zero and propagate NaN into the reconciled speaker
            // database when these segments are merged across chunks.
            speakerDatabase: ["S1": [1, 0, 0]]
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

    /// #135: a system-only orphan (no `<base>_mic.wav`) must not be misclassified as dual-stream.
    /// `ChunkProcessor` decides dual-stream via `FileManager.fileExists(atPath: chunk.micPath)`
    /// (ChunkProcessor.swift:111) — if recovery points `micPath` at the system WAV (which exists)
    /// instead of the real, absent mic WAV, that check lies and the chunk gets treated as
    /// dual-stream, with its system audio transcribed and diarized a second time as the "local"
    /// channel and echo-deduped against itself.
    @Test func recoversSystemOnlyOrphanAsSingleStream() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0]
        )
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)
        // Deliberately no m-1_mic.wav — this orphan is system-audio-only.

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        )

        let unwrapped = try #require(result)
        let data = try Data(contentsOf: unwrapped.jsonPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        let dualStream = try #require(metadata["dual_stream"] as? Bool)
        #expect(dualStream == false)
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

    /// Finding 1 (#154): a recovered session must still carry `capture_provenance` in its transcript
    /// metadata. `finalize` reads it off `sessionState.provenance`, which is always nil for a
    /// synthesized/rehydrated session unless `recover` threads a caller-supplied provenance onto it.
    @Test func stampsProvenanceOntoRecoveredTranscript() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1]
        )
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2_mic.wav"), seconds: 1)

        let provenance = CaptureProvenance(
            engine: "fluidAudio", systemFormat: "48000/1", micFormat: "48000/1", micDevice: "Test Mic",
            routeChanges: 0, retries: 0, recovered: true, anomalyCount: 0
        )

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner(),
            provenance: provenance
        )

        let unwrapped = try #require(result)
        let data = try Data(contentsOf: unwrapped.jsonPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        let stamped = try #require(metadata["capture_provenance"] as? [String: Any])
        #expect(stamped["recovered"] as? Bool == true)
        #expect(stamped["mic_device"] as? String == "Test Mic")
    }

    /// Finding 7 (#154): no session.json at all — the entire session is one orphan WAV. Exercises the
    /// synthesized-baseState branch (as opposed to the session.json-plus-one-orphan branches above).
    @Test func recoversFromOrphanOnlyWhenNoSessionJSON() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        )

        let unwrapped = try #require(result)
        #expect(FileManager.default.fileExists(atPath: unwrapped.jsonPath.path))
    }
}
