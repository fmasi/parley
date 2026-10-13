import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    /// `degraded` (#308): every content anomaly on the side was a rate drift the helper healed — or the capture stop
    /// ended (#333 R4) — within `RateDriftWindow.healedBoundSeconds`: a few seconds at the wrong rate, the rest
    /// captured correctly.
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, degraded, compromised }

    public var expectedSeconds: Double = 0
    /// nil = not measured (SCK counts no tap callbacks) — never a claimed 0.
    public var heartbeatCallbacks: Int?
    public var deliveredSeconds: Double = 0
    /// nil = not measured (SCK has no exact-zero guard) — never a claimed 0.
    public var exactZeroSeconds: Double?
    /// The part of `exactZeroSeconds` nobody can vouch for (`TapPermissionGuard.unprovenZeroFrames`, #333): the
    /// zeros before the session's first real audio, and every zero run during which a denial or an unconfirmed
    /// rebuild withdrew the proof, from the run's first frame until real audio returned. The rest is silence
    /// on a tap that had delivered real audio, with its grant never in question during it. nil = not measured
    /// (SCK, the mic, a record made before the field existed), never a claimed 0: a reader then judges the
    /// total, as before.
    public var exactZeroUnprovenSeconds: Double?
    public var paddedSeconds: Double = 0
    public var longestGapSeconds: Double = 0
    public var gapCount: Int = 0
    public var rebuilds: Int = 0
    /// The value sums measured sessions with unmeasured ones (a tap session and an SCK one): it is
    /// a lower bound, and the record says so (R2b item 8). One mark for both exact-zero values: it is also
    /// set when only the unproven seconds were unmeasured in one of the sessions.
    public var exactZeroIsLowerBound = false
    public var heartbeatCallbacksIsLowerBound = false
    /// Every value is a lower bound, never stamped as exact: the helper's stop timed out sealing the capture (its
    /// counts are the last tick's, final review R-M1), the counts are a crashed helper's last status pull standing in
    /// for its stop (#295), or the record was built without its folder (#229). A sum with one such session is one too.
    public var coverageIncomplete = false

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case expectedSeconds, heartbeatCallbacks, deliveredSeconds, exactZeroSeconds, exactZeroUnprovenSeconds, paddedSeconds,
             longestGapSeconds, gapCount, rebuilds, exactZeroIsLowerBound, heartbeatCallbacksIsLowerBound, coverageIncomplete
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedSeconds, forKey: .expectedSeconds)
        try c.encodeIfPresent(heartbeatCallbacks, forKey: .heartbeatCallbacks)
        try c.encode(deliveredSeconds, forKey: .deliveredSeconds)
        try c.encodeIfPresent(exactZeroSeconds, forKey: .exactZeroSeconds)
        try c.encodeIfPresent(exactZeroUnprovenSeconds, forKey: .exactZeroUnprovenSeconds)
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
        exactZeroUnprovenSeconds = try c.decodeIfPresent(Double.self, forKey: .exactZeroUnprovenSeconds)
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
    /// `healedDrifts` (#308): how many of `contentAnomalies` are rate drifts that healed within the bound, summed
    /// over the side (`RateDriftWindow.healedWithinBound`). When they are ALL of them, the side is `.degraded`, not `.compromised` —
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
            || (lhs.exactZeroUnprovenSeconds == nil) != (rhs.exactZeroUnprovenSeconds == nil)
        lhs.exactZeroSeconds = sum(lhs.exactZeroSeconds, rhs.exactZeroSeconds)
        lhs.exactZeroUnprovenSeconds = sum(lhs.exactZeroUnprovenSeconds, rhs.exactZeroUnprovenSeconds)
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
            ("exact_zero_unproven_seconds", exactZeroUnprovenSeconds.map { String(format: "%.1f", $0) }),
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
        if detail["\(prefix)_exact_zero_unproven_seconds"] != nil {
            guard let unproven = finiteOrDefault("exact_zero_unproven_seconds", 0) else { return nil }
            exactZeroUnprovenSeconds = unproven
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
        if let exactZeroUnprovenSeconds { d["exact_zero_unproven_seconds"] = exactZeroUnprovenSeconds }
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
    /// Seconds from the detection to the helper's own `captureStop`, when that is what ended the drift (#333 R4): no
    /// rebuild had delivered first frames by then — the user stopped first, or the remediation budget was spent. The
    /// wrong-rate audio ends where the recording does. nil = it healed, or nothing in the record ends it.
    public var stoppedAfterSeconds: Double?
    /// Whether the window starts after the remote side's last transcript segment, by more than
    /// `afterSpeechMarginSeconds` (#333 R5). Answered by `TranscriptAssembler` for a stop-bounded window only, and only
    /// when the record's timeline can be compared with the transcript's; nil = not judged.
    public var afterLastSpeech: Bool?

    /// The most wrong-rate audio, summed over a side's drifts, that still reads `degraded` rather than `compromised`: the same 15 s the record
    /// already tolerates as a coverage shortfall (`TrackAccounting.minimumDeficitSeconds`). A side may lose up to that
    /// much audio and stay healthy; a heal that corrupted no more than that is a blemish to state, not a side to
    /// distrust. The real 0.9.0 case (#308) measured a ~5 s window, a ~3 s rebuild and at most ~3 s before it: ~11 s.
    public static let healedBoundSeconds: Double = TrackAccounting.minimumDeficitSeconds

    /// How far past a side's last transcript segment a window must start to have touched no speech (#333 R5).
    public static let afterSpeechMarginSeconds: Double = 1

    public init(detectedOffsetSeconds: Double? = nil, onsetWithinSeconds: Double? = nil, healedAfterSeconds: Double? = nil,
                stoppedAfterSeconds: Double? = nil) {
        self.detectedOffsetSeconds = detectedOffsetSeconds
        self.onsetWithinSeconds = onsetWithinSeconds
        self.healedAfterSeconds = healedAfterSeconds
        self.stoppedAfterSeconds = stoppedAfterSeconds
    }

    /// At most this many seconds were captured at the wrong rate; nil when the onset is unknown, or when nothing in
    /// the record ends the drift (neither a rebuild's first frames nor the capture stop).
    public var affectedSeconds: Double? {
        guard let onsetWithinSeconds, let endedAfter = healedAfterSeconds ?? stoppedAfterSeconds else { return nil }
        return onsetWithinSeconds + endedAfter
    }

    /// Seconds from capture start to where the wrong-rate window begins, at the earliest; nil when the detection's
    /// offset or the onset is unknown.
    public var startOffsetSeconds: Double? {
        guard let detectedOffsetSeconds, let onsetWithinSeconds else { return nil }
        return max(0, detectedOffsetSeconds - onsetWithinSeconds)
    }

    /// How many of a side's drifts may count as healed for `TrackAccounting.status`: the healed ones with a known
    /// window, and only while their windows SUM to no more than the bound (#311 review) — three 7 s drifts are 21 s
    /// at the wrong rate, not three blemishes. 0 otherwise, which keeps the side `compromised`. A drift the capture
    /// stop ended (#333 R4) counts the same, in the same sum: its wrong-rate audio is bounded too.
    public static func healedWithinBound(_ windows: [RateDriftWindow]) -> Int {
        let healed = windows.compactMap(\.affectedSeconds)
        return healed.reduce(0, +) <= healedBoundSeconds ? healed.count : 0
    }

    private enum CodingKeys: String, CodingKey {
        case detectedOffsetSeconds = "detected_offset_seconds"
        case onsetWithinSeconds = "onset_within_seconds"
        case healedAfterSeconds = "healed_after_seconds"
        case stoppedAfterSeconds = "stopped_after_seconds"
        case afterLastSpeech = "after_last_speech"
    }

    /// `ended_by` of a window the capture stop ended (#333 R4).
    static let endedByStop = "stop"

    /// One entry of `metadata.capture.remote.rate_drift`. `offset_seconds` is where the wrong-rate window starts
    /// (the earliest onset), `affected_seconds` its length at most; an unknown onset says so instead. A window the
    /// capture stop ended says `ended_by: "stop"` and `healed: false` (#333 R4): the recording ended, nothing healed.
    public func asMetadataDictionary() -> [String: Any] {
        var d: [String: Any] = ["healed": healedAfterSeconds != nil]
        if let detectedOffsetSeconds { d["detected_offset_seconds"] = Self.tenths(detectedOffsetSeconds) }
        if onsetWithinSeconds != nil {
            if let startOffsetSeconds { d["offset_seconds"] = Self.tenths(startOffsetSeconds) }
        } else {
            d["onset"] = "unknown"
        }
        if let healedAfterSeconds {
            d["healed_after_seconds"] = Self.tenths(healedAfterSeconds)
        } else if let stoppedAfterSeconds {
            d["ended_by"] = Self.endedByStop
            d["stopped_after_seconds"] = Self.tenths(stoppedAfterSeconds)
            if let afterLastSpeech { d["after_last_speech"] = afterLastSpeech }
        }
        if let affectedSeconds {
            d["affected_seconds"] = Self.tenths(affectedSeconds)
            d["affected_seconds_is_upper_bound"] = true
        }
        return d
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// How many of a side's drifts are recorded but not announced (#333 R5), read from the side's stamped dictionary
    /// (`metadata.capture.remote`, `capture_provenance.remote_coverage`): all of them when the side is `degraded` and
    /// EVERY window ended at the Stop after the side's last speech; 0 otherwise. The one rule the summary header and
    /// banner and the completion notice all read, so they cannot disagree. The status stays `degraded` in the record:
    /// this decides what is said, never what is written.
    public static func unannounced(inSide side: [String: Any]?) -> Int {
        guard let side, side["status"] as? String == TrackAccounting.Status.degraded.rawValue,
              let windows = side["rate_drift"] as? [[String: Any]], !windows.isEmpty,
              windows.allSatisfy({ $0["ended_by"] as? String == endedByStop && $0["after_last_speech"] as? Bool == true })
        else { return 0 }
        return windows.count
    }
}
