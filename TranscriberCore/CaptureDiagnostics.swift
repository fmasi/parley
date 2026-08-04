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
    /// The MID-RECORDING system (remote) stream could not be restarted within budget — the remote side
    /// stopped being captured even though the mic kept recording (#86). Severity `.anomaly`.
    case systemAudioUnrecovered
    /// The output device changed sample rate underneath the tap (Bluetooth A2DP -> HFP is NOT a
    /// device change, so no output-switch listener fires). The IOProc keeps delivering against a
    /// stale format: fewer frames arrive than the declared rate implies, the writer pads silence to
    /// hold the wall clock, and the remote audio comes out 2x-fast with gaps — correct duration,
    /// corrupt content. The stream is still RUNNING, so this is not a stop error. Severity `.anomaly`.
    case rateDrift

    /// Too much of a written track is silence we FABRICATED rather than captured. The timeline padder
    /// inserts silence so samples land at their true wall-clock position; when a device under-delivers,
    /// that same mechanism quietly makes up the shortfall and turns a detectably-short file into an
    /// undetectably-corrupt one of exactly the right length. Padding only ever responds to delivery
    /// deficit — never to quiet audio, which still arrives as buffers of zeros — so a high ratio means
    /// frames genuinely went missing, whatever the cause. This is the mechanism-independent backstop
    /// for the whole silent-divergence class (#58). Severity `.anomaly`.
    case excessivePadding

    /// A sustained run of system buffers rejected by the sticky format gate — the system track has
    /// stopped being written while the stream still appears to run. Distinct from the transient
    /// `formatChanged` so the two can be told apart when judging whether a recording is compromised.
    case sustainedFormatDrop
}

extension CaptureEventKind {
    /// The kinds that mean THE RECORDING'S CONTENT may be wrong — as opposed to something happening
    /// and being handled.
    ///
    /// `anomalyCount` cannot answer that question: `.streamStopError` is recorded as an anomaly for
    /// what its own call site calls "a benign audio-route change (e.g. AirPods HFP↔A2DP)", and since
    /// opening the mic is what triggers that flip, it fires on essentially EVERY recording made on
    /// the default source with Bluetooth headphones — then the #86 restart recovers it completely.
    /// Labelling those recordings "capture anomalies" would make the warning meaningless within a
    /// week, which is worse than not warning at all: the point of the label is that it is rare.
    ///
    /// So the user-facing quality signal counts only the kinds that survive recovery.
    public static let qualityCompromising: Set<CaptureEventKind> = [
        .excessivePadding,
        .rateDrift,
        .sustainedFormatDrop,
        .systemAudioUnrecovered,
        .restartFailed,
    ]
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
    /// Subset of `anomalyCount` that indicates compromised CONTENT rather than a handled event.
    /// The user-facing "capture anomalies" label reads this, so that a routine Bluetooth route
    /// change — which is recorded as an anomaly and fully recovered — does not brand every
    /// recording as suspect.
    public let qualityAnomalyCount: Int
    /// True when the MID-RECORDING system (remote) stream could not be restarted within budget during
    /// the session — the remote side stopped being captured even though the mic kept recording (#86).
    public let systemAudioUnrecovered: Bool

    enum CodingKeys: String, CodingKey {
        case engine
        case systemFormat = "system_format"
        case micFormat = "mic_format"
        case micDevice = "mic_device"
        case routeChanges = "route_changes"
        case retries
        case recovered
        case anomalyCount = "anomaly_count"
        case qualityAnomalyCount = "quality_anomaly_count"
        case systemAudioUnrecovered = "system_audio_unrecovered"
    }

    public init(
        engine: String,
        systemFormat: String?,
        micFormat: String?,
        micDevice: String?,
        routeChanges: Int,
        retries: Int,
        recovered: Bool,
        anomalyCount: Int,
        qualityAnomalyCount: Int = 0,
        systemAudioUnrecovered: Bool = false
    ) {
        self.engine = engine
        self.systemFormat = systemFormat
        self.micFormat = micFormat
        self.micDevice = micDevice
        self.routeChanges = routeChanges
        self.retries = retries
        self.recovered = recovered
        self.anomalyCount = anomalyCount
        self.qualityAnomalyCount = qualityAnomalyCount
        self.systemAudioUnrecovered = systemAudioUnrecovered
    }

    /// Build the snake_case dictionary embedded in transcript metadata under `capture_provenance`.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "engine": engine,
            "route_changes": routeChanges,
            "retries": retries,
            "recovered": recovered,
            "anomaly_count": anomalyCount,
            "quality_anomaly_count": qualityAnomalyCount,
            "system_audio_unrecovered": systemAudioUnrecovered,
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
    /// Count handled benign route changes via the in-place restart they each trigger. (The pinned
    /// 48kHz/mono system tap never emits `.formatChanged`, so counting that would always read 0 for
    /// the AirPods HFP↔A2DP scenario this exists to surface — council F5.)
    public var routeChangeCount: Int { events.lazy.filter { $0.kind == .restartInPlace }.count }
    public var retryCount: Int { events.lazy.filter { $0.kind == .retry }.count }
    public var didRecover: Bool { events.contains { $0.kind == .launchRecovery } }
    public var anomalyCount: Int { events.lazy.filter { $0.severity == .anomaly }.count }
    /// Anomalies that mean the CONTENT may be wrong, as opposed to something that happened and was
    /// handled. This is what the user-facing quality notice reads — see `qualityCompromising`.
    public var qualityAnomalyCount: Int {
        events.lazy.filter { CaptureEventKind.qualityCompromising.contains($0.kind) }.count
    }
    /// True when the mid-recording system stream was declared unrecoverable during the session (#86).
    public var systemAudioUnrecovered: Bool { events.contains { $0.kind == .systemAudioUnrecovered } }

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
            anomalyCount: anomalyCount,
            qualityAnomalyCount: qualityAnomalyCount,
            systemAudioUnrecovered: systemAudioUnrecovered
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

    /// Empty the ring (per-session reset at the start of capture, #101) so a skipped finalize (crash)
    /// can't carry the previous session's events into the next one.
    public func clear() {
        lock.withLock { $0.clear() }
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
