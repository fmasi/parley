import Foundation
import AudioCaptureProtocol
import TranscriberCore
import os

// AudioPaths moved to TranscriberCore (RecordingCaptureClient.swift) so RecordingCoordinator
// can consume stop() results without importing this XPC client.

@MainActor
final class AudioCaptureClient {
    private var connection: NSXPCConnection?
    /// Crash detection, armed per capture generation (C1, L-N1): an idle-exit of the helper between
    /// recordings is not a crash, and each capture escalates at most once.
    private var interruptionPolicy = XPCInterruptionPolicy()
    private var reverseChannel: ReverseChannel?

    /// The session's capture evidence (§8.11): the anomaly-gated ring — helper-origin events drained over
    /// XPC plus the app's own (interruptions, retries, launch recovery) — the live log beside the
    /// recording, and each helper session's latest coverage. Reset only on a NEW session id (council
    /// A-C1); flushed to `<session>.diag.jsonl` only when the session was anomalous (#95).
    private let evidence = SessionEvidence()
    /// What a start drained from a helper that then refused it as busy with an earlier capture (L review 157): that
    /// capture's events, never the refused session's — kept for the coordinator to attribute to the held session.
    private var refusedStartDrain: Data?

    /// Invoked when the XPC connection is invalidated or interrupted by a *real* crash (a fresh
    /// crash report names the helper). Drives the full relaunch / re-attach recovery flow.
    var onServiceCrash: (@Sendable () -> Void)?

    /// Invoked on an XPC interruption with NO matching crash report where the helper is still
    /// capturing — a benign connection blip. The app shows a transient notice and keeps recording
    /// instead of tearing down (#86).
    var onBriefInterruption: (@Sendable () -> Void)?

    /// Invoked (reverse channel) when the helper restarted a benign SCStream stop in place — no
    /// audio lost; the app surfaces a "Recording Resumed" notice (#86).
    var onRestartInPlace: (@Sendable () -> Void)?

    /// Invoked (reverse channel) when the helper could not restart within budget — fatal (#86).
    var onFatalFailure: (@Sendable (String) -> Void)?

    /// Invoked (reverse channel) when the mic auto-switched to a new device — `deviceId` is the
    /// resolved UID (`nil` = system default). Used to refresh the menu label without a banner.
    var onMicDeviceChanged: (@Sendable (String?) -> Void)?

    /// Invoked (reverse channel) when the helper could not restart the MID-RECORDING system (remote)
    /// stream within budget (#86) — surface a "mic only" warning. The recording is NEVER stopped (the
    /// mic keeps recording on its own AVCaptureSession).
    var onSystemAudioUnrecoverable: (@Sendable (String) -> Void)?

    /// Invoked (reverse channel) for a live capture-quality anomaly detected WHILE the recording is
    /// still running (#193/#196) — an exact-zero mic run, a liveness gap, or a disk-full write
    /// failure. `kind` is the `CaptureEventKind` raw value, `message` a user-facing description.
    /// The recording is NEVER stopped by this; it is a warning surface only.
    var onQualityAnomaly: (@Sendable (String, String) -> Void)?

    /// Invoked (reverse channel) on the first heartbeat of a capture generation: (track, helper
    /// session id). Clears the stale alarms a replaced helper left on that track (§6.2).
    var onFirstFrames: (@Sendable (CaptureTrack, String) -> Void)?

    /// Invoked (reverse channel) when the helper pushes a changed alarm set (§6.2).
    var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?

    /// Invoked (reverse channel) on the first non-zero sample on a track: (track, helper session id).
    /// The helper's real-audio evidence (§6.2) — clears the stale CONTENT alarms a replaced helper left.
    var onRealAudio: (@Sendable (CaptureTrack, String) -> Void)?

    /// Invoked (reverse channel) on a successful write: (helper session id). The helper's
    /// write-succeeded evidence (§6.2) — clears a stale `diskWriteFailure` a replaced helper left.
    var onWriteSucceeded: (@Sendable (String) -> Void)?

    func connect() {
        let conn = NSXPCConnection(serviceName: audioCaptureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        // Reverse channel (#86): receive in-place-restart / fatal-failure callbacks from the helper.
        let reverse = ReverseChannel(client: self)
        conn.exportedInterface = NSXPCInterface(with: AudioCaptureClientProtocol.self)
        conn.exportedObject = reverse
        self.reverseChannel = reverse

        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Bind the connection identity so we can detect a concurrent invalidation/recovery
                // cycle that swaps the connection out from under us while we await below (council F7).
                let boundConnection = self.connection
                // An XPC interruption is only a "crash" if a fresh crash report names the helper.
                // A benign route-change blip writes no .ips — classify before tearing down (#86).
                let classification = CrashReportScanner.classifyLive()
                switch self.interruptionPolicy.onInterruption(classification: classification) {
                case .ignoreIdle:
                    if self.interruptionPolicy.expectingCapture {
                        // This generation already escalated once (its crash is being handled): a second
                        // interruption is the same event, not a new one. Nothing to record.
                        Logger.audio.info("XPC interrupted — already handled for this capture generation")
                    } else {
                        // Not capturing: launchd idle-exited the helper. No ping (a ping would spawn a
                        // throwaway helper), no latch. Lands in the unified log and the live log only;
                        // the next resetSession() wipes it from the app ring (it belongs to no session).
                        self.record(.helperIdleExit, .info)
                        Logger.audio.info("XPC interrupted while idle — helper idle-exit, ignored")
                    }
                case .crash:
                    self.record(.xpcInterruption, .anomaly, ["classification": "crash"])
                    Logger.audio.warning("XPC interrupted — crash report present, treating as crash")
                    self.onServiceCrash?()
                case .verifyCapture:
                    self.record(.xpcInterruption, .warning, ["classification": "blip"])
                    let generation = self.interruptionPolicy.captureGeneration
                    Logger.audio.warning("XPC interrupted — no crash report; verifying capture is alive")
                    // A ping the helper does not answer counts as not capturing here: escalate (L round 5).
                    let stillCapturing = await self.captureState() == .capturing
                    // If a concurrent invalidation/recovery already replaced the connection while we
                    // awaited, that path owns this teardown — don't double-fire onServiceCrash (F7).
                    guard self.connection === boundConnection else { return }
                    switch self.interruptionPolicy.onVerified(stillCapturing: stillCapturing, generation: generation) {
                    case .briefInterruption: self.onBriefInterruption?()
                    case .crash:
                        Logger.audio.warning("XPC interrupted — helper not capturing, escalating to crash recovery")
                        self.onServiceCrash?()
                    case .ignoreIdle, .verifyCapture: break
                    }
                case .briefInterruption:
                    break   // onInterruption never returns this; onVerified does
                }
            }
        }
        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self else { return }
                // An older connection's invalidation (one `dropConnection` already replaced) is not this
                // connection's news: it must not clear a newer connection, nor count as its crash. Compared by
                // identity (`===`) through a weak reference, never an `ObjectIdentifier`, which a freed
                // connection's address can hand to a new one (L review 114).
                if let current = self.connection, current !== conn { return }
                self.connection = nil
                switch self.interruptionPolicy.onInvalidation() {
                case .crash:
                    Logger.audio.warning("XPC connection invalidated during capture")
                    self.record(.xpcInvalidation, .anomaly)
                    self.onServiceCrash?()
                default:
                    Logger.audio.info("XPC connection invalidated while idle")
                    self.record(.xpcInvalidation, .info)
                }
            }
        }
        conn.resume()
        Logger.audio.debug("XPC connection established")
        connection = conn
        // Pull the helper's alarm state on every connect (§6.2): a re-attached or restarted helper's
        // state reaches the app without waiting for its next push. The body runs after `connect()`
        // has returned; a connection already replaced by then (an instant invalidation) is skipped,
        // so this can never become a reconnect loop.
        Task { @MainActor [weak self] in
            guard let self, self.connection === conn, let s = await self.captureStatus() else { return }
            self.onAlarmsChanged?(s)
        }
    }

    func record(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        _ detail: [String: String] = [:]
    ) {
        evidence.record(CaptureEvent(
            timestamp: Date(), origin: .app, kind: kind, severity: severity, detail: detail
        ))
    }

    /// Record an XPC-retry event (a relaunch/reconnect attempt after a crash) (#95).
    func recordRetry(_ detail: [String: String] = [:]) {
        record(.retry, .warning, detail)
    }

    /// The recording ended without `stop()` (recovery gave up, or nothing was restarted): disarm (C1).
    func captureEnded() { interruptionPolicy.captureStopped() }

    /// A launch re-attach to a capture this process did not start: arm, as `start` does (C1).
    func captureReattached() { interruptionPolicy.captureStarted() }

    /// Record that the app re-attached to or relaunched a recording on launch (crash recovery) (#95).
    func recordLaunchRecovery(_ detail: [String: String] = [:]) {
        record(.launchRecovery, .warning, detail)
    }

    /// A relaunch continues `sessionId`: adopt it first, then drain the helper into it (L follow-up 43) — unless the
    /// helper holds ANOTHER session's capture (a held one, L review 167): then it binds without draining.
    /// The resume's own `start` then keeps it all (the same session id resets nothing).
    func adoptSession(sessionId: String, directory: URL, drainHelper: Bool) async {
        evidence.beginCapture(sessionId: sessionId, directory: directory)
        guard drainHelper else { return }
        if !(await drainHelperDiagnostics()) { recordDrainTimeout() }
    }

    /// A start that never became a recording (L11 review 68): its evidence is dropped, its live log deleted.
    func discardSessionEvidence(sessionId: String, directory: URL) {
        evidence.discard(sessionId: sessionId, directory: directory)
    }

    /// A relaunch binds the session it continues at once, before anything is recorded into it; the adopt that
    /// follows then only drains (L review 121).
    func bindSession(sessionId: String, directory: URL) {
        evidence.beginCapture(sessionId: sessionId, directory: directory)
    }

    /// The session's transcript is on disk: its live log goes (L review 97).
    func commitSessionDiagnostics(sessionId: String, directory: URL) {
        evidence.commit(sessionId: sessionId, directory: directory)
    }

    /// A pending retry stopped a stray helper: drain it ONCE, and give its events to the pending session that
    /// knows its helper sessions, or to none (L review 98). The folders are read off the main actor, bounded. False when
    /// the drain did not answer — it timed out, or failed — and the helper's events are still with it (L review 142).
    func attributeHelperDrain(toOneOf sessions: [(sessionId: String, directory: URL)]) async -> Bool {
        switch await drainHelperData() {
        case .timedOut:
            Logger.audio.error("The capture helper did not answer drainDiagnostics within 3 s — its events stay with it")
            return false
        case .failed:
            Logger.audio.error("The capture helper's drainDiagnostics failed — its events stay with it")
            return false
        case .nothing:
            return true
        case .data(let data):
            await evidence.attributeHelperDrain(data, toOneOf: sessions)
            return true
        }
    }

    /// A start the helper refused as busy (L review 157): what that start drained is the busy capture's — given to the
    /// pending session that knows its helper sessions, never lost with the refused session's evidence.
    func attributeRefusedStartDrain(toOneOf sessions: [(sessionId: String, directory: URL)]) async {
        guard let data = refusedStartDrain else { return }
        refusedStartDrain = nil
        await evidence.attributeHelperDrain(data, toOneOf: sessions)
    }

    /// Every queued live-log write reaches the disk (L review 96). Blocking file work: off the main actor; the
    /// caller bounds it.
    func flushEvidence() async {
        await Task.detached(priority: .userInitiated) { LiveDiagnosticsLog.flushAll() }.value
    }

    /// Reverse-channel receipt of a system-stream-unrecoverable warning (#86). Records the anomaly into
    /// the app ring — so it lands in the transcript provenance (`system_audio_unrecovered`) and flags
    /// the session — then surfaces the warning. The recording is NEVER stopped (the mic keeps recording).
    func handleSystemAudioUnrecoverable(reason: String) {
        record(.systemAudioUnrecovered, .anomaly, ["reason": reason])
        onSystemAudioUnrecoverable?(reason)
    }

    /// Reverse-channel receipt of a live capture-quality anomaly (#193/#196). NOT re-recorded into
    /// the app ring here — the helper already recorded the matching event into ITS OWN ring (origin
    /// `.helper`), which `drainHelperDiagnostics()` merges in at session end; doing it again here
    /// would double-count the same event under a different origin. This method is purely the live
    /// user-facing surface.
    func handleQualityAnomaly(kind: String, message: String) {
        onQualityAnomaly?(kind, message)
    }

    // MARK: - Deadlines (§8.8)

    /// One helper call, bounded (Core's `boundedReply`, on awake time): the reply, the XPC error handler and
    /// the deadline race, and a late reply is ignored. A timeout is recorded as an `xpcTimeout` anomaly —
    /// into the session the call was made for, never a later one (L9 review 52) — and thrown as
    /// `CaptureCallTimeout`, a Core type the coordinator recognizes.
    private func bounded<T: Sendable>(
        _ call: String, seconds: Double,
        _ send: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let madeIn = evidence.epoch
        let result: Result<T, Error> = await boundedReply(call, seconds: seconds, send)
        if case .failure(let error as CaptureCallTimeout) = result {
            Logger.audio.error("The capture helper did not answer \(call, privacy: .public) within \(seconds, privacy: .public) s")
            evidence.record(CaptureEvent(timestamp: Date(), origin: .app, kind: .xpcTimeout, severity: .anomaly, detail: ["call": call]),
                            madeIn: madeIn)
            throw error
        }
        return try result.get()
    }

    /// Pull and clear the helper's diagnostic ring over XPC, merging its events into the app ring.
    /// Bounded at 3 s: a helper that does not answer leaves its events behind, never the caller stuck. False
    /// on that timeout: the caller records it into the session it concerns (L11 review 68) — a start's drain,
    /// say, is the NEW session's first call, while its events still belong to the previous one.
    private func drainHelperDiagnostics() async -> Bool {
        merge(await drainHelperData())
    }

    /// A drain into the ring: false when it timed out. A failed drain is said — never silent (L review 142) — and on
    /// record in the session's evidence (L review 203).
    private func merge(_ drain: HelperDrain) -> Bool {
        if case .timedOut = drain { Logger.audio.error("The capture helper did not answer drainDiagnostics within 3 s") }
        return evidence.mergeDrain(drain)
    }

    /// A drain of the helper's ring, as it came back (L reviews 142, 203).
    private typealias HelperDrain = SessionEvidence.HelperDrain

    private func drainHelperData() async -> HelperDrain {
        guard let conn = connection else { return .nothing }
        let reply: Result<HelperDrain, Error> = await boundedReply("drainDiagnostics", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(.failed)) } as! AudioCaptureProtocol
            proxy.drainDiagnostics { done(.success($0.map(HelperDrain.data) ?? .nothing)) }
        }
        guard case .success(let drain) = reply else { return .timedOut }
        return drain
    }

    private func recordDrainTimeout() {
        record(.xpcTimeout, .anomaly, ["call": "drainDiagnostics"])
    }

    /// Drain the helper, merge the live log and the helper sessions' latest coverage (L11), and build the
    /// transcript provenance stamp. The evidence writes `<sessionId>.diag.jsonl` beside the recording only
    /// when the session was anomalous (#95). Its live log stays until `commitSessionDiagnostics`, once the transcript
    /// exists (L review 97). A clean session writes no log, only the ~200-byte provenance stamp the caller embeds.
    func finalizeSessionDiagnostics(
        sessionId: String,
        engine: String,
        recordingDirectory: URL,
        drainHelper: Bool
    ) async -> CaptureProvenance {
        // Not while the helper holds ANOTHER (held) session's capture (L review 198): its events wait for that session.
        if drainHelper, !(await drainHelperDiagnostics()) { recordDrainTimeout() }
        let diagnostics = await evidence.finalize(sessionId: sessionId, directory: recordingDirectory)

        func formatString(_ kind: CaptureEventKind) -> String? {
            guard let e = diagnostics.events.last(where: { $0.kind == kind }) else { return nil }
            return "\(e.detail["rate"] ?? "?")Hz/\(e.detail["channels"] ?? "?")ch"
        }
        // The mic device is whatever the most recent start / switch / mic-recovery event captured on.
        // Including the mic in-place restart (a route-change fallback or re-pin) keeps mic_device
        // honest about the device that ACTUALLY captured the audio after a fallback (council HOL-3) —
        // not the originally-pinned device that may have since disconnected.
        let micDevice = diagnostics.events.last {
            $0.kind == .micSwitch || $0.kind == .captureStart
                || ($0.kind == .restartInPlace && $0.detail["source"] == "mic")
        }?.detail["mic"]

        return diagnostics.makeProvenance(
            engine: engine,
            systemFormat: formatString(.systemFormatDetected),
            micFormat: formatString(.micFormatDetected),
            micDevice: micDevice
        )
    }

    /// Bounded: the drain of the previous helper's events (3 s) and `configureCapture` (3 s, best effort) run
    /// first, then the `startCapture` call itself (15 s) — worst case 21 s to a start failure (§8.8).
    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String? = nil,
        systemAudioSource: SystemAudioSource = .screenCaptureKit,
        options: CaptureOptions = CaptureOptions(),
        sessionId: String = ""
    ) async throws {
        refusedStartDrain = nil
        // The previous helper's events first (bounded, 3 s): its start clears its own ring, and an
        // in-session restart must not lose them (L11).
        let drain = await drainHelperData()
        let drained = merge(drain)
        // A NEW session resets every tally, so no recording inherits an earlier one's facts (council
        // A-C1); the SAME session — an in-session restart, a resume — keeps its evidence.
        evidence.beginCapture(sessionId: sessionId, directory: outputDirectory)
        // A drain that timed out is this start's news: recorded into the session starting (L11 review 68).
        if !drained { recordDrainTimeout() }
        // Armed BEFORE the XPC start (C1): a crash during configure/start is this capture's crash.
        interruptionPolicy.captureStarted()
        let conn = try getConnection()
        await configureCapture(options, on: conn)
        do {
            try await startCapture(on: conn, outputDirectory: outputDirectory, baseName: baseName,
                                   microphoneDeviceId: microphoneDeviceId, systemAudioSource: systemAudioSource)
        } catch {
            // Refused: the helper is busy with an earlier capture. What this start drained is THAT capture's (L review 157).
            if error.localizedDescription == CaptureReplies.alreadyInProgress, case .data(let data) = drain { refusedStartDrain = data }
            throw error
        }
    }

    /// The `startCapture` call itself, bounded at 15 s.
    private func startCapture(on conn: NSXPCConnection, outputDirectory: URL, baseName: String, microphoneDeviceId: String?,
                              systemAudioSource: SystemAudioSource) async throws {
        try await bounded("start", seconds: 15) { (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                done(.failure(CaptureError.startFailed("XPC connection failed: \(error.localizedDescription)")))
            } as! AudioCaptureProtocol

            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId,
                systemAudioSource: systemAudioSource.rawValue
            ) { success, errorMessage in
                done(success ? .success(()) : .failure(CaptureError.startFailed(errorMessage ?? "Unknown error")))
            }
        }
    }

    /// Best effort, 3 s: a helper that does not answer records with its defaults, which are today's behaviour.
    private func configureCapture(_ options: CaptureOptions, on conn: NSXPCConnection) async {
        let reply: Result<Bool, Error> = await boundedReply("configureCapture", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(false)) } as! AudioCaptureProtocol
            proxy.configureCapture(optionsJSON: options.encoded()) { done(.success($0)) }
        }
        let acknowledged = (try? reply.get()) ?? false
        if !acknowledged { Logger.audio.warning("configureCapture not acknowledged — the helper records with default capture options") }
    }

    /// Bounded at 20 s (§8.8): the coordinator salvages from disk when the helper never answers.
    func stop() async throws -> AudioPaths {
        // Disarmed first: the helper exiting after a stop is expected, not a crash (C1).
        interruptionPolicy.captureStopped()
        let conn = try getConnection()
        return try await bounded("stop", seconds: 20) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                done(.failure(CaptureError.stopFailed("XPC connection failed: \(error.localizedDescription)")))
            } as! AudioCaptureProtocol

            proxy.stopCapture { systemPath, micPath, errorMessage in
                if let sys = systemPath, let mic = micPath {
                    done(.success(AudioPaths(systemAudio: URL(fileURLWithPath: sys), micAudio: URL(fileURLWithPath: mic))))
                } else {
                    done(.failure(CaptureError.stopFailed(errorMessage ?? "Unknown error")))
                }
            }
        }
    }

    func rotateChunk(
        outputDirectory: String,
        newBaseName: String
    ) async throws -> (systemPath: String, micPath: String) {
        let conn = try getConnection()
        // Bounded at 10 s (§8.8). The reply text is passed on as-is: the coordinator reads it in one place
        // (`RecordingCoordinator.helperReply`) — a dead capture, a refusal while stopping, or neither.
        let paths: (systemPath: String, micPath: String) = try await bounded("rotateChunk", seconds: ChunkRotator.rotateCallSeconds) { done in   // one bound, the rotator's (L review 241)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                done(.failure(CaptureError.rotateChunkFailed("XPC connection failed: \(error.localizedDescription)")))
            } as! AudioCaptureProtocol

            proxy.rotateChunk(outputDirectory: outputDirectory, newBaseName: newBaseName) { oldSystemPath, oldMicPath, errorMessage in
                if let sys = oldSystemPath, let mic = oldMicPath {
                    done(.success((systemPath: sys, micPath: mic)))
                } else {
                    done(.failure(CaptureError.rotateChunkFailed(errorMessage ?? "Unknown error")))
                }
            }
        }
        // Every rotation also keeps the helper session's coverage (L11): a pull, off the rotation's path.
        Task { _ = await self.captureStatus() }
        return paths
    }

    /// Bounded at 10 s (§8.8).
    func updateMicrophone(deviceId: String?) async throws {
        let conn = try getConnection()
        try await bounded("updateMicrophone", seconds: 10) { (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                done(.failure(CaptureError.micSwitchFailed("XPC connection failed: \(error.localizedDescription)")))
            } as! AudioCaptureProtocol

            proxy.updateMicrophone(deviceId: deviceId) { success, errorMessage in
                done(success ? .success(()) : .failure(CaptureError.micSwitchFailed(errorMessage ?? "Unknown error")))
            }
        }
    }

    /// The System Audio Recording permission as the helper sees it (#220), or `nil` if it can't be
    /// verified (SPI unavailable, or the helper unreachable). Asked of the helper because TCC caches
    /// the answer per process — the app's own view goes stale for its whole lifetime.
    /// Bounded: the launch gate waits on this, and a helper that never answers must not leave the app
    /// stuck (it fails open to `nil` — unverifiable — after 3 s).
    func systemAudioPermissionStatus() async -> PermissionStatus? {
        guard let conn = try? getConnection() else { return nil }
        let reply: Result<PermissionStatus?, Error> = await boundedReply("systemAudioPermissionStatus", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(nil)) } as! AudioCaptureProtocol
            proxy.systemAudioPermissionStatus { done(.success(SystemAudioRecordingPermission.status(fromWire: $0))) }
        }
        return (try? reply.get()) ?? nil
    }

    /// The helper's alarm state + per-track health (§6.2), or `nil` if the helper is unreachable or
    /// does not answer within 3 s. A pull's coverage becomes that helper session's latest (L11): a helper
    /// crash can no longer erase it.
    func captureStatus() async -> CaptureStatusSnapshot? {
        guard let conn = try? getConnection() else { return nil }
        let reply: Result<CaptureStatusSnapshot?, Error> = await boundedReply("captureStatus", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(nil)) } as! AudioCaptureProtocol
            proxy.captureStatus { done(.success($0.flatMap(CaptureStatusSnapshot.decode))) }
        }
        let snapshot = (try? reply.get()) ?? nil
        if let snapshot { evidence.noteCoverage(snapshot) }
        return snapshot
    }

    /// Forward an `NSWorkspace` sleep / wake to the helper (§8.10). Bounded at 3 s.
    func systemPowerEvent(_ kind: String) async {
        guard let conn = try? getConnection() else { return }
        _ = await boundedReply("systemPowerEvent", seconds: 3) { (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(())) } as! AudioCaptureProtocol
            proxy.systemPowerEvent(kind: kind) { done(.success(())) }
        }
    }

    /// Rebuild the tap in place once the permission is granted mid-recording, so remote audio resumes
    /// in the same recording (#220). Returns false if nothing was rebuilt.
    @discardableResult
    func restartSystemAudio() async -> Bool {
        guard let conn = try? getConnection() else { return false }
        // The helper replies from its audio queue; a stalled queue must not hang the caller.
        let reply: Result<Bool, Error> = await boundedReply("restartSystemAudio", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(false)) } as! AudioCaptureProtocol
            proxy.restartSystemAudio { success, error in
                if let error { Logger.audio.info("System audio restart skipped: \(error, privacy: .private)") }
                done(.success(success))
            }
        }
        return (try? reply.get()) ?? false
    }

    /// Pings the XPC service: is a capture session active? Reconnects if the connection is nil. `.unknown`
    /// when the helper did not answer within 3 s (§8.8) — a slow helper may still be capturing (L9 review 49);
    /// `.notCapturing` when it answered no, or is unreachable.
    func captureState() async -> HelperCaptureState {
        if connection == nil { connect() }
        guard let conn = connection else { return .notCapturing }
        let state: HelperCaptureState
        do {
            state = try await bounded("status", seconds: 3) { done in
                let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(.notCapturing)) } as! AudioCaptureProtocol
                proxy.status { isCapturing, _ in done(.success(isCapturing ? .capturing : .notCapturing)) }
            }
        } catch {
            state = .unknown
        }
        Logger.audio.debug("XPC status ping: \(String(describing: state), privacy: .public)")
        return state
    }

    /// Drop the connection after a helper call timed out (L9 review 45): the helper's invalidation handler
    /// stops and finalizes its capture (main.swift), and `getConnection()` reconnects lazily. Replaced first,
    /// so this deliberate invalidation never reads as a crash of whatever capture comes next.
    func dropConnection() {
        guard let conn = connection else { return }
        Logger.audio.error("Dropping the XPC connection: a helper call timed out and the helper may still be capturing")
        record(.xpcInvalidation, .warning, ["cause": "app dropped the connection after a timeout"])
        connection = nil
        conn.invalidate()
    }

    private func getConnection() throws -> NSXPCConnection {
        if connection == nil { connect() }
        guard let conn = connection else {
            throw CaptureError.notConnected
        }
        return conn
    }
}

/// Receives the helper's reverse-channel callbacks (#86). XPC delivers these on a private queue,
/// so each hop bounces onto the main actor where AudioCaptureClient lives.
final class ReverseChannel: NSObject, AudioCaptureClientProtocol {
    private weak var client: AudioCaptureClient?
    init(client: AudioCaptureClient) { self.client = client }

    func captureDidRestartInPlace() {
        Task { @MainActor [weak client] in
            Logger.audio.warning("Helper restarted capture stream in place")
            client?.onRestartInPlace?()
        }
    }

    func captureDidFailFatally(reason: String) {
        Task { @MainActor [weak client] in
            Logger.audio.error("Helper reported fatal capture failure: \(reason, privacy: .private)")
            client?.onFatalFailure?(reason)
        }
    }

    func micDeviceChanged(to deviceId: String?) {
        Task { @MainActor [weak client] in
            Logger.audio.info("Mic device auto-switched to: \(deviceId ?? "default", privacy: .private)")
            client?.onMicDeviceChanged?(deviceId)
        }
    }

    func captureSystemAudioUnrecoverable(reason: String) {
        Task { @MainActor [weak client] in
            Logger.audio.warning("Helper reports system stream unrecoverable — remote side not captured: \(reason, privacy: .private)")
            client?.handleSystemAudioUnrecoverable(reason: reason)
        }
    }

    func captureQualityAnomaly(kind: String, message: String) {
        Task { @MainActor [weak client] in
            Logger.audio.warning("Helper reports live capture-quality anomaly (\(kind, privacy: .public)): \(message, privacy: .private)")
            client?.handleQualityAnomaly(kind: kind, message: message)
        }
    }

    func captureDidDeliverFirstFrames(track: String, helperSessionId: String) {
        guard let captureTrack = CaptureTrack(rawValue: track) else {
            Logger.audio.warning("Helper reported first frames on an unknown track — ignored")
            return
        }
        Task { @MainActor [weak client] in client?.onFirstFrames?(captureTrack, helperSessionId) }
    }

    func captureAlarmsChanged(snapshot: Data) {
        guard let decoded = CaptureStatusSnapshot.decode(snapshot) else {
            Logger.audio.warning("Helper pushed an alarm snapshot this build cannot decode — ignored")
            return
        }
        Task { @MainActor [weak client] in client?.onAlarmsChanged?(decoded) }
    }

    // Explicitly `@objc`: they compile before the protocol declares them and satisfy its
    // `@objc optional` requirements by selector once it does.
    @objc func captureDidDeliverRealAudio(track: String, helperSessionId: String) {
        guard let captureTrack = CaptureTrack(rawValue: track) else {
            Logger.audio.warning("Helper reported real audio on an unknown track — ignored")
            return
        }
        Task { @MainActor [weak client] in client?.onRealAudio?(captureTrack, helperSessionId) }
    }

    @objc func captureDidWriteSuccessfully(helperSessionId: String) {
        Task { @MainActor [weak client] in client?.onWriteSucceeded?(helperSessionId) }
    }
}

/// Every `RecordingCaptureClient` member (including `ChunkRotationClient`'s
/// `rotateChunk(outputDirectory:newBaseName:)`) already exists on this class with the exact
/// protocol signatures — this conformance is the seam that lets `RecordingCoordinator` and
/// `ChunkRotator` (both in TranscriberCore) hold the protocol instead of the concrete XPC
/// client (#135 prep, #139 PR-6).
extension AudioCaptureClient: RecordingCaptureClient {}

enum CaptureError: LocalizedError {
    case notConnected
    case startFailed(String)
    case stopFailed(String)
    case micSwitchFailed(String)
    case rotateChunkFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection not available — run as .app bundle"
        case .startFailed(let msg): return msg
        case .stopFailed(let msg): return msg
        case .micSwitchFailed(let msg): return msg
        case .rotateChunkFailed(let msg): return msg
        }
    }
}
