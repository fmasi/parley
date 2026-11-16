@preconcurrency import EventKit
import TranscriberCore
import os

/// Deliberately NOT main-actor: `events(matching:)` is a synchronous EventKit query over a
/// 12-hour, all-calendars predicate, and can take seconds with Exchange/Google accounts (#197).
/// `currentEventTitle` runs the whole lookup on a background dispatch queue (not `Task.detached`
/// — a multi-second *synchronous* call there would tie up one of Swift's limited cooperative
/// thread-pool threads for its whole duration; `withCheckedContinuation` + `DispatchQueue` keeps
/// the caller merely suspended, same pattern as `LaunchAgentManager.runLaunchctl`) so a caller on
/// the main actor — e.g. the naming panel opening on Start Recording — is never blocked on it.
final class CalendarService {
    /// Which path asked (#358), logged `.public` beside the outcome: the next real call then says which lookup named it.
    enum Purpose: String {
        case islandOffer = "island offer"
        case afterQuickStart = "after a one-click start"
        case namingPanel = "naming panel"
    }

    func currentEventTitle(
        lookaheadMinutes: Int = 10,
        from calendars: [EKCalendar]? = nil,
        purpose: Purpose = .namingPanel
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
                // TODO: if Exchange/LDAP accounts regress (Apple's docs also discourage creating
                // multiple EKEventStore instances at all, not just sharing one across threads),
                // replace this with a dedicated actor holding one retained store instead.
                // Without full access EventKit answers with no events at all — read as "no meeting" before #358, so a
                // missing permission and an empty calendar looked the same.
                let status = EKEventStore.authorizationStatus(for: .event)
                guard CalendarEventPicker.canRead(status) else {
                    Self.log(CalendarEventPicker.noAccess(status), purpose: purpose)
                    continuation.resume(returning: nil)
                    return
                }
                let store = EKEventStore()
                let calendars = calendarIDs.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
                let now = Date()
                // The predicate window must include both the lookback for in-progress events and
                // the lookahead for imminent ones. EventKit needs at least a few hours back to
                // surface events that started earlier in the day.
                let lookahead = max(lookaheadMinutes, 0)
                let predicate = store.predicateForEvents(
                    withStart: now.addingTimeInterval(-TimeInterval(CalendarEventPicker.lookbackHours) * 3600),
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

                let pick = CalendarEventPicker.pick(
                    from: notDeclined,
                    declinedCount: events.count - notDeclined.count,
                    now: now,
                    lookaheadMinutes: lookahead
                )
                Self.log(pick, purpose: purpose)
                continuation.resume(returning: pick.event?.title)
            }
        }
    }

    /// One line per lookup (#358): whether an event was found and why not, in counts (`.public`); the title `.private`.
    /// `.notice`, not `.info`: info lines are not kept in the log store, and this one is read after the call.
    private static func log(_ pick: CalendarEventPicker.Pick, purpose: Purpose) {
        if let title = pick.event?.title {
            Logger.state.notice("""
                Calendar lookup (\(purpose.rawValue, privacy: .public)): \(pick.summary, privacy: .public) — \
                “\(title, privacy: .private)”
                """)
        } else {
            Logger.state.notice("Calendar lookup (\(purpose.rawValue, privacy: .public)): \(pick.summary, privacy: .public)")
        }
    }
}
