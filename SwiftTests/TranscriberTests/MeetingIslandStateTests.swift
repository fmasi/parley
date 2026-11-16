import Testing
@testable import TranscriberCore

/// What the island shows and when (#358): the presenter only carries out these effects, so every transition is pinned here.
@Suite struct MeetingIslandStateTests {
    private let key = "/r/2026-11-16/101500-zoom call"

    private func step(_ state: MeetingIslandState, _ event: MeetingIslandEvent, recording: String? = "/r/2026-11-16/101500-zoom call",
                      sensingOn: Bool = true) -> (MeetingIslandState, [MeetingIslandEffect]) {
        let r = MeetingIslandReducer.reduce(state, event, recordingSessionKey: recording, sensingOn: sensingOn)
        return (r.state, r.effects)
    }

    /// A one-click start: the island becomes the recording, expanded.
    private func recordingIsland(fromCalendar: Bool = true) -> MeetingIslandState {
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: fromCalendar))
        #expect(e == [.showRecording(expanded: true)])
        #expect(s.showing == .recording && s.recording?.fromCalendar == fromCalendar)
        return s
    }

    @Test func aOneClickStartShowsTheRecordingExpanded() {
        _ = recordingIsland()
    }

    @Test func aStartForARecordingThatIsNoLongerTheOneShowsNothing() {
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: false), recording: nil)
        #expect(e.isEmpty && s.showing == nil)
    }

    @Test func withdrawingTheStartOfferNeverHidesTheRecordingIsland() {
        let (s, e) = step(recordingIsland(), .startOfferWithdrawn)
        #expect(e.isEmpty && s.showing == .recording)
        // …but it does hide a start offer.
        let (offer, _) = step(MeetingIslandState(), .startOfferShown, recording: nil)
        let (gone, hide) = step(offer, .startOfferWithdrawn, recording: nil)
        #expect(hide == [.hide] && gone.showing == nil)
    }

    @Test func aStopOfferReplacesTheIslandAndItComesBackCompact() {
        let (offered, shown) = step(recordingIsland(), .stopOfferShown)
        #expect(shown.isEmpty && offered.showing == .stopOffer)
        let (back, effects) = step(offered, .stopOfferWithdrawn)
        #expect(effects == [.hide, .showRecording(expanded: false)])
        #expect(back.showing == .recording)
    }

    @Test func hideSurvivesAStopOffer() {
        let (hidden, effects) = step(recordingIsland(), .hideChosen)
        #expect(effects == [.hide] && hidden.showing == nil && hidden.recording?.hidden == true)
        let (offered, _) = step(hidden, .stopOfferShown)
        let (after, back) = step(offered, .stopOfferWithdrawn)
        #expect(back == [.hide], "the stop offer goes; the recording island stays hidden")
        #expect(after.showing == nil)
        let (_, renamed) = step(after, .renamedByUser)
        #expect(renamed.isEmpty, "a rename does not bring it back either")
    }

    @Test func theRecordingsEndClearsIt() {
        let (ended, effects) = step(recordingIsland(), .recordingEnded, recording: nil)
        #expect(effects == [.hide] && ended == MeetingIslandState())
        // Ended while the stop offer was up: the offer's withdrawal does not bring the recording island back.
        let (offered, _) = step(recordingIsland(), .stopOfferShown)
        let (endedUnderOffer, none) = step(offered, .recordingEnded, recording: nil)
        #expect(none.isEmpty && endedUnderOffer.recording == nil)
        let (_, withdrawn) = step(endedUnderOffer, .stopOfferWithdrawn, recording: nil)
        #expect(withdrawn == [.hide])
    }

    @Test func turningSensingOffClearsIt() {
        let (off, effects) = step(recordingIsland(), .sensingTurnedOff, sensingOn: false)
        #expect(effects == [.hide] && off.showing == nil && off.recording?.hidden == true)
        let (_, refreshed) = step(off, .calendarTitleAdopted(sessionKey: key), sensingOn: true)
        #expect(refreshed.isEmpty, "not back for this recording, even with sensing on again")
        // With sensing off, a one-click start (queued earlier) never shows it.
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: false), sensingOn: false)
        #expect(e.isEmpty && s.showing == nil)
    }

    @Test func aLateCalendarTitleOrARenameRefreshesTheIsland() {
        let (late, effects) = step(recordingIsland(fromCalendar: false), .calendarTitleAdopted(sessionKey: key))
        #expect(effects == [.refreshRecording] && late.recording?.fromCalendar == true)
        let (other, none) = step(recordingIsland(fromCalendar: false), .calendarTitleAdopted(sessionKey: "/r/d/090000-other"))
        #expect(none.isEmpty && other.recording?.fromCalendar == false, "another recording's title")
        let (renamed, refresh) = step(late, .renamedByUser)
        #expect(refresh == [.refreshRecording] && renamed.recording?.fromCalendar == false)
    }

    @Test func answeringAnOfferHidesIt() {
        let (offer, _) = step(MeetingIslandState(), .startOfferShown, recording: nil)
        let (answered, effects) = step(offer, .offerAnswered, recording: nil)
        #expect(effects == [.hide] && answered.showing == nil)
        let (_, nothing) = step(MeetingIslandState(), .offerAnswered, recording: nil)
        #expect(nothing.isEmpty)
    }
}
