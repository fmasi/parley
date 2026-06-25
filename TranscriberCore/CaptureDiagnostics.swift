import Foundation
import os

// MARK: - Event model

/// The kind of a capture event. Anomaly kinds (stream errors, format changes, XPC
/// interruptions, retries, recovery) are what gate the on-disk diagnostic flush (#95).
public enum CaptureEventKind: String, Codable, Sendable {
    case captureStart
    case captureStop
    case systemFormatDetected
    case micFormatDetected
    case formatChanged
    case streamStopError
    case restartInPlace
    case restartFailed
    case micSwitch
    case xpcInterruption
    case xpcInvalidation
    case retry
    case launchRecovery
}

/// One structured capture event for the anomaly-gated diagnostic log.
public struct CaptureEvent: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case app, helper }
    public enum Severity: String, Codable, Sendable { case info, warning, anomaly }

    public let timestamp: Date
    public let origin: Origin
    public let kind: CaptureEventKind
    public let severity: Severity
    public let detail: [String: String]

    public init(
        timestamp: Date,
        origin: Origin,
        kind: CaptureEventKind,
        severity: Severity,
        detail: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.origin = origin
        self.kind = kind
        self.severity = severity
        self.detail = detail
    }
}

// MARK: - Provenance stamp

/// Compact provenance stamp embedded in every transcript (clean run or not) — ~200 bytes.
public struct CaptureProvenance: Codable, Equatable, Sendable {
    public let engine: String
    public let systemFormat: String?
    public let micFormat: String?
    public let micDevice: String?
    public let routeChanges: Int
    public let retries: Int
    public let recovered: Bool
    public let anomalyCount: Int

    enum CodingKeys: String, CodingKey {
        case engine
        case systemFormat = "system_format"
        case micFormat = "mic_format"
        case micDevice = "mic_device"
        case routeChanges = "route_changes"
        case retries
        case recovered
        case anomalyCount = "anomaly_count"
    }

    public init(
        engine: String,
        systemFormat: String?,
        micFormat: String?,
        micDevice: String?,
        routeChanges: Int,
        retries: Int,
        recovered: Bool,
        anomalyCount: Int
    ) {
        self.engine = engine
        self.systemFormat = systemFormat
        self.micFormat = micFormat
        self.micDevice = micDevice
        self.routeChanges = routeChanges
        self.retries = retries
        self.recovered = recovered
        self.anomalyCount = anomalyCount
    }

    /// Build the snake_case dictionary embedded in transcript metadata under `capture_provenance`.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "engine": engine,
            "route_changes": routeChanges,
            "retries": retries,
            "recovered": recovered,
            "anomaly_count": anomalyCount,
        ]
        if let systemFormat { d["system_format"] = systemFormat }
        if let micFormat { d["mic_format"] = micFormat }
        if let micDevice { d["mic_device"] = micDevice }
        return d
    }
}

// MARK: - Bounded ring

/// A bounded, in-memory ring of capture events. Costs nothing on a clean run (only a
/// provenance stamp is persisted); on an anomaly the ring is flushed to `<session>.diag.jsonl`.
/// Eviction drops the oldest events once either the event-count or byte cap is exceeded (#95).
public struct CaptureDiagnostics: Sendable {
    public private(set) var events: [CaptureEvent] = []
    public private(set) var droppedCount: Int = 0
    public let maxEvents: Int
    public let maxBytes: Int

    private var byteCosts: [Int] = []
    private var totalBytes: Int = 0

    public init(maxEvents: Int = 5000, maxBytes: Int = 1_000_000) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encode(_ event: CaptureEvent) -> Data {
        (try? makeEncoder().encode(event)) ?? Data()
    }

    public mutating func record(_ event: CaptureEvent) {
        let cost = Self.encode(event).count + 1  // + newline
        events.append(event)
        byteCosts.append(cost)
        totalBytes += cost
        evict()
    }

    private mutating func evict() {
        while events.count > maxEvents || (totalBytes > maxBytes && events.count > 1) {
            totalBytes -= byteCosts.removeFirst()
            events.removeFirst()
            droppedCount += 1
        }
    }

    /// Empty the ring (after a drain to the app side).
    public mutating func clear() {
        events.removeAll()
        byteCosts.removeAll()
        totalBytes = 0
        droppedCount = 0
    }

    /// Merge events drained from another ring (e.g. the helper), keeping the result time-sorted.
    public mutating func merge(_ other: [CaptureEvent]) {
        let combined = (events + other).sorted { $0.timestamp < $1.timestamp }
        clear()
        for event in combined { record(event) }
    }

    public var isAnomalous: Bool { events.contains { $0.severity == .anomaly } }
    public var routeChangeCount: Int { events.lazy.filter { $0.kind == .formatChanged }.count }
    public var retryCount: Int { events.lazy.filter { $0.kind == .retry }.count }
    public var didRecover: Bool { events.contains { $0.kind == .launchRecovery } }
    public var anomalyCount: Int { events.lazy.filter { $0.severity == .anomaly }.count }

    /// Newline-delimited JSON of all events (the `.diag.jsonl` payload).
    public func jsonlData() -> Data {
        var out = Data()
        for event in events {
            out.append(Self.encode(event))
            out.append(0x0A)
        }
        return out
    }

    /// Encode the ring's events for transport across XPC (helper → app).
    public func snapshotData() -> Data {
        (try? Self.makeEncoder().encode(events)) ?? Data()
    }

    /// Decode events transported across XPC. Returns `[]` on any failure (fail-soft).
    public static func events(from data: Data) -> [CaptureEvent] {
        (try? makeDecoder().decode([CaptureEvent].self, from: data)) ?? []
    }

    public func makeProvenance(
        engine: String,
        systemFormat: String?,
        micFormat: String?,
        micDevice: String?
    ) -> CaptureProvenance {
        CaptureProvenance(
            engine: engine,
            systemFormat: systemFormat,
            micFormat: micFormat,
            micDevice: micDevice,
            routeChanges: routeChangeCount,
            retries: retryCount,
            recovered: didRecover,
            anomalyCount: anomalyCount
        )
    }
}

// MARK: - Thread-safe wrapper (helper side)

/// Thread-safe wrapper around a `CaptureDiagnostics` ring for the XPC helper, where capture
/// callbacks arrive on background queues and the app drains over XPC. App-side code uses the
/// plain struct on the main actor.
public final class LockedDiagnostics: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: CaptureDiagnostics())

    public init() {}

    public func record(_ event: CaptureEvent) {
        lock.withLock { $0.record(event) }
    }

    /// Snapshot the ring for transport and clear it, atomically.
    public func drainData() -> Data {
        lock.withLock {
            let data = $0.snapshotData()
            $0.clear()
            return data
        }
    }
}
