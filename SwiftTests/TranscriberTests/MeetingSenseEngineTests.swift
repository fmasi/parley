import Foundation
import Testing
@testable import TranscriberCore

/// Drives the pure engine like the presenter does: one state, a sequence of inputs, an injected clock.
private struct Sim {
    var state = MeetingSenseState()
    var mode: MeetingSenseMode = .prompt
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: TimeInterval) -> Date { Self.epoch.addingTimeInterval(s) }

    @discardableResult
    mutating func step(_ input: MeetingSenseInput, at seconds: TimeInterval) -> [MeetingSenseAction] {
        let r = MeetingSenseEngine.step(state, input: input, mode: mode, now: at(seconds))
        state = r.state
        return r.actions
    }
    @discardableResult
    mutating func snap(_ ids: Set<String>, at seconds: TimeInterval) -> [MeetingSenseAction] {
        step(.snapshot(CaptureSnapshot(capturingBundleIDs: ids)), at: seconds)
    }
    @discardableResult
    mutating func phase(_ p: MeetingSensePhase, at seconds: TimeInterval) -> [MeetingSenseAction] {
        step(.phaseChanged(p), at: seconds)
    }
}

private let zoom = MeetingApps.classify(bundleID: "us.zoom.xos")!
private let chrome = MeetingApps.classify(bundleID: "com.google.Chrome")!
private let debounce = MeetingSenseEngine.stopDebounce
private let cooldown = MeetingSenseEngine.expansionCooldown

@Suite("MeetingSenseEngine — start offers")
struct MeetingSenseEngineStartTests {
    @Test("first snapshot counts as a transition: launching mid-call prompts (expanded)")
    func firstSnapshotOffers() {
        var s = Sim()
        #expect(s.snap(["us.zoom.xos"], at: 0) == [.offerStart(zoom, expand: true)])
        #expect(s.state.pendingStart == zoom)
    }

    @Test("a steady snapshot is not a transition")
    func steadyStateIsSilent() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap(["us.zoom.xos"], at: 1) == [])
    }

    @Test("unknown bundle IDs never prompt")
    func unknownIsSilent() {
        var s = Sim()
        #expect(s.snap(["com.example.dictation", ""], at: 0) == [])
    }

    @Test("still offers while transcribing")
    func offersWhileTranscribing() {
        var s = Sim()
        s.phase(.transcribing, at: 0)
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.offerStart(zoom, expand: true)])
    }

    @Test("a second app transitioning while one offer is pending folds in")
    func secondAppFoldsIn() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap(["us.zoom.xos", "com.google.Chrome"], at: 1) == [])
        #expect(s.state.pendingStart == zoom)
    }

    @Test("the offered app releasing withdraws the offer")
    func earlyReleaseWithdraws() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap([], at: 1) == [.withdrawStart])
        #expect(s.state.pendingStart == nil)
    }

    @Test("withdrawal promotes another app still capturing")
    func withdrawPromotesOther() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.snap(["us.zoom.xos", "com.google.Chrome"], at: 1)
        #expect(s.snap(["com.google.Chrome"], at: 2) == [.withdrawStart, .offerStart(chrome, expand: true)])
    }

    @Test("expansion cooldown gates only `expand`; the offer itself always comes")
    func expansionCooldown() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)                 // expanded
        s.snap([], at: 10)                             // call dropped
        #expect(s.snap(["us.zoom.xos"], at: 60) == [.offerStart(zoom, expand: false)])   // reconnect: compact
        s.snap([], at: 70)
        #expect(s.snap(["us.zoom.xos"], at: cooldown + 1) == [.offerStart(zoom, expand: true)])
    }

    @Test("expansion cooldown boundary: exactly at the window it expands again (>= is inclusive)")
    func expandsExactlyAtCooldownBoundary() {
        // Pins the >= vs > fence-post: at exactly `expansionCooldown` since the last expanded offer
        // the next one must expand again.
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)                 // expanded; starts the cooldown
        s.snap([], at: 10)                             // call dropped
        #expect(s.snap(["us.zoom.xos"], at: cooldown) == [.offerStart(zoom, expand: true)])
    }

    @Test("Not now suppresses the episode until the app releases the mic")
    func notNowSuppressesEpisode() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.step(.notNow, at: 1) == [.withdrawStart])
        #expect(s.state.suppressed == [zoom])
        #expect(s.snap(["us.zoom.xos"], at: 2) == [])      // same episode: quiet
        s.snap([], at: 3)                                  // released → suppression cleared
        #expect(s.state.suppressed.isEmpty)
        #expect(s.snap(["us.zoom.xos"], at: 4) == [.offerStart(zoom, expand: false)])   // new episode
    }

    @Test("mode off withdraws a pending offer and never offers")
    func modeOffWithdraws() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.mode = .off
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.withdrawStart])
        #expect(s.snap(["com.google.Chrome"], at: 2) == [])
    }
}

@Suite("MeetingSenseEngine — recording, watched set, stop offers")
struct MeetingSenseEngineStopTests {
    /// Recording with Zoom already capturing (the prompt-Record or manual-Record path).
    private func recordingWithZoom() -> Sim {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.phase(.recording, at: 1)
        return s
    }

    @Test("phase → recording withdraws the start offer and seeds the watched set")
    func recordingSeedsWatched() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.phase(.recording, at: 1) == [.withdrawStart, .watch(bundleIDs: ["us.zoom.xos"])])
        #expect(s.state.watched == [zoom])
    }

    @Test("re-attach: phase is recording before any snapshot; the first snapshot seeds watched, no start offer")
    func reattachSeedsFromFirstSnapshot() {
        var s = Sim()
        #expect(s.phase(.recording, at: 0) == [.watch(bundleIDs: [])])
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.watch(bundleIDs: ["us.zoom.xos"])])
        #expect(s.state.watched == [zoom])
        #expect(s.state.pendingStart == nil)
    }

    @Test("an app that starts capturing mid-recording joins the watched set")
    func joinerIsWatched() {
        var s = recordingWithZoom()
        #expect(s.snap(["us.zoom.xos", "com.google.Chrome"], at: 2) == [.watch(bundleIDs: ["us.zoom.xos", "com.google.Chrome"])])
        #expect(s.state.watched == [zoom, chrome])
    }

    @Test("helper bundle IDs of a watched app accumulate into the watch list")
    func helpersAccumulate() {
        var s = recordingWithZoom()
        #expect(s.snap(["us.zoom.xos", "us.zoom.xos.helper"], at: 2) == [.watch(bundleIDs: ["us.zoom.xos", "us.zoom.xos.helper"])])
    }

    @Test("all watched released → schedule a scan at the debounce; at the deadline → one stop offer")
    func stopDebounceExactlyOnce() {
        var s = recordingWithZoom()
        #expect(s.snap([], at: 10) == [.scheduleScan(after: debounce)])
        #expect(s.snap([], at: 10 + debounce) == [.offerStop(zoom)])
        #expect(s.snap([], at: 11 + debounce) == [])
    }

    @Test("a snapshot before the deadline reschedules for the remainder (an early timer can't strand the offer)")
    func earlySnapshotReschedules() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        #expect(s.snap([], at: 20) == [.scheduleScan(after: debounce - 10)])
    }

    @Test("re-acquire (mute/unmute, device switch) cancels the pending release")
    func reacquireCancels() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        #expect(s.snap(["us.zoom.xos"], at: 20) == [])
        #expect(s.state.releasedAt == nil)
        #expect(s.snap([], at: 25) == [.scheduleScan(after: debounce)])   // a fresh release
        #expect(s.snap([], at: 25 + debounce - 1) == [.scheduleScan(after: 1)])
    }

    @Test("re-acquire after the stop offer withdraws it")
    func reacquireWithdrawsStop() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.snap(["us.zoom.xos"], at: 50) == [.withdrawStop])
    }

    @Test("Keep recording suppresses until the app re-acquires and releases again")
    func keepRecordingSuppresses() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.step(.keepRecording, at: 45) == [.withdrawStop])
        #expect(s.snap([], at: 200) == [])                              // still released, still quiet
        s.snap(["us.zoom.xos"], at: 300)                                // re-acquire
        #expect(s.snap([], at: 310) == [.scheduleScan(after: debounce)])
        #expect(s.snap([], at: 310 + debounce) == [.offerStop(zoom)])
    }

    @Test("Keep recording does not outlive the recording: the next meeting still gets a start offer")
    func keepRecordingDoesNotOutliveRecording() {
        // An answer given about THIS recording must never silence the offer for the NEXT meeting.
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)                   // stop offer
        s.step(.keepRecording, at: 45)                  // suppresses zoom for the rest of this recording
        s.phase(.idle, at: 60)                          // the user stops the recording manually
        #expect(s.state.suppressed.isEmpty)
        #expect(s.snap(["us.zoom.xos"], at: 70) == [.offerStart(zoom, expand: false)])
    }

    @Test("recording with no meeting app ever capturing never offers to stop")
    func emptyWatchedNoStop() {
        var s = Sim()
        s.phase(.recording, at: 0)
        #expect(s.snap([], at: 10) == [])
        #expect(s.snap([], at: 100) == [])
    }

    @Test("no start offer while recording")
    func noStartWhileRecording() {
        var s = Sim()
        s.phase(.recording, at: 0)
        let actions = s.snap(["com.google.Chrome"], at: 1)
        #expect(!actions.contains(.offerStart(chrome, expand: true)))
        #expect(!actions.contains(.offerStart(chrome, expand: false)))
    }

    @Test("mode off then back on mid-recording re-arms the watch, so the stop offer still comes")
    func modeOffThenOnMidRecordingRearmsWatch() {
        // The blocker this test exists for: with the watch mirror left standing while the mode was off,
        // the next snapshot found the IDs already "watched", emitted no `.watch`, and the sensor held no
        // per-process listeners for the rest of the recording — the stop offer could never arrive.
        var s = recordingWithZoom()
        s.mode = .off
        s.snap([], at: 2)                                   // the presenter's teardown snapshot
        #expect(s.state.watchedBundleIDs.isEmpty)           // the engine's mirror follows the sensor's
        s.mode = .prompt
        // The sensor restarts and its first scan still sees Zoom holding the mic.
        #expect(s.snap(["us.zoom.xos"], at: 3) == [.watch(bundleIDs: ["us.zoom.xos"])])
        // And the whole point of re-arming: ending the call still offers to stop.
        #expect(s.snap([], at: 10) == [.scheduleScan(after: debounce)])
        #expect(s.snap([], at: 10 + debounce) == [.offerStop(zoom)])
    }

    @Test("phase leaves recording: clears watched, withdraws the stop offer, releases the listeners")
    func leavingRecordingClears() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.phase(.transcribing, at: 50) == [.withdrawStop, .watch(bundleIDs: [])])
        #expect(s.state.watched.isEmpty)
        #expect(s.state.releasedAt == nil)
    }
}
