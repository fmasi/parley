import Foundation
import Testing
@testable import TranscriberCore

// Round J: the Stop path's bounds (#226, #232). The fake client, the harness and `HungStep` are
// RecordingCoordinatorTests.swift's; `roundFTearDown` is RecordingCoordinatorRoundFTests.swift's; `RefusedStoppingError`
// is RecordingCoordinatorTests.swift's.

/// An engine that records what it was asked to read — each file's size as it stood then — and, given a `HungStep`,
/// never answers until the test releases it: a chunk whose processing does not finish.
final class RoundJEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "RoundJ"
    private let lock = NSLock()
    private var seen: [(file: String, bytes: Int)] = []
    private let hang: HungStep?

    init(hang: HungStep? = nil) { self.hang = hang }

    /// Every file it was asked to transcribe, in order, with its size at that moment.
    var transcribed: [(file: String, bytes: Int)] { lock.withLock { seen } }

    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: audioPath.path))?[.size] as? Int) ?? -1
        lock.withLock { seen.append((audioPath.lastPathComponent, bytes)) }
        await hang?.hangAwaited()
        return []   // no words: nothing to diarize, so no model is ever loaded
    }

    func isReady() -> Bool { true }
    func prepare() async throws {}
}

@MainActor
private enum RoundJ {
    nonisolated static let pcmBytes = 4_800

    /// A WAV with `writes` × `pcmBytes` of silence after its header: unlike a header-only one, the engine is asked to read it.
    static func wav(writes: Int = 1) -> Data { Harness.headerOnlyWAV() + Data(count: pcmBytes * writes) }

    /// A recording started on `engine`, its first chunk's system file holding audio. Returns that file.
    static func start(_ h: Harness, engine: RoundJEngine) async throws -> URL {
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.runner.enginesForTesting = (engine, nil)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let chunk0 = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try wav().write(to: chunk0)
        return chunk0
    }

    /// The helper seals chunk 0 at a rotation, and the pipeline starts processing it. Returns the paths the helper's stop
    /// will answer with: chunk 1's, which it never wrote a frame to.
    static func rotate(_ h: Harness, sealing chunk0: URL) async throws -> AudioPaths {
        let dir = chunk0.deletingLastPathComponent()
        let mic = dir.appendingPathComponent(chunk0.deletingPathExtension().lastPathComponent + "_mic.wav")
        h.client.rotateReply = { _ in (chunk0.path, mic.path) }
        let rotator = try #require(h.runner.chunkRotator)
        await rotator.rotateForTesting()
        let live = dir.appendingPathComponent(rotator.currentBaseName + ".wav")
        return AudioPaths(systemAudio: live, micAudio: dir.appendingPathComponent(rotator.currentBaseName + "_mic.wav"))
    }

    static func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// Lets the hung chunk go and waits for what it left behind, so nothing of this test runs into the next.
    static func finish(_ h: Harness, _ hung: HungStep) async {
        hung.release()
        await Harness.until(within: 10) { h.coordinator.chunksStillProcessing.isEmpty && h.appState.isIdle }
        await Harness.settle()
        roundFTearDown(h)
    }
}

// MARK: - The Stop's wait for chunk processing is bounded (#226)

@MainActor
@Suite struct StopPathChunkProcessingBoundRoundJTests {
    /// #226: a chunk whose processing never finishes — its recording folder stopped answering under it — used to hold the
    /// Stop for ever ("Transcribing…", Start refused, force-quit the only way out). The Stop now ends at its bound, while
    /// the chunk is still hung: the session is kept pending, and the user is told Parley will finish it.
    @Test func aStopWhoseChunkNeverFinishesEndsAtItsBoundAndKeepsTheSession() async throws {
        let h = try Harness()
        let hung = HungStep(), engine = RoundJEngine(hang: hung)
        let chunk0 = try await RoundJ.start(h, engine: engine)
        h.client.stopResult = try await RoundJ.rotate(h, sealing: chunk0)
        await Harness.until { hung.reached }
        #expect(hung.isHanging, "chunk 0 is being processed, and does not finish")

        h.coordinator.chunkProcessingDeadline = .milliseconds(200)
        await h.coordinator.stopRecording()

        #expect(hung.isHanging, "ended by the bound, never by the chunk: it was still being processed")
        #expect(h.appState.isIdle, "never left on Transcribing…")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "out of the slot: a new recording can start")
        let kept = try #require(RoundJ.pending(h).first)
        #expect(kept.stopCause == .folderNotAnswering && kept.stopping, "kept for later, salvage-only")
        let critical = try #require(h.criticals.value.last)
        #expect(critical.body.contains("isn’t answering") && critical.body.contains("Parley will finish it"), "\(critical.body)")
        #expect(h.presented.value.isEmpty, "no transcript was written without the chunk")
        #expect(h.client.everyRecordedEvent.contains { $0.kind == .folderNotAnswering && $0.detail["during"] == "chunk processing" })
        await RoundJ.finish(h, hung)
    }

    /// #226: the same wait in `settleAbandonedPipeline` — a Stop the helper refuses (another stop is under way in it) holds
    /// the session; it no longer waits for a chunk that does not finish before it says so.
    @Test func aHeldStopNeverWaitsForAChunkThatDoesNotFinish() async throws {
        let h = try Harness()
        let hung = HungStep(), engine = RoundJEngine(hang: hung)
        let chunk0 = try await RoundJ.start(h, engine: engine)
        _ = try await RoundJ.rotate(h, sealing: chunk0)
        await Harness.until { hung.reached }
        h.client.stopError = RefusedStoppingError()   // every ask: another stop is under way
        h.coordinator.stopDeadline = .milliseconds(300)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)

        h.coordinator.chunkProcessingDeadline = .milliseconds(200)
        await h.coordinator.stopRecording()

        #expect(hung.isHanging, "ended by the bound, never by the chunk")
        #expect(h.appState.isIdle)
        #expect(RoundJ.pending(h).first?.heldReason == .stopUnderWay, "held for the helper, as before")
        await RoundJ.finish(h, hung)
    }

    /// #226: the same wait in `finalizeAbandonedSession` — the helper never answered the stop, so the session is salvaged
    /// from the live pipeline; a chunk that does not finish keeps the session for later, never the salvage waiting.
    @Test func aSalvageWhoseChunkNeverFinishesKeepsTheSession() async throws {
        let h = try Harness()
        let hung = HungStep(), engine = RoundJEngine(hang: hung)
        let chunk0 = try await RoundJ.start(h, engine: engine)
        _ = try await RoundJ.rotate(h, sealing: chunk0)
        await Harness.until { hung.reached }
        let helper = HungStep()   // the helper's stop hangs until released
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        h.coordinator.stopDeadline = .milliseconds(200)

        h.coordinator.chunkProcessingDeadline = .milliseconds(200)
        await h.coordinator.stopRecording()

        #expect(hung.isHanging && helper.isHanging, "ended by its bounds: neither the helper nor the chunk had answered")
        #expect(h.appState.isIdle && h.client.droppedConnections == 1)
        #expect(RoundJ.pending(h).first?.stopCause == .folderNotAnswering, "kept for later")
        let critical = try #require(h.criticals.value.last)
        #expect(critical.body.contains("isn’t answering"), "\(critical.body)")
        #expect(h.presented.value.isEmpty, "no transcript was written without the chunk")
        await RoundJ.finish(h, hung)
    }

    /// #226: the chunk a bounded wait left behind still runs. Until it ends, the session is not salvaged in this process —
    /// a second pipeline over the same file would transcribe the chunk twice and write its archive under the first — and
    /// once it ends, the session is finished: every chunk transcribed once, by the pipeline that had it.
    @Test func aSessionLeftBehindIsFinishedOnceItsChunksEndNeverTwice() async throws {
        let h = try Harness()
        let hung = HungStep(), engine = RoundJEngine(hang: hung), salvageEngine = RoundJEngine()
        h.engine.value = salvageEngine   // what a salvage would transcribe with
        let chunk0 = try await RoundJ.start(h, engine: engine)
        h.client.stopResult = try await RoundJ.rotate(h, sealing: chunk0)
        await Harness.until { hung.reached }
        h.coordinator.chunkProcessingDeadline = .milliseconds(200)
        await h.coordinator.stopRecording()
        #expect(hung.isHanging && RoundJ.pending(h).count == 1)

        // An event (a wake, a mount) retries the pending sessions while the chunk is still being processed.
        h.client.stopResult = nil   // the helper holds nothing now: its stop answers "No capture in progress"
        await h.coordinator.retryPendingSessions()
        #expect(hung.isHanging)
        #expect(salvageEngine.transcribed.isEmpty, "never a second pipeline over a chunk still being processed")
        #expect(RoundJ.pending(h).count == 1 && h.presented.value.isEmpty, "the session still waits")

        hung.release()   // the folder answers: the chunk ends
        // Waited for by its outcome — the transcript presented — never by `.idle` (#298): the completion goes idle before
        // its last await, and presents only after it, so a wait for idle alone could read `presented` one turn early.
        await Harness.until(within: 10) { RoundJ.pending(h).isEmpty && !h.presented.value.isEmpty && h.appState.isIdle }
        #expect(RoundJ.pending(h).isEmpty, "finished without another event")
        #expect(h.presented.value.count == 1, "its transcript is written and presented")
        #expect(engine.transcribed.map(\.file) == [chunk0.lastPathComponent], "chunk 0 was transcribed once…")
        #expect(salvageEngine.transcribed.isEmpty, "…and never again")
        await RoundJ.finish(h, hung)
    }

    /// The healthy path is as it was: a Stop on a folder that answers, under the DEFAULT bound, waits for its chunks and
    /// writes the transcript — no session kept, nothing said to have failed.
    @Test func aStopWhoseChunksFinishIsUnchanged() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let engine = RoundJEngine()
        let chunk0 = try await RoundJ.start(h, engine: engine)
        h.client.stopResult = try await RoundJ.rotate(h, sealing: chunk0)
        #expect(h.coordinator.chunkProcessingDeadline == nil, "the default bound")

        await h.coordinator.stopRecording()

        #expect(h.presented.value.count == 1 && h.criticals.value.isEmpty, "\(h.criticals.value)")
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil && RoundJ.pending(h).isEmpty)
        #expect(engine.transcribed.map(\.file) == [chunk0.lastPathComponent])
        #expect(h.coordinator.chunksStillProcessing.isEmpty)
        #expect(!h.client.everyRecordedEvent.contains { $0.kind == .folderNotAnswering })
    }

    /// The bound: as long as the audio still being processed — from when the oldest unfinished chunk began recording — and
    /// never under the floor. Never a fixed number of seconds a long chunk on a slow Mac could outlast.
    @Test func theBoundIsTheAudioStillBeingProcessedNeverUnderTheFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bound = { (ago: TimeInterval?) in
            RecordingCoordinator.chunkProcessingBound(oldestUnfinishedStart: ago.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(RecordingCoordinator.chunkProcessingFloor == .seconds(300))
        #expect(bound(nil) == .seconds(300), "nothing unfinished: the floor")
        #expect(bound(60) == .seconds(300), "a short chunk: the floor — a cold engine's load is in it")
        #expect(bound(30 * 60) == .seconds(1_800), "a 30-minute chunk: 30 minutes")
        #expect(bound(3 * 3_600) == .seconds(10_800), "three unfinished chunks back, or one chunk no rotation cut: all of it")
        #expect(bound(-60) == .seconds(300), "a clock set back: the floor, never a negative wait")
    }
}

// MARK: - The orphan is re-ingested only once the helper sealed it (#232)

@MainActor
@Suite struct OrphanSealWaitRoundJTests {
    /// A harness whose folder reader lets the test's fake helper write: `beforeLook` runs before every look the app takes
    /// at the last chunk's files.
    private func harness(beforeLook: @escaping @Sendable () -> Void) throws -> Harness {
        let h = try Harness()
        h.coordinator.folderReads = FolderReads(label: "rc-roundj-\(UUID().uuidString)", beforeEachRead: { label in
            if label == "salvage: last chunk seal" { beforeLook() }
        })
        return h
    }

    private nonisolated static func append(_ url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(count: RoundJ.pcmBytes))
    }

    /// #232: a Stop the helper never answered drops the connection, and the helper seals its live chunk in its
    /// invalidation handler — after the app has moved on. The chunk used to be read at once, up to half a second short,
    /// and recorded as transcribed. The fake helper here seals in three more writes, one before each look the app takes
    /// at the file (a helper writing on a timer would make this a stopwatch test): the engine reads the file only after
    /// the last of them.
    @Test func theLastChunkIsReadOnlyOnceTheHelperSealedIt() async throws {
        let live = Harness.Box<URL?>(nil), writes = Harness.Box(0), dropped = Harness.Box(false)
        let h = try harness {
            guard dropped.value, writes.value < 3, let url = live.value else { return }
            writes.value += 1
            Self.append(url)
        }
        defer { roundFTearDown(h) }
        let engine = RoundJEngine()
        live.value = try await RoundJ.start(h, engine: engine)
        let helper = HungStep()   // the helper's stop hangs until released
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        h.client.onDropConnection = { dropped.value = true }
        h.coordinator.stopDeadline = .milliseconds(200)
        h.coordinator.sealWait = (stable: .milliseconds(100), poll: .milliseconds(10), limit: .seconds(10))

        await h.coordinator.stopRecording()

        let sealedBytes = RoundJ.wav(writes: 4).count
        #expect(writes.value == 3, "the helper finished sealing")
        let read = try #require(engine.transcribed.first)
        #expect(read.bytes == sealedBytes, "read at \(read.bytes) bytes, sealed at \(sealedBytes): never before the last write")
        #expect(engine.transcribed.count == 1)
        let critical = try #require(h.criticals.value.last)
        #expect(critical.title == "Transcript Saved After an Error", "\(critical)")
        #expect(!critical.body.contains("couldn’t check the last chunk"), "sealed: nothing left unchecked — \(critical.body)")
        #expect(!h.client.everyRecordedEvent.contains { $0.detail["during"] == "last chunk seal" })
    }

    /// #232: a file that never stops changing — the helper never let go — is not waited for past the limit. The chunk is
    /// still transcribed (its audio is never left out), and the record and the user are told it could not be checked.
    @Test func aLastChunkThatNeverSettlesIsProcessedAndSaidUnchecked() async throws {
        let live = Harness.Box<URL?>(nil), dropped = Harness.Box(false)
        let h = try harness {
            guard dropped.value, let url = live.value else { return }
            Self.append(url)   // every look finds it longer
        }
        defer { roundFTearDown(h) }
        let engine = RoundJEngine()
        live.value = try await RoundJ.start(h, engine: engine)
        let helper = HungStep()
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        h.client.onDropConnection = { dropped.value = true }
        h.coordinator.stopDeadline = .milliseconds(200)
        h.coordinator.sealWait = (stable: .milliseconds(100), poll: .milliseconds(5), limit: .milliseconds(300))

        await h.coordinator.stopRecording()

        #expect(engine.transcribed.count == 1, "transcribed all the same: \(engine.transcribed)")
        let critical = try #require(h.criticals.value.last)
        #expect(critical.body.contains("Parley couldn’t check the last chunk"), "\(critical.body)")
        #expect(h.client.everyRecordedEvent.contains { $0.kind == .folderNotAnswering && $0.detail["during"] == "last chunk seal" })
        #expect(h.appState.isIdle)
    }
}
