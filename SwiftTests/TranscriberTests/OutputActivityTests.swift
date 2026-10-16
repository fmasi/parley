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

    /// §4.1: the probe fails OPEN — a process whose IsRunningOutput could not be read counts as
    /// running (a missed alarm is worse than a check), except our own pid, which never opens the gate.
    @Test func anUnreadableProcessOpensTheGateUnlessItIsOurs() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 2430, isRunningOutput: nil, outputDevices: [])], ownPid: 99))
        #expect(OutputActivity.othersRunningOutput([P(pid: 99, isRunningOutput: nil, outputDevices: [])], ownPid: 99) == false)
    }

    // MARK: - Lean probe (H review round 1): the 1 Hz probe reads IsRunningOutput first, the pid only
    // for a process that runs output (or whose state is unreadable), and stops at the first OTHER one.

    /// Which process indices each read touched, so a test can see what the probe did NOT read.
    private final class Reads { var running: [Int] = []; var pid: [Int] = [] }

    private func lean(_ procs: [(pid: Int32?, running: Bool?)]?, reads: Reads = Reads()) -> Bool {
        OutputActivity.othersRunningOutput(
            processes: procs.map { Array($0.indices) }, ownPid: 99,
            isRunningOutput: { i in reads.running.append(i); return procs![i].running },
            pid: { i in reads.pid.append(i); return procs![i].pid })
    }

    @Test func leanProbeStopsAtTheFirstOtherProcessRunningOutput() {
        let reads = Reads()
        #expect(lean([(10, false), (2430, true), (11, true), (12, nil)], reads: reads))
        #expect(reads.running == [0, 1], "short-circuits on the first other running process")
        #expect(reads.pid == [1], "never reads the pid of a process that is not running output")
    }

    @Test func leanProbeSkipsOurOwnRunningAggregate() {
        #expect(lean([(99, true)]) == false)
        #expect(lean([(99, true), (10, true)]))
    }

    @Test func leanProbeFailsOpenExceptOnOurOwnPid() {
        #expect(lean(nil), "an unreadable process list counts as running")
        #expect(lean([(2430, nil)]), "another process whose state can't be read counts as running")
        #expect(lean([(nil, true)]), "a running process whose pid can't be read is not known to be us")
        #expect(lean([(99, nil)]) == false, "our own unreadable state never opens the gate")
    }

    @Test func leanProbeWithNobodyRunningIsClosed() {
        #expect(lean([(10, false), (11, false)]) == false)
        #expect(lean([]) == false)
    }
}
