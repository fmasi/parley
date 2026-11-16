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
}
