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
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.live.jsonl").path))
        var ring = CaptureDiagnostics()
        ring.record(retry(at: 1))
        ring.record(retry(at: 2))
        let merged = log.merged(into: ring)
        #expect(merged.events.count == 2, "the event both on disk and in the ring is one event")
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
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }

    @Test func aCorruptLineIsSkippedAndTheRestSurvive() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let log = LiveDiagnosticsLog(directory: d, sessionId: "s")
        log.append(retry(at: 1))
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
}
