import Testing
import Foundation
@testable import TranscriberCore

/// `ResumeOnce` guards every XPC call that must not hang (the permission checks, #220): the reply and
/// the deadline race, and whichever arrives first wins.
struct ResumeOnceTests {
    @Test func firstResumeWins() async {
        let value: Int? = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let once = ResumeOnce<Int?>(cont)
            once.resume(1)
            once.resume(2)   // a late deadline: must be a no-op, not a double-resume crash
            once.resume(nil)
        }
        #expect(value == 1)
    }

    @Test func deadlineWinsWhenTheWorkNeverReplies() async {
        let value: Int? = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let once = ResumeOnce<Int?>(cont)
            // A stalled helper: the reply never comes, only the deadline does.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { once.resume(nil) }
        }
        #expect(value == nil)
    }

    @Test func aLateReplyAfterTheDeadlineIsIgnored() async {
        let value: Int? = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let once = ResumeOnce<Int?>(cont)
            once.resume(nil)   // the deadline fired first
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { once.resume(42) }
        }
        #expect(value == nil)
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
