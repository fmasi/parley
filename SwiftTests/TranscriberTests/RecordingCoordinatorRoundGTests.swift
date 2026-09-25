import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round G (items 235–250). The fake client and the harness are RecordingCoordinatorTests.swift's; `HungRead` is
// RecordingCoordinatorRoundCTests.swift's; `roundFPendingSession` and `roundFTearDown` are RecordingCoordinatorRoundFTests.swift's.

/// A pending session `name` whose transcript was already written (its finalized marker there): a retry's gate only cleans
/// it up.
@MainActor
func roundGFinishedPendingSession(_ h: Harness, _ name: String) async throws -> RecordingSentinel {
    let p = try roundFPendingSession(h, name)
    let dir = URL(fileURLWithPath: p.systemAudioPath).deletingLastPathComponent()
    _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: name, config: h.config.config,
                                                               transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
    return p
}

// MARK: - Crash detection is disarmed only by whoever still owns the app (242)

@MainActor
@Suite struct CaptureOwnershipRoundGTests {
    /// L review 242 (129): the finalized gate awaits the adopt and the record's build between its ownership check and the end
    /// of the capture. A Start that gets in there owns the app: its crash detection is never disarmed — the gate's
    /// bookkeeping (the commit, the forget) still happens.
    @Test func aStartDuringAFinishedRetrysBuildKeepsItsCrashDetectionArmed() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        let p = try await roundGFinishedPendingSession(h, "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let coordinator = h.coordinator, client = h.client
        client.onFinalizeDiagnostics = {
            client.onFinalizeDiagnostics = nil
            await coordinator.startRecording(sessionName: "new", microphoneDeviceId: nil)
        }
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.isRecording && client.startCalls.count == 1, "the new recording runs")
        #expect(client.captureEndedCalls == 0, "its crash detection stays armed")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "the finished session is still forgotten")
        #expect(client.commitCalls == ["p"], "and its evidence committed")
    }
}

// MARK: - A stuck recovery file never holds an exit, nor lets a stopped recording resume (235, 236)

/// A recovery-file queue that sticks at every operation named in `labels` (all of them when nil) while `stuck` is set — up
/// to its watchdog — as a folder that stopped answering does.
final class StuckSentinelQueue: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var isStuck = true
    }
    private let state = State()
    let io: SentinelIO
    init(_ labels: Set<String>? = nil, watchdog: Double = 10) {
        let state = state
        io = SentinelIO(label: "rc-g-sentinel-\(UUID().uuidString)", beforeEach: { label in
            guard labels?.contains(label) ?? true, state.lock.withLock({ state.isStuck }) else { return }
            _ = state.gate.wait(timeout: .now() + watchdog)
        })
    }
    /// Unsticks it: every waiting operation runs, and none waits again.
    func release() {
        state.lock.withLock { state.isStuck = false }
        for _ in 0..<50 { state.gate.signal() }
    }
}

@MainActor
@Suite struct StuckRecoveryFileRoundGTests {
    /// L review 235: the marks a logout makes — `willPowerOff`'s, the terminate delegate's, the preparation's — are bounded:
    /// a recovery file's queue stuck behind a hung operation never holds the reply past the termination's bound. The
    /// helper is still stopped.
    @Test func aStuckRecoveryFileNeverHoldsALogoutPastItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let stuck = StuckSentinelQueue()
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        let began = ContinuousClock.now
        h.coordinator.markPowerOffDuringFinalize()   // willPowerOff
        h.coordinator.markForTermination()           // the terminate delegate, before it answers
        await h.coordinator.prepareForTermination(bound: .seconds(2))
        let took = ContinuousClock.now - began
        #expect(took < .seconds(4), "replied within its bound: \(took)")
        #expect(h.client.stopCalls == 1, "the helper was still stopped")
    }

    /// L review 236: the Stop's stopping mark does not answer (the recovery file's queue is stuck), and Parley dies before the
    /// Stop is done. The next launch never RESUMES the recording the user stopped: it is salvaged.
    @Test func aStopWhoseMarkTimedOutIsNeverResumedAfterACrash() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == false)
        let stuck = StuckSentinelQueue(["mark stopping"])
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        // Parley "dies" inside the helper's stop: nothing after it runs until the test is over.
        let client = h.client
        let dead = Harness.Box<CheckedContinuation<Void, Never>?>(nil)
        client.onStop = { await withCheckedContinuation { dead.value = $0 } }
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { dead.value != nil }
        #expect(dead.value != nil, "the Stop went on past its mark")
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == false, "the mark never landed")
        // The relaunch: a new process, the same folders — the helper is not capturing, and the recording was alive a moment ago.
        let relaunched = try Harness(tmp: h.tmp)
        await relaunched.coordinator.recoverAtLaunch()
        #expect(relaunched.client.startCalls.isEmpty, "never resumed")
        #expect(relaunched.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil, "salvaged")
        #expect(relaunched.appState.activeAlarms[.recordingResumedWithGap] == nil)
        // The first process is let go, its Stop finished, before the folder goes.
        stuck.release()
        client.onStop = nil
        dead.value?.resume()
        await stopping.value
    }
}

@Suite struct StopKeptApartDecisionRoundGTests {
    /// L review 236 (b): a Stop kept apart — asked for no earlier than the recording was last alive — is a stopping recording:
    /// salvaged, never resumed, and never re-attached (the helper that still captures is stopped by the relaunch).
    @Test func aStopKeptApartIsStopping() {
        let alive = Date(timeIntervalSince1970: 1000), now = alive.addingTimeInterval(20)
        func decide(_ requested: Date?, capturing: Bool = false) -> RelaunchDecision {
            RelaunchDecision.decide(lastAliveAt: alive, bootSessionUUID: "b", wasStopping: false, now: now, helperCapturing: capturing,
                                    currentBootSessionUUID: "b", folderReachable: true, stopRequestedAt: requested)
        }
        #expect(decide(nil) == .resumeSameSession(gapStart: alive))
        #expect(decide(alive.addingTimeInterval(5)) == .salvageAndStop(reason: .wasStopping))
        #expect(decide(alive.addingTimeInterval(5), capturing: true) == .salvageAndStop(reason: .wasStopping))
        #expect(decide(alive.addingTimeInterval(-5)) == .resumeSameSession(gapStart: alive), "alive after it: not this stop's")
    }
}

// MARK: - The exit's flush: a spent budget is not a hung folder (244)

@MainActor
@Suite struct ExitFlushRoundGTests {
    /// L review 244 (195): a flush that had no real budget left — the exit's deadline all but spent — says nothing about the
    /// folder: the app's own last flush is not skipped for it.
    @Test func aFlushWithNoBudgetLeftIsNotAHungFolder() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .milliseconds(20))
        #expect(!h.coordinator.exitFlushTimedOut)
        h.coordinator.evidenceFlushBound = .milliseconds(200)
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        #expect(h.coordinator.exitFlushTimedOut, "a real budget that ran out: the folder is not answering")
    }

    /// … and each exit attempt says it afresh: an earlier attempt's timeout never skips a later exit's last flush.
    @Test func eachExitAttemptSaysItsOwnFlush() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        h.coordinator.evidenceFlushBound = .milliseconds(200)
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        #expect(h.coordinator.exitFlushTimedOut)
        h.client.onFlush = nil
        await h.coordinator.prepareForTermination(bound: .seconds(2))   // nothing in flight: a quick exit
        #expect(!h.coordinator.exitFlushTimedOut)
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        h.client.onFlush = nil
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(!h.coordinator.exitFlushTimedOut, "the Quit's own attempt")
    }
}

// MARK: - Which volume: the recording root alone is resolved, on a queue of its own (237, 238, 241)

@Suite struct FolderVolumeRoundGTests {
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func hang() { _ = semaphore.wait(timeout: .now() + 10) }   // the watchdog: never a wedged run
        func release() { for _ in 0..<8 { semaphore.signal() } }
    }
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [String] = []
        var value: [String] { lock.withLock { folders } }
        func append(_ folder: String) { lock.withLock { folders.append(folder) } }
    }

    /// L review 237: a resolution that hangs (a dying local disk under a link) never makes another folder's read wait: the
    /// resolutions run on a queue of their own, never the one a read with no volume yet falls back to.
    @Test func aHungResolutionNeverDelaysAnotherFoldersRead() async throws {
        let gate = Gate()
        defer { gate.release() }
        let reads = FolderReads(label: "folder-reads-g-\(UUID().uuidString)", volumeOf: { folder in
            if folder.hasPrefix("/Volumes/Dying") { gate.hang() }
            return folder.hasPrefix("/Volumes/Dying") ? "/Volumes/Dying" : "/"
        })
        _ = await reads.read("dying", folder: "/Volumes/Dying/rec", seconds: 0.3) { 1 }
        let began = ContinuousClock.now
        let healthy = await reads.read("healthy", folder: "/Users/me/Recordings/2026-09-25", seconds: 0.5) { 2 }
        #expect(healthy == 2, "answered")
        #expect(ContinuousClock.now - began < .seconds(1), "within its bound")
    }

    /// L review 237: only the recording root is resolved — once — and every folder under it is derived from it lexically.
    @Test func onlyTheRecordingRootIsResolved() async {
        let asked = Asked()
        let reads = FolderReads(label: "folder-reads-g-\(UUID().uuidString)", volumeOf: { asked.append($0); return "/Volumes/Rec" })
        reads.noteRecordingRoot("/Users/me/Recordings")
        for folder in ["/Users/me/Recordings/2026-09-25", "/Users/me/Recordings/2026-09-26", "/Users/me/Recordings"] {
            #expect(await reads.read("day", folder: folder, seconds: 1) { 1 } == 1)
        }
        #expect(asked.value == ["/Users/me/Recordings"], "\(asked.value)")
    }

    /// L review 238 (214): the resolution never reads a share through the Data volume's firmlinked spelling of it, nor —
    /// on a case-insensitive boot volume — through another case of its mount point.
    @Test func theResolutionNeverReadsAShareThroughAnotherSpellingOfIt() {
        let mounts: [FolderReads.Mount] = [.init(path: "/", isLocal: true), .init(path: "/System/Volumes/Data", isLocal: true),
                                           .init(path: "/Volumes/NAS", isLocal: false)]
        var readOnShare: [String] = []
        func readLink(_ path: String) -> String? {
            if path.lowercased().contains("/volumes/nas") { readOnShare.append(path) }
            return nil
        }
        #expect(FolderReads.volume(of: "/System/Volumes/Data/Volumes/NAS/rec", mounts: mounts, readLink: readLink) == "/Volumes/NAS")
        #expect(FolderReads.volume(of: "/volumes/nas/rec", mounts: mounts, readLink: readLink, caseInsensitive: true) == "/Volumes/NAS")
        #expect(readOnShare.isEmpty, "read on the share: \(readOnShare)")
    }

    /// L review 241: a mutation nothing waits for — a cleanup's deletes on a slow share — has its own queue per volume, never
    /// queued ahead of a read of that volume (a Start's).
    @Test func aSlowMutationNeverDelaysARead() async throws {
        let gate = Gate()
        defer { gate.release() }
        let started = DispatchSemaphore(value: 0)
        let reads = FolderReads(label: "folder-reads-g-\(UUID().uuidString)", volumeOf: { _ in "/Volumes/Slow" })
        reads.enqueue("slow deletes", folder: "/Volumes/Slow/rec") { started.signal(); gate.hang() }
        _ = await Task.detached { started.wait(timeout: .now() + 5) }.value
        let began = ContinuousClock.now
        #expect(await reads.read("start", folder: "/Volumes/Slow/rec", seconds: 0.5) { 1 } == 1)
        #expect(ContinuousClock.now - began < .seconds(1))
    }

    /// L review 241: an automount the mount table spells under the Data volume (`/System/Volumes/Data/home`) is the volume of
    /// its firmlinked spelling (`/home/…`).
    @Test func anAutomountSpelledUnderTheDataVolumeIsFound() {
        let mounts: [FolderReads.Mount] = [.init(path: "/", isLocal: true), .init(path: "/System/Volumes/Data", isLocal: true),
                                           .init(path: "/System/Volumes/Data/home", isLocal: false)]
        #expect(FolderReads.lexicalVolume(of: "/home/me/Recordings", mounts: mounts, caseInsensitive: false) == "/System/Volumes/Data/home")
        #expect(FolderReads.lexicalVolume(of: "/System/Volumes/Data/home/me", mounts: mounts, caseInsensitive: false) == "/System/Volumes/Data/home")
    }
}

// MARK: - The folder alarm says each folder's own state (241)

@MainActor
@Suite struct FolderAlarmWordingRoundGTests {
    /// L review 241: pending folders in DIFFERENT states — one read-only, one on a drive that is away — are each said as
    /// what they are, never all "not reachable".
    @Test func mixedFolderStatesAreEachSaid() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let readOnly = try roundFPendingSession(h, "ro")
        let away = RecordingSentinel(startedAt: Date(), sessionName: "away",
                                     systemAudioPath: "/Volumes/NoSuchDrive-\(UUID().uuidString)/rec/away-0.wav",
                                     micAudioPath: "/Volumes/NoSuchDrive/rec/away-0_mic.wav", stopping: true)
        try RecordingSentinel.writePending([readOnly, away], directory: h.tmp)
        let roFolder = URL(fileURLWithPath: readOnly.systemAudioPath).deletingLastPathComponent().path
        let live = RecordingCoordinator.FolderProbe.live
        h.coordinator.folderProbe = .init(exists: live.exists,
                                          isWritable: { $0.path.hasPrefix(roFolder) ? false : live.isWritable($0) },
                                          isVolumeRoot: live.isVolumeRoot)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingFolderUnavailable]?.message)
        #expect(row.contains("permissions") && row.contains("isn’t reachable"), "\(row)")
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 2, "both kept")
    }
}

// MARK: - The late-chunks row's wording (241)

@Suite struct LateChunksWordingRoundGTests {
    /// L review 241: one chunk is "it", several are "they".
    @Test func theLateChunksRowAgreesInNumber() {
        let one = RecoveryMessages.lateChunksUnchecked(files: ["m-1.wav"], folder: "~/Rec")
        #expect(one.contains("a chunk") && one.contains("If it is in ~/Rec, its audio is kept there"), "\(one)")
        let two = RecoveryMessages.lateChunksUnchecked(files: ["m-1.wav", "m-2.wav"], folder: "~/Rec")
        #expect(two.contains("2 chunks") && two.contains("If they are in ~/Rec, their audio is kept there"), "\(two)")
    }
}

// MARK: - A finalize's cleanup is a mutation after its look (241)

@MainActor
@Suite struct FinalizeCleanupRoundGTests {
    /// L review 241 (215): a finalize that finds its session already finalized cleans its leftovers up as a mutation queued
    /// AFTER its bounded look — never inside it — and still never writes over the transcript.
    @Test func anAlreadyFinalizedSessionsCleanupRunsAfterTheLook() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runner-g-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        try RecoveryFixtures.writeSessionJSON(dir: d, sessionId: "f", meetingStart: Date(), chunkIndices: [0])
        let state = try #require(SessionState.read(directory: d, sessionId: "f"))
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "runner-g-\(UUID().uuidString)")
        let first = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        let written = try Data(contentsOf: first.jsonPath)
        try SessionState.write(state, directory: d)   // a leftover progress file
        let labels = Harness.Box<[String]>([]), lock = NSLock()
        runner.folderReads = FolderReads(label: "runner-g-\(UUID().uuidString)", beforeEachRead: { label in
            lock.withLock { labels.value.append(label) }
        })
        await #expect(throws: SessionAlreadyFinalized.self) {
            _ = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        }
        await Harness.until { SessionState.read(directory: d, sessionId: "f") == nil }
        #expect(lock.withLock { labels.value }.contains("transcript: cleanup finalized"), "\(lock.withLock { labels.value })")
        #expect(SessionState.read(directory: d, sessionId: "f") == nil, "cleaned up")
        #expect(try Data(contentsOf: first.jsonPath) == written, "never written over")
    }
}
