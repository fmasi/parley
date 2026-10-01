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
}
