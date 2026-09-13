import Testing
import Foundation
// Deliberately NOT @testable: ResumeOnce is used from the app target (CalendarService, #197),
// so this suite pins its public surface as well as its resume-once behaviour.
import TranscriberCore

@Suite("ResumeOnce")
struct ResumeOnceTests {
    @Test func firstResumeWins() async {
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = ResumeOnce(continuation)
            once.resume(1)
            once.resume(2)
        }
        #expect(value == 1)
    }

    @Test func laterResumesAreNoOps() async {
        // A second resume of an already-resumed CheckedContinuation traps, so surviving the
        // extra calls at all is the assertion; the value just confirms which one landed.
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            let resumed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                once.resume("work")
                resumed.signal()
            }
            resumed.wait()     // ordering, not a sleep: no CI load can flip which resume is first
            once.resume(nil)   // the "deadline" path, arriving second
        }
        #expect(value == "work")
    }

    @Test func racingResumesResumeExactlyOnce() async {
        // Many threads racing the same continuation: exactly one resume must get through.
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                once.resume(index)
            }
        }
        // As above, the assertion that matters is that this returns at all: a second resume of an
        // already-resumed CheckedContinuation traps. The value only confirms a real resume landed.
        #expect(value >= 0 && value < 16)
    }
}
