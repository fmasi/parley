import Foundation
import Testing
@testable import TranscriberCore

/// #358: the recording's name can be seen and changed while it records. The change waits for the transcript and is
/// applied by `SessionRenamer` — the one rename routine the post-call rename dialog uses (#357) — so nothing on the capture
/// path changes. Synthetic temp folders only.
@Suite struct PendingSessionNameTests {

    @Test func theNameOfASessionKeyIsWhatFollowsItsTimestamp() {
        #expect(PendingSessionName.name(ofSessionKey: "/r/2026-11-16/093000-weekly sync") == "weekly sync")
        #expect(PendingSessionName.name(ofSessionKey: "/r/2026-11-16/093000") == "")
        #expect(PendingSessionName.name(ofSessionKey: "/r/2026-11-16/093000-a-b") == "a-b")
    }

    @Test func aTypedNameIsOneTrimmedLine() {
        #expect(PendingSessionName.normalized("  Weekly\nsync \n") == "Weekly sync")
        #expect(PendingSessionName.normalized(" \n ") == "")
    }

    /// A calendar title that arrives after a one-click start names the recording — unless the user already did.
    @Test func aLateCalendarTitleNeverReplacesTheUsersName() {
        let key = "/r/d/093000-zoom call"
        let adopted = PendingSessionName.adoptingCalendarTitle("  Weekly sync\n", sessionKey: key, current: nil)
        #expect(adopted == PendingSessionName(sessionKey: key, name: "Weekly sync", origin: .calendar))
        let typed = PendingSessionName(sessionKey: key, name: "Mine", origin: .user)
        #expect(PendingSessionName.adoptingCalendarTitle("Weekly sync", sessionKey: key, current: typed) == nil)
        #expect(PendingSessionName.adoptingCalendarTitle("   ", sessionKey: key, current: nil) == nil)
        // A name typed for an EARLIER recording is not this one's.
        let earlier = PendingSessionName(sessionKey: "/r/d/080000-old", name: "Old", origin: .user)
        #expect(PendingSessionName.adoptingCalendarTitle("Weekly sync", sessionKey: key, current: earlier)?.name == "Weekly sync")
    }
}

@MainActor
@Suite struct RecordingSessionNameCoordinatorTests {

    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// A recording started as `name`, its first chunk on disk; the helper's stop answers with it.
    private func start(_ h: Harness, as name: String = "Zoom call") async throws -> URL {
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        await h.coordinator.startRecording(sessionName: name, microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys,
                                         micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        return call.outputDirectory
    }

    @Test func theRecordingsNameIsShownWhileItRecordsAndNotOtherwise() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        #expect(h.coordinator.recordingSessionName == nil, "nothing is recording")
        #expect(!h.coordinator.renameRecordingInProgress(to: "x"), "no recording to rename")
        _ = try await start(h)
        #expect(h.coordinator.recordingSessionName == "Zoom call")
        #expect(h.coordinator.renameRecordingInProgress(to: " Weekly\nsync "))
        #expect(h.coordinator.recordingSessionName == "Weekly sync")
        #expect(h.coordinator.recordingSessionNameIsPending)
        #expect(h.coordinator.renameRecordingInProgress(to: "Zoom call"))
        #expect(!h.coordinator.recordingSessionNameIsPending, "back to the name the files already carry")
    }

    /// The point of #358: a name changed mid-recording is what the finished files carry — the transcript, its archive,
    /// its marker — and what the completion notice and the rename dialog are handed.
    @Test func aNameChangedWhileRecordingIsAppliedOnceTheTranscriptIsWritten() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = try await start(h)
        #expect(h.coordinator.renameRecordingInProgress(to: "Weekly sync"))

        await h.coordinator.stopRecording()

        let presented = try #require(h.presented.value.first)
        #expect(presented.lastPathComponent.hasSuffix("-Weekly sync.json"), "\(presented.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: presented.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.contains("Zoom call") }, "no file keeps the old name: \(names)")
        #expect(h.appState.lastJsonPath == presented.path)
        #expect(h.notified.value.last?.body.hasPrefix(presented.lastPathComponent) == true, "\(h.notified.value)")
        #expect(h.coordinator.unappliedSessionName(forTranscript: presented) == nil)
        #expect(h.appState.isIdle)
    }

    @Test func withoutAnEditTheNameIsTheOneItStartedWith() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await start(h)
        await h.coordinator.stopRecording()
        let presented = try #require(h.presented.value.first)
        #expect(presented.lastPathComponent.hasSuffix("-Zoom call.json"))
    }

    /// A one-click start whose calendar lookup landed late: the title names the recording, and a name the user typed
    /// first is never replaced by it.
    @Test func aLateCalendarTitleNamesTheRecordingUnlessTheUserAlreadyDid() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await start(h)
        let key = try #require(h.coordinator.recordingSessionKey)
        #expect(h.coordinator.adoptLateCalendarTitle("Weekly sync", forSession: key))
        #expect(h.coordinator.recordingSessionName == "Weekly sync")
        #expect(h.coordinator.renameRecordingInProgress(to: "Mine"))
        #expect(!h.coordinator.adoptLateCalendarTitle("Other", forSession: key))
        #expect(!h.coordinator.adoptLateCalendarTitle("Other", forSession: "/elsewhere/093000-x"), "never another recording's")
        #expect(h.coordinator.recordingSessionName == "Mine")
    }

    /// The rename refused (a recording of that name is already in the folder): the transcript keeps its name, nothing is
    /// half-renamed, and the rename dialog starts from the chosen name — so a Save applies it, once.
    @Test func aNameThatCannotBeAppliedIsHandedToTheRenameDialog() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = try await start(h)
        let stamp = String(try #require(h.client.startCalls.first).baseName.prefix(6))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("\(stamp)-Weekly sync.json"))   // the name is taken
        #expect(h.coordinator.renameRecordingInProgress(to: "Weekly sync"))

        await h.coordinator.stopRecording()

        let presented = try #require(h.presented.value.first)
        #expect(presented.lastPathComponent == "\(stamp)-Zoom call.json")
        #expect(FileManager.default.fileExists(atPath: presented.path))
        #expect(h.coordinator.unappliedSessionName(forTranscript: presented) == "Weekly sync")
        #expect(h.coordinator.unappliedSessionName(forTranscript: presented) == nil, "handed over once")
    }

    /// A name typed for one recording never reaches the next.
    @Test func aNewRecordingStartsWithoutTheLastOnesName() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await start(h)
        #expect(h.coordinator.renameRecordingInProgress(to: "Weekly sync"))
        await h.coordinator.stopRecording()
        h.client.startCalls = []
        _ = try await start(h, as: "Teams call")
        #expect(h.coordinator.recordingSessionName == "Teams call")
        #expect(!h.coordinator.recordingSessionNameIsPending)
    }

    /// The finish applies only the recording's own name: one chosen for another session is dropped, never applied.
    @Test func aPendingNameOfAnotherSessionIsNotApplied() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("101500-done.json")
        try Data(#"{"metadata":{},"segments":[]}"#.utf8).write(to: transcript)
        h.coordinator.pendingSessionName = PendingSessionName(sessionKey: dir.appendingPathComponent("093000-x").path,
                                                              name: "Weekly sync", origin: .user)
        let result = await h.coordinator.applyPendingSessionName(to: TranscriptionResult(jsonPath: transcript))
        #expect(result.jsonPath == transcript)
        #expect(FileManager.default.fileExists(atPath: transcript.path))
        #expect(h.coordinator.pendingSessionName == nil)
    }

    // MARK: - The finish's waits and bounds (review of #358)

    /// A finished session in a folder of its own, with a pending name for it: what the finish hands `applyPendingSessionName`.
    private func finished(_ h: Harness, id: String = "101500-zoom call") throws -> (folder: URL, transcript: URL) {
        let dir = h.tmp.appendingPathComponent("d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: ["metadata": ["audio_files": ["\(id)-0.m4a"]], "segments": []]).write(to: transcript)
        try Data(count: 64).write(to: dir.appendingPathComponent("\(id)-0.m4a"))
        h.coordinator.pendingSessionName = PendingSessionName(sessionKey: dir.appendingPathComponent(id).path,
                                                              name: "weekly sync", origin: .user)
        return (dir, transcript)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// The quota pass protects the session's archives by their OLD names: until it has run, nothing is renamed — the name
    /// goes to the rename dialog — and the completion notice is not made to wait for it a second time.
    @Test func aQuotaPassThatHasNotRunKeepsTheFilesAndHandsTheNameOver() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let (folder, transcript) = try finished(h)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        let result = await h.coordinator.applyPendingSessionName(to: TranscriptionResult(jsonPath: transcript, quotaPass: QuotaOutcome()))
        #expect(result.jsonPath == transcript)
        #expect(result.quotaPass == nil, "waited for once")
        #expect(names(in: folder) == ["101500-zoom call.json", "101500-zoom call-0.m4a"])
        #expect(h.coordinator.unappliedSessionName(forTranscript: transcript) == "weekly sync")
    }

    /// The live log's delete is queued by session id: until it has run, nothing is renamed.
    @Test func aLiveLogFlushThatDoesNotAnswerKeepsTheFilesAndHandsTheNameOver() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let (folder, transcript) = try finished(h)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        h.client.onFlush = { try? await Task.sleep(for: .seconds(2)) }
        let result = await h.coordinator.applyPendingSessionName(to: TranscriptionResult(jsonPath: transcript))
        #expect(result.jsonPath == transcript)
        #expect(names(in: folder) == ["101500-zoom call.json", "101500-zoom call-0.m4a"])
        #expect(h.coordinator.unappliedSessionName(forTranscript: transcript) == "weekly sync")
    }

    /// The folder does not answer before the rename could start: it is abandoned and never runs later — a rename landing
    /// after the app showed the old path would break the notice, the dialog and the summary. The name goes to the dialog.
    @Test func aRenameThatHadNotStartedByItsBoundNeverRuns() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let (folder, transcript) = try finished(h)
        let gate = DispatchSemaphore(value: 0)
        h.coordinator.folderReads = FolderReads(label: "rename-abandon-\(UUID().uuidString)", beforeEachRead: { label in
            if label == "finish: session rename" { gate.wait() }
        })
        h.coordinator.folderWriteDeadline = .milliseconds(200)
        let result = await h.coordinator.applyPendingSessionName(to: TranscriptionResult(jsonPath: transcript))
        #expect(result.jsonPath == transcript)
        #expect(h.coordinator.unappliedSessionName(forTranscript: transcript) == "weekly sync")
        gate.signal()   // the folder answers: the queued rename gets its turn, and must do nothing
        await Harness.settle(0.3)
        #expect(names(in: folder) == ["101500-zoom call.json", "101500-zoom call-0.m4a"], "never renamed late")
    }

    /// The rename had started when its bound ran out: it runs on, and the finish shows the transcript where it is now.
    @Test func aRenameAlreadyUnderWayAtItsBoundShowsTheTranscriptWhereItIs() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let (folder, transcript) = try finished(h)
        let fs = HangingReplaceFileSystem()
        h.coordinator.sessionRenameFileSystem = fs
        // Long enough for the rename to START on a loaded machine (then it hangs): the bound must find it under way.
        h.coordinator.folderWriteDeadline = .milliseconds(1500)
        let result = await h.coordinator.applyPendingSessionName(to: TranscriptionResult(jsonPath: transcript))
        #expect(fs.reachedReplace, "the rename was under way when its bound ran out")
        #expect(result.jsonPath == folder.appendingPathComponent("101500-weekly sync.json"), "the files had moved: the new path")
        #expect(h.coordinator.unappliedSessionName(forTranscript: transcript) == nil)
        fs.release()
        await Harness.until { self.names(in: folder) == ["101500-weekly sync.json", "101500-weekly sync-0.m4a"] }
        #expect(names(in: folder) == ["101500-weekly sync.json", "101500-weekly sync-0.m4a"])
    }

    /// Renamed only once the stopping recovery file is gone: a death between the two would otherwise send the next launch
    /// after the old names.
    @Test func theSessionIsRenamedOnlyOnceItsRecoveryFileIsGone() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await start(h)
        #expect(h.coordinator.renameRecordingInProgress(to: "weekly sync"))
        let dir = h.tmp
        let slotAtPresent = Harness.Box<Bool?>(nil)
        h.onPresent.value = { _ in slotAtPresent.value = RecordingSentinel.read(directory: dir) != nil }
        await h.coordinator.stopRecording()
        #expect(h.presented.value.first?.lastPathComponent.hasSuffix("-weekly sync.json") == true)
        #expect(slotAtPresent.value == false, "the recovery file was deleted before the rename and the presentation")
    }

    /// A recording that ends through a salvage, not its Stop's finish (the stop failed): never renamed there — never under
    /// the recovery gate — and the name goes to the rename dialog, never silently dropped.
    @Test func aSalvagedRecordingHandsItsNameToTheDialog() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        h.runner.enginesForTesting = (FakeEngine(), nil)
        let folder = try await start(h)
        #expect(h.coordinator.renameRecordingInProgress(to: "weekly sync"))
        h.client.stopError = FakeCaptureError()
        await h.coordinator.stopRecording()
        let transcripts = names(in: folder).filter { $0.hasSuffix(".json") && SessionRenamer.sessionId(ofTranscript: URL(fileURLWithPath: $0)) != nil }
        let written = try #require(transcripts.first, "the salvage wrote a transcript: \(names(in: folder))")
        #expect(written.hasSuffix("-Zoom call.json"), "never renamed by the salvage")
        #expect(h.coordinator.unappliedSessionName(forTranscript: folder.appendingPathComponent(written)) == "weekly sync")
        #expect(h.coordinator.pendingSessionName == nil)
    }

    /// A transcript a recovery presents (not this Stop's finish) for the recording with a pending name: handed to the dialog.
    @Test func aRecoveredTranscriptOfTheSessionHandsItsNameToTheDialog() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let (_, transcript) = try finished(h)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: transcript))
        #expect(h.presented.value == [transcript])
        #expect(h.coordinator.pendingSessionName == nil)
        #expect(h.coordinator.unappliedSessionName(forTranscript: transcript) == "weekly sync")
    }
}

/// Moves files, then hangs on the first content rewrite until released: a rename under way when its bound runs out.
final class HangingReplaceFileSystem: SessionRenameFileSystem, @unchecked Sendable {
    private let live = LiveSessionRenameFileSystem()
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reached = false
    var reachedReplace: Bool { lock.withLock { reached } }
    func release() { gate.signal() }
    func list(_ folder: URL) -> [String]? { live.list(folder) }
    func sessionIdsWithState(in folder: URL) -> Set<String>? { live.sessionIdsWithState(in: folder) }
    func exists(_ url: URL) -> Bool { live.exists(url) }
    func sameFile(_ a: URL, _ b: URL) -> Bool { live.sameFile(a, b) }
    func read(_ url: URL) -> Data? { live.read(url) }
    func move(_ from: URL, to: URL, sameFile: Bool) throws { try live.move(from, to: to, sameFile: sameFile) }
    func replace(_ url: URL, with data: Data) throws {
        lock.withLock { reached = true }
        gate.wait()
        gate.signal()   // open from now on: only the first rewrite hangs
        try live.replace(url, with: data)
    }
}
