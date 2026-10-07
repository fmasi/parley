import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    /// `degraded` (#308): every content anomaly on the side was a rate drift the helper healed within
    /// `RateDriftWindow.healedBoundSeconds` — a few seconds at the wrong rate, the rest captured correctly.
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, degraded, compromised }

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
    /// The value sums measured sessions with unmeasured ones (a tap session and an SCK one): it is
    /// a lower bound, and the record says so (R2b item 8).
    public var exactZeroIsLowerBound = false
    public var heartbeatCallbacksIsLowerBound = false
    /// The helper's stop timed out sealing the capture: its counts are the last tick's (≤ 1 s stale), so every
    /// value is a lower bound (final review R-M1) — never stamped as exact. A sum with one such session is one too.
    public var coverageIncomplete = false

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case expectedSeconds, heartbeatCallbacks, deliveredSeconds, exactZeroSeconds, paddedSeconds,
             longestGapSeconds, gapCount, rebuilds, exactZeroIsLowerBound, heartbeatCallbacksIsLowerBound, coverageIncomplete
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedSeconds, forKey: .expectedSeconds)
        try c.encodeIfPresent(heartbeatCallbacks, forKey: .heartbeatCallbacks)
        try c.encode(deliveredSeconds, forKey: .deliveredSeconds)
        try c.encodeIfPresent(exactZeroSeconds, forKey: .exactZeroSeconds)
        try c.encode(paddedSeconds, forKey: .paddedSeconds)
        try c.encode(longestGapSeconds, forKey: .longestGapSeconds)
        try c.encode(gapCount, forKey: .gapCount)
        try c.encode(rebuilds, forKey: .rebuilds)
        if exactZeroIsLowerBound { try c.encode(true, forKey: .exactZeroIsLowerBound) }
        if heartbeatCallbacksIsLowerBound { try c.encode(true, forKey: .heartbeatCallbacksIsLowerBound) }
        if coverageIncomplete { try c.encode(true, forKey: .coverageIncomplete) }
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
        exactZeroIsLowerBound = try c.decodeIfPresent(Bool.self, forKey: .exactZeroIsLowerBound) ?? false
        heartbeatCallbacksIsLowerBound = try c.decodeIfPresent(Bool.self, forKey: .heartbeatCallbacksIsLowerBound) ?? false
        coverageIncomplete = try c.decodeIfPresent(Bool.self, forKey: .coverageIncomplete) ?? false
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
    ///
    /// `healedDrifts` (#308): how many of `contentAnomalies` are rate drifts that healed within the bound
    /// (`RateDriftWindow.isShortAndHealed`). When they are ALL of them, the side is `.degraded`, not `.compromised` —
    /// after every other rule, so a deficit still makes it compromised and nothing makes it healthy.
    public func status(isTap: Bool, contentAnomalies: Int, healedDrifts: Int = 0) -> Status {
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 1, deliveredSeconds == 0 { return .neverDelivered }
        if contentAnomalies > healedDrifts { return .compromised }
        if contentAnomalies == 0, isTap, expectedSeconds < 1, let zeros = exactZeroSeconds, deliveredSeconds - zeros < 1 { return .idle }
        let deficit = expectedSeconds - deliveredSeconds
        if expectedSeconds > 0, deficit >= Self.minimumDeficitSeconds, deficit / expectedSeconds >= Self.deficitRatio {
            return .compromised
        }
        return contentAnomalies > 0 ? .degraded : .healthy
    }

    /// Unmeasured plus unmeasured stays unmeasured; a measured value plus an unmeasured one keeps
    /// the measurement, marked as a lower bound (never an invented number, never a claimed total).
    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting) {
        lhs.expectedSeconds += rhs.expectedSeconds
        lhs.heartbeatCallbacksIsLowerBound = lhs.heartbeatCallbacksIsLowerBound || rhs.heartbeatCallbacksIsLowerBound
            || (lhs.heartbeatCallbacks == nil) != (rhs.heartbeatCallbacks == nil)
        lhs.heartbeatCallbacks = sum(lhs.heartbeatCallbacks, rhs.heartbeatCallbacks)
        lhs.deliveredSeconds += rhs.deliveredSeconds
        lhs.exactZeroIsLowerBound = lhs.exactZeroIsLowerBound || rhs.exactZeroIsLowerBound
            || (lhs.exactZeroSeconds == nil) != (rhs.exactZeroSeconds == nil)
        lhs.exactZeroSeconds = sum(lhs.exactZeroSeconds, rhs.exactZeroSeconds)
        lhs.paddedSeconds += rhs.paddedSeconds
        lhs.longestGapSeconds = max(lhs.longestGapSeconds, rhs.longestGapSeconds)
        lhs.gapCount += rhs.gapCount
        lhs.rebuilds += rhs.rebuilds
        lhs.coverageIncomplete = lhs.coverageIncomplete || rhs.coverageIncomplete
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
            ("exact_zero_seconds_is_lower_bound", exactZeroIsLowerBound ? "1" : nil),
            ("heartbeat_callbacks_is_lower_bound", heartbeatCallbacksIsLowerBound ? "1" : nil),
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
        exactZeroIsLowerBound = detail["\(prefix)_exact_zero_seconds_is_lower_bound"] == "1"
        heartbeatCallbacksIsLowerBound = detail["\(prefix)_heartbeat_callbacks_is_lower_bound"] == "1"
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
        // The stop's own mark, for both sides: NOT prefixed (`AudioCaptureService`'s timed-out seal, R-M1).
        coverageIncomplete = detail["coverage_incomplete"] == "true"
    }

    /// `metadata.capture.<side>`. An unmeasured value is left out, never written as 0.
    public func asMetadataDictionary(status: Status) -> [String: Any] {
        var d: [String: Any] = [
            "status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
            "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds, "gap_count": gapCount, "rebuilds": rebuilds,
        ]
        if let exactZeroSeconds { d["exact_zero_seconds"] = exactZeroSeconds }
        if let heartbeatCallbacks { d["heartbeat_callbacks"] = heartbeatCallbacks }
        if exactZeroIsLowerBound { d["exact_zero_seconds_is_lower_bound"] = true }
        if heartbeatCallbacksIsLowerBound { d["heartbeat_callbacks_is_lower_bound"] = true }
        if coverageIncomplete { d["coverage_incomplete"] = true }
        return d
    }
}

/// One rate drift on the tap (#308): the output device changed rate under it, so audio was captured at the wrong
/// rate from the drift's onset until the helper's rebuild delivered its first frames. Built by
/// `CaptureDiagnostics.makeProvenance` from the `rateDrift`, its `restartInPlace` ("rate drift remediation") and the
/// next system `firstFrames`; stamped under `metadata.capture.remote.rate_drift`.
public struct RateDriftWindow: Codable, Equatable, Sendable {
    /// Seconds from capture start to the detection; nil when no `captureStart` was seen.
    public var detectedOffsetSeconds: Double?
    /// How long before the detection the drift can have begun, at the earliest (the helper's
    /// `onset_within_seconds`); nil = onset unknown (the event carries no measurement, e.g. a drift found at
    /// setup, or one from an older helper).
    public var onsetWithinSeconds: Double?
    /// Seconds from the detection to the remediation rebuild's first frames; nil = never healed.
    public var healedAfterSeconds: Double?

    /// The longest wrong-rate window that still reads `degraded` rather than `compromised`: the same 15 s the record
    /// already tolerates as a coverage shortfall (`TrackAccounting.minimumDeficitSeconds`). A side may lose up to that
    /// much audio and stay healthy; a heal that corrupted no more than that is a blemish to state, not a side to
    /// distrust. The real 0.9.0 case (#308) measured a ~5 s window, a ~3 s rebuild and at most ~3 s before it: ~11 s.
    public static let healedBoundSeconds: Double = TrackAccounting.minimumDeficitSeconds

    public init(detectedOffsetSeconds: Double? = nil, onsetWithinSeconds: Double? = nil, healedAfterSeconds: Double? = nil) {
        self.detectedOffsetSeconds = detectedOffsetSeconds
        self.onsetWithinSeconds = onsetWithinSeconds
        self.healedAfterSeconds = healedAfterSeconds
    }

    /// At most this many seconds were captured at the wrong rate; nil when the onset is unknown or it never healed.
    public var affectedSeconds: Double? {
        guard let onsetWithinSeconds, let healedAfterSeconds else { return nil }
        return onsetWithinSeconds + healedAfterSeconds
    }

    /// Healed, with a known onset, inside the bound. Anything else keeps the side `compromised`.
    public var isShortAndHealed: Bool { affectedSeconds.map { $0 <= Self.healedBoundSeconds } ?? false }

    private enum CodingKeys: String, CodingKey {
        case detectedOffsetSeconds = "detected_offset_seconds"
        case onsetWithinSeconds = "onset_within_seconds"
        case healedAfterSeconds = "healed_after_seconds"
    }

    /// One entry of `metadata.capture.remote.rate_drift`. `offset_seconds` is where the wrong-rate window starts
    /// (the earliest onset), `affected_seconds` its length at most; an unknown onset says so instead.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = ["healed": healedAfterSeconds != nil]
        if let detectedOffsetSeconds { d["detected_offset_seconds"] = Self.tenths(detectedOffsetSeconds) }
        if let onsetWithinSeconds {
            if let detectedOffsetSeconds { d["offset_seconds"] = Self.tenths(max(0, detectedOffsetSeconds - onsetWithinSeconds)) }
        } else {
            d["onset"] = "unknown"
        }
        if let healedAfterSeconds { d["healed_after_seconds"] = Self.tenths(healedAfterSeconds) }
        if let affectedSeconds {
            d["affected_seconds"] = Self.tenths(affectedSeconds)
            d["affected_seconds_is_upper_bound"] = true
        }
        return d
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
