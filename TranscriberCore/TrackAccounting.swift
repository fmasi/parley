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
    public func status(isTap: Bool, contentAnomalies: Int) -> Status {
        if contentAnomalies > 0 { return .compromised }
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 5, deliveredSeconds == 0 { return .neverDelivered }
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

    public init?(detail: [String: String], prefix: String) {
        guard let e = detail["\(prefix)_expected_seconds"].flatMap(Double.init) else { return nil }
        expectedSeconds = e
        heartbeatCallbacks = detail["\(prefix)_heartbeat_callbacks"].flatMap(Int.init) ?? 0
        deliveredSeconds = detail["\(prefix)_delivered_seconds"].flatMap(Double.init) ?? 0
        exactZeroSeconds = detail["\(prefix)_exact_zero_seconds"].flatMap(Double.init) ?? 0
        paddedSeconds = detail["\(prefix)_padded_seconds"].flatMap(Double.init) ?? 0
        longestGapSeconds = detail["\(prefix)_longest_gap_seconds"].flatMap(Double.init) ?? 0
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
    }

    public func asMetadataDictionary(status: Status) -> [String: Any] {
        ["status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
         "exact_zero_seconds": exactZeroSeconds, "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds,
         "gap_count": gapCount, "rebuilds": rebuilds, "heartbeat_callbacks": heartbeatCallbacks]
    }
}
