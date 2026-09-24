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
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default,
                                        seededState: seeded, firstChunkIndex: 1)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.chunks.map(\.index) == [0] && state.sessionId == "m")
        #expect(runner.chunkRotator?.currentChunkInfo.index == 1)
        runner.teardownChunkedPipeline()
    }

    @Test func firstChunkIndexIsPassedToTheRotator() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m",
                                        config: .default, firstChunkIndex: 5)
        #expect(runner.chunkRotator?.currentChunkInfo.index == 5)
        runner.teardownChunkedPipeline()
    }

    @Test func recordCaptureGapPersistsIntoSessionJson() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default)
        await runner.recordCaptureGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3), reason: "sleep"))
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

    @Test func processingIssueDictionariesFlattenChunkAndSessionIssues() {
        let chunk = ProcessedChunk(index: 2, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-2.m4a", segments: [], speakerDatabase: [:],
                                   issues: [ChunkIssue(code: .asrFailed, track: "remote", count: nil),
                                            ChunkIssue(code: .duplicatesFlagged, track: "local", count: 3)])
        let dicts = TranscriptionRunner.processingIssueDictionaries(
            chunks: [chunk],
            sessionIssues: [SessionIssue(chunk: 2, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil)),
                            SessionIssue(chunk: nil, issue: ChunkIssue(code: .sessionWriteFailed, track: nil, count: nil))])
        #expect(dicts.count == 4)
        #expect(dicts[0]["chunk"] as? Int == 2 && dicts[0]["code"] as? String == "asr_failed" && dicts[0]["track"] as? String == "remote" && dicts[0]["count"] == nil)
        #expect(dicts[1]["count"] as? Int == 3 && dicts[1]["track"] as? String == "local")
        #expect(dicts[2]["chunk"] as? Int == 2 && dicts[2]["track"] == nil)
        #expect(dicts[3]["chunk"] == nil && dicts[3]["code"] as? String == "session_write_failed")
    }

    /// §7.2: `metadata.diarization` is false when a chunk's diarization failed; a clean tracked
    /// session writes an empty `processing_issues`.
    @Test func finalizeStampsDiarizationFromChunkIssues() async throws {
        func finalize(_ issues: [ChunkIssue]) async throws -> [String: Any] {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                segments: [.init(start: 0, end: 5, text: "hi", speaker: "Speaker 1", source: "remote")],
                speakerDatabase: ["Speaker 1": [1, 0, 0]], issues: issues)
            let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
            let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
            return try #require(json?["metadata"] as? [String: Any])
        }
        let failed = try await finalize([ChunkIssue(code: .diarizationFailed, track: "remote", count: nil)])
        #expect(failed["diarization"] as? Bool == false)
        let clean = try await finalize([])
        #expect(clean["diarization"] as? Bool == true)
        #expect((clean["processing_issues"] as? [Any])?.isEmpty == true)
    }

    /// Review round 1 item 10: a seed from another session or engine is accepted but never silently.
    @Test func aMismatchedSeedIsRecorded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = SessionState(sessionId: "other", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10)
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default, seededState: seeded, firstChunkIndex: 0)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.issues.contains(SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedMismatch, track: nil, count: nil))))
        runner.teardownChunkedPipeline()
    }

    /// R0/R2 round ruling (R345 item 9): an engine change between crash and resume is informational;
    /// only a different session id is a problem.
    @Test func anEngineOnlySeedChangeIsInformational() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "some_other_engine", chunkDurationMinutes: 10)
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default, seededState: seeded, firstChunkIndex: 0)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.issues.map(\.issue.code) == [.seedEngineChanged])
        #expect(!ChunkIssue.Code.seedEngineChanged.affectsContent && ChunkIssue.Code.seedMismatch.affectsContent)
        runner.teardownChunkedPipeline()
    }

    /// R7: a flag set on a chunk segment survives session.json → merger → finalize → JSON, and the
    /// flagged text stays out of the TXT.
    @Test func flagsSurviveEveryHopToTheTranscript() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a", segments: [
            .init(start: 0, end: 1, text: "kept words", speaker: "Remote Speaker 1", source: "remote"),
            .init(start: 1, end: 2, text: "gate noise", speaker: "Remote Unknown", source: "remote", filtered: true),
            .init(start: 2, end: 3, text: "mic bleed", speaker: "Local Speaker 1", source: "local", echo: true),
            .init(start: 3, end: 4, text: "kept words", speaker: "Remote Speaker 1", source: "remote", duplicate: true),
        ], speakerDatabase: ["Remote Speaker 1": [1, 0, 0]], localSpeakerDatabase: ["Local Speaker 1": [0, 1, 0]], isDualStream: true)
        try SessionState.write(SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio",
                                            chunkDurationMinutes: 10, chunks: [chunk]), directory: dir)
        let state = try #require(SessionState.read(directory: dir))
        var config = Config.default
        config.outputFormat = "txt"
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: config)
        let segs = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])?["segments"] as? [[String: Any]])
        #expect(segs.count == 4)
        #expect(segs.first { $0["text"] as? String == "gate noise" }?["filtered"] as? Bool == true)
        #expect(segs.first { $0["text"] as? String == "mic bleed" }?["echo"] as? Bool == true)
        #expect(segs.filter { $0["duplicate"] as? Bool == true }.count == 1)
        let txt = try String(contentsOf: result.jsonPath.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        #expect(txt.contains("kept words") && !txt.contains("gate noise") && !txt.contains("mic bleed"))
        #expect(txt.components(separatedBy: "kept words").count == 2, "the duplicate is hidden too")
    }

    /// Round 3 item 2: a `firstChunkIndex` at or below the seeded max would restart over a settled
    /// chunk — it is clamped to max + 1.
    @Test func aFirstChunkIndexInsideTheSeedIsClamped() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunks = (0...2).map { ProcessedChunk(index: $0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-\($0).m4a", segments: [], speakerDatabase: [:]) }
        let seeded = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: Config.default.engine.rawValue,
                                  chunkDurationMinutes: 10, chunks: chunks)
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default,
                                        seededState: seeded, firstChunkIndex: 1)
        #expect(runner.chunkRotator?.currentChunkInfo.index == 3)
        runner.teardownChunkedPipeline()
    }
}
