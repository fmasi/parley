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
                    let stillCapturing = await self.isCapturing()
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
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
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

    /// A relaunch continues `sessionId`: adopt it first, then drain the helper into it (L follow-up 43).
    /// The resume's own `start` then keeps it all (the same session id resets nothing).
    func adoptSession(sessionId: String, directory: URL) async {
        evidence.beginCapture(sessionId: sessionId, directory: directory)
        await drainHelperDiagnostics()
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

    /// One helper call, bounded: the reply, the XPC error handler and the deadline race through
    /// `ResumeOnce`, so whichever comes first wins and a late reply is ignored (never a second resume, never
    /// a leaked continuation). A timeout is recorded as an `xpcTimeout` anomaly and thrown as
    /// `CaptureCallTimeout`, a Core type the coordinator recognizes.
    private func bounded<T: Sendable>(
        _ call: String, seconds: Double,
        _ send: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let result: Result<T, Error> = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            send { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(.failure(CaptureCallTimeout(call: call, seconds: seconds)))
            }
        }
        if case .failure(let error as CaptureCallTimeout) = result {
            Logger.audio.error("The capture helper did not answer \(call, privacy: .public) within \(seconds, privacy: .public) s")
            record(.xpcTimeout, .anomaly, ["call": call])
            throw error
        }
        return try result.get()
    }

    /// Pull and clear the helper's diagnostic ring over XPC, merging its events into the app ring.
    /// Bounded at 3 s: a helper that does not answer leaves its events behind, never the caller stuck.
    func drainHelperDiagnostics() async {
        guard let conn = connection else { return }
        let data: Data? = try? await bounded("drainDiagnostics", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(nil)) } as! AudioCaptureProtocol
            proxy.drainDiagnostics { done(.success($0)) }
        }
        if let data {
            evidence.mergeHelperEvents(CaptureDiagnostics.events(from: data))
        }
    }

    /// Drain the helper, merge the live log and the helper sessions' latest coverage (L11), build the
    /// transcript provenance stamp, and — only when the session was anomalous — flush the full event ring
    /// to `<sessionId>.diag.jsonl` beside the recording (#95). A clean session writes no log, only the
    /// ~200-byte provenance stamp the caller embeds.
    func finalizeSessionDiagnostics(
        sessionId: String,
        engine: String,
        recordingDirectory: URL
    ) async -> CaptureProvenance {
        await drainHelperDiagnostics()
        let diagnostics = evidence.finalize(sessionId: sessionId, directory: recordingDirectory)

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

        if diagnostics.isAnomalous {
            let url = recordingDirectory.appendingPathComponent("\(sessionId).diag.jsonl")
            do {
                try diagnostics.jsonlData().write(to: url, options: .atomic)
                Logger.files.info("Flushed capture diagnostics: \(url.lastPathComponent, privacy: .sensitive) (\(diagnostics.events.count) events)")
            } catch {
                Logger.files.error("Failed to flush diagnostics: \(error, privacy: .public)")
            }
        }

        return diagnostics.makeProvenance(
            engine: engine,
            systemFormat: formatString(.systemFormatDetected),
            micFormat: formatString(.micFormatDetected),
            micDevice: micDevice
        )
    }

    /// Bounded: `configureCapture` (3 s, best effort) runs first, then the `startCapture` call itself
    /// (15 s) — worst case 18 s to a start failure (§8.8).
    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String? = nil,
        systemAudioSource: SystemAudioSource = .screenCaptureKit,
        options: CaptureOptions = CaptureOptions(),
        sessionId: String = ""
    ) async throws {
        // The previous helper's events first (bounded, 3 s): its start clears its own ring, and an
        // in-session restart must not lose them (L11).
        await drainHelperDiagnostics()
        // A NEW session id resets every tally, so no recording inherits an earlier one's facts (council
        // A-C1); the SAME id — an in-session restart — keeps the session's evidence.
        evidence.beginCapture(sessionId: sessionId, directory: outputDirectory)
        // Armed BEFORE the XPC start (C1): a crash during configure/start is this capture's crash.
        interruptionPolicy.captureStarted()
        let conn = try getConnection()
        await configureCapture(options, on: conn)
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
        let acknowledged = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(false) } as! AudioCaptureProtocol
            proxy.configureCapture(optionsJSON: options.encoded()) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(false) }
        }
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
        // (`RecordingCoordinator.rotateFailure`) — a dead capture, a refusal while stopping, or neither.
        let paths: (systemPath: String, micPath: String) = try await bounded("rotateChunk", seconds: 10) { done in
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
        return await withCheckedContinuation { (cont: CheckedContinuation<PermissionStatus?, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                once.resume(nil)
            } as! AudioCaptureProtocol
            proxy.systemAudioPermissionStatus { once.resume(SystemAudioRecordingPermission.status(fromWire: $0)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
    }

    /// The helper's alarm state + per-track health (§6.2), or `nil` if the helper is unreachable or
    /// does not answer within 3 s. A pull's coverage becomes that helper session's latest (L11): a helper
    /// crash can no longer erase it.
    func captureStatus() async -> CaptureStatusSnapshot? {
        guard let conn = try? getConnection() else { return nil }
        let snapshot = await withCheckedContinuation { (cont: CheckedContinuation<CaptureStatusSnapshot?, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as! AudioCaptureProtocol
            proxy.captureStatus { once.resume($0.flatMap(CaptureStatusSnapshot.decode)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
        if let snapshot { evidence.noteCoverage(snapshot) }
        return snapshot
    }

    /// Forward an `NSWorkspace` sleep / wake to the helper (§8.10). Bounded at 3 s.
    func systemPowerEvent(_ kind: String) async {
        guard let conn = try? getConnection() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in once.resume(()) } as! AudioCaptureProtocol
            proxy.systemPowerEvent(kind: kind) { once.resume(()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(()) }
        }
    }

    /// Rebuild the tap in place once the permission is granted mid-recording, so remote audio resumes
    /// in the same recording (#220). Returns false if nothing was rebuilt.
    @discardableResult
    func restartSystemAudio() async -> Bool {
        guard let conn = try? getConnection() else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                once.resume(false)
            } as! AudioCaptureProtocol
            proxy.restartSystemAudio { success, error in
                if let error { Logger.audio.info("System audio restart skipped: \(error, privacy: .public)") }
                once.resume(success)
            }
            // The helper replies from its audio queue; a stalled queue must not hang the caller.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(false) }
        }
    }

    /// Pings the XPC service to check whether a capture session is currently active.
    /// Attempts to reconnect if the connection is nil. Returns false if the service
    /// is unreachable (used for crash-recovery Flow A re-attach on launch).
    func isCapturing() async -> Bool {
        guard let conn = connection else {
            connect()
            guard let conn = connection else { return false }
            let result = await pingStatus(conn)
            Logger.audio.debug("XPC status ping: \(result)")
            return result
        }
        let result = await pingStatus(conn)
        Logger.audio.debug("XPC status ping: \(result)")
        return result
    }

    /// Bounded at 3 s (§8.8): a helper that does not answer counts as not capturing.
    private func pingStatus(_ conn: NSXPCConnection) async -> Bool {
        (try? await bounded("status", seconds: 3) { done in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done(.success(false)) } as! AudioCaptureProtocol
            proxy.status { isCapturing, _ in done(.success(isCapturing)) }
        }) ?? false
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
            Logger.audio.error("Helper reported fatal capture failure: \(reason, privacy: .public)")
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
