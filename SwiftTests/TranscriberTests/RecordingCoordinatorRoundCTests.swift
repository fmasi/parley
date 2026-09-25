import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round C (items 139–168): the coordinator's side. The fake client and the harness are
// RecordingCoordinatorTests.swift's.

/// A read queue whose read named `label` hangs until released (or a watchdog does it, so a regression fails instead
/// of wedging the run).
final class HungRead: @unchecked Sendable {
    let label: String
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var began = false
    var reached: Bool { lock.withLock { began } }
    init(_ label: String) { self.label = label }
    func hangIfNamed(_ name: String) {
        guard name == label else { return }
        lock.withLock { began = true }
        _ = semaphore.wait(timeout: .now() + 10)   // the watchdog: never a wedged run
    }
    func release() { semaphore.signal() }
}

// MARK: - Folder reads per volume, coalescing (160, 164)

@MainActor
@Suite struct RecordingCoordinatorVolumeTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 160: a read hung on one volume (a dead share) never makes a Start refuse a HEALTHY folder on another.
    @Test func aHungVolumeNeverRefusesAStartOnAnother() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let hung = HungRead("dead share")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-c-\(UUID().uuidString)",
                                                volumeOf: { $0.hasPrefix("/Volumes/Dead") ? "/Volumes/Dead" : "/" },
                                                beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderReadDeadline = .milliseconds(300)
        let reads = h.coordinator.folderReads
        let deadRead = Task { await reads.read("dead share", folder: "/Volumes/Dead/rec", seconds: 5) { 0 } }
        await Harness.until { hung.reached }
        await h.coordinator.startRecording(sessionName: "healthy", microphoneDeviceId: nil)
        #expect(h.appState.isRecording && h.client.startCalls.count == 1, "\(String(describing: h.appState.errorMessage))")
        hung.release()
        _ = await deadRead.value
    }

    /// L review 164: a pending folder whose read is coalesced — an earlier read of it has not answered YET — is "no
    /// answer yet": the folder alarm is left as it was, never raised as "not reachable".
    @Test func aCoalescedPendingFolderReadLeavesTheAlarmAlone() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: folder.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: folder.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let hung = HungRead("earlier read")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let reads = h.coordinator.folderReads
        let earlier = Task { await reads.read("earlier read", folder: folder.path, seconds: 5) { 0 } }
        await Harness.until { hung.reached }
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] == nil, "no answer yet is not \"unreachable\"")
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "still pending")
        hung.release()
        _ = await earlier.value
    }
}
