import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round D (items 169–185): the coordinator's side. The fake client and the harness are
// RecordingCoordinatorTests.swift's; `HungRead` is RecordingCoordinatorRoundCTests.swift's.

// MARK: - Quit, power-off (170, 171, 173, 174)

@MainActor
@Suite struct RecordingCoordinatorQuitRoundDTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// L review 170: once the relaunch's ping answered `.capturing` (Flow A), a capture is running: a Quit before the
    /// re-attach is done — here, during its folder scan — is a Quit of a recording. It asks, and the recording is stopped
    /// within the bound — never an exit that leaves the capture running with no app.
    @Test func aQuitOnceTheProbeFoundACaptureAsksAndStopsIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        try Harness.headerOnlyWAV().write(to: outDir(s).appendingPathComponent("sess-1.wav"))   // the helper's live file
        h.client.isCapturingResult = true
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        let hung = HungRead("re-attach: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-d-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { hung.reached }
        let asked = Harness.Box(false)
        let quit = Task { await coordinator.prepareForQuit(confirm: { asked.value = true; return true }) }
        await Harness.until { asked.value }
        #expect(asked.value, "a capture is running: the Quit asks")
        hung.release()
        let quitting = await quit.value
        await relaunch.value
        #expect(quitting, "Parley quits once the recording is stopped")
        #expect(h.client.stopCalls >= 1 && h.appState.isIdle, "the capture was stopped, never left running")
        #expect(h.presented.value.map(\.lastPathComponent) == ["sess.json"], "and finished")
    }

    /// … and answering No keeps Parley — and the re-attach — going.
    @Test func aQuitOnceTheProbeFoundACaptureCanBeDeclined() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        let hung = HungRead("re-attach: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-d-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { hung.reached }
        #expect(await coordinator.prepareForQuit(confirm: { false }) == false)
        hung.release()
        await relaunch.value
        #expect(h.appState.isRecording && h.client.stopCalls == 0, "re-attached, untouched")
    }

    /// L review 171: a Stop deferred during a crash restart (`stopRequestedDuringRecovery`) is a stop in flight to Quit —
    /// asked nothing, and waited for: Parley never quits before the restart has honoured the Stop and the transcript is
    /// written.
    @Test func aQuitDuringAStopDeferredByARestartWaitsForIt() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let released = Harness.Box(false)
        h.client.onStartAsync = { while !released.value { await Task.yield() } }
        let coordinator = h.coordinator
        let recovering = Task { await coordinator.handleXPCCrash() }
        await Harness.until { h.client.startCalls.count == 2 }
        await h.coordinator.stopRecording()   // deferred to the restart
        #expect(h.coordinator.stopRequestedDuringRecovery && !h.appState.isRecording)
        let quit = Harness.Box<Bool?>(nil)
        let quitting = Task { quit.value = await coordinator.prepareForQuit(confirm: { Issue.record("the user already stopped it"); return false }) }
        for _ in 0..<50 { await Task.yield() }
        #expect(quit.value == nil, "waiting for the deferred Stop")
        h.client.onStartAsync = nil
        released.value = true
        await recovering.value
        await quitting.value
        #expect(quit.value == true && h.appState.isIdle)
        #expect(h.client.finalizeCalls.count == 1, "the Stop ran before Parley quit")
    }

    /// L review 174: `willPowerOff` marks a transcript being finished as a quit — for `powerOffMarkWindow` only. A logout
    /// the user cancelled leaves the app running: past the window the mark goes, so a later crash is said as a crash.
    @Test func aPowerOffQuitMarkExpiresWhenTheAppOutlivesIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.coordinator.powerOffMarkWindow = .milliseconds(100)
        h.coordinator.markPowerOffDuringFinalize()
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true, "marked at once, synchronously")
        await Harness.until { RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == false }
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == false, "the logout never came: the mark is gone")
        // The app then crashes: the next launch says so.
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("Parley crashed") && !row.contains("quit"), "\(row)")
    }

    /// … while a real quit inside the window keeps it: a quit's own mark never expires.
    @Test func aQuitInsideThePowerOffWindowKeepsTheMark() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.coordinator.powerOffMarkWindow = .milliseconds(100)
        h.coordinator.markPowerOffDuringFinalize()
        h.coordinator.markForTermination()   // the logout went ahead: the termination marks it too
        try await Task.sleep(for: .milliseconds(300))
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true)
    }
}

// MARK: - The rename's own reads (175, 184)

@MainActor
@Suite struct RenameReadsRoundDTests {
    /// L review 184 (item 134's test): the rename panel's parse of a transcript is bounded — a folder that does not answer
    /// gives nil within the deadline, so the panel is skipped and the rename queue never wedges; one that answers parses.
    @Test func theRenameParseIsBounded() async throws {
        let hung = HungRead("rename: transcript")
        defer { hung.release() }
        let reads = RenameReads(reads: FolderReads(label: "rename-d-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) }))
        let url = URL(fileURLWithPath: "/tmp/rename-d/sess.json")
        let began = ContinuousClock.now
        let parsed = await reads.read(transcript: url, seconds: 0.2) { $0.lastPathComponent }
        #expect(parsed == nil && hung.reached, "not answered: skipped")
        #expect(ContinuousClock.now - began < .seconds(1), "bounded")
        let answering = RenameReads(reads: FolderReads(label: "rename-d-\(UUID().uuidString)"))
        #expect(await answering.read(transcript: url, seconds: 1) { $0.lastPathComponent } == "sess.json")
    }

    /// L review 175: the rename reads through a folder reader of its OWN — its own queues, its own keys — never the
    /// coordinator's (`FolderReads.shared`).
    @Test func theRenameNeverSharesTheCoordinatorsReader() {
        #expect(RenameReads.shared.reads !== FolderReads.shared)
    }

    private func pendingSession(_ h: Harness, _ name: String, in dir: URL) throws -> RecordingSentinel {
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0])
        return RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                 micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
    }

    /// L review 175: while a rename panel parses a transcript in a folder — slowly — a recovery pass over two sessions in
    /// that SAME folder salvages both, with the app's own readers (the coordinator's `FolderReads.shared`, the rename's
    /// `RenameReads.shared`): the parse neither makes their reads "no answer yet" nor holds their queue. Each panel then
    /// parses its transcript.
    @Test func aSlowPanelParseNeverKeepsTwoSameFolderSessionsWaiting() async throws {
        let h = try Harness()
        defer { h.runner.teardownChunkedPipeline(); try? FileManager.default.removeItem(at: h.tmp) }
        h.coordinator.folderReads = .shared   // the app's own
        h.coordinator.folderReadDeadline = .milliseconds(500)
        let dir = h.tmp.appendingPathComponent("day")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = try pendingSession(h, "a", in: dir), b = try pendingSession(h, "b", in: dir)
        try RecordingSentinel.writePending([a, b], directory: h.tmp)
        // An earlier recording's panel is still parsing its transcript in that folder, slowly.
        let hung = HungRead("slow panel")
        defer { hung.release() }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("earlier.json"))
        let slowPanel = Task { await RenameReads.shared.read(transcript: dir.appendingPathComponent("earlier.json")) { url -> String in
            hung.hangIfNamed("slow panel"); return url.lastPathComponent
        } }
        await Harness.until { hung.reached }
        let panels = Harness.Box<[String?]>([])
        let parses = Harness.Box<[Task<Void, Never>]>([])
        h.onPresent.value = { url in
            parses.value.append(Task { @MainActor in
                panels.value.append(await RenameReads.shared.read(transcript: url, seconds: 5) { $0.lastPathComponent })
            })
        }
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.map(\.lastPathComponent).sorted() == ["a.json", "b.json"], "both salvaged")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "neither kept waiting")
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] == nil, "never \"not answering\"")
        hung.release()
        #expect(await slowPanel.value == "earlier.json")
        for parse in parses.value { await parse.value }
        #expect(panels.value.compactMap { $0 }.sorted() == ["a.json", "b.json"], "each panel shown: \(panels.value)")
    }
}

// MARK: - Late audio, fixed reference, honest row (176, 181); network mounts (179)

@MainActor
@Suite struct RecordingCoordinatorLateAudioRoundDTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// A pending session finalized the way a stop finalizes it — its transcript written two minutes ago — with the
    /// leftovers a crash between the transcript and the sentinel's delete leaves, and `late` written after it.
    private func finalizedPending(_ h: Harness, late: (name: String, seconds: Double?)) async throws -> (RecordingSentinel, URL) {
        let dir = h.tmp.appendingPathComponent("day")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunk = ProcessedChunk(index: 0, startTime: Date(), audioPath: "sess-0.m4a",
                                   segments: [.init(start: 0, end: 5, text: "chunk 0", speaker: "Speaker 1", source: "remote", qualityScore: 1)],
                                   speakerDatabase: ["Speaker 1": [1, 0, 0]], isDualStream: false, issues: [])
        let state = SessionState(sessionId: "sess", meetingStart: Date(), engine: "fluidAudio", chunkDurationMinutes: 1, chunks: [chunk])
        try SessionState.write(state, directory: dir)
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "sess", config: h.config.config, transcriber: FakeEngine(), diarizer: FakeDiarizer(),
            runner: h.runner))
        try SessionState.write(state, directory: dir)   // the leftover progress file
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: result.jsonPath.path)
        let lateURL = dir.appendingPathComponent(late.name)
        if let seconds = late.seconds { try RecoveryFixtures.writeFakeWav(at: lateURL, seconds: seconds) } else { try Data(repeating: 7, count: 4_096).write(to: lateURL) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lateURL.path)
        let s = RecordingSentinel(startedAt: Date(), sessionName: "sess", systemAudioPath: dir.appendingPathComponent("sess-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("sess-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
        try RecordingSentinel.writePending([s], directory: h.tmp)
        return (s, result.jsonPath)
    }

    /// L review 176: lateness is judged from a FIXED reference — the transcript's time as the first look found it, kept in
    /// the note — never from the transcript's modification time, which the note's own write moves. A Start during the
    /// scan interrupts the pass after the note is written; the retry still raises the row. L review 181: the row is honest
    /// — seconds under a minute, the transcript named, and no "Recording STOPPED" (nothing just stopped).
    @Test func aRetryAfterAnInterruptedScanStillSaysTheLateAudio() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        h.config.update { $0.recordingDirectory = "/Volumes/Absent-\(UUID().uuidString)/rec" }
        let (_, transcript) = try await finalizedPending(h, late: ("sess-7.wav", 30))
        let hung = HungRead("salvage: session folder")
        defer { hung.release(); hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-d-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let coordinator = h.coordinator
        let pass = Task { await coordinator.retryPendingSessions() }
        await Harness.until { hung.reached }
        coordinator.announceStart()   // the user's Start, during the scan
        hung.release()
        await pass.value
        #expect(h.appState.activeAlarms[.recordingStopped] == nil && RecordingSentinel.readPending(directory: h.tmp).count == 1, "interrupted: kept")
        let note = try #require(((try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])?["metadata"] as? [String: Any])?["audio_after_transcript"] as? [String: Any])
        #expect((note["files"] as? [String]) == ["sess-7.wav"], "noted before the Start got in")
        await coordinator.startRecording(sessionName: "x", microphoneDeviceId: nil)   // refused (its folder is away): idle again
        #expect(h.appState.isIdle && !coordinator.isStartInFlight)
        hung.release()   // the retry's scan answers at once
        await coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("30 s") && row.contains("sess.json") && row.contains("not transcribed"), "\(row)")
        #expect(!row.contains("STOPPED") && !row.contains("min"), "\(row)")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "done")
    }

    /// L review 181: a late file whose length cannot be read is said as such — never a made-up "1 min".
    @Test func aLateFileOfUnknownLengthIsSaidAsSuch() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await finalizedPending(h, late: ("sess-7.wav", nil))
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("length unknown") && !row.contains("min"), "\(row)")
    }

    /// L review 181, the wording itself.
    @Test func theLateAudioRowIsHonest() {
        let under = RecoveryMessages.audioAfterTranscript(seconds: 45, transcript: "sess.json", folder: "~/Rec")
        #expect(under.contains("45 s") && under.contains("sess.json") && under.contains("~/Rec") && !under.contains("STOPPED"), "\(under)")
        let over = RecoveryMessages.audioAfterTranscript(seconds: 150, transcript: "sess.json", folder: "~/Rec")
        #expect(over.contains("3 min") && !over.contains(" s "), "\(over)")
        let unknown = RecoveryMessages.audioAfterTranscript(seconds: nil, transcript: "sess.json", folder: "~/Rec")
        #expect(unknown.contains("length unknown") && unknown.contains("sess.json"), "\(unknown)")
    }

    /// L review 179: item 126 outside `/Volumes`. A missing automounted share (`/Network/…`, `/net/…`, `/mnt/…`) whose
    /// nearest existing ancestor is root's and not writable is a share that is not there — unreachable — never a
    /// permissions problem. A folder there that the USER owns and cannot write still is one.
    @Test func aMissingNetworkMountIsUnreachableNotAPermissionsProblem() {
        for folder in ["/Network/Servers/nas/share/Rec/day", "/net/nas/share/Rec/day", "/mnt/nas/Rec/day"] {
            let root = "/" + URL(fileURLWithPath: folder).pathComponents[1]
            let probe = RecordingCoordinator.FolderProbe(exists: { ["/", root, "/Network/Servers"].contains($0.path) }, isWritable: { _ in false },
                                                         isVolumeRoot: { _ in false }, ownerIsRoot: { _ in true })
            #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: folder), probe: probe) == .unreachable, "\(folder)")
        }
        let owned = RecordingCoordinator.FolderProbe(exists: { ["/", "/mnt", "/mnt/data"].contains($0.path) }, isWritable: { _ in false },
                                                     isVolumeRoot: { _ in false }, ownerIsRoot: { $0.path != "/mnt/data" })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/mnt/data/Rec"), probe: owned) == .notWritable)
        let home = RecordingCoordinator.FolderProbe(exists: { $0.path == "/" }, isWritable: { _ in false }, isVolumeRoot: { _ in false },
                                                    ownerIsRoot: { _ in true })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/Rec"), probe: home) == .notWritable, "not an automount root")
    }
}
