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
