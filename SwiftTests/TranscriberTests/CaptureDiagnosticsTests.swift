import Testing
import Foundation
@testable import TranscriberCore

struct CaptureDiagnosticsTests {
    let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func event(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        at offset: TimeInterval,
        origin: CaptureEvent.Origin = .app
    ) -> CaptureEvent {
        CaptureEvent(timestamp: base.addingTimeInterval(offset), origin: origin, kind: kind, severity: severity)
    }

    @Test func recordsInOrder() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1))
        #expect(d.events.count == 2)
        #expect(d.events.first?.kind == .captureStart)
        #expect(d.events.last?.kind == .formatChanged)
    }

    @Test func eventCapEvictsOldest() {
        var d = CaptureDiagnostics(maxEvents: 3, maxBytes: 1_000_000)
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        #expect(d.events.count == 3)
        #expect(d.droppedCount == 2)
        #expect(d.events.first?.timestamp == base.addingTimeInterval(2))  // oldest two dropped
    }

    @Test func byteCapEvictsToNewest() {
        var d = CaptureDiagnostics(maxEvents: 5000, maxBytes: 10)  // smaller than a single event
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        #expect(d.events.count == 1)            // guard always keeps the newest
        #expect(d.droppedCount == 4)
        #expect(d.events.first?.timestamp == base.addingTimeInterval(4))
    }

    @Test func isAnomalousOnlyWithAnomalyEvent() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.systemFormatDetected, .info, at: 1))
        #expect(d.isAnomalous == false)
        d.record(event(.streamStopError, .anomaly, at: 2))
        #expect(d.isAnomalous == true)
    }

    @Test func countersReflectKinds() {
        var d = CaptureDiagnostics()
        d.record(event(.formatChanged, .anomaly, at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1))
        d.record(event(.retry, .anomaly, at: 2))
        d.record(event(.launchRecovery, .anomaly, at: 3))
        #expect(d.routeChangeCount == 2)
        #expect(d.retryCount == 1)
        #expect(d.didRecover == true)
        #expect(d.anomalyCount == 4)
    }

    @Test func mergeInterleavesByTime() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.captureStop, .info, at: 4))
        d.merge([event(.micSwitch, .info, at: 2, origin: .helper)])
        #expect(d.events.map { $0.timestamp } == [0, 2, 4].map { base.addingTimeInterval($0) })
    }

    @Test func jsonlRoundTrips() throws {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.formatChanged, .anomaly, at: 1, origin: .helper))
        let lines = d.jsonlData().split(separator: 0x0A).map { Data($0) }
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(CaptureEvent.self, from: $0) }
        #expect(decoded == d.events)
    }

    @Test func snapshotRoundTripsAcrossXPC() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.retry, .anomaly, at: 1))
        let restored = CaptureDiagnostics.events(from: d.snapshotData())
        #expect(restored == d.events)
    }

    @Test func cleanRunProvenanceIsZeroed() {
        var d = CaptureDiagnostics()
        d.record(event(.captureStart, .info, at: 0))
        d.record(event(.systemFormatDetected, .info, at: 1))
        let p = d.makeProvenance(engine: "fluid_audio", systemFormat: "48000Hz/1ch", micFormat: "48000Hz/1ch", micDevice: "AirPods")
        #expect(d.isAnomalous == false)
        #expect(p.routeChanges == 0)
        #expect(p.retries == 0)
        #expect(p.recovered == false)
        #expect(p.anomalyCount == 0)
        #expect(p.engine == "fluid_audio")
    }

    @Test func clearResetsRing() {
        var d = CaptureDiagnostics(maxEvents: 2)
        for i in 0..<5 { d.record(event(.captureStart, .info, at: TimeInterval(i))) }
        d.clear()
        #expect(d.events.isEmpty)
        #expect(d.droppedCount == 0)
    }
}

struct CaptureProvenanceTests {
    @Test func encodesSnakeCaseKeysAndRoundTrips() throws {
        let p = CaptureProvenance(
            engine: "fluid_audio", systemFormat: "48000Hz/1ch", micFormat: nil, micDevice: "AirPods",
            routeChanges: 1, retries: 2, recovered: true, anomalyCount: 3
        )
        let data = try JSONEncoder().encode(p)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("route_changes"))
        #expect(str.contains("anomaly_count"))
        #expect(str.contains("mic_device"))
        let back = try JSONDecoder().decode(CaptureProvenance.self, from: data)
        #expect(back == p)
    }

    @Test func metadataDictionaryOmitsNilOptionals() {
        let p = CaptureProvenance(
            engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil,
            routeChanges: 0, retries: 0, recovered: false, anomalyCount: 0
        )
        let dict = p.asMetadataDictionary()
        #expect(dict["system_format"] == nil)
        #expect(dict["mic_device"] == nil)
        #expect(dict["engine"] as? String == "e")
        #expect(dict["route_changes"] as? Int == 0)
    }
}
