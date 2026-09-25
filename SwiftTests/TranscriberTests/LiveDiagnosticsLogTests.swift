import Foundation
import Testing
@testable import TranscriberCore

/// L4/L14 (§8.11): the diagnostics ring is in memory and is lost with the process. Anomalies are
/// appended to disk as they happen, and finalize merges the file back without duplicates.
@Suite struct LiveDiagnosticsLogTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func retry(at seconds: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSince1970: seconds), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"])
    }

    @Test func appendsAnomaliesAsTheyHappenAndMergesWithoutDuplicates() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        log.flush()
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
        var ring = CaptureDiagnostics()
        ring.record(retry(at: 1))
        ring.record(retry(at: 2))
        let merged = log.merged(into: ring)
        #expect(merged.events.count == 2, "the event both on disk and in the ring is one event")
    }

    /// L review 96: live-log writes are queued (item 65); an exit flushes every queued write of every log.
    @Test func flushAllWaitsForEveryQueuedWrite() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        let release = DispatchSemaphore(value: 0)
        log.writeObserver = { release.wait() }   // the write queue is held until the flush is under way
        log.append(retry(at: 1))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { release.signal() }
        LiveDiagnosticsLog.flushAll()
        let onDisk = try String(contentsOf: d.appendingPathComponent("s.diag.live.jsonl"), encoding: .utf8)
        #expect(onDisk.contains("retry"))
    }

    /// L review 102: two coverage writes racing never leave the OLDER map on disk: each write is queued inside the
    /// lock that built its map, so the queue writes them in the order they were built.
    @Test func concurrentCoverageWritesLeaveTheNewestMapOnDisk() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        for round in 0..<20 {
            let log = LiveDiagnosticsLog(directory: d, sessionId: "s\(round)")
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<16 {
                    group.addTask { log.writeCoverage(helperSession: "h\(i % 4)", facts: ["n": "\(i)"], at: Date(timeIntervalSince1970: Double(i))) }
                }
            }
            log.flush()
            let cached = log.coverageSnapshots()
            let onDisk = LiveDiagnosticsLog(directory: d, sessionId: "s\(round)").coverageSnapshots()
            #expect(onDisk == cached, "round \(round): the file holds the last map built")
        }
    }

    @Test func aSubSecondTimestampDedupsAcrossDiskAndRing() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        let event = CaptureEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 811_968_756.916193),
            origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"]
        )
        log.append(event)
        var ring = CaptureDiagnostics()
        ring.record(event)
        let merged = log.merged(into: ring)
        #expect(merged.events.count == 1, "the same sub-second anomaly recorded to both the ring and disk is one event, not two")
    }

    @Test func informationalEventsAreNotWritten() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(CaptureEvent(timestamp: Date(), origin: .app, kind: .captureStart, severity: .info))
        log.flush()
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }

    /// L11 ruling: coverage evidence is `.info`, and dropping it lost every pre-crash second of coverage.
    /// `captureStop` and `trackCoverage` are written whatever their severity.
    @Test func coverageEvidenceIsWrittenWhateverItsSeverity() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .helper, kind: .captureStop, severity: .info,
                                detail: ["remote_expected_seconds": "60.0"]))
        log.append(CaptureEvent(timestamp: Date(timeIntervalSince1970: 2), origin: .helper, kind: .trackCoverage, severity: .info,
                                detail: ["remote_expected_seconds": "30.0"]))
        #expect(log.events().map(\.kind) == [.captureStop, .trackCoverage])
    }

    /// Council A-I4 / C-I1: the latest coverage of each helper session is kept beside the live log — one
    /// entry per helper session, the newest wins — and goes with it on delete.
    @Test func coverageSnapshotsKeepTheLatestPerHelperSession() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.writeCoverage(helperSession: "1000-0", facts: ["remote_expected_seconds": "10.0"], at: Date(timeIntervalSince1970: 10))
        log.writeCoverage(helperSession: "1000-0", facts: ["remote_expected_seconds": "20.0"], at: Date(timeIntervalSince1970: 15))
        log.writeCoverage(helperSession: "2000-0", facts: ["remote_expected_seconds": "5.0"], at: Date(timeIntervalSince1970: 20))
        log.flush()
        let snapshots = LiveDiagnosticsLog(directory: d, sessionId: "s").coverageSnapshots()   // a later process reads it
        #expect(snapshots["1000-0"]?.facts["remote_expected_seconds"] == "20.0")
        #expect(snapshots["1000-0"]?.at == Date(timeIntervalSince1970: 15))
        #expect(snapshots["2000-0"]?.facts["remote_expected_seconds"] == "5.0")
        log.delete()
        #expect(LiveDiagnosticsLog(directory: d, sessionId: "s").coverageSnapshots().isEmpty)
    }

    @Test func aCorruptLineIsSkippedAndTheRestSurvive() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        log.flush()
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{not json\n".utf8)); try handle.close()
        log.append(retry(at: 3))
        #expect(log.events().map(\.timestamp.timeIntervalSince1970) == [1, 3])
    }

    @Test func deleteRemovesTheFile() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
        log.delete()
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }

    /// E2 fix round 1 item 1: an event evicted from the bounded ring is still on disk, so a naive
    /// merge at finalize re-presents it as "extra" and double-counts it (retries) and re-evicts it
    /// (events_dropped). Counting must be idempotent per event, not per merge.
    @Test func mergeAfterEvictionDoesNotDoubleCountRetriesOrDrops() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        var ring = CaptureDiagnostics(maxEvents: 3)
        let r = retry(at: 0)
        ring.record(r)
        log.append(r)
        for i in 1...5 {
            let e = CaptureEvent(timestamp: Date(timeIntervalSince1970: TimeInterval(i)), origin: .app, kind: .restartInPlace, severity: .warning)
            ring.record(e)
            log.append(e)
        }
        #expect(ring.events.count == 3 && ring.droppedCount == 3 && ring.retryCount == 1)

        let merged = log.merged(into: ring)
        #expect(merged.retryCount == 1, "the retry evicted from the ring must not be recounted from disk")
        let p = merged.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.eventsDropped == 3, "re-evicting the same events at merge must not inflate the drop count")
    }

    /// L11 review 65: the live log's file writes run on its own serial queue, never on the caller's thread —
    /// the app appends and pulls coverage on the main actor every 5 s. Reads still see every write before them.
    @MainActor
    @Test func writesRunOffTheCallersThreadAndReadsSeeThem() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        final class Seen: @unchecked Sendable { var onMain: [Bool] = [] }
        let seen = Seen()
        log.writeObserver = { seen.onMain.append(Thread.isMainThread) }
        log.append(retry(at: 1))
        log.writeCoverage(helperSession: "1000-0", facts: ["remote_expected_seconds": "10.0"], at: Date(timeIntervalSince1970: 1))
        #expect(log.events().map(\.timestamp.timeIntervalSince1970) == [1], "a read waits for the writes before it")
        #expect(LiveDiagnosticsLog(directory: d, sessionId: "s").coverageSnapshots()["1000-0"] != nil)
        #expect(seen.onMain == [false, false])
    }
}
