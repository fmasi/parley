import Testing
@testable import TranscriberCore

/// Q4.1 / H3b: the "is anything playing?" gate must be process-level and must exclude the helper
/// itself — the probe showed our own anchor-only aggregate reports `IsRunningOutput = 1`, and a
/// process on a non-default device is invisible to the old default-output check.
@Suite struct OutputActivityTests {
    typealias P = OutputActivity.ProcessOutputState

    @Test func nobodyRunningOutputIsClosed() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 10, isRunningOutput: false, outputDevices: [])], ownPid: 99) == false)
    }

    @Test func anotherProcessRunningOutputOpensTheGateWhateverTheDevice() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 2430, isRunningOutput: true, outputDevices: [84])], ownPid: 99))
    }

    /// run-own-aggregate.txt: pid 37097 (our probe) reported piro=1 outDevs=[84].
    @Test func ourOwnAggregateNeverOpensTheGate() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 99, isRunningOutput: true, outputDevices: [84])], ownPid: 99) == false)
    }

    @Test func emptyListIsClosed() {
        #expect(OutputActivity.othersRunningOutput([], ownPid: 99) == false)
    }
}
