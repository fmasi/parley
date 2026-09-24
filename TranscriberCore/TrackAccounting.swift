import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }

    public var expectedSeconds: Double = 0
    public var heartbeatCallbacks: Int = 0
    public var deliveredSeconds: Double = 0
    public var exactZeroSeconds: Double = 0
    public var paddedSeconds: Double = 0
    public var longestGapSeconds: Double = 0
    public var gapCount: Int = 0
    public var rebuilds: Int = 0

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    /// `contentAnomalies` is the count of CONTENT-compromising events on this track (rate drift,
    /// exact-zero mic, permission denied, converter failure, write failure, sustained format drop) —
    /// never healed liveness events (scan C12); `makeProvenance` (E1) computes it.
    ///
    /// Precedence (review fix 1): `.neverDelivered` is checked BEFORE the content-anomaly check, so a
    /// track that delivered nothing never reads as merely `.compromised` — R1 must not print "partly
    /// captured (0 s delivered…)" for a side that captured nothing at all.
    ///
    /// Threshold (review fix 2, controller ruling): below 1 s expected, the existing startup window
    /// still applies (tap `.idle`, mic `.healthy`) — a session that short is just short. At or above
    /// 1 s, 0 delivered is `.neverDelivered` on BOTH tracks: "never healthy when nothing was captured
    /// while audio was expected". The old 5 s debounce belongs to the live alarm, not to this
    /// after-the-fact record.
    public func status(isTap: Bool, contentAnomalies: Int) -> Status {
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 1, deliveredSeconds == 0 { return .neverDelivered }
        if contentAnomalies > 0 { return .compromised }
        let deficit = expectedSeconds - deliveredSeconds
        if expectedSeconds > 0, deficit >= Self.minimumDeficitSeconds, deficit / expectedSeconds >= Self.deficitRatio {
            return .compromised
        }
        return .healthy
    }

    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting) {
        lhs.expectedSeconds += rhs.expectedSeconds
        lhs.heartbeatCallbacks += rhs.heartbeatCallbacks
        lhs.deliveredSeconds += rhs.deliveredSeconds
        lhs.exactZeroSeconds += rhs.exactZeroSeconds
        lhs.paddedSeconds += rhs.paddedSeconds
        lhs.longestGapSeconds = max(lhs.longestGapSeconds, rhs.longestGapSeconds)
        lhs.gapCount += rhs.gapCount
        lhs.rebuilds += rhs.rebuilds
    }

    private static let keys = ["expected_seconds", "heartbeat_callbacks", "delivered_seconds", "exact_zero_seconds",
                               "padded_seconds", "longest_gap_seconds", "gap_count", "rebuilds"]

    public func asDetail(prefix: String) -> [String: String] {
        let values: [String] = [String(format: "%.1f", expectedSeconds), "\(heartbeatCallbacks)", String(format: "%.1f", deliveredSeconds),
                                String(format: "%.1f", exactZeroSeconds), String(format: "%.1f", paddedSeconds),
                                String(format: "%.1f", longestGapSeconds), "\(gapCount)", "\(rebuilds)"]
        return Dictionary(uniqueKeysWithValues: zip(Self.keys.map { "\(prefix)_\($0)" }, values))
    }

    /// Review fix 3 (controller ruling: crash risk): rejects a non-finite value (`nan`/`inf`) on any
    /// Double field. Letting one through to `asMetadataDictionary` and then `JSONSerialization`
    /// raises an uncatchable ObjC exception — reject it here instead, at the parse boundary.
    public init?(detail: [String: String], prefix: String) {
        guard let expectedRaw = detail["\(prefix)_expected_seconds"], let e = Double(expectedRaw), e.isFinite else { return nil }
        expectedSeconds = e

        func finiteOrDefault(_ suffix: String, _ def: Double) -> Double? {
            guard let raw = detail["\(prefix)_\(suffix)"] else { return def }
            guard let d = Double(raw) else { return def }
            return d.isFinite ? d : nil
        }
        guard let delivered = finiteOrDefault("delivered_seconds", 0) else { return nil }
        deliveredSeconds = delivered
        guard let exactZero = finiteOrDefault("exact_zero_seconds", 0) else { return nil }
        exactZeroSeconds = exactZero
        guard let padded = finiteOrDefault("padded_seconds", 0) else { return nil }
        paddedSeconds = padded
        guard let longestGap = finiteOrDefault("longest_gap_seconds", 0) else { return nil }
        longestGapSeconds = longestGap

        heartbeatCallbacks = detail["\(prefix)_heartbeat_callbacks"].flatMap(Int.init) ?? 0
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
    }

    public func asMetadataDictionary(status: Status) -> [String: Any] {
        ["status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
         "exact_zero_seconds": exactZeroSeconds, "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds,
         "gap_count": gapCount, "rebuilds": rebuilds, "heartbeat_callbacks": heartbeatCallbacks]
    }
}
