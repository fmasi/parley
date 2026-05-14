import Testing
import EventKit
@testable import TranscriberCore

struct CalendarEventPickerTests {
    private let store = EKEventStore()

    /// Anchor "now" so tests are deterministic regardless of wall-clock.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEvent(
        title: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isAllDay: Bool = false
    ) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = now.addingTimeInterval(startOffset)
        event.endDate = now.addingTimeInterval(endOffset)
        event.isAllDay = isAllDay
        return event
    }

    // MARK: - Empty / all-day

    @Test func emptyArrayReturnsNil() {
        let result = CalendarEventPicker.pickEvent(from: [], now: now, lookaheadMinutes: 10)
        #expect(result == nil)
    }

    @Test func filtersOutAllDayEvents() {
        let allDay = makeEvent(title: "Holiday", startOffset: -3600, endOffset: 3600, isAllDay: true)
        let result = CalendarEventPicker.pickEvent(from: [allDay], now: now, lookaheadMinutes: 10)
        #expect(result == nil)
    }

    @Test func keepsInProgressNonAllDayEvent() {
        let meeting = makeEvent(title: "Standup", startOffset: -1800, endOffset: 1800)
        let result = CalendarEventPicker.pickEvent(from: [meeting], now: now, lookaheadMinutes: 10)
        #expect(result?.title == "Standup")
    }

    // MARK: - In-progress tiebreaker

    @Test func picksMostRecentlyStartedAmongInProgress() {
        let earlier = makeEvent(title: "Earlier Meeting", startOffset: -3600, endOffset: 1800)
        let later = makeEvent(title: "Later Meeting", startOffset: -600, endOffset: 3000)
        let result = CalendarEventPicker.pickEvent(from: [earlier, later], now: now, lookaheadMinutes: 10)
        #expect(result?.title == "Later Meeting")
    }

    @Test func filtersAllDayAndPicksTimedInProgress() {
        let allDay = makeEvent(title: "Birthday", startOffset: -3600, endOffset: 3600, isAllDay: true)
        let timed = makeEvent(title: "Sprint Review", startOffset: -900, endOffset: 2700)
        let result = CalendarEventPicker.pickEvent(from: [allDay, timed], now: now, lookaheadMinutes: 10)
        #expect(result?.title == "Sprint Review")
    }

    @Test func allEventsFilteredReturnsNil() {
        let allDay1 = makeEvent(title: "Holiday", startOffset: -3600, endOffset: 3600, isAllDay: true)
        let allDay2 = makeEvent(title: "Birthday", startOffset: -7200, endOffset: 7200, isAllDay: true)
        let result = CalendarEventPicker.pickEvent(from: [allDay1, allDay2], now: now, lookaheadMinutes: 10)
        #expect(result == nil)
    }

    // MARK: - Upcoming-within-grace

    @Test func picksUpcomingMeetingWithinGrace() {
        // No in-progress meeting; one starts in 5 minutes (within 10 min grace).
        let upcoming = makeEvent(title: "Project Sync", startOffset: 5 * 60, endOffset: 35 * 60)
        let result = CalendarEventPicker.pickEvent(from: [upcoming], now: now, lookaheadMinutes: 10)
        #expect(result?.title == "Project Sync")
    }

    @Test func ignoresUpcomingOutsideGrace() {
        // Starts in 15 minutes; grace is 10. Should be ignored.
        let later = makeEvent(title: "Far Future", startOffset: 15 * 60, endOffset: 60 * 60)
        let result = CalendarEventPicker.pickEvent(from: [later], now: now, lookaheadMinutes: 10)
        #expect(result == nil)
    }

    @Test func picksEarliestUpcomingWithinGrace() {
        let starts3min = makeEvent(title: "Soonest", startOffset: 3 * 60, endOffset: 33 * 60)
        let starts8min = makeEvent(title: "After Soonest", startOffset: 8 * 60, endOffset: 38 * 60)
        let result = CalendarEventPicker.pickEvent(
            from: [starts8min, starts3min],  // unordered input on purpose
            now: now,
            lookaheadMinutes: 10
        )
        #expect(result?.title == "Soonest")
    }

    // MARK: - In-progress beats upcoming

    @Test func inProgressBeatsUpcomingEvenIfUpcomingIsCloser() {
        // In-progress started 25 min ago and ends in 5 min; upcoming starts in 2 min.
        // Distance from "now" is greater for in-progress, but it still wins.
        let inProgress = makeEvent(title: "Current Meeting", startOffset: -25 * 60, endOffset: 5 * 60)
        let upcoming = makeEvent(title: "Next Meeting", startOffset: 2 * 60, endOffset: 32 * 60)
        let result = CalendarEventPicker.pickEvent(
            from: [inProgress, upcoming],
            now: now,
            lookaheadMinutes: 10
        )
        #expect(result?.title == "Current Meeting")
    }

    // MARK: - Edge cases

    @Test func graceZeroIgnoresAllUpcoming() {
        let upcoming = makeEvent(title: "Soon", startOffset: 30, endOffset: 30 * 60)
        let result = CalendarEventPicker.pickEvent(from: [upcoming], now: now, lookaheadMinutes: 0)
        #expect(result == nil)
    }

    @Test func eventEndingExactlyAtNowIsNotInProgress() {
        // endDate == now means the meeting has ended; it should not be counted as in-progress.
        let justEnded = makeEvent(title: "Just Ended", startOffset: -30 * 60, endOffset: 0)
        let result = CalendarEventPicker.pickEvent(from: [justEnded], now: now, lookaheadMinutes: 10)
        #expect(result == nil)
    }

    @Test func eventStartingExactlyAtNowCountsAsInProgress() {
        // startDate == now means the meeting just began; treat it as in-progress.
        let justStarted = makeEvent(title: "Just Started", startOffset: 0, endOffset: 30 * 60)
        let result = CalendarEventPicker.pickEvent(from: [justStarted], now: now, lookaheadMinutes: 10)
        #expect(result?.title == "Just Started")
    }
}
