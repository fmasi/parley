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
}
