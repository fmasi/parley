import Foundation
import Testing
@testable import TranscriberCore

/// L review 90: a recovery pass that salvages several recordings opens their rename panels one at a time.
@MainActor
@Suite struct OneAtATimeQueueTests {
    @Test func itemsRunOneAtATimeInOrder() {
        var shown: [Int] = []
        var finish: [() -> Void] = []
        let queue = OneAtATimeQueue<Int> { item, done in shown.append(item); finish.append(done) }
        queue.enqueue(1); queue.enqueue(2); queue.enqueue(3)
        #expect(shown == [1], "one at a time")
        finish[0]()
        #expect(shown == [1, 2])
        finish[0]()   // a second `done` for the same item changes nothing
        #expect(shown == [1, 2])
        finish[1]()
        #expect(shown == [1, 2, 3])
        finish[2]()
        queue.enqueue(4)
        #expect(shown == [1, 2, 3, 4], "idle again: the next one runs at once")
    }
}
