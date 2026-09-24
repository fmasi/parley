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
}
