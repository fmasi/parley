import AppKit
import Foundation
import Observation
import TranscriberCore
import os

/// Re-runs `read` whenever an `@Observable` property it touched changes, then hands the value to
/// `apply` **outside** the tracking scope. Two reasons for the split: `onChange` fires before the new
/// value lands, so the re-read is deferred one main-actor hop and sees it; and the effects must not be
/// tracked — `MeetingIslandController.show` reads the island's model, so running effects inside the
/// tracking block would register a dependency on the island and make every subtitle update re-enter
/// the loop. A presenter that has been released reads nothing observable, so the loop stops re-arming
/// on its own.
@MainActor
private func keepObserving<T>(
    _ read: @escaping @MainActor () -> T,
    apply: @escaping @MainActor (T) -> Void
) {
    let value = withObservationTracking { read() } onChange: {
        Task { @MainActor in keepObserving(read, apply: apply) }
    }
    apply(value)
}

/// Turns engine actions into UI (island, menu-bar icon, banner) and routes the user's answers back
/// (#118). Owns the engine state, the sensor and the island; runs the two observation loops
/// (`AppState.phase`, `Config.meetingSensing`). Never starts or stops a recording on its own — every
/// `quickStart`/`stopRecording` below is the direct result of a click.
@MainActor
final class MeetingPromptPresenter {
    /// Deliberately longer than the 1 s bound a click gets: nobody is waiting on this lookup. It runs
    /// when the offer appears — seconds before the user answers — precisely so the first (cold,
    /// multi-second) EventKit query of a session resolves in time to name the recording (Ruling 7).
    private static let calendarWarmTimeout: TimeInterval = 10

    private let appState: AppState
    private let configManager: ConfigManager
    private let coordinator: RecordingCoordinator
    private let launcher: RecordingLauncher
    private let calendarService: CalendarService
    private let island = MeetingIslandController()
    private var sensor: MeetingSensor!
    private var state = MeetingSenseState()
    private var mode: MeetingSenseMode = .off
    private var isActive = false
    /// The user chose Record while transcribing; fires when the phase becomes idle, only if the app is
    /// still capturing then.
    private var queuedStart: MeetingApp?
    private var calendarTitle: String?

    init(appState: AppState, configManager: ConfigManager, coordinator: RecordingCoordinator,
         launcher: RecordingLauncher, calendarService: CalendarService) {
        self.appState = appState
        self.configManager = configManager
        self.coordinator = coordinator
        self.launcher = launcher
        self.calendarService = calendarService
        // `onSnapshot` arrives on the sensor's private queue — hop to the main actor, which is the only
        // place the engine state is ever touched.
        sensor = MeetingSensor { [weak self] snapshot in
            Task { @MainActor in self?.feed(.snapshot(snapshot)) }
        }
    }

    /// Call once, after launch-time crash recovery AND the launch gate have both completed — so a
    /// relaunch mid-recording never shows the engine an `.idle` phase with a call in progress.
    func activate() {
        guard !isActive else { return }
        isActive = true
        // Mode first, deliberately: each loop's `apply` runs synchronously here, so registering the
        // mode loop second would feed the engine its first `.phaseChanged` while `mode` is still the
        // initial `.off`. That happens to be harmless today (the engine stores the phase whatever the
        // mode), but this order depends on no such detail. The sensor cannot get ahead either: its
        // snapshots reach the engine through a main-actor hop, which cannot run until `activate()`
        // returns.
        keepObserving({ [weak self] in self?.configManager.config.meetingSensing }) { [weak self] mode in
            guard let self, let mode else { return }
            self.modeChanged(mode)
        }
        keepObserving({ [weak self] in self?.appState.phase }) { [weak self] phase in
            guard let self, let phase else { return }
            self.feed(.phaseChanged(Self.sensePhase(of: phase)))
            self.fireQueuedStartIfIdle()
        }
    }

    // MARK: - User answers (island menu / banner buttons)

    func record(_ app: MeetingApp) {
        if appState.isTranscribing {
            island.hide()
            queuedStart = app
            appState.detectedMeeting = DetectedMeeting(app: app, kind: .queued)
            return
        }
        // Decide before tearing the island down: a start the coordinator would refuse must leave the
        // offer standing rather than hide the island and leave a banner button that does nothing.
        guard appState.isIdle else {
            Logger.state.info("Record chosen while neither idle nor transcribing — ignoring")
            return
        }
        island.hide()
        let title = calendarTitle
        Task { [launcher] in
            let started = await launcher.quickStart(app: app, calendarTitle: title)
            // The only refusal left is the narrow window where a start is in flight with the phase
            // still idle; the phase flip that immediately follows withdraws this offer anyway.
            if !started { Logger.state.warning("Quick start refused (not idle / start in flight)") }
        }
    }

    func nameFirst() {
        island.hide()   // the banner stays until the recording starts
        Task { [launcher] in await launcher.promptAndStart() }
    }

    func notNow() { feed(.notNow) }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    func stop() {
        // Guard BEFORE hiding, so a rejected stop leaves the offer on screen instead of dismissing it.
        // The mirror of the coordinator's start guard. `startInFlight` is internal to Core, but a start
        // in flight has not reached `.recording` yet (the phase flips only once the helper is up), so
        // requiring `.recording` here is that same guard seen from outside: this stop can never race a
        // start, and a click on a stale offer after the recording ended does nothing.
        guard appState.isRecording else {
            Logger.state.info("Stop offer answered while not recording — ignoring")
            return
        }
        island.hide()
        Task { [coordinator] in await coordinator.stopRecording() }
    }

    func keepRecording() { feed(.keepRecording) }

    // MARK: - Engine plumbing

    private func feed(_ input: MeetingSenseInput) {
        let result = MeetingSenseEngine.step(state, input: input, mode: mode, now: Date())
        state = result.state
        result.actions.forEach(apply)
    }

    private func modeChanged(_ newMode: MeetingSenseMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .prompt {
            sensor.start()
        } else {
            // Teardown is the presenter's job here, never an engine action: with the mode off while
            // recording the engine emits no `.watch` at all, so the per-process listeners must be
            // cleared from this side — and cleared as the sensor's standing instruction, so a later
            // restart cannot re-arm them from stale bundle IDs.
            sensor.setWatched(bundleIDs: [])
            sensor.stop()
            // An empty snapshot, so the engine forgets what was capturing and (via its `mode == .off`
            // tail) withdraws whatever is on screen.
            feed(.snapshot(CaptureSnapshot(capturingBundleIDs: [])))
        }
        Logger.state.info("Meeting sensing mode: \(newMode.rawValue, privacy: .public)")
    }

    private func apply(_ action: MeetingSenseAction) {
        switch action {
        case .offerStart(let app, let expand):
            showStartOffer(app, expand: expand)
        case .withdrawStart:
            island.hide()
            appState.detectedMeeting = nil
            queuedStart = nil
            calendarTitle = nil
        case .offerStop(let app):
            showStopOffer(app)
        case .withdrawStop:
            island.hide()
            appState.detectedMeeting = nil
        case .watch(let bundleIDs):
            sensor.setWatched(bundleIDs: bundleIDs)
        case .scheduleScan(let after):
            sensor.scheduleScan(after: after)
        }
    }

    private func showStartOffer(_ app: MeetingApp, expand: Bool) {
        // Claimed once, ever; the rule and its store live in Core so "exactly once" has a test.
        let firstEver = MeetingDisclosure.consumeFirstShowing(store: UserDefaults.standard)
        island.show(MeetingIslandOffer(
            title: MeetingOfferText.startTitle,
            subtitle: MeetingOfferText.startSubtitle(app: app, firstEver: firstEver),
            primaryTitle: "Record",
            primary: { [weak self] in self?.record(app) },
            menu: [
                ("Name it first…", { [weak self] in self?.nameFirst() }),
                ("Not now", { [weak self] in self?.notNow() }),
                ("Turn off meeting detection…", { [weak self] in self?.openSettings() }),
            ],
            compactLabel: app.displayName
        ), expanded: expand)
        appState.detectedMeeting = DetectedMeeting(app: app, kind: .start)
        warmCalendar(for: app, decorateSubtitle: !firstEver)
    }

    /// Look the calendar title up as soon as the offer appears, not when Record is clicked: the click
    /// must start a recording immediately, and the name is baked into the filenames at start. Off main
    /// and bounded, like every other lookup (#197) — only the deadline is longer, because this one
    /// blocks nothing. The title only decorates the subtitle when it is not carrying the disclosure.
    private func warmCalendar(for app: MeetingApp, decorateSubtitle: Bool) {
        calendarTitle = nil   // never name this meeting after the last one
        Task { [weak self] in
            guard let self else { return }
            let title = await self.calendarService.currentEventTitle(
                lookaheadMinutes: self.configManager.config.calendarLookaheadMinutes,
                timeout: Self.calendarWarmTimeout
            )
            // The offer may have been answered or withdrawn while the query ran.
            guard let title, !title.isEmpty, self.state.pendingStart == app else { return }
            self.calendarTitle = title
            if decorateSubtitle {
                self.island.update(subtitle: MeetingOfferText.startSubtitle(calendarTitle: title, app: app))
            }
        }
    }

    private func showStopOffer(_ app: MeetingApp) {
        let session = RecordingSentinel.read()?.sessionName ?? "this recording"
        island.show(MeetingIslandOffer(
            title: MeetingOfferText.stopTitle,
            subtitle: MeetingOfferText.stopSubtitle(app: app, sessionName: session),
            primaryTitle: "Stop",
            primary: { [weak self] in self?.stop() },
            menu: [("Keep recording", { [weak self] in self?.keepRecording() })],
            compactLabel: app.displayName
        ), expanded: true)
        appState.detectedMeeting = DetectedMeeting(app: app, kind: .stop)
    }

    /// The other half of the queued start (`record` while transcribing). Runs on every phase change;
    /// the rule itself is `MeetingQueuedStart`, so "never start a recording for a call that already
    /// ended" is pinned by tests rather than by this wiring.
    private func fireQueuedStartIfIdle() {
        switch MeetingQueuedStart.decide(
            queued: queuedStart, isIdle: appState.isIdle, capturing: Set(state.capturing.keys)
        ) {
        case .wait:
            return
        case .drop:
            queuedStart = nil
            appState.detectedMeeting = nil
            Logger.state.info("Queued start dropped — the call ended before the previous recording finished")
        case .start(let app):
            queuedStart = nil
            let title = calendarTitle
            Task { [launcher, appState] in
                let started = await launcher.quickStart(app: app, calendarTitle: title)
                guard !started else { return }
                Logger.state.warning("Queued start refused (not idle / start in flight)")
                // Nothing else would clear it: no phase flip follows a refusal, so the engine emits no
                // withdrawal and the `.queued` banner would sit there with a dead button until the call
                // app released the mic.
                appState.detectedMeeting = nil
            }
        }
    }

    private static func sensePhase(of phase: AppState.Phase) -> MeetingSensePhase {
        switch phase {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        }
    }
}
