import Testing
import Foundation
@testable import TranscriberCore

struct SingleInstanceGuardTests {
    private func inst(_ pid: Int32, _ t: Double?) -> SingleInstanceGuard.Instance {
        SingleInstanceGuard.Instance(pid: pid, launchDate: t.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func singleInstanceNeverTerminates() {
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: [inst(100, 10)]) == false)
    }

    @Test func emptyListNeverTerminates() {
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: []) == false)
    }

    @Test func earliestSurvivesLaterTerminates() {
        let a = inst(100, 10)   // earliest
        let b = inst(200, 20)   // later
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: [a, b]) == false) // a survives
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 200, instances: [a, b]) == true)  // b exits
    }

    @Test func tieOnLaunchDateBreaksByLowestPid() {
        let a = inst(200, 10)
        let b = inst(100, 10)   // same date, lower pid → survivor
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: [a, b]) == false)
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 200, instances: [a, b]) == true)
    }

    @Test func nilLaunchDateSortsLast() {
        let dated = inst(200, 10)  // has a date → preferred survivor
        let undated = inst(100, nil)
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 200, instances: [dated, undated]) == false) // dated survives
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: [dated, undated]) == true)  // undated exits
    }

    @Test func bothNilFallBackToPid() {
        let a = inst(100, nil)   // lower pid → survivor
        let b = inst(200, nil)
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 100, instances: [a, b]) == false)
        #expect(SingleInstanceGuard.shouldTerminate(selfPid: 200, instances: [a, b]) == true)
    }

    @Test func exactlyOneSurvivesAcrossThreeInstances() {
        let insts = [inst(300, 30), inst(100, 10), inst(200, 20)]
        // Only pid 100 (earliest) survives; the other two terminate → exactly one survivor.
        let survives = [Int32(100), 200, 300].filter {
            !SingleInstanceGuard.shouldTerminate(selfPid: $0, instances: insts)
        }
        #expect(survives == [100])
    }
}
