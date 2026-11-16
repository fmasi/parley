import Testing
@testable import TranscriberCore

/// What the island shows and when (#358): the presenter only carries out these effects, so every transition is pinned here.
/// The recording island is shown after a one-click start and withdraws once its collapse delay
/// (`MeetingIslandCollapse`, about 20 s) has run out (owner decision): the name lives on in the menu for the call.
@Suite struct MeetingIslandStateTests {
    private let key = "/r/2026-11-16/101500-zoom call"

    private func step(_ state: MeetingIslandState, _ event: MeetingIslandEvent, recording: String? = "/r/2026-11-16/101500-zoom call",
                      sensingOn: Bool = true) -> (MeetingIslandState, [MeetingIslandEffect]) {
        let r = MeetingIslandReducer.reduce(state, event, recordingSessionKey: recording, sensingOn: sensingOn)
        return (r.state, r.effects)
    }

    /// A one-click start: the island becomes the recording.
    private func recordingIsland(fromCalendar: Bool = true) -> MeetingIslandState {
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: fromCalendar))
        #expect(e == [.showRecording])
        #expect(s.showing == .recording && s.recording?.fromCalendar == fromCalendar)
        return s
    }

    /// The recording island once its delay has run out.
    private func faded() -> MeetingIslandState {
        let (s, e) = step(recordingIsland(), .recordingIslandExpired)
        #expect(e == [.hide])
        return s
    }

    @Test func aOneClickStartShowsTheRecording() {
        _ = recordingIsland()
    }

    @Test func aStartForARecordingThatIsNoLongerTheOneShowsNothing() {
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: false), recording: nil)
        #expect(e.isEmpty && s.showing == nil)
    }

    /// Owner decision: about 20 s after the start there is no island at all — no compact pill for the call.
    @Test func theRecordingIslandWithdrawsOnceItsDelayRunsOut() {
        let s = faded()
        #expect(s.showing == nil)
        #expect(s.recording?.hidden == true, "not shown again for this recording")
    }

    /// A late calendar title, or a rename from the menu, after the island has gone: the menu and the pending name take it
    /// (the coordinator's), the island does not come back.
    @Test func aLateTitleOrARenameAfterTheFadeNeverBringsTheIslandBack() {
        let (late, titled) = step(faded(), .calendarTitleAdopted(sessionKey: key))
        #expect(titled.isEmpty && late.showing == nil)
        let (_, renamed) = step(late, .renamedByUser)
        #expect(renamed.isEmpty)
    }

    /// The stop offer works as before #358: after its withdrawal there is nothing to restore.
    @Test func aStopOfferAfterTheFadeLeavesNothingToRestore() {
        let (offered, shown) = step(faded(), .stopOfferShown)
        #expect(shown.isEmpty && offered.showing == .stopOffer)
        let (after, withdrawn) = step(offered, .stopOfferWithdrawn)
        #expect(withdrawn == [.hide] && after.showing == nil)
    }

    /// A stop offer within the 20 s replaces the recording island for good: its withdrawal brings nothing back.
    @Test func aStopOfferWithinTheDelayReplacesTheRecordingIslandForGood() {
        let (offered, _) = step(recordingIsland(), .stopOfferShown)
        #expect(offered.showing == .stopOffer)
        let (after, withdrawn) = step(offered, .stopOfferWithdrawn)
        #expect(withdrawn == [.hide] && after.showing == nil)
        let (_, late) = step(after, .calendarTitleAdopted(sessionKey: key))
        #expect(late.isEmpty)
    }

    /// The delay running out once the island already shows something else (or nothing) changes nothing.
    @Test func aStaleExpiryChangesNothing() {
        let (offered, _) = step(recordingIsland(), .stopOfferShown)
        let (still, none) = step(offered, .recordingIslandExpired)
        #expect(none.isEmpty && still.showing == .stopOffer)
        let (_, nothing) = step(MeetingIslandState(), .recordingIslandExpired, recording: nil)
        #expect(nothing.isEmpty)
    }

    @Test func withdrawingTheStartOfferNeverHidesTheRecordingIsland() {
        let (s, e) = step(recordingIsland(), .startOfferWithdrawn)
        #expect(e.isEmpty && s.showing == .recording)
        // …but it does hide a start offer.
        let (offer, _) = step(MeetingIslandState(), .startOfferShown, recording: nil)
        let (gone, hide) = step(offer, .startOfferWithdrawn, recording: nil)
        #expect(hide == [.hide] && gone.showing == nil)
    }

    @Test func hideWithdrawsItAtOnce() {
        let (hidden, effects) = step(recordingIsland(), .hideChosen)
        #expect(effects == [.hide] && hidden.showing == nil && hidden.recording?.hidden == true)
        let (_, renamed) = step(hidden, .renamedByUser)
        #expect(renamed.isEmpty, "a rename does not bring it back")
    }

    @Test func theRecordingsEndClearsIt() {
        let (ended, effects) = step(recordingIsland(), .recordingEnded, recording: nil)
        #expect(effects == [.hide] && ended == MeetingIslandState())
        // Ended while the stop offer was up: the offer goes with the engine's own withdrawal.
        let (offered, _) = step(recordingIsland(), .stopOfferShown)
        let (endedUnderOffer, none) = step(offered, .recordingEnded, recording: nil)
        #expect(none.isEmpty && endedUnderOffer.recording == nil)
        let (_, withdrawn) = step(endedUnderOffer, .stopOfferWithdrawn, recording: nil)
        #expect(withdrawn == [.hide])
    }

    @Test func turningSensingOffClearsIt() {
        let (off, effects) = step(recordingIsland(), .sensingTurnedOff, sensingOn: false)
        #expect(effects == [.hide] && off.showing == nil && off.recording?.hidden == true)
        // With sensing off, a one-click start (queued earlier) never shows it.
        let (s, e) = step(MeetingIslandState(), .recordingStarted(sessionKey: key, fromCalendar: false), sensingOn: false)
        #expect(e.isEmpty && s.showing == nil)
    }

    /// Within the 20 s, a late calendar title or a rename updates the island's line (never restarting its delay).
    @Test func aLateCalendarTitleOrARenameWithinTheDelayUpdatesTheIsland() {
        let (late, effects) = step(recordingIsland(fromCalendar: false), .calendarTitleAdopted(sessionKey: key))
        #expect(effects == [.updateRecordingSubtitle] && late.recording?.fromCalendar == true)
        let (other, none) = step(recordingIsland(fromCalendar: false), .calendarTitleAdopted(sessionKey: "/r/d/090000-other"))
        #expect(none.isEmpty && other.recording?.fromCalendar == false, "another recording's title")
        let (renamed, refresh) = step(late, .renamedByUser)
        #expect(refresh == [.updateRecordingSubtitle] && renamed.recording?.fromCalendar == false)
    }

    @Test func answeringAnOfferHidesIt() {
        let (offer, _) = step(MeetingIslandState(), .startOfferShown, recording: nil)
        let (answered, effects) = step(offer, .offerAnswered, recording: nil)
        #expect(effects == [.hide] && answered.showing == nil)
        let (_, nothing) = step(MeetingIslandState(), .offerAnswered, recording: nil)
        #expect(nothing.isEmpty)
    }
}
