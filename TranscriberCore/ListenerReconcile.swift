import Foundation

/// The pure set bookkeeping behind `MeetingSensor`'s Core Audio property listeners (#118), factored out
/// of the sensor so it can be unit-tested without a HAL.
///
/// The sensor holds listeners on a changing population of objects (input devices come and go; so do the
/// process objects of the watched meeting apps). Deciding which objects are wanted, and which of those
/// are newly wanted or no longer wanted, is a set diff — that part is pure, so it lives here.
///
/// This is deliberately NOT the whole leak story: whether a registration is actually recorded or
/// actually released depends on the `OSStatus` handling around the Add/Remove calls in `MeetingSensor`,
/// which no unit test can reach and only the device test can settle.
public enum ListenerReconcile {
    /// What to change to move a set of registrations from `current` to `desired`.
    public struct Plan<Object: Hashable> {
        /// Objects to register a listener on (none of them already registered).
        public let add: Set<Object>
        /// Objects to unregister (all of them currently registered).
        public let remove: Set<Object>
        public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    }

    /// `add` = newly desired, `remove` = no longer desired, everything else untouched. An empty
    /// `desired` removes every registration — which is what a full teardown relies on.
    public static func plan<Object: Hashable>(current: Set<Object>, desired: Set<Object>) -> Plan<Object> {
        Plan(add: desired.subtracting(current), remove: current.subtracting(desired))
    }

    /// The process objects that should carry a per-process listener: those whose bundle ID is in
    /// `watched`. Several process objects can share one bundle ID (an app and its audio helper each
    /// connect to the HAL), and all of them are targeted — missing one means missing the moment the app
    /// lets go of the microphone. An empty `watched` yields no targets, so a cleared watch really does
    /// unregister everything.
    ///
    /// A process whose bundle ID could not be read is recorded as `""` by the sensor; it never matches,
    /// so a stray `""` in `watched` can't turn every unidentifiable process into a listener target.
    public static func watchTargets<Object: Hashable>(
        processBundleIDs: [Object: String],
        watched: Set<String>
    ) -> Set<Object> {
        guard !watched.isEmpty else { return [] }
        return Set(processBundleIDs.compactMap {
            !$0.value.isEmpty && watched.contains($0.value) ? $0.key : nil
        })
    }
}
