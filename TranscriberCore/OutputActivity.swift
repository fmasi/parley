import Foundation

/// "Is any OTHER process rendering output right now?" — the only "expected to produce" rule for
/// the tap (§4.3). Process-level, so it is route-independent and sees per-app output devices;
/// excludes our own pid because the helper's own aggregate reports itself as running output.
/// Fails OPEN (§4.1): a process whose state could not be read counts as running.
public enum OutputActivity {
    public struct ProcessOutputState: Equatable, Sendable {
        public let pid: Int32
        /// `kAudioProcessPropertyIsRunningOutput`; `nil` = the read failed.
        public let isRunningOutput: Bool?
        public let outputDevices: [UInt32]
        public init(pid: Int32, isRunningOutput: Bool?, outputDevices: [UInt32]) {
            self.pid = pid; self.isRunningOutput = isRunningOutput; self.outputDevices = outputDevices
        }
    }

    public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool {
        othersRunningOutput(processes: states, ownPid: ownPid, isRunningOutput: { $0.isRunningOutput }, pid: { $0.pid })
    }

    /// The same rule for the helper's 1 Hz probe, reading lazily (H review round 1: the full per-process
    /// read cost ~1 % of a core while recording). `isRunningOutput` is read first; the pid only for a
    /// process that runs output or whose state is unreadable; the scan stops at the first OTHER process
    /// running output — the gate needs one boolean. Fails OPEN: `processes == nil` (unreadable list), an
    /// unreadable state, or an unreadable pid all count as running, except a process known to be us.
    public static func othersRunningOutput<Process>(
        processes: [Process]?, ownPid: Int32,
        isRunningOutput: (Process) -> Bool?, pid: (Process) -> Int32?
    ) -> Bool {
        guard let processes else { return true }
        for process in processes where isRunningOutput(process) != false {
            if let id = pid(process), id == ownPid { continue }
            return true
        }
        return false
    }
}
