import EventKit
import TranscriberCore

/// EventKit lookup for the current meeting's title.
///
/// `events(matching:)` is synchronous and cannot be cancelled, and over a 12-hour window of every
/// calendar it takes seconds with Exchange/Google accounts — worst on the first call. It therefore runs
/// off the main thread and is raced against `timeout`: past the deadline the caller gets nil and the
/// query's late result is discarded, the query itself running on to completion unwatched (#197).
/// `CalendarEventPicker` holds the pure selection rule.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    /// Lookups run here, one at a time. `EKEventStore` is not thread safe and an abandoned query may
    /// still be running when the next lookup starts, so they are serialized rather than overlapped; a
    /// dedicated queue also keeps a multi-second blocking call off the cooperative thread pool.
    private let queue = DispatchQueue(label: "calendar-lookup")

    func currentEventTitle(lookaheadMinutes: Int = 10, timeout: TimeInterval = 1) async -> String? {
        // Touched only on `queue` below — never on main, and never from two contexts at once.
        nonisolated(unsafe) let store = self.store
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            queue.async {
                once.resume(Self.lookup(store: store, lookaheadMinutes: lookaheadMinutes))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Past the deadline the caller records with no suggested name rather than waiting.
                once.resume(nil)
            }
        }
    }

    nonisolated private static func lookup(store: EKEventStore, lookaheadMinutes: Int) -> String? {
        let now = Date()
        // The predicate window must include both the lookback for in-progress events and
        // the lookahead for imminent ones. EventKit needs at least a few hours back to
        // surface events that started earlier in the day.
        let lookahead = max(lookaheadMinutes, 0)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(TimeInterval(lookahead) * 60 + 60),
            calendars: nil
        )
        let events = store.events(matching: predicate)

        // Filter out declined events before handing to the picker.
        let notDeclined = events.filter { event in
            guard let attendees = event.attendees else { return true }
            let selfAttendee = attendees.first { $0.isCurrentUser }
            guard let me = selfAttendee else { return true }
            return me.participantStatus != .declined
        }

        return CalendarEventPicker.pickEvent(
            from: notDeclined,
            now: now,
            lookaheadMinutes: lookahead
        )?.title
    }
}
