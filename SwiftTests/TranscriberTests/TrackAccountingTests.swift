import Foundation
import Testing
@testable import TranscriberCore

/// §7.1: the record says per side how much was expected and delivered. Incident B's provenance
/// said `system_delivered_seconds 0, anomaly_count 0` and nothing about 2736 s of expected output.
@Suite struct TrackAccountingTests {
    @Test func nothingExpectedNothingDeliveredIsIdleForTheTap() {
        var a = TrackAccounting()
        a.expectedSeconds = 0.4
        #expect(a.status(isTap: true, contentAnomalies: 0) == .idle)
        #expect(a.status(isTap: false, contentAnomalies: 0) == .healthy, "the mic is always expected; a 0.4 s session is just short")
    }

    /// Incident B.
    @Test func expectedButNeverDeliveredIsNeverDelivered() {
        var a = TrackAccounting()
        a.expectedSeconds = 2736
        #expect(a.status(isTap: true, contentAnomalies: 0) == .neverDelivered)
    }

    @Test func aDeficitOfTenPercentAndFifteenSecondsIsCompromised() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 84
        #expect(a.status(isTap: true, contentAnomalies: 0) == .compromised)
        a.deliveredSeconds = 91
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "9 % short: within tolerance")
        a.expectedSeconds = 60; a.deliveredSeconds = 50
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "10 s short: under the 15 s floor")
    }

    @Test func aContentAnomalyIsCompromisedRegardlessOfCoverage() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 100
        #expect(a.status(isTap: false, contentAnomalies: 1) == .compromised)
    }

    /// Review focus 5: the probe failed open / TapAutoStart=false zeros — frames without a gate.
    @Test func deliveredWithNothingExpectedIsHealthyNotIdle() {
        var a = TrackAccounting()
        a.deliveredSeconds = 30
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy)
    }

    @Test func detailRoundTripsAndSums() throws {
        var a = TrackAccounting()
        a.expectedSeconds = 10; a.deliveredSeconds = 9.5; a.exactZeroSeconds = 1; a.paddedSeconds = 0.5
        a.longestGapSeconds = 3; a.gapCount = 1; a.rebuilds = 2; a.heartbeatCallbacks = 940
        let back = try #require(TrackAccounting(detail: a.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(back == a)
        var sum = a; sum += back
        #expect(sum.expectedSeconds == 20 && sum.rebuilds == 4 && sum.longestGapSeconds == 3)
        #expect(TrackAccounting(detail: [:], prefix: "remote") == nil)
    }

    // MARK: - Fix round 1

    /// Review fix 1 [Important]: a never-delivered track must read `.neverDelivered`, not
    /// `.compromised`, even when a content anomaly is also present on it — otherwise R1 prints
    /// "partly captured (0 s delivered…)" for a side that captured nothing at all.
    @Test func neverDeliveredTakesPrecedenceOverContentAnomaly() {
        var a = TrackAccounting()
        a.expectedSeconds = 2736
        #expect(a.status(isTap: true, contentAnomalies: 1) == .neverDelivered)
    }

    /// Review fix 2 [Important, controller ruling]: 0 delivered with ≥1 s expected is
    /// `.neverDelivered` on BOTH tracks — "never healthy when nothing was captured while audio was
    /// expected". Below 1 s the existing startup window still applies (tap `.idle`, mic `.healthy`);
    /// the old 5 s debounce belonged to the live alarm, not to this after-the-fact record.
    @Test func zeroDeliveredAtOrAboveOneSecondExpectedIsNeverDeliveredOnBothTracks() {
        for isTap in [true, false] {
            var underOneSecond = TrackAccounting()
            underOneSecond.expectedSeconds = 0.9
            #expect(underOneSecond.status(isTap: isTap, contentAnomalies: 0) == (isTap ? .idle : .healthy),
                    "under 1 s keeps the existing startup window (isTap: \(isTap))")

            for expected in [3.0, 5.0] {
                var a = TrackAccounting()
                a.expectedSeconds = expected
                #expect(a.status(isTap: isTap, contentAnomalies: 0) == .neverDelivered,
                        "expected \(expected) s, 0 delivered, isTap: \(isTap)")
            }
        }
    }

    /// Review fix 3 [Important, controller ruling: crash risk]: a non-finite value reaching
    /// `asMetadataDictionary` via `JSONSerialization` raises an uncatchable ObjC exception — reject
    /// it at the parse boundary instead.
    @Test func nonFiniteDetailValuesAreRejected() {
        #expect(TrackAccounting(detail: ["remote_expected_seconds": "10", "remote_delivered_seconds": "nan"], prefix: "remote") == nil)
        #expect(TrackAccounting(detail: ["remote_expected_seconds": "inf"], prefix: "remote") == nil)
        #expect(TrackAccounting(detail: ["remote_expected_seconds": "-inf"], prefix: "remote") == nil)
    }

    /// Review fix 4: pin the exact key set R1 parses by name. Characterization test — the keys
    /// were already correct, no implementation change was needed for this one.
    @Test func metadataDictionaryKeysArePinned() {
        var measured = TrackAccounting()
        measured.exactZeroSeconds = 0; measured.heartbeatCallbacks = 0
        let keys = Set(measured.asMetadataDictionary(status: .healthy).keys)
        #expect(keys == ["status", "expected_seconds", "delivered_seconds", "exact_zero_seconds",
                          "padded_seconds", "longest_gap_seconds", "gap_count", "rebuilds", "heartbeat_callbacks"])
    }

    // MARK: - R2 council (XI bug 1, C-M10): unmeasured is not a measured 0

    /// SCK measures neither exact zeros nor tap callbacks; the helper omits both keys. They stay nil
    /// through parse, sum, detail and metadata — never a claimed 0.
    @Test func unmeasuredZerosAndCallbacksStayUnmeasured() throws {
        let sck = try #require(TrackAccounting(detail: ["remote_expected_seconds": "600", "remote_delivered_seconds": "600"], prefix: "remote"))
        #expect(sck.exactZeroSeconds == nil && sck.heartbeatCallbacks == nil)
        #expect(sck.asDetail(prefix: "remote")["remote_exact_zero_seconds"] == nil)
        #expect(sck.asDetail(prefix: "remote")["remote_heartbeat_callbacks"] == nil)
        let metadata = sck.asMetadataDictionary(status: .healthy)
        #expect(metadata["exact_zero_seconds"] == nil && metadata["heartbeat_callbacks"] == nil)
        var twoSessions = sck; twoSessions += sck
        #expect(twoSessions.exactZeroSeconds == nil && twoSessions.heartbeatCallbacks == nil && twoSessions.expectedSeconds == 1200)
        #expect(TrackAccounting().exactZeroSeconds == nil, "a fresh counter has measured nothing")
    }

    /// A measured value summed with an unmeasured session keeps what was measured (a lower bound on
    /// the silence, never an invented one); a measured 0 stays 0.
    @Test func aMeasuredValuePlusAnUnmeasuredOneKeepsTheMeasurement() throws {
        var tap = TrackAccounting(); tap.expectedSeconds = 600; tap.exactZeroSeconds = 42; tap.heartbeatCallbacks = 60_000
        var sum = tap
        sum += try #require(TrackAccounting(detail: ["remote_expected_seconds": "300"], prefix: "remote"))
        #expect(sum.exactZeroSeconds == 42 && sum.heartbeatCallbacks == 60_000 && sum.expectedSeconds == 900)
        var zero = TrackAccounting(); zero.expectedSeconds = 1; zero.exactZeroSeconds = 0
        #expect(TrackAccounting(detail: zero.asDetail(prefix: "local"), prefix: "local")?.exactZeroSeconds == 0)
    }

    /// C-M7: synthesized Decodable required every key, so a field added later made an older
    /// session.json undecodable (and recovery drops an undecodable session). Absent keys decode.
    @Test func legacyAndMinimalJsonDecodes() throws {
        let minimal = try JSONDecoder().decode(TrackAccounting.self, from: Data(#"{"expectedSeconds": 12}"#.utf8))
        #expect(minimal.expectedSeconds == 12 && minimal.deliveredSeconds == 0 && minimal.exactZeroSeconds == nil)
        let legacy = try JSONDecoder().decode(TrackAccounting.self, from: Data(#"{"expectedSeconds":10,"heartbeatCallbacks":5,"deliveredSeconds":9,"exactZeroSeconds":1,"paddedSeconds":0,"longestGapSeconds":0,"gapCount":0,"rebuilds":0,"fromTheFuture":true}"#.utf8))
        #expect(legacy.exactZeroSeconds == 1 && legacy.heartbeatCallbacks == 5)
        var a = TrackAccounting(); a.expectedSeconds = 3; a.exactZeroSeconds = 2
        #expect(try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(a)) == a)
    }

    /// C-M12: a tap that was never expected (nothing played) and delivered only exact zeros was
    /// "healthy"; nothing played on this Mac, so it is idle. Real audio, or unmeasured zeros, keep it
    /// healthy; a content anomaly still wins.
    @Test func aNeverExpectedTapOfOnlyZerosIsIdle() {
        var zeros = TrackAccounting(); zeros.expectedSeconds = 0.4; zeros.deliveredSeconds = 30; zeros.exactZeroSeconds = 30
        #expect(zeros.status(isTap: true, contentAnomalies: 0) == .idle)
        #expect(zeros.status(isTap: false, contentAnomalies: 0) == .healthy, "a mic is never idle")
        #expect(zeros.status(isTap: true, contentAnomalies: 1) == .compromised)
        var real = zeros; real.exactZeroSeconds = 12
        #expect(real.status(isTap: true, contentAnomalies: 0) == .healthy)
        var unmeasured = zeros; unmeasured.exactZeroSeconds = nil
        #expect(unmeasured.status(isTap: true, contentAnomalies: 0) == .healthy)
    }

    /// R2b item 8: a sum of a measured session and an unmeasured one is a lower bound, and says so —
    /// in the detail, the metadata and the provenance (whose bare integer is then left out).
    @Test func aMixedSumIsMarkedAsALowerBound() throws {
        var tap = TrackAccounting(); tap.expectedSeconds = 600; tap.deliveredSeconds = 600; tap.exactZeroSeconds = 42; tap.heartbeatCallbacks = 6
        var sum = tap
        sum += try #require(TrackAccounting(detail: ["remote_expected_seconds": "300", "remote_delivered_seconds": "300"], prefix: "remote"))
        #expect(sum.exactZeroSeconds == 42 && sum.exactZeroIsLowerBound && sum.heartbeatCallbacksIsLowerBound)
        let metadata = sum.asMetadataDictionary(status: .healthy)
        #expect(metadata["exact_zero_seconds_is_lower_bound"] as? Bool == true && metadata["heartbeat_callbacks_is_lower_bound"] as? Bool == true)
        let back = try #require(TrackAccounting(detail: sum.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(back == sum, "the mark survives the helper-to-app wire")
        var measuredTwice = tap; measuredTwice += tap
        #expect(!measuredTwice.exactZeroIsLowerBound && measuredTwice.asMetadataDictionary(status: .healthy)["exact_zero_seconds_is_lower_bound"] == nil)
        let decoded = try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(sum))
        #expect(decoded.exactZeroIsLowerBound)

        var diagnostics = CaptureDiagnostics()
        for (i, side) in [tap, try #require(TrackAccounting(detail: ["remote_expected_seconds": "300", "remote_delivered_seconds": "300"], prefix: "remote"))].enumerated() {
            diagnostics.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: Double(i)), origin: .helper, kind: .captureStop, severity: .info,
                                            detail: side.asDetail(prefix: "remote")))
        }
        let p = diagnostics.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.systemExactZeroSeconds == nil, "the bare integer can't carry the mark: left out")
        #expect((p.asMetadataDictionary()["remote_coverage"] as? [String: Any])?["exact_zero_seconds_is_lower_bound"] as? Bool == true)
    }

    /// Final review R-M1: a `captureStop` whose seal timed out carries `coverage_incomplete` (last-tick counts, ≤ 1 s stale):
    /// the seconds are a lower bound, and the record says so — never stamped as exact. The key is not prefixed (it is the
    /// stop's, for both sides).
    @Test func coverageIncompleteIsCarriedAsALowerBound() throws {
        let stale = try #require(TrackAccounting(detail: ["remote_expected_seconds": "300", "remote_delivered_seconds": "290",
                                                          "coverage_incomplete": "true"], prefix: "remote"))
        #expect(stale.coverageIncomplete)
        #expect(stale.asMetadataDictionary(status: .healthy)["coverage_incomplete"] as? Bool == true)
        let complete = try #require(TrackAccounting(detail: ["remote_expected_seconds": "600", "remote_delivered_seconds": "600"], prefix: "remote"))
        #expect(!complete.coverageIncomplete && complete.asMetadataDictionary(status: .healthy)["coverage_incomplete"] == nil,
                "absent: never an invented mark")
        var sum = complete; sum += stale
        #expect(sum.coverageIncomplete && sum.expectedSeconds == 900, "a sum with an incomplete session is incomplete")
        var other = stale; other += complete
        #expect(other.coverageIncomplete)
        let decoded = try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(sum))
        #expect(decoded.coverageIncomplete, "session.json keeps the mark")
        #expect(try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(complete)).coverageIncomplete == false)

        // Through the record: the stop's mark reaches `capture_provenance.<side>_coverage`, whichever session it was.
        var diagnostics = CaptureDiagnostics()
        let stops: [[String: String]] = [complete.asDetail(prefix: "remote"),
                                         stale.asDetail(prefix: "remote").merging(["coverage_incomplete": "true"]) { $1 }]
        for (i, detail) in stops.enumerated() {
            diagnostics.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: Double(i)), origin: .helper, kind: .captureStop,
                                            severity: .info, detail: detail))
        }
        let p = diagnostics.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect((p.asMetadataDictionary()["remote_coverage"] as? [String: Any])?["coverage_incomplete"] as? Bool == true)
    }

    // MARK: - Unproven zeros (#333 R3)

    /// The 2026-10-13 call: 571 s of exact zeros on a tap that had delivered real audio (a call app
    /// renders digital silence while the other side is quiet), about 2 s of them before its first
    /// real audio. The record carries both numbers, on the wire, in session.json and in the transcript.
    @Test func unprovenZerosTravelBesideTheTotal() throws {
        var a = TrackAccounting()
        a.expectedSeconds = 3952; a.deliveredSeconds = 3952; a.exactZeroSeconds = 571; a.exactZeroUnprovenSeconds = 2
        let detail = a.asDetail(prefix: "remote")
        #expect(detail["remote_exact_zero_unproven_seconds"] == "2.0" && detail["remote_exact_zero_seconds"] == "571.0")
        #expect(try #require(TrackAccounting(detail: detail, prefix: "remote")) == a, "the helper-to-app wire")
        #expect(try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(a)) == a, "session.json")
        let metadata = a.asMetadataDictionary(status: .healthy)
        #expect(metadata["exact_zero_unproven_seconds"] as? Double == 2 && metadata["exact_zero_seconds"] as? Double == 571)
        var sum = a; sum += a
        #expect(sum.exactZeroUnprovenSeconds == 4 && sum.exactZeroSeconds == 1142 && !sum.exactZeroIsLowerBound)
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "the status never reads it")
    }

    /// Same rules as the total: absent = not measured (SCK has no guard; an older helper or an older
    /// session.json never wrote it), never a claimed 0, and a measured 0 stays a 0.
    @Test func unmeasuredUnprovenZerosStayUnmeasured() throws {
        let older = try #require(TrackAccounting(detail: ["remote_expected_seconds": "600", "remote_delivered_seconds": "600",
                                                          "remote_exact_zero_seconds": "42.0"], prefix: "remote"))
        #expect(older.exactZeroSeconds == 42 && older.exactZeroUnprovenSeconds == nil)
        #expect(older.asDetail(prefix: "remote")["remote_exact_zero_unproven_seconds"] == nil)
        #expect(older.asMetadataDictionary(status: .healthy)["exact_zero_unproven_seconds"] == nil)
        var twice = older; twice += older
        #expect(twice.exactZeroUnprovenSeconds == nil && twice.exactZeroSeconds == 84 && !twice.exactZeroIsLowerBound)
        #expect(TrackAccounting().exactZeroUnprovenSeconds == nil, "a fresh counter has measured nothing")
        let legacy = try JSONDecoder().decode(TrackAccounting.self, from: Data(#"{"expectedSeconds":10,"deliveredSeconds":9,"exactZeroSeconds":1}"#.utf8))
        #expect(legacy.exactZeroSeconds == 1 && legacy.exactZeroUnprovenSeconds == nil, "an older session.json still decodes")

        var zero = TrackAccounting(); zero.expectedSeconds = 1; zero.exactZeroSeconds = 5; zero.exactZeroUnprovenSeconds = 0
        let back = try #require(TrackAccounting(detail: zero.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(back.exactZeroUnprovenSeconds == 0)
        #expect(back.asMetadataDictionary(status: .healthy)["exact_zero_unproven_seconds"] as? Double == 0)
        #expect(try JSONDecoder().decode(TrackAccounting.self, from: JSONEncoder().encode(zero)).exactZeroUnprovenSeconds == 0)
    }

    /// A non-finite value is rejected at the parse boundary, like every other Double of the record
    /// (`JSONSerialization` raises an uncatchable exception on one).
    @Test func aNonFiniteUnprovenValueIsRejected() {
        for bad in ["nan", "inf", "-inf"] {
            #expect(TrackAccounting(detail: ["remote_expected_seconds": "10", "remote_exact_zero_seconds": "1.0",
                                             "remote_exact_zero_unproven_seconds": bad], prefix: "remote") == nil)
        }
    }

    /// The unproven seconds share the total's lower-bound mark: summed with a session that did not
    /// measure them (an SCK session, or a tap session recorded before the field existed), the sum is
    /// at least that much, and the record says so with the mark it already has.
    @Test func aMixedSumOfUnprovenZerosIsMarkedAsALowerBound() throws {
        var tap = TrackAccounting(); tap.expectedSeconds = 600; tap.deliveredSeconds = 600
        tap.exactZeroSeconds = 42; tap.exactZeroUnprovenSeconds = 30; tap.heartbeatCallbacks = 6
        let sck = try #require(TrackAccounting(detail: ["remote_expected_seconds": "300", "remote_delivered_seconds": "300"], prefix: "remote"))
        for sum in [{ var s = tap; s += sck; return s }(), { var s = sck; s += tap; return s }()] as [TrackAccounting] {
            #expect(sum.exactZeroUnprovenSeconds == 30 && sum.exactZeroSeconds == 42 && sum.exactZeroIsLowerBound)
        }
        var older = tap; older.exactZeroUnprovenSeconds = nil
        var mixed = tap; mixed += older
        #expect(mixed.exactZeroUnprovenSeconds == 30 && mixed.exactZeroSeconds == 84)
        #expect(mixed.exactZeroIsLowerBound, "one session never said how much of its silence was unproven")
        let wire = try #require(TrackAccounting(detail: mixed.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(wire == mixed)
    }

    /// Through the record: a `captureStop`, and a crashed helper's stand-in (its last status pull,
    /// #295), both put the unproven seconds into `capture_provenance.remote_coverage`. Without the
    /// stand-in carrying it, a crash-recovered record would fall back to judging the total.
    @Test func unprovenZerosReachTheRecordFromAStopAndFromAStandIn() throws {
        var stopped = TrackAccounting(); stopped.expectedSeconds = 600; stopped.deliveredSeconds = 600
        stopped.exactZeroSeconds = 90; stopped.exactZeroUnprovenSeconds = 2
        var crashed = stopped; crashed.exactZeroSeconds = 300; crashed.exactZeroUnprovenSeconds = 25
        var diagnostics = CaptureDiagnostics()
        diagnostics.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 0), origin: .helper, kind: .captureStop, severity: .info,
                                        detail: stopped.asDetail(prefix: "remote").merging(["helper_session": "1000-0"]) { $1 }))
        diagnostics.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .helper, kind: .captureStop, severity: .info,
                                        detail: crashed.asDetail(prefix: "remote").merging(["helper_session": "2000-0", "from": CaptureDiagnostics.standInSource]) { $1 }))
        let p = diagnostics.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteCoverage?.exactZeroUnprovenSeconds == 27 && p.remoteCoverage?.exactZeroSeconds == 390)
        let remote = try #require(p.asMetadataDictionary()["remote_coverage"] as? [String: Any])
        #expect(remote["exact_zero_unproven_seconds"] as? Double == 27)
    }
}
