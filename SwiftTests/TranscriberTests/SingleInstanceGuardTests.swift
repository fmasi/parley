import Foundation
import Testing
@testable import TranscriberCore

@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    typealias Instance = SingleInstanceGuard.Instance

    @Test("A lone instance never yields")
    func loneInstanceDoesNotYield() {
        let me = Instance(pid: 100, launchDate: Date(timeIntervalSince1970: 1000))
        #expect(SingleInstanceGuard.shouldYield(me: me, others: []) == false)
    }

    @Test("Yields when an older-by-date instance is running")
    func yieldsToOlderByDate() {
        let older = Instance(pid: 200, launchDate: Date(timeIntervalSince1970: 1000))
        let me = Instance(pid: 100, launchDate: Date(timeIntervalSince1970: 2000)) // later launch, lower PID
        // Date must win over PID: I launched later, so I yield even though my PID is lower.
        #expect(SingleInstanceGuard.shouldYield(me: me, others: [older]) == true)
    }

    @Test("Does not yield when the only other instance is younger")
    func doesNotYieldToYounger() {
        let younger = Instance(pid: 999, launchDate: Date(timeIntervalSince1970: 3000))
        let me = Instance(pid: 100, launchDate: Date(timeIntervalSince1970: 1000))
        #expect(SingleInstanceGuard.shouldYield(me: me, others: [younger]) == false)
    }

    @Test("Equal dates fall back to PID: lower PID survives")
    func equalDatesTieBreakOnPID() {
        let date = Date(timeIntervalSince1970: 1000)
        let lowerPID = Instance(pid: 50, launchDate: date)
        let higherPID = Instance(pid: 80, launchDate: date)
        // The higher-PID instance yields to the lower-PID one.
        #expect(SingleInstanceGuard.shouldYield(me: higherPID, others: [lowerPID]) == true)
        // The lower-PID instance does not yield to the higher-PID one.
        #expect(SingleInstanceGuard.shouldYield(me: lowerPID, others: [higherPID]) == false)
    }

    @Test("Nil launch dates fall back to PID ordering")
    func nilDatesTieBreakOnPID() {
        let a = Instance(pid: 10, launchDate: nil)
        let b = Instance(pid: 20, launchDate: nil)
        #expect(SingleInstanceGuard.shouldYield(me: b, others: [a]) == true)   // 20 yields to 10
        #expect(SingleInstanceGuard.shouldYield(me: a, others: [b]) == false)  // 10 keeps running
    }

    @Test("One known date beats a nil date via PID fallback, consistently both ways")
    func mixedNilAndKnownDateIsConsistent() {
        let withDate = Instance(pid: 30, launchDate: Date(timeIntervalSince1970: 1000))
        let noDate = Instance(pid: 10, launchDate: nil)
        // Comparison falls back to PID (10 < 30), so noDate is "older". Exactly one yields.
        let aYields = SingleInstanceGuard.shouldYield(me: withDate, others: [noDate])
        let bYields = SingleInstanceGuard.shouldYield(me: noDate, others: [withDate])
        #expect(aYields != bYields)
    }

    @Test("Exactly one survivor across a crowd of duplicates")
    func exactlyOneSurvivorInACrowd() {
        // Five instances with assorted dates/PIDs (all PIDs unique). Every instance evaluates the
        // guard against all the others; exactly one must NOT yield.
        let instances = [
            Instance(pid: 5, launchDate: Date(timeIntervalSince1970: 1000)),
            Instance(pid: 9, launchDate: Date(timeIntervalSince1970: 1000)), // date tie with pid 5
            Instance(pid: 3, launchDate: Date(timeIntervalSince1970: 1500)),
            Instance(pid: 42, launchDate: nil),
            Instance(pid: 7, launchDate: Date(timeIntervalSince1970: 900)),  // earliest date -> should survive
        ]
        let survivors = instances.filter { me in
            let others = instances.filter { $0.pid != me.pid }
            return SingleInstanceGuard.shouldYield(me: me, others: others) == false
        }
        #expect(survivors.count == 1)
        #expect(survivors.first?.pid == 7) // earliest launch date wins
    }
}
