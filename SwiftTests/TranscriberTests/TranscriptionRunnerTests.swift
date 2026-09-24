import Foundation
import Testing
@testable import TranscriberCore

/// #135 H2: each per-segment WAV in a crash-recovered / CLI multi-segment run starts at its own
/// t=0. Without a cumulative offset, segment 2's minute-2 line collides with segment 1's minute-2
/// line in the merged transcript. `segmentStartOffsets` is the pure, unit-tested guarantee that
/// `run()` turns each segment's file-relative timestamps into absolute ones.
@Suite struct TranscriptionRunnerTests {

    @Test func cumulativeOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [60, 45, 30]) == [0, 60, 105])
    }

    @Test func singleSegmentHasNoOffset() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [42]) == [0])
    }

    @Test func noSegmentsYieldsNoOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: []) == [])
    }
}

/// #135 H3: each recovery/CLI segment is diarized independently, so segment 0's "Speaker 1" and
/// segment 1's "Speaker 1" are unrelated raw labels — they may be the SAME person or two DIFFERENT
/// people. `reconcileRecoverySegments` reuses `SpeakerReconciler`'s cosine matching (rather than a
/// hand-rolled comparator) to decide which, and returns a segment-namespaced mapping so `run()` can
/// relabel every segment's segments into one consistent global namespace before merging.
@Suite struct TranscriptionRunnerReconciliationTests {

    @Test func crossSegmentIdentityYieldsTwoSpeakers() {
        // Two segments, each a single speaker under the same raw label "Speaker 1", but with
        // far-apart embeddings — i.e. two different people who both happened to be diarized as
        // "Speaker 1" locally. Must NOT collapse into one global speaker.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0, 1, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 2)
    }

    @Test func crossSegmentMatchingVoiceprintYieldsOneSpeaker() {
        // Same person's voiceprint (near-identical embedding) reappearing under "Speaker 1" in
        // both segments must reconcile to the SAME global label.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0.99, 0.01, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 1)
    }
}

@MainActor
@Suite struct TranscriptionRunnerPipelineSeamTests {
    private final class NoopRotationClient: ChunkRotationClient {
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            ("\(outputDirectory)/\(newBaseName).wav", "\(outputDirectory)/\(newBaseName)_mic.wav")
        }
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runner-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L7: a relaunch seeds the pipeline with the persisted session so completed chunks are not re-done.
    @Test func seededStateIsUsedByTheChunkPipeline() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                                   segments: [], speakerDatabase: [:])
        let seeded = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default, seededState: seeded)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.chunks.map(\.index) == [0] && state.sessionId == "m")
        runner.teardownChunkedPipeline()
    }

    @Test func recordCaptureGapPersistsIntoSessionJson() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default)
        let processor = try #require(runner.chunkProcessor)
        await processor.appendGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
        #expect(SessionState.read(directory: dir)?.gaps.map(\.reason) == ["sleep"])
        runner.teardownChunkedPipeline()
    }

    @Test func failSetupForTestingThrowsBeforeCreatingTheProcessor() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        runner.failSetupForTesting = true
        #expect(throws: (any Error).self) {
            try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default)
        }
        #expect(runner.chunkProcessor == nil)
    }

    /// P8: `dual_stream` is the capture-time flag the writer persisted, not "did a local segment survive".
    @Test func finalizeStampsDualStreamFromTheChunkFlags() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 5, text: "hi", speaker: "Remote Speaker 1", source: "remote")],
            speakerDatabase: ["Remote Speaker 1": [1, 0, 0]], localSpeakerDatabase: [:], isDualStream: true)
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
        #expect((json?["metadata"] as? [String: Any])?["dual_stream"] as? Bool == true)
    }
}
