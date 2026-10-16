import CoreGraphics
import Foundation
import Observation
import os

// Sleep, wake, power-off and quit (§8.10): moved out of RecordingCoordinator.swift as is (L review 111, M8). The
// state they share stays in the class; what they reach across the file boundary is internal, not private.
extension RecordingCoordinator {
    // MARK: - Sleep, wake, power-off, quit (§8.10)

    /// Follow the phase: begin or end the idle-sleep activity, close a sleep/wake pairing the recording's end
    /// left open, run a pending-session retry asked for while busy once idle, then re-evaluate on the phase's
    /// next change.
    func trackIdleSleepActivity() {
        // A pending-session retry asked for while busy runs now the app is idle (L follow-up 35).
        if appState.isIdle, retryPendingWhenIdle, !recoveryGateHeld {
            Task { await self.retryPendingSessions() }
        }
        // The recording ended between a sleep and its wake: the helper still gets its "wake" (L10 review 57).
        if !appState.isRecording, sleptAt != nil { closeSleepPairing() }
        if !appState.isRecording {
            implicitWakeAt = nil
            framesSinceImplicitWake = false
        }
        if !appState.isIdle, idleSleepActivity == nil {
            idleSleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Recording a meeting")
        } else if appState.isIdle, let activity = idleSleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            idleSleepActivity = nil
        }
        withObservationTracking {
            _ = appState.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIdleSleepActivity() }
        }
    }

    /// `NSWorkspace.willSleep` while recording: nothing is captured until the wake. The helper is told
    /// (it pauses its detectors), the status poll and the rotation timer stop — a rotation the timer
    /// would owe on wake is the wake's forced one — and the lost-wake watchdog is armed (L10 review 55).
    /// During a Stop only the helper's pairing and the record matter: the stop owns the rest (L10 review 54).
    public func systemWillSleep(at date: Date = Date()) {
        guard appState.isRecording, sleptAt == nil else { return }
        Logger.state.info("System going to sleep while recording")
        sleptAt = date
        implicitWakeAt = nil   // a new sleep: the last one's implicit wake is settled
        framesSinceImplicitWake = false
        captureClient.record(.systemSleep, .info, [:])
        if !stopInFlight {
            stopStatusPoll()
            transcriptionRunner.stopChunkRotation()
        }
        let previous = sleepDelivery
        sleepDelivery = Task {
            await previous?.value
            await self.captureClient.systemPowerEvent("sleep")
        }
        armLostWakeWatchdog(sleptAt: date)
    }

    /// `NSWorkspace.didWake`: the helper is told — only after its "sleep" landed (H7) — and, while recording,
    /// the sleep becomes a capture gap in the session (re-detect's bound reads an unrecorded gap as implausible
    /// timing), a rotation seals the chunk that spans the sleep, and "Resumed" waits for the first frames again.
    /// A Stop in flight gets the gap and the pairing, never a rotation, a timer, a poll or a banner (L10 review
    /// 54). `implicit`: no didWake came, the watchdog stands in (L10 review 55).
    public func systemDidWake(at date: Date = Date()) {
        if sleptAt == nil, let since = implicitWakeAt {
            realWakeAfterImplicit(since: since, at: date)
            return
        }
        systemDidWake(at: date, implicit: false)
    }

    /// The watchdog stood in for a wake that had not come — a DarkWake it took for one — and the real one is here
    /// (L review 104): the rest of the sleep is a gap too, and the rotation and the "waiting for audio" banner run
    /// again. The helper already had its "wake": one sleep, one wake.
    func realWakeAfterImplicit(since: Date, at date: Date) {
        implicitWakeAt = nil
        let framesBack = framesSinceImplicitWake
        framesSinceImplicitWake = false
        guard appState.isRecording else { return }
        let end = max(since, date)
        // The capture's frames came back after the implicit wake: that audio WAS captured — no second gap over it, and
        // nothing to redo (L review 162).
        guard !framesBack else {
            Logger.state.info("The real wake arrived after the implicit one, once audio was back — no second gap")
            captureClient.record(.systemWake, .info, ["after_implicit": "true", "frames_back": "true"])
            return
        }
        Logger.state.info("The real wake arrived after the implicit one (\(Int(end.timeIntervalSince(since)), privacy: .public) s after its gap's end)")
        captureClient.record(.systemWake, .info, ["seconds": "\(Int(end.timeIntervalSince(since)))", "after_implicit": "true"])
        let gap = CaptureGap(start: since, end: end, reason: "sleep")
        Task { await self.transcriptionRunner.recordCaptureGap(gap) }
        guard !stopInFlight else { return }
        resumeMonitoringAfterWake()
    }

    func systemDidWake(at date: Date, implicit: Bool) {
        guard let start = sleptAt else { return }
        guard appState.isRecording else {
            closeSleepPairing()   // the recording ended meanwhile: the pairing only
            return
        }
        sleptAt = nil
        lostWakeWatchdog?.cancel()
        lostWakeWatchdog = nil
        let end = max(start, date)
        Logger.state.info("System woke while recording (\(Int(end.timeIntervalSince(start)), privacy: .public) s asleep\(implicit ? ", implicit" : "", privacy: .public))")
        var detail = ["seconds": "\(Int(end.timeIntervalSince(start)))"]
        if implicit { detail["implicit"] = "true" }
        captureClient.record(.systemWake, .info, detail)
        let gap = CaptureGap(start: start, end: end, reason: "sleep")
        Task { await self.transcriptionRunner.recordCaptureGap(gap) }
        if implicit { implicitWakeAt = end }
        deliverWake()
        guard !stopInFlight else { return }   // the recording is ending: nothing to restart
        resumeMonitoringAfterWake()
    }

    /// A rotation seals the chunk that spans the sleep; the timer, the poll and "Resumed"'s wait for frames restart.
    /// `rotateNow()` before `startChunkRotation()` is safe (L review 241): the sleep stopped the rotator, and the rotation it
    /// queues runs in a Task — only after this synchronous turn, by which `start()` has cleared the stop flag it checks.
    func resumeMonitoringAfterWake() {
        transcriptionRunner.chunkRotator?.rotateNow()
        transcriptionRunner.startChunkRotation()
        startStatusPoll()
        awaitingRecoveryFrames = true
        recoveryFramesAt = nil
        appState.interruptionWarning = "Recording restarted — waiting for audio…"
    }

    /// The helper's "wake", after its "sleep" landed.
    func deliverWake() {
        let sleep = sleepDelivery
        sleepDelivery = Task {
            await sleep?.value
            await self.captureClient.systemPowerEvent("wake")
        }
    }

    /// The recording ended between a sleep and its wake: the helper gets its "wake" now — the pairing holds —
    /// and the sleep is forgotten, so a later didWake does nothing (L10 review 57).
    func closeSleepPairing() {
        guard sleptAt != nil else { return }
        sleptAt = nil
        lostWakeWatchdog?.cancel()
        lostWakeWatchdog = nil
        deliverWake()
    }

    /// A DarkWake or Power Nap is awake time with the display asleep (L review 104): the watchdog re-arms instead of
    /// firing, for up to `darkWakeCap` after the first dark sign — bounded as the helper's own pause is.
    func armLostWakeWatchdog(sleptAt start: Date) {
        lostWakeWatchdog?.cancel()
        let clock = wakeWatchdogClock, timeout = lostWakeTimeout, cap = darkWakeCap
        lostWakeWatchdog = Task { [weak self] in
            var dark: Duration = .zero
            while true {
                do { try await clock.sleep(for: timeout) } catch { return }   // cancelled: the wake came
                guard let self, self.sleptAt == start else { return }
                guard !self.displayIsAwake(), dark < cap else { break }
                dark += timeout
                Logger.state.info("Awake with the display asleep (a DarkWake) — still waiting for the real wake")
            }
            guard let self else { return }
            // Every re-arm counted (L review 162): the awake time since the sleep is the timeout plus the dark stretches.
            Logger.state.error("No wake arrived \(Self.seconds(timeout + dark), privacy: .public) s of awake time after the sleep — waking implicitly")
            // Awake for `timeout` since the wake that never came: it was about that long ago.
            self.systemDidWake(at: Date().addingTimeInterval(-Self.seconds(timeout)), implicit: true)
        }
    }

    // MARK: Quit and termination (L10 review 53, 58, 60)

    /// What an exit would cut short now (L10 review 53): a recording, a start or a stop in flight, a
    /// transcript being finished, or a crash recovery.
    public var hasWorkInFlight: Bool {
        TerminationPolicy.isBusy(recording: appState.isRecording, startInFlight: isStartInFlight, stopInFlight: stopInFlight,
                                 transcribing: appState.isTranscribing, recoveryInFlight: recoveryInFlight)
    }

    /// Every Quit Parley offers goes through here (L10 review 58) — the menu's, and the setup panel's, which
    /// can be up during a Flow A re-attach or a resume: with a coordinator, it asks and stops first
    /// (`prepareForQuit`); without one nothing can be recording.
    public static func quitGate(_ coordinator: RecordingCoordinator?, confirm: () async -> Bool) async -> Bool {
        guard let coordinator else { return true }
        return await coordinator.prepareForQuit(confirm: confirm)
    }

    /// Quit. Idle → true. While recording, or while a start is in flight → `confirm()`: true → the start is
    /// awaited, then the recording is stopped — or a stop, a finalize or a recovery already running awaited —
    /// within `quitStopBound`, then true; false → false (Parley stays). A stop still running at the bound is
    /// left to the next launch, worded as a quit.
    ///
    /// A Stop already in flight — the helper's stop, or the finalize after it, or a Stop a crash restart deferred (L
    /// review 171) — asks nothing: the recording is already stopping; the Quit waits for it within the same bound (L
    /// review 111). The relaunch probing a previous recording is not a start the user made: nothing is asked or stopped
    /// then, and the next launch probes again (L review 138) — until its ping answers that a capture IS running (Flow A):
    /// from then on that capture is a recording, asked about and stopped (L review 170).
    public func prepareForQuit(confirm: () async -> Bool) async -> Bool {
        exitFlushTimedOut = false   // each exit attempt says its own flush (L review 244)
        let alreadyStopping = stopInFlight || stopRequestedDuringRecovery
        guard appState.isRecording || userStartInFlight || alreadyStopping || relaunchFoundCapture else {
            await markExitDuringFinalize(by: SuspendingClock.now + exitMarkBound)
            await decideLaunchAgentKeep(by: SuspendingClock.now + exitMarkBound)   // an idle Quit too (L review 257)
            return true
        }
        if !alreadyStopping {
            guard await confirm() else { return false }
        }
        isQuitting = true
        quitLeftAHeldSession = false
        defer { isQuitting = false }
        // A long quit says so: the menu shows it, and a notification once it outlasts `quitFeedbackDelay`.
        let delay = quitFeedbackDelay
        let feedback = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isQuitting else { return }
            self.notify("Quitting Parley", "Parley is saving the recording before it quits — this can take up to half a minute.")
        }
        defer { feedback.cancel() }
        let deadline = SuspendingClock.now + quitStopBound
        await stopForExit(bound: quitStopBound)
        await markExitDuringFinalize(by: max(deadline, SuspendingClock.now + exitMarkBound))
        await decideLaunchAgentKeep(by: max(deadline, SuspendingClock.now + exitMarkBound))
        return true
    }

    /// Whether the Quit leaves a session the helper still holds (L reviews 223, 257, 269): decided from what is ON DISK at
    /// every exit of the Quit — never from whether a hold happened to land while the Quit waited (one landing while its alert
    /// was up, or after its bound ran out, used to be missed). Kept when a pending session — or the slot's — is held, or is a
    /// session whose stop attempt has not seen its helper let go (`sessionsNotLetGo`: from the attempt's start — the refusal
    /// re-asks and the wait before a hold included — until the helper lets go or the hold is written): said, never a silent
    /// exit, and the LaunchAgent stays so the next launch finishes it. The look is bounded by the exit's `deadline` (never past
    /// `exitMarkBound`); one that does not answer falls back to what this run knows — a hold during the Quit, or a session
    /// not let go.
    func decideLaunchAgentKeep(by deadline: SuspendingClock.Instant) async {
        let directory = sentinelDirectory, notLetGo = sessionsNotLetGo
        var onDisk: Bool?
        if !sentinelIO.isStalled {
            let bound = min(exitMarkBound, max(.zero, deadline - .now))
            onDisk = await sentinelIO.run("quit: held sessions", seconds: max(0.001, Self.seconds(bound))) {
                let sessions = RecordingSentinel.readPending(directory: directory) + [RecordingSentinel.read(directory: directory)].compactMap { $0 }
                return sessions.contains { $0.heldReason != nil || notLetGo.contains($0.sessionKey) }
            }
        }
        let keep: Bool
        if let onDisk {
            keep = onDisk
        } else {
            Logger.state.error("The recovery file did not answer the Quit's look for a held recording — deciding from what this run knows")
            keep = quitLeftAHeldSession || !notLetGo.isEmpty
        }
        keepsLaunchAgentOnQuit = keep
        guard keep else { return }
        notify("Quitting Parley", "A previous recording is still being stopped; Parley will finish it next time.")
    }

    /// Logout, shutdown, restart, or a quit from outside Parley (Activity Monitor, `osascript`, Sparkle): the
    /// process ends right after this returns (L10 review 53). Within `bound` — tight — a start in flight is let
    /// resolve and the helper is stopped, so it seals its files; the sentinel is left marked `stopping` (and
    /// quit-during-finalize), and the long finalize is skipped: the next launch salvages it through
    /// `.salvageAndStop(.wasStopping)`. A second request joins the first.
    public func prepareForTermination(bound: Duration) async {
        if let running = terminationPrep {
            await running.value
            return
        }
        let prep = Task { await self.prepareTermination(bound: bound) }
        terminationPrep = prep
        await prep.value
        terminationPrep = nil
    }

    func prepareTermination(bound: Duration) async {
        let deadline = SuspendingClock.now + bound
        exitFlushTimedOut = false   // each exit attempt says its own flush (L review 244)
        guard hasWorkInFlight else { return }
        Logger.state.info("Parley is being terminated with work in flight — stopping the helper, the finalize is left to the next launch")
        // A crash restart in flight keeps the user's stop across its sentinel rewrite.
        if recoveryInFlight { stopRequestedDuringRecovery = true }
        await markSentinelStoppingOffMain(by: deadline)
        await markExitDuringFinalize(by: deadline)
        _ = try? await withDeadline(seconds: Self.seconds(until: deadline), label: "termination: start in flight") {
            await self.awaitSettled { !$0.isStartInFlight }
        }
        await markSentinelStoppingOffMain(by: deadline)   // a start that just wrote its sentinel
        if appState.isRecording || recoveryInFlight {
            stopStatusPoll()
            transcriptionRunner.stopChunkRotation()
            if stopInFlight {
                // The user's Stop is asking the helper already: wait for its answer, not its finalize. No answer by
                // the deadline: the connection is dropped, and the helper's invalidation handler stops it (L review
                // 111, M7) — never a helper left capturing behind an app that is gone.
                do {
                    try await withDeadline(seconds: Self.seconds(until: deadline), label: "termination: stop in flight") {
                        await self.awaitSettled { !$0.appState.isRecording }
                    }
                } catch {
                    Logger.state.error("The Stop in flight did not get the helper's answer within the termination's bound — dropping the connection")
                    captureClient.dropConnection()
                }
            } else {
                _ = try? await withDeadline(seconds: Self.seconds(until: deadline), label: "termination: rotation") {
                    await self.awaitRotationInFlight()
                }
                do {
                    try await bounded("termination stop", seconds: Self.seconds(until: deadline)) { try await self.stopHelper() }
                } catch is CaptureCallTimeout {
                    captureClient.dropConnection()   // the helper's invalidation handler stops it (L9 review 45)
                } catch {
                    Logger.state.error("The capture helper's stop at termination failed: \(error, privacy: .private)")
                }
            }
        }
        // Again: a restart or a start may have rewritten the sentinel meanwhile.
        await markSentinelStoppingOffMain(by: deadline)
        await markExitDuringFinalize(by: deadline)
        await flushEvidenceForExit(by: deadline)   // within what is left of the bound (L review 145)
    }

    /// The app is ending NOW (L review 85): SYNCHRONOUSLY — the process can exit in the same turn, before any Task runs — the
    /// sentinel is marked `stopping` (salvage-only) and quit, so the next launch salvages it as a quit even if the bounded
    /// helper stop that follows never gets to run. The terminate delegate calls it before it answers `.terminateLater`.
    /// Bounded (L review 235): never past `exitMarkBound`, and not waited for at all on a recovery file's queue already
    /// stuck — the preparation that follows marks it again, within the termination's own bound.
    public func markForTermination() {
        let directory = sentinelDirectory
        _ = markNow("mark for termination") {
            Self.markStopping(directory: directory)
            Self.markQuit(directory: directory)
        }
    }

    /// The app is about to end while a stopped recording's transcript is still being finished (its
    /// sentinel is there, marked `stopping`): say so in the sentinel, so the next launch words it as a
    /// quit, never "Parley crashed" (L follow-up 42). Synchronous and public (L review 85) — bounded (L review 235). A live
    /// recording is left alone — a logout can still be cancelled. The quit's own mark: it stands, even over `willPowerOff`'s
    /// time-boxed one.
    public func markExitDuringFinalize() {
        let directory = sentinelDirectory
        _ = markNow("mark quit") { Self.markQuit(directory: directory) }
    }

    /// `markExitDuringFinalize`, for a Quit or a termination preparing its exit (L review 235): off the main actor, within the
    /// exit's own `deadline` — a stuck recovery file never holds the exit past its bound.
    func markExitDuringFinalize(by deadline: SuspendingClock.Instant) async {
        let directory = sentinelDirectory
        _ = await exitMark("mark quit", by: deadline) { Self.markQuit(directory: directory) }
    }

    /// The quit mark itself, read and written in one step on the recovery file's queue.
    nonisolated static func markQuit(directory: URL?) {
        guard var sentinel = RecordingSentinel.read(directory: directory), sentinel.stopping,
              !sentinel.quitDuringFinalize || sentinel.quitMarkedByPowerOff else { return }
        sentinel.quitDuringFinalize = true
        sentinel.quitMarkedByPowerOff = false
        do {
            try RecordingSentinel.write(sentinel, directory: directory)
        } catch {
            Logger.state.error("Could not mark the recovery file as quit during finalize: \(error, privacy: .private)")
        }
    }

    /// `willPowerOff` (L reviews 85, 174): a logout, shutdown or restart is under way — or one the user will cancel. A
    /// transcript being finished is marked as quit at once, SYNCHRONOUSLY (the process can end right after) — bounded (L
    /// review 235) — but only for `powerOffMarkWindow`: the termination itself marks it again for good (`markForTermination`,
    /// the quit), while an app still running past the window saw the logout cancelled — the mark goes, and a later crash is
    /// said as a crash. The mark remembers the session it marked where it lands, on the recovery file's queue: the withdraw,
    /// queued after it, finds it even when this wait ran out first.
    public func markPowerOffDuringFinalize() {
        let directory = sentinelDirectory, mark = powerOffMark
        _ = markNow("mark power-off") { Self.markPowerOff(directory: directory, into: mark) }
        powerOffMarkExpiry?.cancel()
        let window = powerOffMarkWindow
        powerOffMarkExpiry = Task { [weak self] in
            do { try await Task.sleep(for: window) } catch { return }
            await self?.withdrawPowerOffMark()
        }
    }

    nonisolated static func markPowerOff(directory: URL?, into mark: PowerOffMark) {
        guard var sentinel = RecordingSentinel.read(directory: directory), sentinel.stopping, !sentinel.quitDuringFinalize else { return }
        sentinel.quitDuringFinalize = true
        sentinel.quitMarkedByPowerOff = true
        do {
            try RecordingSentinel.write(sentinel, directory: directory)
        } catch {
            Logger.state.error("Could not mark the recovery file as quit during finalize: \(error, privacy: .private)")
            return
        }
        mark.set(sentinel.sessionKey)
    }

    /// The logout or shutdown did not come within its window: `willPowerOff`'s quit mark is withdrawn — from the slot and
    /// from a pending entry that carried it — and a quit's own mark is left alone (L review 174). Only the marks THIS process
    /// set, on every session it marked (L reviews 221, 259): one a dead earlier process left is final — its power-off
    /// happened. Off the main actor, bounded (L review 235).
    func withdrawPowerOffMark() async {
        powerOffMarkExpiry = nil
        let directory = sentinelDirectory, mark = powerOffMark
        if await sentinelIO.run("withdraw power-off mark", seconds: Self.seconds(sentinelDeadline), {
            Self.withdrawPowerOff(directory: directory, mark: mark)
        }) == nil {
            Logger.state.error("The power-off mark's withdraw did not answer — it stays queued")
        }
    }

    nonisolated static func withdrawPowerOff(directory: URL?, mark: PowerOffMark) {
        let marked = mark.take()
        guard !marked.isEmpty else { return }
        if var sentinel = RecordingSentinel.read(directory: directory), marked.contains(sentinel.sessionKey), sentinel.quitMarkedByPowerOff {
            sentinel.quitDuringFinalize = false
            sentinel.quitMarkedByPowerOff = false
            do {
                try RecordingSentinel.write(sentinel, directory: directory)
                Logger.state.info("No logout or shutdown followed willPowerOff — the quit mark on the transcript being finished is withdrawn")
            } catch {
                Logger.state.error("Could not withdraw the power-off quit mark: \(error, privacy: .private)")
            }
        }
        let pending = RecordingSentinel.loadPending(directory: directory).sessions
        guard pending.contains(where: { marked.contains($0.sessionKey) && $0.quitMarkedByPowerOff }) else { return }
        do {
            try RecordingSentinel.writePending(pending.map {
                var entry = $0
                if marked.contains(entry.sessionKey), entry.quitMarkedByPowerOff { entry.quitDuringFinalize = false; entry.quitMarkedByPowerOff = false }
                return entry
            }, directory: directory)
        } catch {
            Logger.state.error("Could not withdraw the power-off quit mark from the pending sessions: \(error, privacy: .private)")
        }
    }

    /// The sessions `willPowerOff`'s marks landed on — every one this process marked (L reviews 221, 259) — set and taken on
    /// the recovery file's queue.
    final class PowerOffMark: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: Set<String> = []
        func set(_ key: String) { lock.withLock { _ = sessions.insert(key) } }
        func take() -> Set<String> { lock.withLock { defer { sessions = [] }; return sessions } }
    }

    /// A mark on the recovery file a Stop or an exit makes (L reviews 217, 235): on its queue, bounded by the exit's
    /// `deadline` — never past `exitMarkBound` then — else by `sentinelDeadline`. A queue already stuck behind an operation
    /// past its bound is not waited on at all: the mark is only queued, and lands in order if it unsticks. True when it
    /// answered.
    func exitMark(_ label: String, by deadline: SuspendingClock.Instant?, _ work: @escaping @Sendable () -> Void) async -> Bool {
        guard !sentinelIO.isStalled else {
            sentinelIO.enqueue(label, work)
            Logger.state.error("The recovery file's queue is stuck — \(label, privacy: .public) is queued, never waited for")
            return false
        }
        let bound = deadline.map { min(exitMarkBound, max(.zero, $0 - .now)) } ?? sentinelDeadline
        guard await sentinelIO.run(label, seconds: max(0.001, Self.seconds(bound)), work) != nil else {
            Logger.state.error("The recovery file did not answer \(label, privacy: .public) — it stays queued")
            return false
        }
        return true
    }

    /// A mark made synchronously — the process may end in this very turn (L review 85) — yet bounded (L review 235): it
    /// waits `exitMarkBound` at most, and not at all on a queue already stuck. It lands in order later if the queue unsticks.
    @discardableResult
    func markNow<T>(_ label: String, _ work: @escaping @Sendable () -> T) -> T? {
        guard !sentinelIO.isStalled else {
            sentinelIO.enqueue(label) { _ = work() }
            Logger.state.error("The recovery file's queue is stuck — \(label, privacy: .public) is queued, never waited for")
            return nil
        }
        guard let answer = sentinelIO.waitBounded(label, seconds: Self.seconds(exitMarkBound), work) else {
            Logger.state.error("The recovery file did not answer \(label, privacy: .public) within its bound — it stays queued")
            return nil
        }
        return answer
    }

    /// Before the process ends: let a start in flight resolve (bounded by its own deadline and the stop that
    /// may follow it), then stop the recording — or await the stop, finalize or recovery already running —
    /// until the app is idle, within `bound`. Awaited, never polled (L10 review 60).
    ///
    /// ONE deadline covers the start's wait and the stop (L review 105): a hung start never adds its own 50 s to the
    /// stop's bound. A start still in flight at the deadline leaves its recovery file `stopping`, so the next launch
    /// salvages it and never resumes a recording the user quit.
    func stopForExit(bound: Duration) async {
        let deadline = SuspendingClock.now + bound
        do {
            try await withDeadline(seconds: Self.seconds(until: deadline), label: "exit: start in flight") {
                await self.awaitSettled { !$0.isStartInFlight }
            }
            if !appState.isIdle {
                _ = try? await withDeadline(seconds: Self.seconds(until: deadline), label: "exit stop") { await self.stopUntilIdle() }
            }
        } catch {
            Logger.state.error("A recording start was still running when the quit's bound ran out — its recovery file is marked for salvage")
            await markSentinelStoppingOffMain(by: SuspendingClock.now + exitMarkBound)
        }
        await flushEvidenceForExit(by: deadline)
    }

    func stopUntilIdle() async {
        if appState.isRecording, !stopInFlight { await stopRecording() }
        await awaitSettled { $0.appState.isIdle }
    }

    /// Returns once `condition` holds, re-checked on every change of the observable state it reads.
    func awaitSettled(_ condition: @escaping @MainActor (RecordingCoordinator) -> Bool) async {
        while !condition(self) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition(self)
                } onChange: {
                    cont.resume()
                }
            }
        }
    }
}
