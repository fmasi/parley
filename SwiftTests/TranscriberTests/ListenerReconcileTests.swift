import Testing
@testable import TranscriberCore

/// The pure half of `MeetingSensor`'s HAL listener bookkeeping (#118): which objects are wanted, and
/// which of them are newly wanted or no longer wanted. Whether a registration is really held or really
/// released also depends on the `OSStatus` handling around the Core Audio calls in the app target, which
/// these tests cannot reach — that part is device-verified, not covered here.
@Suite("ListenerReconcile")
struct ListenerReconcileTests {
    @Test("adds what is newly desired, removes what is no longer desired, leaves the rest alone")
    func diff() {
        let plan = ListenerReconcile.plan(current: [1, 2, 3], desired: [2, 3, 4])
        #expect(plan.add == [4])
        #expect(plan.remove == [1])
    }

    @Test("an empty desired set removes every registered listener")
    func desiredEmptyRemovesAll() {
        // The property `stop()` and `setWatched(bundleIDs: [])` both rely on: when the engine goes quiet
        // (including mode .off while recording, where it emits no `.watch` at all), nothing stays armed.
        let plan = ListenerReconcile.plan(current: [7, 8, 9], desired: Set<Int>())
        #expect(plan.add.isEmpty)
        #expect(plan.remove == [7, 8, 9])
    }

    @Test("an empty current set adds everything and removes nothing")
    func currentEmptyAddsAll() {
        let plan = ListenerReconcile.plan(current: Set<Int>(), desired: [1, 2])
        #expect(plan.add == [1, 2])
        #expect(plan.remove.isEmpty)
    }

    @Test("identical sets are a no-op")
    func noChange() {
        let plan = ListenerReconcile.plan(current: [1, 2], desired: [1, 2])
        #expect(plan.isEmpty)
    }

    @Test("add and remove are always disjoint, and stay within their source sets")
    func invariants() {
        let cases: [(Set<Int>, Set<Int>)] = [
            ([], []), ([1], []), ([], [1]), ([1, 2, 3], [3, 4, 5]), ([1, 2], [1, 2]), ([5], [6]),
        ]
        for (current, desired) in cases {
            let plan = ListenerReconcile.plan(current: current, desired: desired)
            #expect(plan.add.isDisjoint(with: plan.remove))
            #expect(plan.add.isSubset(of: desired))       // never register for something unwanted
            #expect(plan.remove.isSubset(of: current))    // never remove a listener we never added
            #expect(current.subtracting(plan.remove).union(plan.add) == desired)
        }
    }

    @Test("watch targets are the process objects whose bundle ID is watched")
    func watchTargets() {
        let processes = [10: "us.zoom.xos", 11: "com.apple.Safari", 12: "us.zoom.xos.helper"]
        #expect(ListenerReconcile.watchTargets(processBundleIDs: processes,
                                               watched: ["us.zoom.xos"]) == [10])
        // Several process objects can share one watched bundle ID (an app and its helper each connect to
        // the HAL); every one of them must be listened to, or the release of the last is missed.
        #expect(ListenerReconcile.watchTargets(processBundleIDs: processes,
                                               watched: ["us.zoom.xos", "us.zoom.xos.helper"]) == [10, 12])
    }

    @Test("no watched bundle IDs means no per-process listeners")
    func watchTargetsEmpty() {
        let processes = [10: "us.zoom.xos", 11: "com.apple.Safari"]
        #expect(ListenerReconcile.watchTargets(processBundleIDs: processes, watched: []).isEmpty)
    }

    @Test("a watched bundle ID with no live process yields no target")
    func watchTargetsVanished() {
        // The Process object went away between scans: it simply drops out of the target set, and the diff
        // above then removes its listener.
        #expect(ListenerReconcile.watchTargets(processBundleIDs: [11: "com.apple.Safari"],
                                               watched: ["us.zoom.xos"]).isEmpty)
        #expect(ListenerReconcile.watchTargets(processBundleIDs: [:], watched: ["us.zoom.xos"]).isEmpty)
    }

    @Test("processes with an unreadable (empty) bundle ID are never targeted")
    func watchTargetsEmptyBundleID() {
        #expect(ListenerReconcile.watchTargets(processBundleIDs: [10: "", 11: "us.zoom.xos"],
                                               watched: ["", "us.zoom.xos"]) == [11])
    }
}
