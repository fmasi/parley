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

    func diarize(
        audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> DiarizationResult {
        // Calls the callback rather than silently dropping it: `TranscriptRediarizer.rediarize`'s
        // onProgress plumbing for this path (the `.detectingSpeakers` fraction) was otherwise
        // never exercised by any test — a divide-by-zero on `total == 0`, or the wrong phase being
        // reported, wouldn't be caught. Two calls, matching what a real backend reporting partial
        // then complete progress would look like.
        progress?(1, 2)
        progress?(2, 2)
        return DiarizationResult(
            segments: [DiarizedSegment(start: 0, end: 5, speaker: "S1")],
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

    /// #158 item 1: the canonical post-crash scenario has MULTIPLE orphan chunks, not one — every
    /// other end-to-end test above uses exactly one. Seeds chunk 0 in session.json (already
    /// completed before the crash) and drops two more orphan WAVs (`m-1`, `m-2`) that never made
    /// it into session.json, then asserts the recovered transcript covers all three chunks in
    /// order. Deliberately system-only orphans (no `_mic.wav` companion), like
    /// `recoversSystemOnlyOrphanAsSingleStream` above, so each orphan contributes exactly one
    /// FakeEngine segment instead of exercising the separate dual-stream merge/echo-dedup logic.
    @Test func recoversTranscriptCoveringAllOrphansInOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecoveryFixtures.writeSessionJSON(
            dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0]
        )
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-2.wav"), seconds: 1)

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        )

        let unwrapped = try #require(result)
        let data = try Data(contentsOf: unwrapped.jsonPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        // Chunk 0 (from session.json) contributes "chunk 0"; orphans 1 and 2 each contribute one
        // "hello" segment from FakeEngine — three chunks' worth of content, offset-ordered.
        #expect(segments.count == 3)
        let texts = segments.compactMap { $0["text"] as? String }
        #expect(texts == ["chunk 0", "hello", "hello"])
    }

    /// #158 item 2: `ChunkProcessor` appends a `ProcessedChunk` for every orphan unconditionally —
    /// even one whose transcription comes back with zero segments — so `recover()` still succeeds
    /// here with a transcript that has no segments; it does NOT hit the
    /// `guard !state.chunks.isEmpty else { return nil }` nil-return path (that guard can only fire
    /// if a future `ChunkProcessor` change starts skipping the append for a fully-empty chunk).
    /// Covers the "every orphan transcribes empty" case the guard's cleanup was written to protect,
    /// and pins today's actual behavior so a future change to either side is caught.
    @Test func recoversEmptyTranscriptWhenEveryOrphanTranscribesEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        struct EmptyEngine: TranscriptionEngine {
            let name = "Empty"
            func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { [] }
            func isReady() -> Bool { true }
            func prepare() async throws {}
        }

        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)

        let result = try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: EmptyEngine(), diarizer: nil, runner: TranscriptionRunner()
        )

        let unwrapped = try #require(result)
        let data = try Data(contentsOf: unwrapped.jsonPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.isEmpty)
    }

    /// #158 item 2 (the actually-reachable half): directly exercises `SessionState.delete`, the
    /// cleanup call added to `ChunkedSessionRecovery`'s nil-return guard so a stale session.json
    /// doesn't linger on the (currently theoretical, see above) path where recovery finds nothing
    /// to salvage after orphans existed. `ChunkedSessionRecoveryTests.returnsNilWhenNothingToRecover`
    /// already covers the nil return itself; this pins that the cleanup helper it now calls behaves.
    @Test func sessionJSONCleanupIsNoOpWhenAlreadyAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionState.delete(directory: dir, sessionId: "m")  // must not throw or crash with nothing on disk
        #expect(SessionState.read(directory: dir) == nil)
    }

    /// C-I4: chunk 1 was archived and its WAVs deleted, then the app died before session.json got it.
    /// Recovery transcribes it from the archive; its words and its audio are in the transcript.
    @Test func recoversAnArchiveOnlyOrphan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)
        _ = try await AudioArchiver.archiveSystemOnly(systemAudio: dir.appendingPathComponent("m-0.wav"), outputDirectory: dir, bitrateKbps: 64)
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)
        _ = try await AudioArchiver.archiveSystemOnly(systemAudio: dir.appendingPathComponent("m-1.wav"), outputDirectory: dir, bitrateKbps: 64)

        var config = Config.default
        config.mergeChunkedAudio = false
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: config,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        ))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        #expect((json["segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["chunk 0", "hello"])
        #expect((json["metadata"] as? [String: Any])?["audio_files"] as? [String] == ["m-0.m4a", "m-1.m4a"])
    }

    /// C-I3: the session was moved aside by a later recording in the same folder. Recovery by id still
    /// finds and finalizes it, deletes only its own files, and leaves the other recording's alone.
    @Test func recoversAMovedAsideSessionAndLeavesTheOtherAlone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1])
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "later", meetingStart: Date(timeIntervalSince1970: 7200), chunkIndices: [0])
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "m", config: .default,
            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner()
        ))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        #expect((json["segments"] as? [[String: Any]])?.count == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("session-m.json").path))
        #expect(SessionState.read(directory: dir, sessionId: "later")?.chunks.count == 1, "the later recording's session is untouched")
    }

    /// R2a item 12 (IMPORTANT, D12): with preserve_source_wav on (the owner's setting) the WAVs survive
    /// finalize. A lingering sentinel then re-ingested every one and RE-FINALIZED over the finished
    /// transcript, losing renames. A finalized session is marked durably; recovery never re-ingests or
    /// re-finalizes it — it hands back the transcript as it is.
    @Test func aFinalizedSessionIsNeverReFinalized() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = Config.default
        config.preserveSourceWAV = true
        let processor = await ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        for i in 0...1 {
            try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-\(i).wav"), seconds: 1)
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: i, systemPath: dir.appendingPathComponent("m-\(i).wav").path,
                                                                         micPath: dir.appendingPathComponent("m-\(i)_mic.wav").path,
                                                                         startTime: Date(timeIntervalSince1970: Double(i) * 60)))
        }
        let runner = await TranscriptionRunner()
        let result = try await runner.finalize(sessionState: await processor.getSessionState(), outputDirectory: dir, config: config)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m-0.wav").path), "preserved: the WAVs are still there")
        #expect(CrashRecoveryPlanner.isFinalized(outputDirectory: dir, sessionId: "m"))

        // The user renames a speaker in the finished transcript.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        var segments = try #require(json["segments"] as? [[String: Any]])
        segments[0]["speaker"] = "Alice"
        json["segments"] = segments
        try TranscriptAssembler.write(json, to: result.jsonPath)
        let renamed = try Data(contentsOf: result.jsonPath)

        // Relaunch with the sentinel still there.
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
        #expect(CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: []).isEmpty)
        let again = try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "m", config: config,
                                                             transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: runner)
        #expect(again?.jsonPath == result.jsonPath, "the finished transcript, handed back")
        #expect(try Data(contentsOf: result.jsonPath) == renamed, "never re-finalized: the rename survives")
        #expect(SessionState.read(directory: dir, sessionId: "m") == nil, "nothing re-ingested")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m-0.wav").path), "the preserved WAVs are untouched")
    }

    // MARK: - Round 3 (items 2, 3, 4)

    /// A finalized session "m" with preserved WAVs: returns the directory, the transcript and the runner.
    private func finalizedSession(format: String = "json") async throws -> (dir: URL, transcript: URL, config: Config, runner: TranscriptionRunner) {
        let dir = try makeTempDir()
        var config = Config.default
        config.preserveSourceWAV = true
        config.outputFormat = format
        let processor = await ChunkProcessor(config: config, outputDirectory: dir,
            sessionState: SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-0.wav"), seconds: 1)
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: 0, systemPath: dir.appendingPathComponent("m-0.wav").path,
                                                                     micPath: dir.appendingPathComponent("m-0_mic.wav").path,
                                                                     startTime: Date(timeIntervalSince1970: 0)))
        let runner = await TranscriptionRunner()
        let result = try await runner.finalize(sessionState: await processor.getSessionState(), outputDirectory: dir, config: config)
        return (dir, result.jsonPath, config, runner)
    }

    /// Item 2: the transcript is flushed to the disk BEFORE the marker that vouches for it.
    @Test func theTranscriptIsDurableBeforeTheMarker() async throws {
        DurableFile.recordsSyncsForTesting = true
        defer { DurableFile.recordsSyncsForTesting = false }
        let before = DurableFile.syncedForTesting.count
        let (dir, transcript, _, _) = try await finalizedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synced = Array(DurableFile.syncedForTesting.dropFirst(before))
        let transcriptAt = try #require(synced.firstIndex(of: transcript.path))
        let markerAt = try #require(synced.firstIndex(of: dir.appendingPathComponent(".m.finalized").path))
        #expect(transcriptAt < markerAt)
    }

    /// Items 2 + 3: a finalized session's leftover session.json (a crash after the marker, before its
    /// deletion) is cleaned up once the transcript is verified, a missing TXT is re-written from the
    /// transcript, and the next recording records no false displacement.
    @Test func aVerifiedFinalizedSessionIsCleanedUpNotReFinalized() async throws {
        let (dir, transcript, config, runner) = try await finalizedSession(format: "txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let leftover = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1)
        try SessionState.write(leftover, directory: dir)
        let txt = dir.appendingPathComponent("m.txt")
        try FileManager.default.removeItem(at: txt)
        let bytes = try Data(contentsOf: transcript)
        let result = try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "m", config: config,
                                                              transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: runner)
        let after = try Data(contentsOf: transcript)
        #expect(result?.jsonPath == transcript && after == bytes)
        #expect(SessionState.read(directory: dir, sessionId: "m") == nil, "the leftover session.json is gone")
        #expect(FileManager.default.fileExists(atPath: txt.path), "the TXT is re-written from the transcript")
        #expect(try SessionState.write(SessionState(sessionId: "next", meetingStart: Date(), engine: "fluid_audio", chunkDurationMinutes: 1), directory: dir) == nil,
                "the next recording displaces nothing")
    }

    /// Item 2: the marker vouches for a transcript that does NOT parse (damaged). session.json is kept
    /// and the session is finalized again from it — never deleted on the marker's word alone.
    @Test func anUnverifiableTranscriptKeepsSessionJsonAndIsFinalizedAgain() async throws {
        let (dir, transcript, config, runner) = try await finalizedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1,
                                 chunks: [ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                                                         segments: [.init(start: 0, end: 5, text: "from session.json", speaker: "Speaker 1", source: "remote")],
                                                         speakerDatabase: ["Speaker 1": [1, 0, 0]])])
        try SessionState.write(state, directory: dir)
        let damaged = Data("{ damaged".utf8)
        try damaged.write(to: transcript)
        // Round 4 item 3: a chunk whose session.json write had failed is an orphan the rebuild must take.
        try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("m-1.wav"), seconds: 1)
        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
        let relaunch = CaptureProvenance(engine: "fluid_audio", systemFormat: nil, micFormat: nil, micDevice: nil,
                                         routeChanges: 0, retries: 0, recovered: true, anomalyCount: 0)
        // No merge: the fixture's session starts in 1970 and the orphan's start is estimated from its
        // file's date, so merging would pad decades of silence.
        var rebuildConfig = config
        rebuildConfig.mergeChunkedAudio = false
        let result = try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "m", config: rebuildConfig,
                                                              transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: runner,
                                                              provenance: relaunch)
        let rewritten = try #require(result).jsonPath
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rewritten)) as? [String: Any])
        #expect((json["segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["from session.json", "hello"],
                "round 4 item 3: the rebuild ingests the unregistered orphan too")
        #expect(SessionState.read(directory: dir, sessionId: "m") == nil, "deleted only after the new transcript was written")
        // Round 4 item 2: the damaged file is kept, moved aside, never overwritten.
        #expect(try Data(contentsOf: dir.appendingPathComponent("m.damaged.json")) == damaged)
        // Round 4 item 7: the rebuild's capture facts come from the relaunch — said so.
        let stamp = try #require((json["metadata"] as? [String: Any])?["capture_provenance"] as? [String: Any])
        #expect(stamp["reconstructed"] as? Bool == true)
        #expect((stamp["reconstructed_note"] as? String)?.contains("may be incomplete") == true)
    }

    /// Item 4: the marker alone — the transcript renamed or removed by the user, no session.json. The
    /// preserved WAVs are NOT orphans; nothing is re-ingested, nothing is written.
    @Test func aMarkerAloneNeverReIngests() async throws {
        let (dir, transcript, config, runner) = try await finalizedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(at: transcript, to: dir.appendingPathComponent("Renamed by me.json"))
        #expect(CrashRecoveryPlanner.isFinalized(outputDirectory: dir, sessionId: "m"))
        #expect(CrashRecoveryPlanner.orphanChunks(outputDirectory: dir, sessionId: "m", completedIndices: []).isEmpty)
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
        let result = try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "m", config: config,
                                                              transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: runner)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: transcript.path), "no transcript is re-created")
        #expect(SessionState.read(directory: dir, sessionId: "m") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m-0.wav").path), "the preserved WAV is untouched")
    }

    /// Round 4 item 1: `isChunkedSessionRecoverable` gated recovery off for a finalized session whose
    /// transcript verifies, so its leftover session.json and a missing TXT were never cleaned in the
    /// running app. It reports them now, and `cleanupFinalized` (what stream L's launch gate calls —
    /// no rename dialog, no auto-summary) removes the leftover, sweeps temp files and re-writes the TXT.
    @Test func cleanupFinalizedRemovesTheLeftoversSilently() async throws {
        let (dir, transcript, _, _) = try await finalizedSession(format: "txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"), "clean: nothing to do")
        try SessionState.write(SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1),
                               directory: dir)
        let txt = dir.appendingPathComponent("m.txt")
        try FileManager.default.removeItem(at: txt)
        let staleTmp = dir.appendingPathComponent("m.json.\(UUID().uuidString).tmp")
        try Data("{".utf8).write(to: staleTmp)
        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"), "leftovers are work to do")
        let bytes = try Data(contentsOf: transcript)
        #expect(CrashRecoveryPlanner.cleanupFinalized(outputDirectory: dir, sessionId: "m"))
        #expect(SessionState.read(directory: dir, sessionId: "m") == nil)
        #expect(FileManager.default.fileExists(atPath: txt.path))
        #expect(!FileManager.default.fileExists(atPath: staleTmp.path), "round 4 item 5: temp leftovers swept")
        #expect(try Data(contentsOf: transcript) == bytes)
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
        #expect(!CrashRecoveryPlanner.cleanupFinalized(outputDirectory: dir, sessionId: "never-recorded"))
    }

    /// Round 4 item 5: finalize sweeps the temp files an interrupted transcript or marker write left.
    @Test func finalizeSweepsTemporaryLeftovers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = [dir.appendingPathComponent("m.json.\(UUID().uuidString).tmp"),
                     dir.appendingPathComponent(".m.finalized.\(UUID().uuidString).tmp")]
        for url in stale { try Data("{".utf8).write(to: url) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
                                   segments: [.init(start: 0, end: 1, text: "hi", speaker: "Speaker 1", source: "remote")],
                                   speakerDatabase: ["Speaker 1": [1, 0, 0]])
        _ = try await TranscriptionRunner().finalize(
            sessionState: SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 1, chunks: [chunk]),
            outputDirectory: dir, config: .default)
        #expect(stale.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
