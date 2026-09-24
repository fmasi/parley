import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }

    public var expectedSeconds: Double = 0
    /// nil = not measured (SCK counts no tap callbacks) — never a claimed 0.
    public var heartbeatCallbacks: Int?
    public var deliveredSeconds: Double = 0
    /// nil = not measured (SCK has no exact-zero guard) — never a claimed 0.
    public var exactZeroSeconds: Double?
    public var paddedSeconds: Double = 0
    public var longestGapSeconds: Double = 0
    public var gapCount: Int = 0
    public var rebuilds: Int = 0

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case expectedSeconds, heartbeatCallbacks, deliveredSeconds, exactZeroSeconds, paddedSeconds,
             longestGapSeconds, gapCount, rebuilds
    }

    /// Tolerant (C-M7): session.json persists this inside the provenance, and synthesized Decodable
    /// required every key — a field added later made an older session.json undecodable, and an
    /// undecodable session is dropped by recovery. Every key is optional here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expectedSeconds = try c.decodeIfPresent(Double.self, forKey: .expectedSeconds) ?? 0
        heartbeatCallbacks = try c.decodeIfPresent(Int.self, forKey: .heartbeatCallbacks)
        deliveredSeconds = try c.decodeIfPresent(Double.self, forKey: .deliveredSeconds) ?? 0
        exactZeroSeconds = try c.decodeIfPresent(Double.self, forKey: .exactZeroSeconds)
        paddedSeconds = try c.decodeIfPresent(Double.self, forKey: .paddedSeconds) ?? 0
        longestGapSeconds = try c.decodeIfPresent(Double.self, forKey: .longestGapSeconds) ?? 0
        gapCount = try c.decodeIfPresent(Int.self, forKey: .gapCount) ?? 0
        rebuilds = try c.decodeIfPresent(Int.self, forKey: .rebuilds) ?? 0
    }

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
    ///
    /// C-M12: a tap that was never expected (nothing played on this Mac) and delivered only exact
    /// digital zeros is `idle` too, not `healthy` — after the content-anomaly check, so a permission
    /// denial is never hidden. Unmeasured zeros (SCK) can't show that, so they never make it idle.
    public func status(isTap: Bool, contentAnomalies: Int) -> Status {
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 1, deliveredSeconds == 0 { return .neverDelivered }
        if contentAnomalies > 0 { return .compromised }
        if isTap, expectedSeconds < 1, let zeros = exactZeroSeconds, deliveredSeconds - zeros < 1 { return .idle }
        let deficit = expectedSeconds - deliveredSeconds
        if expectedSeconds > 0, deficit >= Self.minimumDeficitSeconds, deficit / expectedSeconds >= Self.deficitRatio {
            return .compromised
        }
        return .healthy
    }

    /// Unmeasured plus unmeasured stays unmeasured; a measured value plus an unmeasured one keeps
    /// the measurement (a lower bound, never an invented number).
    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting) {
        lhs.expectedSeconds += rhs.expectedSeconds
        lhs.heartbeatCallbacks = sum(lhs.heartbeatCallbacks, rhs.heartbeatCallbacks)
        lhs.deliveredSeconds += rhs.deliveredSeconds
        lhs.exactZeroSeconds = sum(lhs.exactZeroSeconds, rhs.exactZeroSeconds)
        lhs.paddedSeconds += rhs.paddedSeconds
        lhs.longestGapSeconds = max(lhs.longestGapSeconds, rhs.longestGapSeconds)
        lhs.gapCount += rhs.gapCount
        lhs.rebuilds += rhs.rebuilds
    }

    private static func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): return a + b
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Detail keys for a `trackCoverage` / `captureStop` event. An unmeasured value is left out.
    public func asDetail(prefix: String) -> [String: String] {
        let values: [(String, String?)] = [
            ("expected_seconds", String(format: "%.1f", expectedSeconds)),
            ("heartbeat_callbacks", heartbeatCallbacks.map { "\($0)" }),
            ("delivered_seconds", String(format: "%.1f", deliveredSeconds)),
            ("exact_zero_seconds", exactZeroSeconds.map { String(format: "%.1f", $0) }),
            ("padded_seconds", String(format: "%.1f", paddedSeconds)),
            ("longest_gap_seconds", String(format: "%.1f", longestGapSeconds)),
            ("gap_count", "\(gapCount)"),
            ("rebuilds", "\(rebuilds)"),
        ]
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in value.map { ("\(prefix)_\(key)", $0) } })
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
        // Absent = not measured (the helper omits it on SCK): nil, never a measured 0 (XI bug 1).
        if detail["\(prefix)_exact_zero_seconds"] != nil {
            guard let exactZero = finiteOrDefault("exact_zero_seconds", 0) else { return nil }
            exactZeroSeconds = exactZero
        }
        guard let padded = finiteOrDefault("padded_seconds", 0) else { return nil }
        paddedSeconds = padded
        guard let longestGap = finiteOrDefault("longest_gap_seconds", 0) else { return nil }
        longestGapSeconds = longestGap

        heartbeatCallbacks = detail["\(prefix)_heartbeat_callbacks"].flatMap(Int.init)
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
    }

    /// `metadata.capture.<side>`. An unmeasured value is left out, never written as 0.
    public func asMetadataDictionary(status: Status) -> [String: Any] {
        var d: [String: Any] = [
            "status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
            "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds, "gap_count": gapCount, "rebuilds": rebuilds,
        ]
        if let exactZeroSeconds { d["exact_zero_seconds"] = exactZeroSeconds }
        if let heartbeatCallbacks { d["heartbeat_callbacks"] = heartbeatCallbacks }
        return d
    }
}
