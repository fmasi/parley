import Foundation

/// "Is any OTHER process rendering output right now?" — the only "expected to produce" rule for
/// the tap (§4.3). Process-level, so it is route-independent and sees per-app output devices;
/// excludes our own pid because the helper's own aggregate reports itself as running output.
public enum OutputActivity {
    public struct ProcessOutputState: Equatable, Sendable {
        public let pid: Int32
        public let isRunningOutput: Bool
        public let outputDevices: [UInt32]
        public init(pid: Int32, isRunningOutput: Bool, outputDevices: [UInt32]) {
            self.pid = pid; self.isRunningOutput = isRunningOutput; self.outputDevices = outputDevices
        }
    }

    public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool {
        states.contains { $0.pid != ownPid && $0.isRunningOutput }
    }
}
