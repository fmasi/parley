@preconcurrency import EventKit
import TranscriberCore

/// Deliberately NOT main-actor: `events(matching:)` is a synchronous EventKit query over a
/// 12-hour, all-calendars predicate, and can take seconds with Exchange/Google accounts (#197).
/// `currentEventTitle` runs the whole lookup on a background dispatch queue (not `Task.detached`
/// — a multi-second *synchronous* call there would tie up one of Swift's limited cooperative
/// thread-pool threads for its whole duration; `withCheckedContinuation` + `DispatchQueue` keeps
/// the caller merely suspended, same pattern as `LaunchAgentManager.runLaunchctl`) so a caller on
/// the main actor — e.g. the naming panel opening on Start Recording — is never blocked on it.
final class CalendarService {
    func currentEventTitle(
        lookaheadMinutes: Int = 10,
        from calendars: [EKCalendar]? = nil
    ) async -> String? {
        // EKCalendar's thread-safety is unspecified by Apple, so don't hand the objects themselves
        // across the queue hop — capture just their (Sendable) identifiers and re-resolve against
        // the fresh, same-thread store below instead.
        let calendarIDs = calendars?.map(\.calendarIdentifier)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // A fresh store per lookup, not a retained property: avoids sharing an EKEventStore
                // across actor/thread boundaries. EKEventStore() isn't actually cheap (Apple's docs
                // warn it's a Core Data stack init, ~50-200ms on Exchange-heavy accounts) — this
                // trades that per-call overhead for correctness, since the lookup only runs once per
                // Start Recording, not on a hot path.
                let store = EKEventStore()
                let calendars = calendarIDs.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
                let now = Date()
                // The predicate window must include both the lookback for in-progress events and
                // the lookahead for imminent ones. EventKit needs at least a few hours back to
                // surface events that started earlier in the day.
                let lookahead = max(lookaheadMinutes, 0)
                let predicate = store.predicateForEvents(
                    withStart: now.addingTimeInterval(-12 * 3600),
                    end: now.addingTimeInterval(TimeInterval(lookahead) * 60 + 60),
                    calendars: calendars
                )
                let events = store.events(matching: predicate)

                // Filter out declined events before handing to the picker.
                let notDeclined = events.filter { event in
                    guard let attendees = event.attendees else { return true }
                    let selfAttendee = attendees.first { $0.isCurrentUser }
                    guard let me = selfAttendee else { return true }
                    return me.participantStatus != .declined
                }

                let title = CalendarEventPicker.pickEvent(
                    from: notDeclined,
                    now: now,
                    lookaheadMinutes: lookahead
                )?.title
                continuation.resume(returning: title)
            }
        }
    }
}
