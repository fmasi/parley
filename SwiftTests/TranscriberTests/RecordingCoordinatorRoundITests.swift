import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round I (items 269–272). The fake client and the harness are RecordingCoordinatorTests.swift's;
// `roundFPendingSession`, `roundFTearDown` and `FakeSpeechInventory` are RecordingCoordinatorRoundFTests.swift's; `NotReadyEngine`
// is RecordingCoordinatorRoundDTests.swift's; `LookingSpeechInventory` is RecordingCoordinatorRoundHTests.swift's.

// MARK: - The Quit's keep follows the whole stop attempt (269)

@MainActor
@Suite struct QuitKeepFollowsTheStopAttemptRoundITests {
    private func saidHeld(_ h: Harness) -> Bool {
        h.notified.value.contains { $0.body.contains("A previous recording is still being stopped; Parley will finish it next time") }
    }

    /// L review 269, IMPORTANT: a Quit whose Stop the helper keeps refusing ("another stop is under way") — its bound runs
    /// out between two asks, while nothing is being asked — still keeps the LaunchAgent: the helper has not let go of the
    /// recording from the start of the attempt until it does, or until the hold is written.
    @Test func aQuitWhoseStopIsRefusedThroughoutKeepsTheLaunchAgent() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.stopError = RefusedStoppingError()   // every ask: another stop is under way
        h.coordinator.stopDeadline = .seconds(1)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        h.coordinator.quitStopBound = .milliseconds(200)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(h.coordinator.keepsLaunchAgentOnQuit, "the helper had not let go")
        #expect(saidHeld(h), "\(h.notified.value)")
        await Harness.until(within: 5) { h.appState.isIdle }   // the Stop ends on its own: held
    }

    /// L review 269: an IDLE Quit — nothing to ask — while a relaunch is between two asks of a helper that keeps refusing its
    /// stop keeps the LaunchAgent: that session's helper has not let go.
    @Test func anIdleQuitDuringARelaunchsRefusalLoopKeepsTheLaunchAgent() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.captureStateResult = .unknown   // the ping does not answer: the relaunch stops the helper first
        h.client.stopError = RefusedStoppingError()
        h.coordinator.helperStopDeadline = .seconds(1)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        let coordinator = h.coordinator
        let launch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { h.client.stopCalls >= 1 }
        #expect(await coordinator.prepareForQuit(confirm: { Issue.record("an idle Quit asks nothing"); return false }))
        #expect(coordinator.keepsLaunchAgentOnQuit, "the relaunch's helper had not let go")
        #expect(saidHeld(h), "\(h.notified.value)")
        await launch.value
    }

    /// … while a Quit whose Stop the helper answered keeps none — the attempt ended when it let go.
    @Test func aQuitWhoseStopWasAnsweredKeepsNone() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.quitStopBound = .milliseconds(200)
        h.runner.finalizeDelayForTesting = .seconds(1)   // the helper let go; the transcript outlasts the Quit's bound
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(!h.coordinator.keepsLaunchAgentOnQuit)
        await Harness.until(within: 5) { h.appState.isIdle }
    }
}

// MARK: - Honest engine wording (270)

#if compiler(>=6.2)
@MainActor
@Suite struct SpeechAnalyzerWordingRoundITests {
    /// L review 270: a model that is not installed is said "not installed" — or, when this Mac does not support its locale,
    /// "not supported on this Mac" — the supported locales looked at only then.
    @Test func aMissingModelIsWordedByWhetherThisMacSupportsIt() async throws {
        guard #available(macOS 26.0, *) else { return }
        let path = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).wav")
        do {
            _ = try await SpeechAnalyzerEngine(language: "en", inventory: FakeSpeechInventory(supported: ["en-US"])).transcribe(audioPath: path)
            Issue.record("transcribed without a model")
        } catch SpeechAnalyzerError.assetNotInstalled(let locale) {
            #expect(locale == "en-US")
        }
        do {
            _ = try await SpeechAnalyzerEngine(language: "ja", inventory: FakeSpeechInventory(supported: ["en-US"])).transcribe(audioPath: path)
            Issue.record("transcribed without a model")
        } catch SpeechAnalyzerError.localeNotSupported(let locale) {
            #expect(locale == "ja-JP")
        }
        let installed = LookingSpeechInventory(installed: ["en-US"])
        _ = try? await SpeechAnalyzerEngine(language: "en", inventory: installed).transcribe(audioPath: path)
        #expect(installed.supportedLooks == 0, "installed: no other look")
        let unsupported = await SpeechAnalyzerEngine(language: "ja", inventory: FakeSpeechInventory(supported: ["en-US"])).notReadyReason()
        #expect(unsupported.contains("not supported on this Mac") && !unsupported.contains("not installed"), "\(unsupported)")
        let missing = await SpeechAnalyzerEngine(language: "en", inventory: FakeSpeechInventory(supported: ["en-US"])).notReadyReason()
        #expect(missing.contains("not installed"), "\(missing)")
    }

    /// L review 270: a readiness look that did not answer in time says just that — Parley couldn't check the speech model
    /// yet, and will check again — never "choose another engine", which nothing showed.
    @Test func aReadinessLookThatTimedOutIsSaidHonestly() async throws {
        guard #available(macOS 26.0, *) else { return }
        let h = try Harness()
        h.config.update { $0.engine = .speechAnalyzer }
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = SpeechAnalyzerEngine(language: "en", inventory: LookingSpeechInventory(installed: ["en-US"], hangs: true))
        h.coordinator.engineReadyDeadline = .milliseconds(300)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("couldn’t check the speech model yet") && row.contains("check again"), "\(row)")
        #expect(!row.contains("choose another engine") && !row.contains("isn’t ready"), "\(row)")
    }
}
#endif

// MARK: - Rows never repeat a sentence (271, 272)

@MainActor
@Suite struct RowsNeverRepeatRoundITests {
    /// L review 271 (261): a pass's row added to one still up adds only the sentences that row does not say yet — never the
    /// same sentence twice. A row raised whole keeps every part (L review 180: two sessions whose rows read the same).
    @Test func anAddedPassRepeatsNoSentence() {
        var registry = CaptureAlarmRegistry()
        registry.raise(.recordingStopped, message: "Held A.", now: Date())
        let added = registry.raise(.recordingStopped, parts: ["Held A.", "Stopped B."], now: Date())
        #expect(added && registry.alarms[.recordingStopped]?.message == "Held A. Stopped B.")
        let again = registry.raise(.recordingStopped, parts: ["Held A.", "Stopped B."], now: Date())
        #expect(!again && registry.alarms[.recordingStopped]?.message == "Held A. Stopped B.", "nothing new")
        var fresh = CaptureAlarmRegistry()
        fresh.raise(.recordingStopped, parts: ["Same.", "Same."], now: Date())
        #expect(fresh.alarms[.recordingStopped]?.message == "Same. Same.", "a row raised whole keeps each session's")
    }

    /// L review 272 (255, 261): a session said to wait for its engine, then recovered once the engine is ready — its "waiting
    /// for the engine" sentence is REPLACED by what the salvage wrote, never left beside it.
    @Test func aRecoveredSessionsWaitingSentenceIsReplaced() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingStopped]?.message.contains("isn’t ready") == true)
        h.engine.value = FakeEngine()   // a model download finished
        await h.coordinator.transcriptionEngineMayBeReady()
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "recovered")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("p.json") && !row.contains("isn’t ready"), "the waiting sentence is replaced: \(row)")
    }
}
