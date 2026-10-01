import Foundation

/// Per-stage timing of one track's capture callback (#247).
///
/// `coreaudiod` reported the helper's IO callback at 56.5 ms against an 11.35 ms budget with about
/// half a millisecond of CPU in that cycle: it was waiting. The tap's IOProc runs as a block on the
/// helper's shared serial audio queue and the HAL blocks until it returns, so the time the block
/// waits for that queue counts as IO duration, and the same queue carries the mic delegate, the WAV
/// writes and a periodic `fsync`. This type makes that measurable. It changes nothing.
///
/// It is fed from the audio queue, once per callback, so it is built for that path:
/// - a value type whose storage is inline and fixed-size (2120 bytes). `record` allocates nothing,
///   and a copy is a `memcpy`: there is no reference to share, so no copy-on-write on the next
///   `record` (`IOCycleStatsTests.recordingACycleAllocatesNothing` holds it to that);
/// - no lock, no log, no clock. Durations come in as plain integers (nanoseconds); the caller reads
///   the clock;
/// - integer arithmetic that cannot trap: counters saturate, subtractions are guarded.
///
/// **Resolution.** Each stage has a histogram of `bucketCount` (70) buckets: four per octave from
/// 8.192 µs (2^13 ns) to 1.074 s (2^30 ns), one below and one above. A percentile is reported as
/// the upper edge of its bucket, never above the exact maximum, so it overstates the true value by
/// at most 25 % and never understates it. That is enough to tell 0.3 ms from 30 ms, which is the
/// question; the two numbers that need to be exact (the maximum and the overrun count) are kept
/// exactly, beside the histogram. Finer buckets would cost more storage per track for no decision
/// this measurement feeds.
///
/// **A stage of 0 is not counted.** A stage that did not run in a cycle (no pad, no `fsync`) or that
/// could not be measured (the mic has no "enqueued at" time, so no queue wait) comes in as 0 and is
/// left out of that stage's histogram. Its percentiles then describe the cycles in which it
/// happened, and its count says how many those were.
public struct IOCycleStats: Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        /// From the start of the HAL's IO cycle to the first line of the callback: the wait for the
        /// shared audio queue. Tap only.
        case queueWait
        /// Buffer allocation, copy and sample-rate conversion to 48 kHz mono Int16.
        case convert
        /// The timeline pad (fabricated silence and its write), without any `fsync` inside it.
        case pad
        /// The samples' file write, with the periodic header rewrite, without the `fsync`.
        case write
        /// The periodic `fsync`, wherever in the cycle it ran.
        case sync
        /// The whole cycle. For the tap it starts at the HAL's cycle start, so it includes the
        /// queue wait; for the mic it starts at the callback's first line.
        case total

        /// The stage's name in diagnostic keys.
        public var key: String {
            switch self {
            case .queueWait: return "queue_wait"
            case .convert: return "convert"
            case .pad: return "pad"
            case .write: return "write"
            case .sync: return "sync"
            case .total: return "total"
            }
        }
    }

    /// One callback's stage durations, in nanoseconds. 0 = the stage did not run or was not measured.
    public struct Cycle: Equatable, Sendable {
        public var queueWaitNanos: UInt64
        public var convertNanos: UInt64
        public var padNanos: UInt64
        public var writeNanos: UInt64
        public var syncNanos: UInt64
        public var totalNanos: UInt64

        public init(queueWaitNanos: UInt64 = 0, convertNanos: UInt64 = 0, padNanos: UInt64 = 0,
                    writeNanos: UInt64 = 0, syncNanos: UInt64 = 0, totalNanos: UInt64) {
            self.queueWaitNanos = queueWaitNanos
            self.convertNanos = convertNanos
            self.padNanos = padNanos
            self.writeNanos = writeNanos
            self.syncNanos = syncNanos
            self.totalNanos = totalNanos
        }

        fileprivate func nanos(_ stage: Stage) -> UInt64 {
            switch stage {
            case .queueWait: return queueWaitNanos
            case .convert: return convertNanos
            case .pad: return padNanos
            case .write: return writeNanos
            case .sync: return syncNanos
            case .total: return totalNanos
            }
        }
    }

    // The constants are computed properties, not stored statics: a stored static is initialised
    // lazily behind a once-token on its first read, and that first read would be on the audio queue.

    /// A cycle whose total is OVER this is an overrun. 8 ms sits under the IO budget reported for
    /// the tap aggregate (11.35 ms, #247), so a cycle is counted before it costs an overload.
    public static var overrunThresholdNanos: UInt64 { 8_000_000 }
    /// At most one overrun EVENT per this long, per track. Every overrun is still counted.
    public static var overrunReportIntervalNanos: UInt64 { 10_000_000_000 }

    // MARK: - Buckets

    static var firstOctave: Int { 13 }
    static var lastOctave: Int { 29 }
    static var bucketsPerOctave: Int { 4 }
    /// One bucket below the first octave, four per octave, one above the last.
    public static var bucketCount: Int { 1 + (lastOctave - firstOctave + 1) * bucketsPerOctave + 1 }
    /// Durations of this much or more land in the last bucket; a percentile there reads as this.
    public static var saturationNanos: UInt64 { 1 << UInt64(lastOctave + 1) }

    static func bucket(for nanos: UInt64) -> Int {
        if nanos < (1 << UInt64(firstOctave)) { return 0 }
        if nanos >= saturationNanos { return bucketCount - 1 }
        let octave = 63 - nanos.leadingZeroBitCount                    // firstOctave...lastOctave
        let quarter = Int((nanos >> UInt64(octave - 2)) & 3)
        return 1 + (octave - firstOctave) * bucketsPerOctave + quarter
    }

    /// Inclusive.
    static func lowerBound(ofBucket bucket: Int) -> UInt64 {
        if bucket <= 0 { return 0 }
        if bucket >= bucketCount - 1 { return saturationNanos }
        let octave = firstOctave + (bucket - 1) / bucketsPerOctave
        let quarter = UInt64((bucket - 1) % bucketsPerOctave)
        return (4 + quarter) << UInt64(octave - 2)
    }

    /// Exclusive. The last bucket has none (`UInt64.max`).
    static func upperBound(ofBucket bucket: Int) -> UInt64 {
        bucket >= bucketCount - 1 ? .max : lowerBound(ofBucket: bucket + 1)
    }

    // MARK: - Storage (inline, fixed-size)

    // A homogeneous tuple is laid out as a contiguous C array, so 512 `UInt32` are one 2048-byte
    // block inside the struct. `Stage.allCases.count * bucketCount` (420) slots are used.
    private typealias Slots8 = (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
    private typealias Slots64 = (Slots8, Slots8, Slots8, Slots8, Slots8, Slots8, Slots8, Slots8)
    private typealias Slots512 = (Slots64, Slots64, Slots64, Slots64, Slots64, Slots64, Slots64, Slots64)
    private static var slotCapacity: Int { 512 }

    private static func zeroSlots() -> Slots512 {
        let z8: Slots8 = (0, 0, 0, 0, 0, 0, 0, 0)
        let z64: Slots64 = (z8, z8, z8, z8, z8, z8, z8, z8)
        return (z64, z64, z64, z64, z64, z64, z64, z64)
    }

    private var slots: Slots512 = IOCycleStats.zeroSlots()
    /// The exact maximum of each stage, by `Stage.rawValue`.
    private var maxima: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0)
    /// Cycles whose total was over the threshold. Exact.
    public private(set) var overrunCount: UInt64 = 0
    private var hasReported = false
    private var lastReportNanos: UInt64 = 0

    public init() {
        // A debug build instantiates the two storage tuples' type metadata (a handful of one-time
        // allocations, once per process) the first time they are handed to a generic function. Do it
        // here, where the value is built, so the first `record` on the audio queue has nothing left to
        // set up. An optimised build has nothing to do here.
        withUnsafeMutableBytes(of: &slots) { _ in }
        withUnsafeMutableBytes(of: &maxima) { _ in }
    }

    private static func slot(_ stage: Stage, _ bucket: Int) -> Int? {
        let index = stage.rawValue * bucketCount + bucket
        guard bucket >= 0, bucket < bucketCount, index >= 0, index < slotCapacity else { return nil }
        return index
    }

    // MARK: - Recording (the audio queue)

    /// Record one callback. `nowNanos` is a monotonic clock reading (the cycle's end), used only for
    /// the rate limit. Returns true when this cycle is an overrun AND an overrun event may be
    /// recorded now (at most one per `overrunReportIntervalNanos`); the caller records it.
    @discardableResult
    public mutating func record(_ cycle: Cycle, nowNanos: UInt64) -> Bool {
        note(.queueWait, cycle.queueWaitNanos)
        note(.convert, cycle.convertNanos)
        note(.pad, cycle.padNanos)
        note(.write, cycle.writeNanos)
        note(.sync, cycle.syncNanos)
        note(.total, cycle.totalNanos)

        guard cycle.totalNanos > Self.overrunThresholdNanos else { return false }
        if overrunCount != .max { overrunCount &+= 1 }
        if hasReported {
            // A reading before the last report cannot come from a monotonic clock: never report on it.
            guard nowNanos >= lastReportNanos, nowNanos &- lastReportNanos >= Self.overrunReportIntervalNanos else {
                return false
            }
        }
        hasReported = true
        lastReportNanos = nowNanos
        return true
    }

    private mutating func note(_ stage: Stage, _ nanos: UInt64) {
        guard nanos > 0, let index = Self.slot(stage, Self.bucket(for: nanos)) else { return }
        withUnsafeMutableBytes(of: &slots) { raw in
            let offset = index * MemoryLayout<UInt32>.stride
            let count = raw.load(fromByteOffset: offset, as: UInt32.self)
            if count != .max { raw.storeBytes(of: count &+ 1, toByteOffset: offset, as: UInt32.self) }
        }
        withUnsafeMutableBytes(of: &maxima) { raw in
            let offset = stage.rawValue * MemoryLayout<UInt64>.stride
            if nanos > raw.load(fromByteOffset: offset, as: UInt64.self) {
                raw.storeBytes(of: nanos, toByteOffset: offset, as: UInt64.self)
            }
        }
    }

    /// Forget everything, the rate limit included.
    public mutating func reset() {
        self = IOCycleStats()
    }

    // MARK: - Reading (off the audio queue: these allocate)

    /// One stage's histogram, by bucket.
    func counts(_ stage: Stage) -> [UInt32] {
        withUnsafeBytes(of: slots) { raw in
            (0..<Self.bucketCount).map { bucket in
                Self.slot(stage, bucket).map { raw.load(fromByteOffset: $0 * MemoryLayout<UInt32>.stride, as: UInt32.self) } ?? 0
            }
        }
    }

    func count(_ stage: Stage, bucket: Int) -> UInt32 {
        (0..<Self.bucketCount).contains(bucket) ? counts(stage)[bucket] : 0
    }

    /// Cycles in which `stage` ran (and was measured).
    public func count(_ stage: Stage) -> UInt64 {
        counts(stage).reduce(0) { $0 + UInt64($1) }
    }

    /// Callbacks recorded.
    public var cycleCount: UInt64 { count(.total) }

    /// The stage's longest duration, exact. 0 when it never ran.
    public func max(_ stage: Stage) -> UInt64 {
        withUnsafeBytes(of: maxima) { $0.load(fromByteOffset: stage.rawValue * MemoryLayout<UInt64>.stride, as: UInt64.self) }
    }

    /// The `p`-th percentile (1...100, nearest rank) of `stage`, in nanoseconds: the upper edge of
    /// the bucket holding it, never above the exact maximum; `saturationNanos` when it lies in the
    /// last bucket. 0 when the stage never ran.
    public func percentile(_ p: Int, _ stage: Stage) -> UInt64 {
        Self.percentile(p, of: counts(stage), max: max(stage))
    }

    private static func percentile(_ p: Int, of counts: [UInt32], max: UInt64) -> UInt64 {
        let total = counts.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return 0 }
        let percent = UInt64(Swift.max(1, Swift.min(100, p)))
        let rank = Swift.max(1, (total * percent + 99) / 100)
        var seen: UInt64 = 0
        for (bucket, count) in counts.enumerated() {
            seen += UInt64(count)
            guard seen >= rank else { continue }
            if bucket == bucketCount - 1 { return saturationNanos }
            return Swift.min(upperBound(ofBucket: bucket), max)
        }
        return max
    }

    // MARK: - Summary

    public struct StageSummary: Equatable, Sendable {
        public let count: UInt64
        public let p50Nanos: UInt64
        public let p99Nanos: UInt64
        public let maxNanos: UInt64

        public init(count: UInt64, p50Nanos: UInt64, p99Nanos: UInt64, maxNanos: UInt64) {
            self.count = count
            self.p50Nanos = p50Nanos
            self.p99Nanos = p99Nanos
            self.maxNanos = maxNanos
        }
    }

    /// What a session's stop reports for one track.
    public struct Summary: Equatable, Sendable {
        public let cycles: UInt64
        public let overruns: UInt64
        /// By `Stage.rawValue`.
        private let stages: [StageSummary]

        fileprivate init(cycles: UInt64, overruns: UInt64, stages: [StageSummary]) {
            self.cycles = cycles
            self.overruns = overruns
            self.stages = stages
        }

        public subscript(stage: Stage) -> StageSummary { stages[stage.rawValue] }

        /// Detail keys for `captureStop`, next to the coverage: `<prefix>_cycles`, `<prefix>_overruns`,
        /// and `<prefix>_<stage>_n` / `_p50_ms` / `_p99_ms` / `_max_ms` for each stage that ran. A
        /// stage that never ran is left out; a track with no cycle adds nothing.
        public func asDetail(prefix: String) -> [String: String] {
            guard cycles > 0 else { return [:] }
            var detail = ["\(prefix)_cycles": "\(cycles)", "\(prefix)_overruns": "\(overruns)"]
            for stage in Stage.allCases where self[stage].count > 0 {
                let s = self[stage]
                detail["\(prefix)_\(stage.key)_n"] = "\(s.count)"
                detail["\(prefix)_\(stage.key)_p50_ms"] = IOCycleStats.milliseconds(s.p50Nanos)
                detail["\(prefix)_\(stage.key)_p99_ms"] = IOCycleStats.milliseconds(s.p99Nanos)
                detail["\(prefix)_\(stage.key)_max_ms"] = IOCycleStats.milliseconds(s.maxNanos)
            }
            return detail
        }

        /// The same numbers as one line for the unified log (counts and durations only). nil when
        /// the track had no cycle.
        public var logLine: String? {
            guard cycles > 0 else { return nil }
            let threshold = IOCycleStats.milliseconds(IOCycleStats.overrunThresholdNanos)
            var parts = ["cycles=\(cycles) overruns=\(overruns) (over \(threshold) ms)"]
            for stage in Stage.allCases where self[stage].count > 0 {
                let s = self[stage]
                parts.append("\(stage.key) n=\(s.count) p50=\(IOCycleStats.milliseconds(s.p50Nanos)) "
                    + "p99=\(IOCycleStats.milliseconds(s.p99Nanos)) max=\(IOCycleStats.milliseconds(s.maxNanos))")
            }
            return parts.joined(separator: " | ") + " (ms)"
        }
    }

    public func summary() -> Summary {
        Summary(cycles: cycleCount, overruns: overrunCount, stages: Stage.allCases.map { stage in
            let counts = counts(stage)
            let longest = max(stage)
            return StageSummary(count: counts.reduce(0) { $0 + UInt64($1) },
                                p50Nanos: Self.percentile(50, of: counts, max: longest),
                                p99Nanos: Self.percentile(99, of: counts, max: longest), maxNanos: longest)
        })
    }

    /// Nanoseconds as milliseconds with microsecond precision ("56.512"), truncated. Integer
    /// formatting: no locale, no float.
    public static func milliseconds(_ nanos: UInt64) -> String {
        let micros = (nanos / 1_000) % 1_000
        let padding = micros < 10 ? "00" : (micros < 100 ? "0" : "")
        return "\(nanos / 1_000_000).\(padding)\(micros)"
    }

    // MARK: - Ticks

    /// `to - from` in clock ticks; 0 when the clock reads backwards (it never traps).
    public static func elapsed(from: UInt64, to: UInt64) -> UInt64 {
        to >= from ? to &- from : 0
    }

    /// Split the clock readings around one "pad, then append" pair into the pad, write and sync
    /// stages (ticks in, ticks out). The writer counts the ticks it spends in `fsync`; `syncBefore`,
    /// `syncAfterPad` and `syncAfterWrite` are that counter before the pad, after it and after the
    /// append, so an `fsync` is taken out of whichever window it ran in and reported on its own.
    /// `padded` false = no silence was written: the pad stage did not run.
    public static func writeStages(
        padded: Bool, padStart: UInt64, padEnd: UInt64, writeEnd: UInt64,
        syncBefore: UInt64, syncAfterPad: UInt64, syncAfterWrite: UInt64
    ) -> (pad: UInt64, write: UInt64, sync: UInt64) {
        let padSpan = elapsed(from: padStart, to: padEnd)
        let writeSpan = elapsed(from: padEnd, to: writeEnd)
        let padSync = elapsed(from: syncBefore, to: syncAfterPad)
        let writeSync = elapsed(from: syncAfterPad, to: syncAfterWrite)
        return (pad: padded ? elapsed(from: padSync, to: padSpan) : 0,
                write: elapsed(from: writeSync, to: writeSpan),
                sync: elapsed(from: syncBefore, to: syncAfterWrite))
    }

    /// The host clock's tick length (`mach_timebase_info`), read once, off the audio queue.
    public struct Timebase: Equatable, Sendable {
        public let numer: UInt64
        public let denom: UInt64

        /// A zero on either side is not a timebase: ticks are then taken as nanoseconds.
        public init(numer: UInt32, denom: UInt32) {
            let valid = numer != 0 && denom != 0
            self.numer = valid ? UInt64(numer) : 1
            self.denom = valid ? UInt64(denom) : 1
        }

        public static func host() -> Timebase {
            var info = mach_timebase_info_data_t()
            guard mach_timebase_info(&info) == KERN_SUCCESS else { return Timebase(numer: 1, denom: 1) }
            return Timebase(numer: info.numer, denom: info.denom)
        }

        /// Saturates instead of overflowing.
        public func nanos(_ ticks: UInt64) -> UInt64 {
            if numer == denom { return ticks }
            let (product, overflow) = ticks.multipliedReportingOverflow(by: numer)
            return overflow ? .max : product / denom
        }
    }
}

extension IOCycleStats.Cycle {
    /// The `ioOverrun` diagnostic event for this cycle: the stage breakdown in milliseconds (a stage
    /// that did not run is left out), the threshold, and how many overruns the track has had so far
    /// (events are rate-limited; the count is not).
    public func overrunEvent(track: CaptureTrack, overruns: UInt64, at timestamp: Date) -> CaptureEvent {
        var detail = [
            "track": track.rawValue,
            "threshold_ms": IOCycleStats.milliseconds(IOCycleStats.overrunThresholdNanos),
            "overruns": "\(overruns)",
        ]
        for stage in IOCycleStats.Stage.allCases where nanos(stage) > 0 {
            detail["\(stage.key)_ms"] = IOCycleStats.milliseconds(nanos(stage))
        }
        return CaptureEvent(timestamp: timestamp, origin: .helper, kind: .ioOverrun, severity: .anomaly, detail: detail)
    }
}
