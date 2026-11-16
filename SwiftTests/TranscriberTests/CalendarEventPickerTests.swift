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
    // MARK: - Why a lookup found what it found (#358)

    /// Several events in progress: the one whose window contains now and started last is chosen, and the summary says
    /// how many there were — in counts only, never a title (it is logged `.public`).
    @Test func overlappingEventsSayWhichWasChosenAndOfHowMany() {
        let block = makeEvent(title: "Office hours", startOffset: -3 * 3600, endOffset: 3600)
        let meeting = makeEvent(title: "Weekly sync", startOffset: -5 * 60, endOffset: 25 * 60)
        let next = makeEvent(title: "Next", startOffset: 4 * 60, endOffset: 34 * 60)
        let pick = CalendarEventPicker.pick(from: [block, meeting, next], declinedCount: 0, now: now, lookaheadMinutes: 10)
        #expect(pick.event?.title == "Weekly sync")
        #expect(pick.reason == .inProgress)
        #expect(pick.candidates == 2, "two events contain now; the upcoming one is not a candidate")
        #expect(pick.summary == "chose 1 of 2 events in progress (the one that started last)")
        #expect(!pick.summary.contains("Weekly") && !pick.summary.contains("Office"))
    }

    @Test func anUpcomingEventSaysItWasTheEarliestWithinTheLookahead() {
        let a = makeEvent(title: "A", startOffset: 3 * 60, endOffset: 33 * 60)
        let b = makeEvent(title: "B", startOffset: 8 * 60, endOffset: 38 * 60)
        let pick = CalendarEventPicker.pick(from: [b, a], declinedCount: 0, now: now, lookaheadMinutes: 10)
        #expect(pick.event?.title == "A" && pick.reason == .upcoming && pick.candidates == 2)
        #expect(pick.summary == "chose 1 of 2 events starting within 10 min (the earliest)")
    }

    @Test func anEmptyWindowSaysSo() {
        let pick = CalendarEventPicker.pick(from: [], declinedCount: 0, now: now, lookaheadMinutes: 10)
        #expect(pick.event == nil && pick.reason == .noEvents)
        #expect(pick.summary == "no event in the window (12 h back, 10 min ahead)")
    }

    /// The miss that matters most: a call that overran its slot. The summary names how long ago the latest event ended,
    /// so the next real call tells an overrun from a calendar that was never there.
    @Test func eventsInTheWindowButNoneCurrentSayWhy() {
        let ended = makeEvent(title: "Ran over", startOffset: -40 * 60, endOffset: -4 * 60)
        let allDay = makeEvent(title: "Holiday", startOffset: -3600, endOffset: 3600, isAllDay: true)
        let later = makeEvent(title: "Later", startOffset: 15 * 60, endOffset: 45 * 60)
        let pick = CalendarEventPicker.pick(from: [ended, allDay, later], declinedCount: 1, now: now, lookaheadMinutes: 10)
        #expect(pick.event == nil && pick.reason == .nothingCurrent)
        #expect(pick.summary
                == "none current: 4 events in the window — 1 all-day, 1 declined, 1 ended (the latest 4 min ago), 1 later than 10 min")
    }

    @Test func onlyDeclinedEventsAreNoneCurrent() {
        let pick = CalendarEventPicker.pick(from: [], declinedCount: 2, now: now, lookaheadMinutes: 10)
        #expect(pick.event == nil && pick.reason == .nothingCurrent)
        #expect(pick.summary == "none current: 2 events in the window — 0 all-day, 2 declined, 0 ended, 0 later than 10 min")
    }

    /// EventKit answers an app without full access with no events at all: indistinguishable from an empty calendar unless the
    /// status is read first.
    @Test func onlyFullAccessCanReadEvents() {
        #expect(CalendarEventPicker.canRead(.fullAccess))
        #expect(!CalendarEventPicker.canRead(.writeOnly))
        #expect(!CalendarEventPicker.canRead(.denied))
        #expect(!CalendarEventPicker.canRead(.restricted))
        #expect(!CalendarEventPicker.canRead(.notDetermined))
        #expect(CalendarEventPicker.noAccess(.denied).summary == "no calendar access (denied)")
        #expect(CalendarEventPicker.noAccess(.notDetermined).summary == "no calendar access (never asked)")
        #expect(CalendarEventPicker.noAccess(.writeOnly).summary == "no calendar access (add events only)")
        #expect(CalendarEventPicker.noAccess(.denied).reason == .noAccess && CalendarEventPicker.noAccess(.denied).event == nil)
    }
}
