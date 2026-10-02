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

    // MARK: - #242: echo verdicts at finalize

    private func verdict(_ label: String, echo: Bool, remote: [String: Double] = [:]) -> EchoDeduplicator.ClusterVerdict {
        EchoDeduplicator.ClusterVerdict(
            label: label, segments: echo ? 40 : 10, matchedSegments: echo ? 36 : 0, seconds: echo ? 400 : 60, matchedSeconds: echo ? 360 : 0,
            words: echo ? 480 : 90, matchedWords: echo ? 432 : 0, share: echo ? 0.9 : 0, verdict: echo ? .echo : .kept,
            bestEmbeddingSimilarity: echo ? 0.68 : 0.08, matchedRemote: remote)
    }

    /// Two chunks whose diarizers numbered the speakers differently: in chunk 1 the bleed voice is
    /// "Local Speaker 1", the user "Local Speaker 2", and the only remote voice "Remote Speaker 1" is
    /// chunk 0's "Remote Speaker 2".
    private func twoChunksWithABleedClusterInTheSecond() -> SessionState {
        let user: [Float] = [1, 0, 0], bleed: [Float] = [0, 1, 0], remoteA: [Float] = [0, 0, 1], remoteB: [Float] = [1, 1, 0]
        let first = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a", segments: [
            .init(start: 0, end: 5, text: "w1 w2 w3", speaker: "Remote Speaker 1", source: "remote"),
            .init(start: 5, end: 10, text: "w4 w5 w6", speaker: "Remote Speaker 2", source: "remote"),
            .init(start: 10, end: 15, text: "w7 w8 w9", speaker: "Local Speaker 1", source: "local"),
        ], speakerDatabase: ["Speaker 1": remoteA, "Speaker 2": remoteB], localSpeakerDatabase: ["Speaker 1": user],
           echoClusters: [verdict("Local Speaker 1", echo: false)], isDualStream: true)
        let second = ProcessedChunk(index: 1, startTime: Date(timeIntervalSince1970: 600), audioPath: "m-1.m4a", segments: [
            .init(start: 0, end: 5, text: "w10 w11 w12", speaker: "Remote Speaker 1", source: "remote"),
            .init(start: 0.2, end: 5.2, text: "w10 w11 w12", speaker: "Local Speaker 1", source: "local", echo: true),
            .init(start: 6, end: 9, text: "w13 w14 w15", speaker: "Local Speaker 2", source: "local"),
        ], speakerDatabase: ["Speaker 1": remoteB], localSpeakerDatabase: ["Speaker 1": bleed, "Speaker 2": user],
           echoSegmentsFlagged: 36,
           echoClusters: [verdict("Local Speaker 1", echo: true, remote: ["Remote Speaker 1": 352.8]), verdict("Local Speaker 2", echo: false)],
           isDualStream: true,
           issues: [ChunkIssue(code: .echoFlagged, track: "local", count: 36), ChunkIssue(code: .echoCluster, track: "local", count: 1)])
        return SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [first, second])
    }

    /// The verdicts reach `metadata.echo_clusters`, one entry per (chunk, local cluster), with the
    /// labels of the transcript's global speaker namespace — the ones its segments carry — and the
    /// count under `echo_segments_flagged`. Read back from session.json first, as a crash-recovered
    /// finalize does.
    @Test func finalizeWritesEchoClustersInTheGlobalSpeakerNamespace() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(twoChunksWithABleedClusterInTheSecond(), directory: dir)
        let state = try #require(SessionState.read(directory: dir, sessionId: "m"))
        var config = Config.default
        config.mergeChunkedAudio = false
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: config)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])

        let clusters = try #require(metadata["echo_clusters"] as? [[String: Any]])
        #expect(clusters.map { "\($0["chunk"] as? Int ?? -1) \($0["label"] as? String ?? "") \($0["verdict"] as? String ?? "")" }
                == ["0 Local Speaker 1 kept", "1 Local Speaker 2 echo", "1 Local Speaker 1 kept"],
                "chunk 1's bleed cluster was its Speaker 1 and is the transcript's Local Speaker 2; its user is Local Speaker 1")
        let echo = try #require(clusters.first { $0["verdict"] as? String == "echo" })
        #expect(echo["track"] as? String == "local")
        #expect(echo["segments"] as? Int == 40 && echo["matched_segments"] as? Int == 36)
        #expect(echo["seconds"] as? Double == 400 && echo["matched_seconds"] as? Double == 360 && echo["share"] as? Double == 0.9)
        #expect(echo["words"] as? Int == 480 && echo["matched_words"] as? Int == 432)
        #expect(echo["embedding_similarity"] as? Double == 0.68)
        #expect(echo["matched_remote"] as? [String: Double] == ["Remote Speaker 2": 352.8], "chunk 1's Remote Speaker 1 is the transcript's Remote Speaker 2")
        // The cluster's label is the one the echo-flagged segment carries in the same transcript.
        let flagged = try #require(segments.first { $0["echo"] as? Bool == true })
        #expect(flagged["speaker"] as? String == echo["label"] as? String)
        #expect(clusters.allSatisfy { $0["text"] == nil }, "numbers and labels only")

        #expect(metadata["echo_segments_flagged"] as? Int == 36 && metadata["echo_segments_removed"] as? Int == 36)
        let issues = try #require(metadata["processing_issues"] as? [[String: Any]])
        #expect(issues.contains { $0["code"] as? String == "echo_cluster" && $0["chunk"] as? Int == 1 && $0["count"] as? Int == 1 && $0["track"] as? String == "local" })
        #expect(metadata["processing_issue_count"] as? Int == 0, "echo_cluster and echo_flagged are informational")
        #expect(segments.count == 6, "nothing is deleted")
    }

    /// The remap is the merger's: a label the mapping does not hold is kept, and a chunk with no
    /// verdicts adds nothing.
    @Test func echoClusterDictionariesRemapWithTheMergersMapping() {
        let chunks = [
            ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a", segments: [], speakerDatabase: [:]),
            ProcessedChunk(index: 4, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-4.m4a", segments: [], speakerDatabase: [:],
                           echoClusters: [verdict("Local Speaker 1", echo: true, remote: ["Remote Speaker 1": 10, "Remote Unknown": 2])]),
        ]
        let dicts = TranscriptionRunner.echoClusterDictionaries(
            chunks: chunks, speakerMapping: [4: ["Local Speaker 1": "Local Speaker 3", "Remote Speaker 1": "Remote Speaker 2"]])
        #expect(dicts.count == 1)
        #expect(dicts[0]["chunk"] as? Int == 4 && dicts[0]["label"] as? String == "Local Speaker 3")
        #expect(dicts[0]["matched_remote"] as? [String: Double] == ["Remote Speaker 2": 10, "Remote Unknown": 2])
        let unmapped = TranscriptionRunner.echoClusterDictionaries(chunks: chunks, speakerMapping: [:])
        #expect(unmapped[0]["label"] as? String == "Local Speaker 1")
    }

    /// A session with no mic stream ran no echo dedup: the key is left out, never written empty.
    @Test func finalizeLeavesEchoClustersOutOfASingleStreamTranscript() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 5, text: "hi", speaker: "Speaker 1", source: "remote")], speakerDatabase: ["Speaker 1": [1, 0, 0]])
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        let metadata = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])?["metadata"] as? [String: Any])
        #expect(metadata["echo_clusters"] == nil && metadata["echo_segments_flagged"] == nil)
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

    /// R2 council (C-I5, reverses review round 1 item 10): a seed from ANOTHER session is refused. It
    /// used to be accepted with its own id, so this recording finalized as `<other>.json` and merged
    /// the other meeting's chunks into its record. The pipeline starts fresh under the current id,
    /// the mismatch is recorded, and the other session's chunks stay out.
    @Test func aMismatchedSeedIsRefusedAndRecorded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "other-0.m4a", segments: [], speakerDatabase: [:])
        let seeded = SessionState(sessionId: "other", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio",
                                  chunkDurationMinutes: 10, chunks: [foreign])
        try SessionState.write(seeded, directory: dir)   // R2a M9: the other session's file is on disk
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default, seededState: seeded, firstChunkIndex: 0)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.sessionId == "m", "the current session's id, never the seed's")
        #expect(state.chunks.isEmpty, "the other session's chunks are not this recording's")
        #expect(state.meetingStart != seeded.meetingStart)
        #expect(state.issues == [SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedMismatch, track: nil, count: nil))])
        #expect(runner.chunkRotator?.currentChunkInfo.index == 0)
        await runner.recordCaptureGap(CaptureGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), reason: "sleep"))
        #expect(SessionState.read(directory: dir, sessionId: "other")?.chunks.map(\.audioPath) == ["other-0.m4a"], "the other session's file is untouched")
        runner.teardownChunkedPipeline()
    }

    /// R2a M3: refusing another session's seed must not start this session EMPTY when its own state
    /// is on disk (here moved aside by the other recording): that state is the fallback.
    @Test func aRefusedSeedFallsBackToThisSessionsOwnState() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let own = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 100), engine: Config.default.engine.rawValue, chunkDurationMinutes: 10,
                               chunks: [ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 100), audioPath: "m-0.m4a", segments: [], speakerDatabase: [:])])
        let other = SessionState(sessionId: "other", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10)
        try SessionState.write(own, directory: dir)
        try SessionState.write(other, directory: dir)                                  // m moved aside
        let runner = TranscriptionRunner()
        // As the caller's bounded look found it (L review 234): the setup never reads the folder itself.
        try runner.setupChunkedPipeline(captureClient: NoopRotationClient(), outputDirectory: dir, sessionBaseName: "m", config: .default,
                                        seededState: other, ownStateOnDisk: SessionState.read(directory: dir, sessionId: "m"), firstChunkIndex: 1)
        let state = try #require(await runner.chunkProcessor?.getSessionState())
        #expect(state.sessionId == "m" && state.chunks.map(\.audioPath) == ["m-0.m4a"] && state.meetingStart == own.meetingStart)
        #expect(state.issues.contains(SessionIssue(chunk: nil, issue: ChunkIssue(code: .seedMismatch, track: nil, count: nil))))
        #expect(runner.chunkRotator?.currentChunkInfo.index == 1)
        runner.teardownChunkedPipeline()
    }

    /// R2a M7: WAVs left next to an archived, registered chunk (a crash after the session.json write
    /// and before their deletion) are cleaned up at finalize — never those the user asked to keep, and
    /// never those of a chunk whose recognition failed or whose audio IS the WAV.
    @Test func leftoverWavsOfArchivedChunksAreCleanedUpAtFinalizeUnlessPreserved() async throws {
        for preserve in [false, true] {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            func wav(_ name: String) throws -> URL { let u = dir.appendingPathComponent(name); try RecoveryFixtures.writeFakeWav(at: u, seconds: 1); return u }
            let archivedSys = try wav("m-0.wav"), archivedMic = try wav("m-0_mic.wav")
            try Data(count: 64).write(to: dir.appendingPathComponent("m-0.m4a"))
            let failedSys = try wav("m-1.wav")
            try Data(count: 64).write(to: dir.appendingPathComponent("m-1.m4a"))
            let wavOnly = try wav("m-2.wav")
            let chunks = [
                ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a", segments: [], speakerDatabase: [:], isDualStream: true),
                ProcessedChunk(index: 1, startTime: Date(timeIntervalSince1970: 600), audioPath: "m-1.m4a", segments: [], speakerDatabase: [:],
                               issues: [ChunkIssue(code: .asrFailed, track: "remote", count: nil)]),
                ProcessedChunk(index: 2, startTime: Date(timeIntervalSince1970: 1200), audioPath: "m-2.wav", segments: [], speakerDatabase: [:],
                               issues: [ChunkIssue(code: .archiveFailed, track: nil, count: nil)]),
            ]
            var config = Config.default
            config.preserveSourceWAV = preserve
            config.mergeChunkedAudio = false
            _ = try await TranscriptionRunner().finalize(
                sessionState: SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: chunks),
                outputDirectory: dir, config: config)
            let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
            // The deletes run once the record is written, fire-and-forget (L review 215).
            if !preserve { await Harness.until { !exists(archivedSys) && !exists(archivedMic) } }
            #expect(exists(archivedSys) == preserve && exists(archivedMic) == preserve, "preserve_source_wav: \(preserve)")
            #expect(exists(failedSys), "an ASR-failed chunk keeps its WAV for re-transcription")
            #expect(exists(wavOnly), "a chunk whose audio IS the WAV keeps it")
        }
    }


    /// C-I3: finalize deletes only ITS session.json — never a later recording's that now holds the file.
    @Test func finalizeDeletesOnlyItsOwnSessionFile() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(SessionState(sessionId: "later", meetingStart: Date(timeIntervalSince1970: 60), engine: "fluid_audio",
                                            chunkDurationMinutes: 10), directory: dir)
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                                   segments: [.init(start: 0, end: 5, text: "hi", speaker: "Speaker 1", source: "remote")],
                                   speakerDatabase: ["Speaker 1": [1, 0, 0]])
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        _ = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        #expect(SessionState.read(directory: dir, sessionId: "later") != nil)
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

/// #264: `run()` — the CLI and the legacy single-file recovery — driven with a fake engine and diarizer through
/// `engineFactoryForTesting`. A side with audio and no speech has no words to label.
@MainActor
@Suite struct TranscriptionRunnerNoSpeechTests {
    /// Hears one line on the streams it is told speak, and nothing on the others.
    private struct ScriptedEngine: TranscriptionEngine {
        let name = "Scripted"
        let speaks: Set<AudioSourceType>
        func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
            speaks.contains(audioSource) ? [TranscriptSegment(start: 0, end: 0.5, text: "hello", language: "en")] : []
        }
        func isReady() -> Bool { true }
        func prepare() async throws {}
    }

    /// Throws on the files it finds no speech in, as FluidAudio's offline diarizer does (`noSpeechDetected`); one speaker
    /// on any other. Keeps the names of the files it was asked to diarize.
    private actor NoSpeechDiarizer: DiarizationProvider {
        struct NoSpeech: Error {}
        private let silent: Set<String>
        private(set) var asked: [String] = []
        init(silent: Set<String>) { self.silent = silent }

        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            asked.append(audioPath.lastPathComponent)
            if silent.contains(audioPath.lastPathComponent) { throw NoSpeech() }
            return DiarizationResult(segments: [DiarizedSegment(start: 0, end: 1, speaker: "S1")], speakerDatabase: ["S1": [1, 0, 0]])
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult { throw NoSpeech() }
    }

    /// A folder with both streams, one second each unless told: `m.wav` (system) and `m_mic.wav`.
    private func recording(seconds: Double = 1) throws -> (dir: URL, system: URL, mic: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-no-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let system = dir.appendingPathComponent("m.wav"), mic = dir.appendingPathComponent("m_mic.wav")
        try RecoveryFixtures.writeFakeWav(at: system, seconds: seconds)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: seconds)
        return (dir, system, mic)
    }

    /// A listen-only recording: words on the system stream, audio and no words on the microphone. The microphone is not
    /// diarized — diarizing it threw (no speech) and failed the whole run — and the system stream is labelled as usual.
    @Test func aStreamWithNoWordsIsNotDiarizedAndTheRunCompletes() async throws {
        let (dir, system, mic) = try recording(); defer { try? FileManager.default.removeItem(at: dir) }
        let diarizer = NoSpeechDiarizer(silent: ["m_mic.wav"])
        let runner = TranscriptionRunner()
        runner.engineFactoryForTesting = { _ in (ScriptedEngine(speaks: [.system]), diarizer) }
        let result = try await runner.run(systemAudio: system, micAudio: mic, outputDirectory: dir, config: .default)
        #expect(await diarizer.asked == ["m.wav"], "the stream with no words is not diarized")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.map { $0["speaker"] as? String } == ["Remote Speaker 1"] && segments.map { $0["source"] as? String } == ["remote"])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["diarization"] as? Bool == true && metadata["dual_stream"] as? Bool == true)
    }

    /// ...while a diarizer that throws on a stream that DOES have words still fails the run: no transcript is written.
    @Test func aDiarizerThrowOnAStreamWithWordsStillFailsTheRun() async throws {
        let (dir, system, mic) = try recording(); defer { try? FileManager.default.removeItem(at: dir) }
        let diarizer = NoSpeechDiarizer(silent: ["m.wav"])
        let runner = TranscriptionRunner()
        runner.engineFactoryForTesting = { _ in (ScriptedEngine(speaks: [.system, .microphone]), diarizer) }
        await #expect(throws: NoSpeechDiarizer.NoSpeech.self) {
            _ = try await runner.run(systemAudio: system, micAudio: mic, outputDirectory: dir, config: .default)
        }
        #expect(await diarizer.asked == ["m.wav"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("m.json").path))
    }

    /// The seam left unset — as in production — `run` builds its own engine and diarizer: two header-only files are
    /// skipped before either is asked anything, and the transcript says diarization was on.
    @Test func withoutTheSeamRunBuildsItsOwnEngineAndDiarizer() async throws {
        let (dir, system, mic) = try recording(seconds: 0); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await TranscriptionRunner().run(systemAudio: system, micAudio: mic, outputDirectory: dir, config: .default)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        #expect((json["segments"] as? [Any])?.isEmpty == true)
        #expect((json["metadata"] as? [String: Any])?["diarization"] as? Bool == true)
    }
}
