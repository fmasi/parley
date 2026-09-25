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
        // Written two minutes ago: its stamp (L review 220) and its file's time say so.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any])
        var metadata = try #require(json["metadata"] as? [String: Any])
        metadata[TranscriptAssembler.writtenAtKey] = TranscriptAssembler.formatWrittenAt(Date().addingTimeInterval(-120))
        json["metadata"] = metadata
        try TranscriptAssembler.write(json, to: result.jsonPath)
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
    /// — seconds under a minute, the transcript named, and no "Recording STOPPED" (nothing just stopped). L review 219: nor
    /// under that headline — its own acknowledgeable kind, "Audio kept after a transcript".
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
        #expect(h.appState.activeAlarms[.recordingStopped] == nil, "never under the \"Recording STOPPED\" headline")
        let alarm = try #require(h.appState.activeAlarms[.audioAfterTranscript])
        #expect(alarm.kind.headline == "Audio kept after a transcript" && alarm.kind.isAcknowledgeable)
        let row = alarm.message
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
        let row = try #require(h.appState.activeAlarms[.audioAfterTranscript]?.message)
        #expect(row.contains("length unknown") && !row.contains("min"), "\(row)")
    }

    /// L review 181, the wording itself. L review 226: never rounded into a length it is not — 150 s is "2 min 30 s", and
    /// under a second is "less than 1 s".
    @Test func theLateAudioRowIsHonest() {
        let under = RecoveryMessages.audioAfterTranscript(seconds: 45, transcript: "sess.json", folder: "~/Rec")
        #expect(under.contains("45 s") && under.contains("sess.json") && under.contains("~/Rec") && !under.contains("STOPPED"), "\(under)")
        let over = RecoveryMessages.audioAfterTranscript(seconds: 150, transcript: "sess.json", folder: "~/Rec")
        #expect(over.hasPrefix("2 min 30 s of audio") && !over.contains("3 min"), "\(over)")
        let whole = RecoveryMessages.audioAfterTranscript(seconds: 120, transcript: "sess.json", folder: "~/Rec")
        #expect(whole.hasPrefix("2 min of audio"), "\(whole)")
        let tiny = RecoveryMessages.audioAfterTranscript(seconds: 0.4, transcript: "sess.json", folder: "~/Rec")
        #expect(tiny.hasPrefix("Less than 1 s of audio"), "never rounded up to a second: \(tiny)")
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

// MARK: - Held sessions, the engine, one row per session (177, 178, 180, 183)

/// An engine whose model is not there (L review 178): created fine, never ready — every transcription fails.
struct NotReadyEngine: TranscriptionEngine {
    struct NotDownloaded: Error, LocalizedError { var errorDescription: String? { "its speech model is not downloaded" } }
    let name = "NotReady"
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw NotDownloaded() }
    func isReady() -> Bool { false }
    func prepare() async throws { throw NotDownloaded() }
}

@MainActor
@Suite struct RecordingCoordinatorHeldRoundDTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// A pending session `name` in `folder`: chunk 0 transcribed in its session.json, and — `orphan` — a chunk 1 on disk that
    /// is not (it needs the engine).
    private func pendingSession(_ h: Harness, _ name: String, in folder: String, orphan: Bool = false,
                                startedAt: Date = Date(), held: RecordingSentinel.HeldReason? = nil) throws -> RecordingSentinel {
        let dir = h.tmp.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: startedAt, chunkIndices: [0])
        if orphan { try RecoveryFixtures.writeFakeWav(at: dir.appendingPathComponent("\(name)-1.wav"), seconds: 1) }
        var s = RecordingSentinel(startedAt: startedAt, sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
        s.heldReason = held
        return s
    }

    /// L review 177: a Stop HELD because another stop was still under way in the helper is, once the helper lets go,
    /// said for what it was — never "Parley crashed".
    @Test func aHeldStopIsSaidForWhatItWasOnceTheHelperLetsGo() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        h.client.stopError = RefusedStoppingError()
        h.coordinator.stopDeadline = .milliseconds(200)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        await h.coordinator.stopRecording()
        #expect(pending(h).first?.heldReason == .stopUnderWay)
        h.appState.acknowledge(.recordingStopped)
        h.client.stopError = nil   // the other stop is over: "No capture in progress"
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty)
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(!row.contains("crashed") && row.contains("another stop was still under way") && row.contains("once the capture helper let go"), "\(row)")
    }

    /// L review 183: while a held helper has not let go, NO held session is salvaged — the stuck helper may still be writing
    /// its chunk. A pending session that was never held still is (L review 167's). Once the helper lets go, both are.
    @Test func noHeldSessionIsSalvagedWhileAHeldHelperHoldsOn() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let older = try pendingSession(h, "held", in: "other", held: .restartFailed)
        let away = try pendingSession(h, "away", in: "third")
        try RecordingSentinel.writePending([older, away], directory: h.tmp)
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the helper will not let go
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value.map(\.lastPathComponent) == ["away.json"], "only the never-held one: \(h.presented.value)")
        #expect(Set(pending(h).map(\.sessionKey)) == [older.sessionKey, s.sessionKey], "the held ones wait")
        h.client.onStop = nil
        h.client.isCapturingResult = false
        h.coordinator.helperStopDeadline = .seconds(5)
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.map(\.lastPathComponent).contains("held.json") && pending(h).isEmpty, "\(h.presented.value)")
    }

    /// L review 178: a salvage whose engine is not ready — its model not downloaded — while there is audio to transcribe is
    /// not the audio's failure: the session stays PENDING, the row says so, and it is finished once the engine is ready.
    @Test func aSalvageWhoseEngineIsNotReadyWaitsForIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p", in: "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey], "kept")
        #expect(h.presented.value.isEmpty && h.client.finalizeCalls.isEmpty, "nothing transcribed without the engine")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("transcription engine isn’t ready") && row.contains("once the engine is ready") && !row.contains("could not be transcribed"), "\(row)")
        h.engine.value = FakeEngine()   // a model download finished
        await h.coordinator.transcriptionEngineMayBeReady()
        #expect(pending(h).isEmpty && h.presented.value.map(\.lastPathComponent) == ["p.json"])
    }

    /// … an engine that cannot even be made (not on this macOS) keeps it pending too — when there is audio to recognise
    /// (L review 232: with none, no engine is needed) …
    @Test func aSalvageWhoseEngineCannotBeMadeWaitsForIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p", in: "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engineError.value = TranscriptionRunner.RunnerError.engineUnavailable("SpeechAnalyzer")
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey], "kept, never \"finalize failed\" and forgotten")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("transcription engine isn’t ready"), "\(row)")
    }

    /// … while a session whose every chunk is already transcribed needs no engine: it is finished at once.
    @Test func aSalvageWithNothingToTranscribeNeedsNoEngine() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p", in: "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty && h.presented.value.map(\.lastPathComponent) == ["p.json"])
    }

    /// L review 180: rows are deduplicated by SESSION, never by their text: two sessions whose rows read the same are both
    /// said.
    @Test func twoSessionsWithTheSameRowAreBothSaid() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try pendingSession(h, "sess", in: "a", startedAt: began), b = try pendingSession(h, "sess", in: "b", startedAt: began)
        try RecordingSentinel.writePending([a, b], directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.count == 2)
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("2 earlier recordings were recovered"), "\(row)")
    }
}

// MARK: - The transcript's writes off the main actor (185)

@MainActor
@Suite struct RecordingCoordinatorFinalizeWritesRoundDTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 185: the transcript's writes — the record, its marker, the format file, the progress file's delete — run on
    /// the folder's queue, bounded, never on the main actor. A folder that stops answering while the transcript is written
    /// leaves the UI responsive ("Finishing…"), and the outcome is honest: no success claimed, no evidence committed, the
    /// session kept pending. When the write lands later, the next pass says the recording was finished after all.
    @Test func aTranscriptWriteThatHangsKeepsTheUIAndTheSession() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        let mic = call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
        let hung = HungRead("transcript: write")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-d-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderWriteDeadline = .seconds(1)
        h.coordinator.folderReadDeadline = .milliseconds(300)
        let coordinator = h.coordinator
        let began = ContinuousClock.now
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { hung.reached }
        #expect(hung.reached, "the transcript's write runs on the folder's queue")
        #expect(h.appState.phase == .transcribing(progress: "Finishing…"), "\(h.appState.phase)")
        // The main actor is free while the write hangs: a main-actor ticker runs on time.
        let tickerBegan = ContinuousClock.now
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ContinuousClock.now - tickerBegan < .milliseconds(500), "the UI stays responsive")
        await stopping.value
        #expect(ContinuousClock.now - began < .seconds(4), "bounded")
        #expect(h.appState.isIdle)
        #expect(h.presented.value.isEmpty && h.client.commitCalls.isEmpty, "no transcript claimed, no evidence committed")
        let body = try #require(h.criticals.value.last?.body)
        #expect(body.contains("isn’t answering") && !body.contains("transcribed"), "\(body)")
        let kept = try #require(RecordingSentinel.readPending(directory: h.tmp).first, "kept pending")
        #expect(kept.stopCause == .folderNotAnswering)
        // The folder answers: the write lands after all — and the next pass says so, once, never silently.
        hung.release()
        let transcript = call.outputDirectory.appendingPathComponent(call.sessionId + ".json")
        await Harness.until { FileManager.default.fileExists(atPath: transcript.path) }
        await Harness.until { !FileManager.default.fileExists(atPath: call.outputDirectory.appendingPathComponent("\(call.sessionId).session.json").path) }
        h.appState.acknowledge(.recordingStopped)
        await h.coordinator.retryPendingSessions()
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "done")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains(transcript.lastPathComponent) && row.contains("once the folder answered"), "\(row)")
    }
}
