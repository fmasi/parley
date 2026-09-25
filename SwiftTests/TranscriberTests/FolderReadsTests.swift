import Foundation
import Testing
@testable import TranscriberCore

/// L review 123: every blocking read of a recording folder runs on a dedicated serial queue behind a continuation and a
/// deadline — never on the Swift cooperative pool, whose few threads (8 on the M1 Air) hung reads of a dead network share
/// would use up, stalling every deadline in the app. L review 160: one such queue per volume.
@Suite struct FolderReadsTests {
    private final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var ran = 0
        var runs: Int { lock.withLock { ran } }
        func hang() { lock.withLock { ran += 1 }; semaphore.wait() }
        func release(_ n: Int) { for _ in 0..<n { semaphore.signal() } }
    }

    /// A regression must FAIL, never wedge the run (L review 165): off the cooperative pool, after `seconds`, it
    /// releases every hung read and says it had to.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false
        var fired: Bool { lock.withLock { didFire } }
        init(after seconds: Double, releasing gate: Gate, count: Int) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                lock.withLock { didFire = true }
                gate.release(count)
            }
        }
    }

    /// More hung reads than the pool has threads (L review 165: `activeProcessorCount + 4`): were they on the pool, it
    /// would starve.
    private static let hungReads = ProcessInfo.processInfo.activeProcessorCount + 4

    @Test func moreHungReadsThanThreadsNeverStarveTheCooperativePool() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)", volumeOf: { _ in "/Volumes/Dead" })
        let gate = Gate(), n = Self.hungReads
        defer { gate.release(2 * n) }   // unwedge the queue whatever happens
        let watchdog = Watchdog(after: 10, releasing: gate, count: 2 * n)
        let began = ContinuousClock.now
        await withTaskGroup(of: Int?.self) { group in
            for i in 0..<n {
                group.addTask { await reads.read("hung \(i)", folder: "/Volumes/Dead/\(i)", seconds: 0.3) { gate.hang(); return i } }
            }
            // Meanwhile, an unrelated deadline must still fire on time: the pool is free.
            let deadlineFired: Bool
            do {
                _ = try await withDeadline(seconds: 0.1, label: "unrelated") { try await Task.sleep(for: .seconds(10)); return 0 }
                deadlineFired = false
            } catch {
                deadlineFired = true
            }
            #expect(deadlineFired && ContinuousClock.now - began < .milliseconds(900), "the deadline fired on time")
            for await answer in group { #expect(answer == nil, "a hung read answers nothing at its deadline") }
        }
        #expect(ContinuousClock.now - began < .seconds(2), "every hung read ended at its own deadline")
        #expect(gate.runs == 1, "one read at a time per volume: only the first ever started")
        #expect(!watchdog.fired, "the watchdog never had to unwedge the run")
    }

    /// L review 160: one serial queue PER VOLUME. A read hung on volume A never delays a read of volume B.
    @Test func aHungVolumeNeverDelaysAnotherVolume() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)",
                                volumeOf: { $0.hasPrefix("/Volumes/A") ? "/Volumes/A" : "/" })
        let gate = Gate()
        defer { gate.release(4) }
        let watchdog = Watchdog(after: 10, releasing: gate, count: 4)
        let hung = Task { await reads.read("hung", folder: "/Volumes/A/rec", seconds: 5) { gate.hang(); return 0 } }
        while gate.runs == 0, !watchdog.fired { try await Task.sleep(for: .milliseconds(5)) }
        let began = ContinuousClock.now
        let healthy = await reads.read("healthy", folder: "/Users/me/rec", seconds: 2) { 1 }
        #expect(healthy == 1 && ContinuousClock.now - began < .milliseconds(500), "the other volume answers at once")
        gate.release(1)
        _ = await hung.value
        #expect(!watchdog.fired)
    }

    /// L review 164: a read never asked — an earlier read of its key is still out, within its deadline — is "no answer
    /// yet", told apart from a read that timed out. Once that earlier read is overdue, the folder is not answering.
    @Test func aCoalescedReadIsBusyNotTimedOut() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)", volumeOf: { _ in "/" })
        let gate = Gate()
        defer { gate.release(4) }
        let first = Task { await reads.outcome("first", folder: "/x", seconds: 0.2) { gate.hang(); return 1 } }
        while gate.runs == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = await reads.outcome("second", folder: "/x", seconds: 5) { 2 }
        guard case .busy = second else { Issue.record("a coalesced read is busy: \(second)"); return }
        guard case .timedOut = await first.value else { Issue.record("the hung read timed out"); return }
        // Once that read is past its own deadline, the folder is known not to answer: a coalesced read says so.
        let third = await reads.outcome("third", folder: "/x", seconds: 5) { 3 }
        guard case .timedOut = third else { Issue.record("a folder whose read is overdue is not answering: \(third)"); return }
        // Another key on the same folder is its own read: asked (and queued behind the hung one, on its volume).
        let other = await reads.outcome("other", folder: "/x", key: "/x#evidence", seconds: 0.1) { 3 }
        guard case .timedOut = other else { Issue.record("a read under another key is asked: \(other)"); return }
    }

    /// The volume is found lexically, from the mount table: a link on a local volume is followed; nothing on a share is
    /// read; a link cycle is "unknown".
    @Test func theVolumeIsFoundWithoutTouchingAShare() {
        let mounts: [FolderReads.Mount] = [.init(path: "/", isLocal: true), .init(path: "/System/Volumes/Data", isLocal: true),
                                           .init(path: "/Volumes/NAS", isLocal: false), .init(path: "/Volumes/Ext", isLocal: true)]
        let links = ["/Users/me/Recordings": "/Volumes/NAS/rec", "/Users/me/Local": "/Volumes/Ext/rec", "/loop": "/loop"]
        var readOnShare = false
        func readLink(_ path: String) -> String? {
            if path.hasPrefix("/Volumes/NAS/") { readOnShare = true }
            return links[path]
        }
        #expect(FolderReads.volume(of: "/Users/me/Recordings/2026-09-25", mounts: mounts, readLink: readLink) == "/Volumes/NAS")
        #expect(FolderReads.volume(of: "/Users/me/Local/2026-09-25", mounts: mounts, readLink: readLink) == "/Volumes/Ext")
        #expect(FolderReads.volume(of: "/Volumes/NAS/a/b", mounts: mounts, readLink: readLink) == "/Volumes/NAS")
        #expect(FolderReads.volume(of: "/Users/me/elsewhere", mounts: mounts, readLink: readLink) == "/")
        #expect(FolderReads.volume(of: "/Volumes/Gone/x", mounts: mounts, readLink: readLink) == "/", "an unmounted volume is a ghost on the boot volume")
        #expect(FolderReads.volume(of: "/loop/x", mounts: mounts, readLink: readLink) == "unknown")
        #expect(FolderReads.volume(of: "/x", mounts: [], readLink: readLink) == "unknown")
        #expect(!readOnShare, "nothing on the share is read")
        // The real mount table: the temporary folder is on a mounted local volume.
        #expect(FolderReads.volume(of: NSTemporaryDirectory()) != "unknown")
    }

    /// At most one read per folder is outstanding: a second read of a folder whose earlier read has not answered is
    /// not queued behind it (coalesced) — it answers nothing at once.
    @Test func aFolderWithAnUnansweredReadGetsNoSecondOne() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)", volumeOf: { _ in "/Volumes/Dead" })
        let gate = Gate()
        defer { gate.release(4) }
        let first = Task { await reads.read("first", folder: "/Volumes/Dead", seconds: 0.2) { gate.hang(); return 1 } }
        while gate.runs == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let began = ContinuousClock.now
        let second = await reads.read("second", folder: "/Volumes/Dead", seconds: 5) { 2 }
        #expect(second == nil && ContinuousClock.now - began < .milliseconds(100))
        #expect(await first.value == nil)
        gate.release(1)
        // Once the hung read finally returns, the folder is read again.
        var answer: Int?
        for _ in 0..<100 where answer == nil {
            answer = await reads.read("later", folder: "/Volumes/Dead", seconds: 1) { 3 }
            if answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(answer == 3)
    }

    @Test func aReadThatAnswersInTimeIsReturned() async {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)")
        #expect(await reads.read("quick", folder: "/tmp", seconds: 1) { Thread.isMainThread ? -1 : 7 } == 7)
    }
}
