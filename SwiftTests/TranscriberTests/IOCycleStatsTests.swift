import Foundation
import Testing
@testable import TranscriberCore

/// #247: coreaudiod reported the capture helper's IO callback at 56.5 ms against an 11.35 ms budget,
/// with about half a millisecond of CPU in that cycle. The callback was waiting, and nothing in the
/// helper could say on what. `IOCycleStats` is the instrument: per-stage durations of every callback
/// in a fixed-size histogram, an exact overrun count, and a rate-limited verdict for the one
/// diagnostic event. It sits on the real-time path, so these tests also pin what it must never do
/// there: trap on a hostile number, or report more than once per 10 s.
@Suite struct IOCycleStatsTests {
    private static let us: UInt64 = 1_000
    private static let ms: UInt64 = 1_000_000
    private static let second: UInt64 = 1_000_000_000

    private func cycle(_ total: UInt64) -> IOCycleStats.Cycle { IOCycleStats.Cycle(totalNanos: total) }

    // MARK: - Percentiles

    /// 100 cycles of 0.1 ms, 0.2 ms … 10.0 ms. A percentile reads as the upper edge of its bucket
    /// (four buckets per octave), never above the exact maximum.
    @Test func percentilesOfAKnownDistribution() {
        var stats = IOCycleStats()
        for i in 1...100 { stats.record(cycle(UInt64(i) * 100 * Self.us), nowNanos: 0) }
        #expect(stats.count(.total) == 100)
        #expect(stats.cycleCount == 100)
        // The 50th value is 5.0 ms, in the bucket [4.194304, 5.242880) ms.
        #expect(stats.percentile(50, .total) == 5_242_880)
        // The 99th value is 9.9 ms, in [8.388608, 10.485760) ms: the edge is clamped to the max.
        #expect(stats.percentile(99, .total) == 10 * Self.ms)
        #expect(stats.max(.total) == 10 * Self.ms)
        #expect(stats.percentile(1, .total) == 114_688, "0.1 ms is in [98.304, 114.688) µs")
    }

    /// The resolution promise: from 8.2 µs to 1.07 s a percentile overstates the true value by at
    /// most 25 %, and never understates it.
    @Test func aPercentileOverstatesByAtMostAQuarter() {
        var value: UInt64 = 9_000
        while value < Self.second {
            var stats = IOCycleStats()
            stats.record(cycle(value), nowNanos: 0)
            stats.record(cycle(5 * Self.second), nowNanos: 0)   // lifts the max, so the bucket edge shows
            let p50 = stats.percentile(50, .total)
            #expect(p50 > value && p50 <= value + value / 4, "value \(value) read as \(p50)")
            value = value * 137 / 100
        }
    }

    @Test func everythingBelowTheFirstEdgeReadsAsAtMostThatEdge() {
        var stats = IOCycleStats()
        stats.record(cycle(1), nowNanos: 0)
        stats.record(cycle(8_191), nowNanos: 0)
        stats.record(cycle(Self.ms), nowNanos: 0)
        #expect(stats.percentile(50, .total) == 8_192)
        #expect(stats.max(.total) == Self.ms)
    }

    @Test func anEmptyStageReadsZero() {
        let stats = IOCycleStats()
        for stage in IOCycleStats.Stage.allCases {
            #expect(stats.count(stage) == 0)
            #expect(stats.max(stage) == 0)
            #expect(stats.percentile(50, stage) == 0)
            #expect(stats.percentile(99, stage) == 0)
        }
        #expect(stats.overrunCount == 0)
    }

    // MARK: - Stages

    /// A stage that did not run in a cycle (no pad, no fsync) or could not be measured (the mic has
    /// no "enqueued at" time) comes in as 0 and is not counted: its percentiles describe the cycles
    /// in which it happened, not a sea of zeros.
    @Test func aStageThatDidNotRunIsNotCounted() {
        var stats = IOCycleStats()
        for i in 0..<50 {
            stats.record(IOCycleStats.Cycle(
                convertNanos: 200 * Self.us, writeNanos: 100 * Self.us,
                syncNanos: i == 0 ? 4 * Self.ms : 0, totalNanos: 400 * Self.us), nowNanos: 0)
        }
        #expect(stats.count(.total) == 50)
        #expect(stats.count(.convert) == 50)
        #expect(stats.count(.write) == 50)
        #expect(stats.count(.sync) == 1)
        #expect(stats.max(.sync) == 4 * Self.ms)
        #expect(stats.percentile(50, .sync) == 4 * Self.ms)
        #expect(stats.count(.queueWait) == 0)
        #expect(stats.count(.pad) == 0)
    }

    /// The storage is one flat block of counters. Every (stage, bucket) pair must own its slot.
    @Test func everyStageAndBucketHasItsOwnCounter() {
        var stats = IOCycleStats()
        func expected(_ stage: IOCycleStats.Stage, _ bucket: Int) -> UInt32 {
            UInt32((stage.rawValue * 7 + bucket) % 4 + 1)
        }
        for stage in IOCycleStats.Stage.allCases {
            for bucket in 0..<IOCycleStats.bucketCount {
                // Bucket 0 starts at 0 ns, which is "did not run": use 1 ns there.
                let value = max(1, IOCycleStats.lowerBound(ofBucket: bucket))
                for _ in 0..<expected(stage, bucket) {
                    var c = IOCycleStats.Cycle(totalNanos: 0)
                    switch stage {
                    case .queueWait: c.queueWaitNanos = value
                    case .convert: c.convertNanos = value
                    case .pad: c.padNanos = value
                    case .write: c.writeNanos = value
                    case .sync: c.syncNanos = value
                    case .total: c.totalNanos = value
                    }
                    stats.record(c, nowNanos: 0)
                }
            }
        }
        for stage in IOCycleStats.Stage.allCases {
            for bucket in 0..<IOCycleStats.bucketCount {
                #expect(stats.count(stage, bucket: bucket) == expected(stage, bucket), "\(stage) bucket \(bucket)")
            }
        }
    }

    @Test func theBucketEdgesAreContiguous() {
        #expect(IOCycleStats.bucketCount == 70, "one below 8.192 µs, 4 per octave over 17 octaves, one from 1.074 s up")
        #expect(IOCycleStats.upperBound(ofBucket: 0) == 8_192)
        #expect(IOCycleStats.lowerBound(ofBucket: 0) == 0)
        for bucket in 0..<(IOCycleStats.bucketCount - 1) {
            #expect(IOCycleStats.upperBound(ofBucket: bucket) == IOCycleStats.lowerBound(ofBucket: bucket + 1))
            #expect(IOCycleStats.bucket(for: IOCycleStats.lowerBound(ofBucket: bucket)) == bucket)
            #expect(IOCycleStats.bucket(for: IOCycleStats.upperBound(ofBucket: bucket) - 1) == bucket)
        }
        #expect(IOCycleStats.lowerBound(ofBucket: IOCycleStats.bucketCount - 1) == IOCycleStats.saturationNanos)
    }

    // MARK: - Overrun threshold

    @Test func aCycleOfExactlyTheThresholdIsNotAnOverrun() {
        var stats = IOCycleStats()
        #expect(IOCycleStats.overrunThresholdNanos == 8 * Self.ms)
        #expect(stats.record(cycle(8 * Self.ms), nowNanos: 0) == false)
        #expect(stats.overrunCount == 0)
        #expect(stats.record(cycle(8 * Self.ms + 1), nowNanos: 0) == true)
        #expect(stats.overrunCount == 1)
    }

    /// The HAL judges the whole cycle, so the verdict reads the total only.
    @Test func theOverrunIsJudgedOnTheTotal() {
        var stats = IOCycleStats()
        let withinBudget = IOCycleStats.Cycle(queueWaitNanos: 3 * Self.ms, convertNanos: 2 * Self.ms,
                                              writeNanos: 2 * Self.ms, totalNanos: 7 * Self.ms + 900 * Self.us)
        #expect(stats.record(withinBudget, nowNanos: 0) == false)
        let waited = IOCycleStats.Cycle(queueWaitNanos: 56 * Self.ms, convertNanos: 200 * Self.us,
                                        writeNanos: 100 * Self.us, totalNanos: 56 * Self.ms + 500 * Self.us)
        #expect(stats.record(waited, nowNanos: 0) == true)
        #expect(stats.overrunCount == 1)
        #expect(stats.max(.queueWait) == 56 * Self.ms)
    }

    // MARK: - Rate limit

    @Test func overrunEventsAreLimitedToOnePerTenSeconds() {
        var stats = IOCycleStats()
        let start = 37 * Self.second   // an uptime, not zero: the first overrun always reports
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start) == true)
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start + 1) == false)
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start + 10 * Self.second - 1) == false)
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start + 10 * Self.second) == true)
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start + 19 * Self.second) == false)
        #expect(stats.record(cycle(20 * Self.ms), nowNanos: start + 20 * Self.second) == true)
        // Every overrun is counted, reported or not.
        #expect(stats.overrunCount == 6)
        #expect(stats.count(.total) == 6)
    }

    @Test func aCycleWithinBudgetNeitherReportsNorSpendsTheRateLimit() {
        var stats = IOCycleStats()
        for i in 0..<1_000 { #expect(stats.record(cycle(Self.ms), nowNanos: UInt64(i) * 10 * Self.ms) == false) }
        #expect(stats.overrunCount == 0)
        #expect(stats.record(cycle(9 * Self.ms), nowNanos: 10 * Self.second + 1) == true)
    }

    /// The limit is 10 s of a monotonic clock. A reading before the last report (it cannot happen
    /// with `mach_absolute_time`) must neither trap nor report early.
    @Test func aClockReadingBeforeTheLastReportDoesNotReport() {
        var stats = IOCycleStats()
        #expect(stats.record(cycle(9 * Self.ms), nowNanos: 100 * Self.second) == true)
        #expect(stats.record(cycle(9 * Self.ms), nowNanos: 50 * Self.second) == false)
        #expect(stats.record(cycle(9 * Self.ms), nowNanos: 0) == false)
        #expect(stats.overrunCount == 3)
    }

    // MARK: - Saturation

    /// Past 1.07 s a duration lands in the top bucket: percentiles read as the saturation limit
    /// ("at least this"), and the maximum stays exact.
    @Test func aDurationPastTheLastBucketSaturatesThereAndTheMaxStaysExact() {
        var stats = IOCycleStats()
        stats.record(cycle(3 * Self.second), nowNanos: 0)
        stats.record(cycle(90 * Self.second), nowNanos: 0)
        stats.record(cycle(UInt64.max), nowNanos: 0)   // never a trap
        #expect(stats.count(.total) == 3)
        #expect(stats.count(.total, bucket: IOCycleStats.bucketCount - 1) == 3)
        #expect(stats.percentile(50, .total) == IOCycleStats.saturationNanos)
        #expect(stats.percentile(99, .total) == IOCycleStats.saturationNanos)
        #expect(IOCycleStats.saturationNanos == 1 << 30)
        #expect(stats.max(.total) == UInt64.max)
        #expect(stats.overrunCount == 3)
    }

    @Test func aPercentileOutsideOneToAHundredIsClamped() {
        var stats = IOCycleStats()
        stats.record(cycle(Self.ms), nowNanos: 0)
        stats.record(cycle(4 * Self.ms), nowNanos: 0)
        #expect(stats.percentile(0, .total) == stats.percentile(1, .total))
        #expect(stats.percentile(-5, .total) == stats.percentile(1, .total))
        #expect(stats.percentile(250, .total) == stats.percentile(100, .total))
        #expect(stats.percentile(100, .total) == 4 * Self.ms)
    }

    // MARK: - Reset

    @Test func resetForgetsEverythingIncludingTheRateLimit() {
        var stats = IOCycleStats()
        let busy = IOCycleStats.Cycle(queueWaitNanos: 12 * Self.ms, convertNanos: Self.ms, padNanos: Self.ms,
                                      writeNanos: Self.ms, syncNanos: 5 * Self.ms, totalNanos: 20 * Self.ms)
        #expect(stats.record(busy, nowNanos: Self.second) == true)
        #expect(stats.record(busy, nowNanos: 2 * Self.second) == false)
        stats.reset()
        for stage in IOCycleStats.Stage.allCases {
            #expect(stats.count(stage) == 0)
            #expect(stats.max(stage) == 0)
            #expect(stats.percentile(99, stage) == 0)
        }
        #expect(stats.overrunCount == 0)
        #expect(stats.summary().asDetail(prefix: "remote_io").isEmpty)
        // One second after the report that was forgotten: allowed again.
        #expect(stats.record(busy, nowNanos: 3 * Self.second) == true)
        #expect(stats.overrunCount == 1)
    }

    // MARK: - Ticks

    @Test func ticksConvertToNanosecondsByTheTimebase() {
        // Apple Silicon: 125/3, one tick is 41.67 ns.
        let arm = IOCycleStats.Timebase(numer: 125, denom: 3)
        #expect(arm.nanos(24) == 1_000)
        #expect(arm.nanos(24_000) == 1_000_000)
        #expect(arm.nanos(0) == 0)
        #expect(IOCycleStats.Timebase(numer: 1, denom: 1).nanos(123_456) == 123_456)
    }

    @Test func aTimebaseNeverTraps() {
        #expect(IOCycleStats.Timebase(numer: 125, denom: 3).nanos(UInt64.max) == UInt64.max, "saturates")
        // A zero denominator cannot come from the kernel; it must still not divide by zero.
        #expect(IOCycleStats.Timebase(numer: 125, denom: 0).nanos(1_000) == 1_000)
        #expect(IOCycleStats.Timebase(numer: 0, denom: 3).nanos(1_000) == 1_000)
        let host = IOCycleStats.Timebase.host()
        #expect(host.nanos(1_000_000) > 0)
    }

    @Test func elapsedTicksAreZeroWhenTheClockReadsBackwards() {
        #expect(IOCycleStats.elapsed(from: 4, to: 10) == 6)
        #expect(IOCycleStats.elapsed(from: 10, to: 10) == 0)
        #expect(IOCycleStats.elapsed(from: 10, to: 4) == 0)
        #expect(IOCycleStats.elapsed(from: UInt64.max, to: 0) == 0)
    }

    /// The writer counts the ticks it spends in `fsync`; the callback reads that counter around the
    /// pad and around the append, and the `fsync` is reported on its own, whichever of the two it
    /// ran in.
    @Test func theFsyncIsTakenOutOfTheWindowItRanIn() {
        // A pad of 100 ticks holding 60 ticks of fsync, then an append of 50 with none.
        let padded = IOCycleStats.writeStages(padded: true, padStart: 1_000, padEnd: 1_100, writeEnd: 1_150,
                                              syncBefore: 500, syncAfterPad: 560, syncAfterWrite: 560)
        #expect(padded.pad == 40)
        #expect(padded.write == 50)
        #expect(padded.sync == 60)
        // The usual cycle: nothing padded (the 2 ticks it took to decide are not a pad stage), and the
        // periodic fsync ran inside the append.
        let usual = IOCycleStats.writeStages(padded: false, padStart: 1_000, padEnd: 1_002, writeEnd: 1_102,
                                             syncBefore: 500, syncAfterPad: 500, syncAfterWrite: 570)
        #expect(usual.pad == 0)
        #expect(usual.write == 30)
        #expect(usual.sync == 70)
        // Readings that go backwards (a rotated writer's counter restarts at 0) never trap.
        let hostile = IOCycleStats.writeStages(padded: true, padStart: 10, padEnd: 5, writeEnd: 0,
                                               syncBefore: 9, syncAfterPad: 3, syncAfterWrite: 1)
        #expect(hostile.pad == 0 && hostile.write == 0 && hostile.sync == 0)
    }

    // MARK: - The audio queue's rule: no allocation

    /// The instrument must not disturb what it measures: on the callback path it may read a clock
    /// and do integer arithmetic into storage that already exists. This counts every malloc-family
    /// call on this thread while cycles are recorded the way the helper records them, and requires
    /// none. (`while`, not `for … in`: at `-Onone` the range iterator itself allocates.)
    @Test func recordingACycleAllocatesNothing() throws {
        // Plain bytes, no reference inside: a copy can never share storage with the original.
        #expect(_isPOD(IOCycleStats.self))
        #expect(_isPOD(IOCycleStats.Cycle.self))
        #expect(MemoryLayout<IOCycleStats>.size <= 4096)
        final class Holder { var system = IOCycleStats(); var mic = IOCycleStats() }   // as in the handler
        let holder = Holder()
        let timebase = IOCycleStats.Timebase(numer: 125, denom: 3)
        var local = IOCycleStats()
        var reports = 0
        var sink: UInt64 = 0

        let seen = try AllocationCounter.count {
            var x: UInt64 = 88172645463325252
            var i = 0
            while i < 200_000 {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17   // durations from nanoseconds to minutes
                let ticks = (x >> 8) & ((1 << (x % 40)) - 1)
                let stages = IOCycleStats.writeStages(
                    padded: i % 97 == 0, padStart: 1_000, padEnd: 1_000 &+ ticks / 5, writeEnd: 1_000 &+ ticks / 3,
                    syncBefore: 0, syncAfterPad: 0, syncAfterWrite: i % 50 == 0 ? ticks / 9 : 0)
                let cycle = IOCycleStats.Cycle(
                    queueWaitNanos: timebase.nanos(ticks), convertNanos: timebase.nanos(ticks / 3),
                    padNanos: timebase.nanos(stages.pad), writeNanos: timebase.nanos(stages.write),
                    syncNanos: timebase.nanos(stages.sync),
                    totalNanos: timebase.nanos(IOCycleStats.elapsed(from: 1_000, to: 1_000 &+ ticks &+ ticks / 2)))
                let now = UInt64(i) &* 10_000_000
                let report = i % 2 == 0 ? holder.system.record(cycle, nowNanos: now) : holder.mic.record(cycle, nowNanos: now)
                if report { reports += 1 }
                if local.record(cycle, nowNanos: now) { reports += 1 }
                if i % 4_800 == 0 {
                    // The 1 Hz coverage refresh copies both tracks: a memcpy, and the next record
                    // must not pay a copy-on-write for it.
                    let copy = (holder.mic, holder.system)
                    sink &+= copy.0.overrunCount &+ copy.1.overrunCount
                }
                i += 1
            }
        }
        #expect(seen == 0, "\(seen) malloc-family calls while recording 400000 cycles")
        #expect(holder.system.cycleCount + holder.mic.cycleCount > 150_000, "the loop really recorded")
        #expect(local.overrunCount > 0 && reports > 0, "and it took the overrun path")
        _ = sink

        // The counter is not blind: one array is seen.
        var boxes = 0
        let control = try AllocationCounter.count { boxes = [Int](repeating: 7, count: 64).count }
        #expect(control > 0 && boxes == 64, "the allocation counter saw no allocation at all: libmalloc's malloc_logger hook is not honoured on this OS, so the test above proves nothing here")
    }

    // MARK: - The diagnostic event and the stop summary

    @Test func millisecondsKeepMicrosecondPrecision() {
        #expect(IOCycleStats.milliseconds(0) == "0.000")
        #expect(IOCycleStats.milliseconds(999) == "0.000")
        #expect(IOCycleStats.milliseconds(21_000) == "0.021")
        #expect(IOCycleStats.milliseconds(8_000_000) == "8.000")
        #expect(IOCycleStats.milliseconds(56_512_345) == "56.512")
        #expect(IOCycleStats.milliseconds(1_073_741_824) == "1073.741")
    }

    @Test func theOverrunEventCarriesTheStageBreakdown() {
        let waited = IOCycleStats.Cycle(queueWaitNanos: 55_870_000, convertNanos: 210_000, writeNanos: 130_000,
                                        totalNanos: 56_512_000)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let event = waited.overrunEvent(track: .system, overruns: 13, at: at)
        #expect(event.kind == .ioOverrun)
        #expect(event.origin == .helper)
        #expect(event.timestamp == at)
        #expect(event.detail == [
            "track": "system", "total_ms": "56.512", "queue_wait_ms": "55.870", "convert_ms": "0.210",
            "write_ms": "0.130", "threshold_ms": "8.000", "overruns": "13",
        ])
    }

    /// The mic has no queue-wait measurement: the key is absent, never "0.000".
    @Test func anOverrunEventLeavesOutTheStagesThatDidNotRun() {
        let fsync = IOCycleStats.Cycle(convertNanos: 300_000, writeNanos: 90_000, syncNanos: 31_400_000,
                                       totalNanos: 31_900_000)
        let detail = fsync.overrunEvent(track: .mic, overruns: 1, at: Date()).detail
        #expect(detail["track"] == "mic")
        #expect(detail["sync_ms"] == "31.400")
        #expect(detail["queue_wait_ms"] == nil)
        #expect(detail["pad_ms"] == nil)
    }

    /// An overrun must reach the disk (the `.diag.jsonl` is written only for a session with an
    /// anomaly), but it says nothing about the recording's content: the user-facing notice and the
    /// per-side verdicts must not move.
    @Test func anOverrunFlushesTheRecordWithoutTouchingTheQualityVerdicts() {
        var ring = CaptureDiagnostics()
        #expect(ring.isAnomalous == false)
        ring.record(cycle(20 * Self.ms).overrunEvent(track: .system, overruns: 1, at: Date()))
        ring.record(cycle(20 * Self.ms).overrunEvent(track: .mic, overruns: 1, at: Date()))
        #expect(ring.isAnomalous)
        #expect(ring.anomalyCount == 2)
        #expect(ring.qualityAnomalyCount == 0)
        #expect(ring.contentAnomalyCount(track: "system") == 0)
        #expect(ring.contentAnomalyCount(track: "mic") == 0)
        #expect(!CaptureEventKind.qualityCompromising.contains(.ioOverrun))
        #expect(!CaptureEventKind.contentCompromising.contains(.ioOverrun))
    }

    @Test func theStopSummaryCarriesEveryMeasuredStage() {
        var stats = IOCycleStats()
        for i in 1...100 {
            stats.record(IOCycleStats.Cycle(
                queueWaitNanos: 20 * Self.us, convertNanos: 200 * Self.us, writeNanos: 100 * Self.us,
                syncNanos: i % 50 == 0 ? 12 * Self.ms : 0,
                totalNanos: i % 50 == 0 ? 12 * Self.ms + 400 * Self.us : 400 * Self.us), nowNanos: 0)
        }
        let summary = stats.summary()
        #expect(summary.cycles == 100)
        #expect(summary.overruns == 2)
        #expect(summary[.sync] == IOCycleStats.StageSummary(count: 2, p50Nanos: 12 * Self.ms, p99Nanos: 12 * Self.ms, maxNanos: 12 * Self.ms))
        #expect(summary[.pad].count == 0)

        let detail = summary.asDetail(prefix: "remote_io")
        #expect(detail["remote_io_cycles"] == "100")
        #expect(detail["remote_io_overruns"] == "2")
        #expect(detail["remote_io_sync_n"] == "2")
        #expect(detail["remote_io_sync_p50_ms"] == "12.000")
        #expect(detail["remote_io_sync_p99_ms"] == "12.000")
        #expect(detail["remote_io_sync_max_ms"] == "12.000")
        #expect(detail["remote_io_queue_wait_n"] == "100")
        #expect(detail["remote_io_queue_wait_max_ms"] == "0.020")
        #expect(detail["remote_io_total_n"] == "100")
        #expect(detail["remote_io_total_max_ms"] == "12.400")
        // 400 µs is in [393.216, 458.752) µs.
        #expect(detail["remote_io_total_p50_ms"] == "0.458")
        #expect(detail["remote_io_total_p99_ms"] == "12.400")
        // The pad never ran: left out, never a claimed 0.
        #expect(detail.keys.contains { $0.hasPrefix("remote_io_pad") } == false)
        // cycles + overruns + 4 keys for each of the 5 stages that ran.
        #expect(detail.count == 2 + 4 * 5)
    }

    @Test func aTrackWithNoCyclesAddsNothingToTheStopSummary() {
        #expect(IOCycleStats().summary().asDetail(prefix: "local_io").isEmpty)
        #expect(IOCycleStats().summary().logLine == nil)
    }

    @Test func theLogLineNamesEveryMeasuredStageInMilliseconds() throws {
        var stats = IOCycleStats()
        stats.record(IOCycleStats.Cycle(convertNanos: 300 * Self.us, writeNanos: 90 * Self.us,
                                        syncNanos: 31_400 * Self.us, totalNanos: 31_900 * Self.us), nowNanos: 0)
        let line = try #require(stats.summary().logLine)
        #expect(line == "cycles=1 overruns=1 (over 8.000 ms) | convert n=1 p50=0.300 p99=0.300 max=0.300 | write n=1 p50=0.090 p99=0.090 max=0.090 | sync n=1 p50=31.400 p99=31.400 max=31.400 | total n=1 p50=31.900 p99=31.900 max=31.900 (ms)")
    }

    /// The summary rides in `captureStop` next to the coverage keys, which the app parses by prefix:
    /// `remote_io_*` must not be read as, or shadow, a `remote_*` coverage value.
    @Test func theStopSummaryDoesNotDisturbTheCoverageInTheSameEvent() throws {
        var remote = TrackAccounting()
        remote.expectedSeconds = 120
        remote.deliveredSeconds = 118.5
        remote.heartbeatCallbacks = 11_250
        remote.exactZeroSeconds = 3
        remote.rebuilds = 1
        var local = TrackAccounting()
        local.expectedSeconds = 120
        local.deliveredSeconds = 120
        local.heartbeatCallbacks = 5_600
        local.exactZeroSeconds = 0

        var stats = IOCycleStats()
        for _ in 0..<500 { stats.record(IOCycleStats.Cycle(queueWaitNanos: 9 * Self.ms, totalNanos: 9 * Self.ms + 300 * Self.us), nowNanos: 0) }
        var detail = remote.asDetail(prefix: "remote").merging(local.asDetail(prefix: "local")) { a, _ in a }
        let coverageKeys = Set(detail.keys)
        let io = stats.summary().asDetail(prefix: "remote_io").merging(stats.summary().asDetail(prefix: "local_io")) { a, _ in a }
        #expect(coverageKeys.isDisjoint(with: io.keys))
        detail.merge(io) { a, _ in a }
        detail["helper_session"] = "1790000000123-0"

        #expect(TrackAccounting(detail: detail, prefix: "remote") == remote)
        #expect(TrackAccounting(detail: detail, prefix: "local") == local)

        var ring = CaptureDiagnostics()
        ring.record(CaptureEvent(timestamp: Date(), origin: .helper, kind: .captureStop, severity: .info, detail: detail))
        let provenance = ring.makeProvenance(engine: "fluid", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(provenance.remoteCoverage == remote)
        #expect(provenance.localCoverage == local)
        #expect(provenance.remoteStatus == TrackAccounting.Status.healthy.rawValue)
        #expect(ring.isAnomalous == false, "a stop summary alone is not an anomaly")
    }
}

/// Counts the malloc-family calls (allocations, reallocations and frees) made on the calling thread
/// while a block runs, through libmalloc's `malloc_logger` hook. The hook is a C function with no
/// context, so its state lives in three preallocated globals, and it does nothing but compare and
/// increment. The previous hook is restored afterwards.
private enum AllocationCounter {
    private typealias Hook = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    struct HookUnavailable: Error {}

    static func count(_ body: () -> Void) throws -> Int {
        guard let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?
            .assumingMemoryBound(to: Hook?.self) else { throw HookUnavailable() }
        // Every global the hook reads is touched BEFORE it is installed: a global's first read runs
        // its lazy initialiser, which allocates, and that must not happen inside the hook.
        pthread_threadid_np(nil, allocationCounterThread)
        allocationCounterCalls.pointee = 0
        allocationCounterArmed.pointee = false
        let previous = slot.pointee
        slot.pointee = { _, _, _, _, _, _ in
            guard allocationCounterArmed.pointee else { return }
            var thread: UInt64 = 0
            pthread_threadid_np(nil, &thread)
            if thread == allocationCounterThread.pointee { allocationCounterCalls.pointee += 1 }
        }
        allocationCounterArmed.pointee = true
        body()
        allocationCounterArmed.pointee = false
        slot.pointee = previous
        return allocationCounterCalls.pointee
    }
}

private let allocationCounterCalls: UnsafeMutablePointer<Int> = {
    let p = UnsafeMutablePointer<Int>.allocate(capacity: 1); p.initialize(to: 0); return p
}()
private let allocationCounterArmed: UnsafeMutablePointer<Bool> = {
    let p = UnsafeMutablePointer<Bool>.allocate(capacity: 1); p.initialize(to: false); return p
}()
private let allocationCounterThread: UnsafeMutablePointer<UInt64> = {
    let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1); p.initialize(to: 0); return p
}()
