import Foundation
import Testing
@testable import TranscriberCore

/// L review 123: every blocking read of a recording folder runs on ONE dedicated serial queue behind a continuation
/// and a deadline — never on the Swift cooperative pool, whose few threads (8 on the M1 Air) hung reads of a dead
/// network share would use up, stalling every deadline in the app.
@Suite struct FolderReadsTests {
    private final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var ran = 0
        var runs: Int { lock.withLock { ran } }
        func hang() { lock.withLock { ran += 1 }; semaphore.wait() }
        func release(_ n: Int) { for _ in 0..<n { semaphore.signal() } }
    }

    @Test func twentyHungReadsNeverStarveTheCooperativePool() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)")
        let gate = Gate()
        defer { gate.release(40) }   // unwedge the queue whatever happens
        let began = ContinuousClock.now
        await withTaskGroup(of: Int?.self) { group in
            for i in 0..<20 {
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
        #expect(gate.runs == 1, "one read at a time: only the first ever started")
    }

    /// At most one read per folder is outstanding: a second read of a folder whose earlier read has not answered is
    /// not queued behind it (coalesced) — it answers nothing at once.
    @Test func aFolderWithAnUnansweredReadGetsNoSecondOne() async throws {
        let reads = FolderReads(label: "folder-reads-test-\(UUID().uuidString)")
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
