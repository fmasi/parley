import Foundation
import Testing
@testable import TranscriberCore

/// A clock that moves only when a test says so: a deadline measured on it proves which clock it runs on.
/// Stands in for `SuspendingClock` (awake time): real time passing while it is not advanced is the Mac asleep.
final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    /// Sleeps not yet woken (or cancelled): a timer that outlives its call shows up here.
    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { sleepers.removeValue(forKey: id) }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on and wakes every sleep that is due.
    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

/// A thread-safe cell for results written by another task.
private final class Cell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// L13 (§8.8): every helper call gets a deadline. `ResumeOnce` already guarantees a continuation is
/// resumed once; this adds "and not later than N seconds".
@Suite struct DeadlineTests {
    @Test func aFastBodyReturnsItsValue() async throws {
        let v = try await withDeadline(seconds: 1, label: "fast") { 42 }
        #expect(v == 42)
    }
    @Test func aSlowBodyThrowsTimedOutWithItsLabel() async {
        await #expect(throws: DeadlineError.timedOut("stop")) {
            try await withDeadline(seconds: 0.05, label: "stop") { try await Task.sleep(for: .seconds(10)); return 1 }
        }
    }
    @Test func aThrowingBodyRethrowsItsOwnError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withDeadline(seconds: 1, label: "boom") { throw Boom() }
        }
    }

    /// L10 review 56: a deadline counts its clock's time only — awake time for every §8.8 deadline. Real time
    /// passing while the clock stands still (the Mac asleep) never times a call out; the clock moving does.
    @Test func aDeadlineCountsOnlyItsClocksTime() async throws {
        let clock = ManualTestClock()
        let outcome = Cell<Result<Int, DeadlineError>?>(nil)
        let call = Task {
            do {
                outcome.value = .success(try await withDeadline(seconds: 0.05, label: "stop", clock: clock) {
                    try await Task.sleep(for: .seconds(5)); return 1
                })
            } catch let error as DeadlineError {
                outcome.value = .failure(error)
            } catch {}
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(outcome.value == nil, "150 ms of real time with the clock standing still is not a timeout")
        clock.advance(by: .milliseconds(60))
        await call.value
        #expect(outcome.value == .failure(.timedOut("stop")))
    }

    /// A body that finishes in time leaves no deadline sleeping behind it.
    @Test func aFinishedBodyCancelsItsDeadline() async throws {
        let clock = ManualTestClock()
        #expect(try await withDeadline(seconds: 10, label: "fast", clock: clock) { 7 } == 7)
        var waited = 0
        while clock.pendingSleeps > 0, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(clock.pendingSleeps == 0)
    }
}

/// L9 review 51: the XPC client's bounded call — the reply, the XPC error handler and the deadline race
/// through `ResumeOnce` — in Core, where it is tested.
@Suite struct BoundedReplyTests {
    private struct HandlerError: Error, Equatable {}

    @Test func aReplyInTimeIsReturned() async throws {
        let clock = ManualTestClock()
        let result: Result<Int, Error> = await boundedReply("status", seconds: 3, clock: clock) { done in done(.success(5)) }
        #expect(try result.get() == 5)
        var waited = 0
        while clock.pendingSleeps > 0, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(clock.pendingSleeps == 0, "the reply cancels the deadline")
    }

    @Test func noReplyTimesOutAndALateReplyIsIgnored() async throws {
        let clock = ManualTestClock()
        let late = Cell<(@Sendable (Result<Int, Error>) -> Void)?>(nil)
        let outcome = Cell<Result<Int, Error>?>(nil)
        let call = Task {
            outcome.value = await boundedReply("stop", seconds: 20, clock: clock) { done in late.value = done }
        }
        var waited = 0
        while clock.pendingSleeps == 0, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        clock.advance(by: .seconds(20))
        await call.value
        guard case .failure(let error as CaptureCallTimeout) = outcome.value else {
            Issue.record("expected a CaptureCallTimeout, got \(String(describing: outcome.value))"); return
        }
        #expect(error == CaptureCallTimeout(call: "stop", seconds: 20))
        late.value?(.success(1))   // the helper answers after all: ignored, never a second resume
    }

    @Test func theErrorHandlerPathFailsTheCall() async {
        let result: Result<Int, Error> = await boundedReply("rotateChunk", seconds: 10, clock: ManualTestClock()) { done in
            done(.failure(HandlerError()))   // the XPC error handler, before any reply
            done(.success(3))                // a reply after it is ignored
        }
        guard case .failure(let error) = result else { Issue.record("expected the handler's error"); return }
        #expect(error as? HandlerError == HandlerError())
    }
}
