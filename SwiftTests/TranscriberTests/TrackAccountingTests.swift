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
        let keys = Set(TrackAccounting().asMetadataDictionary(status: .healthy).keys)
        #expect(keys == ["status", "expected_seconds", "delivered_seconds", "exact_zero_seconds",
                          "padded_seconds", "longest_gap_seconds", "gap_count", "rebuilds", "heartbeat_callbacks"])
    }
}
