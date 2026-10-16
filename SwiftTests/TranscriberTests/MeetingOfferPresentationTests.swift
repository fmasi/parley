import Foundation
import Testing
@testable import TranscriberCore

/// The words on an offer and the queued-start rule: the two pure halves of `MeetingPromptPresenter`
/// (app target, unreachable from tests). Everything else in the presenter is wiring.
@Suite("MeetingOfferText")
struct MeetingOfferTextTests {
    private let zoom = MeetingApps.zoom

    @Test("An ordinary start offer names the app and says what it is doing")
    func startSubtitle() {
        #expect(MeetingOfferText.startSubtitle(app: zoom, firstEver: false)
            == "Zoom is using the microphone")
    }

    @Test("The first-ever offer carries the disclosure instead of the subtitle (D6)")
    func firstEverSubtitleIsTheDisclosure() {
        let subtitle = MeetingOfferText.startSubtitle(app: zoom, firstEver: true)
        #expect(subtitle == "Parley noticed Zoom using the mic — it only checks which app, on this Mac, and never listens.")
        // The two promises that make this the disclosure rather than a description.
        #expect(subtitle.contains("on this Mac"))
        #expect(subtitle.contains("never listens"))
    }

    @Test("A calendar title decorates the subtitle, keeping the app name")
    func calendarSubtitle() {
        #expect(MeetingOfferText.startSubtitle(calendarTitle: "Weekly sync", app: zoom)
            == "Weekly sync · Zoom")
    }

    @Test("The stop offer names the app and the session being recorded")
    func stopSubtitle() {
        #expect(MeetingOfferText.stopSubtitle(app: zoom, sessionName: "Weekly sync")
            == "Zoom released the microphone · Weekly sync")
    }
}

/// In-memory stand-in for `UserDefaults`, counting writes so "writes the flag once" is observable.
private final class FakeFlagStore: OneShotFlagStore {
    var flags: [String: Bool] = [:]
    private(set) var writes = 0
    func bool(forKey key: String) -> Bool { flags[key] ?? false }
    func set(_ value: Bool, forKey key: String) {
        flags[key] = value
        writes += 1
    }
}

@Suite("MeetingDisclosure")
struct MeetingDisclosureTests {
    @Test("The disclosure is claimed exactly once, ever")
    func onlyTheFirstCallGetsIt() {
        let store = FakeFlagStore()
        #expect(MeetingDisclosure.consumeFirstShowing(store: store) == true)
        #expect(MeetingDisclosure.consumeFirstShowing(store: store) == false)
        #expect(MeetingDisclosure.consumeFirstShowing(store: store) == false)
    }

    @Test("Claiming it records the flag, and only on the first claim")
    func writesTheFlagOnce() {
        let store = FakeFlagStore()
        MeetingDisclosure.consumeFirstShowing(store: store)
        #expect(store.flags[MeetingDisclosure.shownKey] == true)
        #expect(store.writes == 1)
        MeetingDisclosure.consumeFirstShowing(store: store)
        #expect(store.writes == 1)   // no second write
    }

    /// A user who has seen it in an earlier session must never see it again.
    @Test("A store that already carries the flag never offers it")
    func respectsAPreviousSession() {
        let store = FakeFlagStore()
        store.flags[MeetingDisclosure.shownKey] = true
        #expect(MeetingDisclosure.consumeFirstShowing(store: store) == false)
        #expect(store.writes == 0)
    }
}

@Suite("MeetingQueuedStart")
struct MeetingQueuedStartTests {
    private let zoom = MeetingApps.zoom
    private let chrome = MeetingApps.chrome

    @Test("Nothing queued: nothing to do")
    func nothingQueued() {
        #expect(MeetingQueuedStart.decide(queued: nil, isIdle: true, capturing: [zoom]) == .wait)
    }

    @Test("Still transcribing: the queued start waits")
    func waitsWhileBusy() {
        #expect(MeetingQueuedStart.decide(queued: zoom, isIdle: false, capturing: [zoom]) == .wait)
    }

    @Test("Idle and the call is still on: start it")
    func startsWhenIdleAndStillCapturing() {
        #expect(MeetingQueuedStart.decide(queued: zoom, isIdle: true, capturing: [zoom, chrome])
            == .start(zoom))
    }

    /// The consent-adjacent rule: never open the mic for a call that already ended.
    @Test("Idle but the call ended meanwhile: drop it")
    func dropsWhenTheCallEnded() {
        #expect(MeetingQueuedStart.decide(queued: zoom, isIdle: true, capturing: [chrome]) == .drop)
        #expect(MeetingQueuedStart.decide(queued: zoom, isIdle: true, capturing: []) == .drop)
    }
}
