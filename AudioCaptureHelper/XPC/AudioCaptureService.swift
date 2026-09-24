import Foundation
import os
import ScreenCaptureKit
import AudioCaptureProtocol
import TranscriberCore

final class AudioCaptureService: NSObject, AudioCaptureProtocol {
    private var handler: AudioOutputHandler?
    private var stream: SCStream?
    private var systemPath: String?
    private var micPath: String?
    private var isCapturing = false
    /// This process's start, in ms on the system's monotonic clock (boot-relative, never steps back),
    /// so a helper started later always names a newer `HelperSessionId` — a wall-clock start could
    /// step backwards and make the replacement look older than the helper it replaced.
    private let processStartMillis = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
    /// Alarm-registry resets in this process. Guarded by `stateLock`. Incremented on every registry
    /// reset (stop, stopAndFinalize, cleanupAfterFailure, failFatally), so each reset names a strictly
    /// newer registry.
    private var registryResets: UInt64 = 0
    /// Sequence of the last `CaptureStatusSnapshot` built (pull reply or push). Guarded by `stateLock`,
    /// taken in the same critical section as the alarm read (`snapshot(tracks:)`).
    private var snapshotSequence: UInt64 = 0
    /// The helper-owned capture alarms (§6.1). Guarded by `stateLock`, next to `registryResets` and
    /// `snapshotSequence`, so a snapshot's id, sequence and alarms are read in one critical section.
    private var alarms = CaptureAlarmRegistry()

    /// Names the helper's alarm-REGISTRY INSTANCE, not the process, as an ordered `HelperSessionId`
    /// (`"<processStartMillis>-<registryResets>"`), in every snapshot and first-frames call: a newer id
    /// tells the app the registry it knew is gone (crash restart), so its alarms turn stale instead of
    /// vanishing (§6.2). Reads `stateLock`: never call it from inside a `stateLock.sync` block.
    var helperSessionId: String {
        let resets = stateLock.sync { registryResets }
        return HelperSessionId(processStartMillis: processStartMillis, registryResets: resets).description
    }
    /// One persistent serial queue for ALL stream callbacks across the session — initial stream
    /// and every in-place restart register on it, so writer swaps / finalization / sample appends
    /// can never run on two different queues concurrently (council F4). Never reassigned or nil'd.
    private let audioQueue = DispatchQueue(label: "audio-capture.shared")
    private let stateLock = DispatchQueue(label: "audio-capture.state")

    // MARK: - #86 in-place restart + #95 diagnostics

    /// Anomaly-gated diagnostic ring, drained by the app over XPC (#95).
    private let diagnostics = LockedDiagnostics()
    /// The decoupled microphone capture session (#96): the mic runs on its own AVCaptureSession, so a
    /// mic route change can no longer tear down the system-audio SCStream. nil when not capturing.
    private var micSession: MicCaptureSession?
    /// The Core Audio output-tap system source (#103), used INSTEAD of `stream` (SCStream) when the
    /// app selects `systemAudioSource == .coreAudioTap`. Exactly one of `stream`/`tapSession` is live
    /// per session. The tap self-heals output-device switches internally (HAL listener), so the
    /// SCK-specific #86 restart/autoheal machinery does not apply to it. nil when not capturing or on SCK.
    private var tapSession: SystemTapSession?
    /// Set by `configureCapture`, CONSUMED by the next `startCapture` (reset to the defaults there), so
    /// a start without a fresh configure records with today's behaviour — never with an earlier
    /// session's options (a leftover `debugDropTapFrames` would drop remote audio). Guarded by `stateLock`.
    private var pendingOptions = CaptureOptions()
    /// Set true while the app is deliberately stopping, so a stop-induced `didStopWithError`
    /// is classified as `.ignore` rather than a route-change restart.
    private var isUserStopping = false
    /// Consecutive failed in-place restarts; reset to 0 on a restart that starts cleanly.
    private var restartAttempts = 0
    /// Guards against overlapping restart loops from rapid repeated stop errors.
    private var isRestarting = false
    /// One-shot latch so the reverse-channel fatal notification fires at most once per session
    /// even if both fatal emitters race (council F8). Reset on a fresh startCapture.
    private var hasFailedFatally = false
    /// One-shot latch: the system stream exhausted its restart budget and was declared unrecoverable.
    /// Once set, the lingering silent stream's further `didStopWithError` callbacks are ignored, the
    /// "unrecoverable" warning fires at most once, and — critically — a system-stream death NEVER
    /// routes to `failFatally` (which would tear down the still-good mic). Reset on a fresh startCapture.
    private var systemStreamGivenUp = false
    private let maxRestartAttempts = 3
    /// #86 liveness probe: after a rebuilt system stream "starts", wait this long for it to actually
    /// deliver a buffer before trusting the restart. SCStream accepting the config is NOT proof of
    /// audio; 4s comfortably exceeds the stream warm-up so a genuinely live stream has delivered by then.
    private let livenessProbeNanos: UInt64 = 4_000_000_000
    /// Backoff between failed in-place restart attempts (transient failure or no-frames probe miss).
    private let restartBackoffNanos: UInt64 = 300_000_000

    /// Reverse-channel callbacks to the app (wired in main.swift from the connection proxy).
    var onRestartInPlace: (() -> Void)?
    var onFailFatally: ((String) -> Void)?
    /// Invoked when the MID-RECORDING system stream could not be restarted within budget (#86). The
    /// mic (separate AVCaptureSession) keeps recording — this only warns; it NEVER stops the session.
    var onSystemAudioUnrecoverable: ((String) -> Void)?
    /// Invoked when the mic auto-switches during a session (route change, fallback, re-pin).
    /// Passes the resolved device UID (`nil` = system default) for menu-label refresh.
    var onMicDeviceChanged: ((String?) -> Void)?
    /// Invoked for a live, user-facing capture-quality anomaly (exact-zero mic, a liveness gap, a
    /// disk-full write failure) — surfaced WHILE the recording is still running, unlike the silent
    /// diagnostic ring which is only read after the fact (#193/#196). `kind` is the
    /// `CaptureEventKind` raw value; `message` is a human-readable description.
    var onQualityAnomaly: ((String, String) -> Void)?
    /// Invoked on the first heartbeat of a capture generation: (track, `helperSessionId` at that moment).
    var onFirstFrames: ((CaptureTrack, String) -> Void)?
    /// Invoked with a JSON `CaptureStatusSnapshot` whenever the alarm set changes (§6.2).
    var onAlarmsChanged: ((Data) -> Void)?
    /// The first non-zero sample on a track, once per registry: (track, `helperSessionId`). Content
    /// evidence that disproves a stale content alarm on the app side (§6.2).
    var onRealAudio: ((CaptureTrack, String) -> Void)?
    /// A writer's first successful write, or its first after a failure: (`helperSessionId`). Disproves
    /// a stale `diskWriteFailure` on the app side (§6.2).
    var onWriteSucceeded: ((String) -> Void)?

    /// Off-audio-queue 1 Hz liveness watchdog (#196). Started once capture is up, stopped on every
    /// teardown path.
    private let livenessWatchdog = LivenessWatchdogDriver()
    /// Runs the tap's healing ladder from the system track's liveness verdicts (§5).
    private let tapHealer = TapHealer()
    /// Mic side of "heal, then alarm" (§6.1). Touched on the watchdog queue only.
    private var micHealPolicy = MicHealPolicy()
    /// Per-track coverage (§7.1) accumulated as it happens: expected seconds from the gate, gaps from
    /// the liveness verdicts, rebuilds from the healer. Delivered / padded / zero / heartbeat counts
    /// are merged in when read (`coverageFacts`). Lock-only, so the audio queue may read it too.
    private let coverage = OSAllocatedUnfairLock<[CaptureTrack: TrackAccounting]>(
        initialState: [.mic: TrackAccounting(), .system: TrackAccounting()])
    /// The previous gate observation, for elapsed-time accounting (0 = none yet this session).
    private let lastGateTickNanos = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Keeps the tap honest about its System Audio Recording permission (#220): see
    /// `TapPermissionGuard`. Confined to `audioQueue`, like the samples that feed it.
    private var tapGuard = TapPermissionGuard()
    /// ~1 Hz tick for `tapGuard`, on `audioQueue`, only while capturing with the tap. The guard does
    /// nothing on a tick unless a problem is suspected or reported. Created and cancelled on `audioQueue`.
    private var tapGuardTimer: DispatchSourceTimer?
    /// Bumped per tap session, so a permission check still in flight from a previous session can't
    /// land in the next session's fresh guard. Read and written on `audioQueue`.
    private var tapGuardEpoch = 0
    /// Serial queue for every TCC permission read: they are synchronous IPC round-trips, so they must
    /// never run on `audioQueue` or on `SystemTapSession`'s config queue (a slow one would delay a
    /// rebuild), and serial so results reach the guard in the order they were asked for.
    private let tccQueue = DispatchQueue(label: "audio-capture.tcc", qos: .utility)
    private let guardEpoch = DispatchTime.now().uptimeNanoseconds
    private func guardNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - guardEpoch) / 1_000_000_000
    }

    private func record(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        _ detail: [String: String] = [:]
    ) {
        diagnostics.record(CaptureEvent(
            timestamp: Date(), origin: .helper, kind: kind, severity: severity, detail: detail
        ))
    }

    /// Wire a `WavFileWriter`'s throwing-`FileHandle` write-failure surface (#196) to the diagnostic
    /// ring and the live user-facing anomaly channel, instead of the legacy `FileHandle` API's
    /// uncatchable Objective-C exception, which could abort the whole helper process mid-meeting.
    private func wireWriteFailure(_ writer: WavFileWriter, track: String) {
        writer.onWriteFailure = { [weak self] message in
            self?.record(.writeFailure, .anomaly, ["track": track, "reason": message])
            self?.onQualityAnomaly?(CaptureEventKind.writeFailure.rawValue, message)
            self?.raiseAlarm(.diskWriteFailure, message)
        }
        // Start writers and every rotation's writers come through here, so each chunk's first write
        // is one cheap evidence call (§6.2).
        writer.onWriteSucceeded = { [weak self] in
            guard let self else { return }
            self.clearAlarm(.diskWriteFailure)
            self.onWriteSucceeded?(self.helperSessionId)
        }
    }

    // MARK: - Alarm registry (§6)

    /// Sequence, id and alarms in ONE `stateLock` section (F2 round 2), so a later sequence can never
    /// carry an older registry. `tracks` is computed by the caller OUTSIDE the lock (it reads other
    /// locks and, in H6, the cached gate). Never call the `helperSessionId` getter in here.
    private func snapshot(tracks: [TrackHealthSnapshot]) -> CaptureStatusSnapshot {
        stateLock.sync {
            snapshotSequence += 1
            let id = HelperSessionId(processStartMillis: processStartMillis, registryResets: registryResets).description
            return CaptureStatusSnapshot(helperSessionId: id, sequence: snapshotSequence, isCapturing: isCapturing,
                                         alarms: alarms.sorted, tracks: tracks)
        }
    }

    /// Per-track liveness for the snapshot (§6.2). Runs inside `raiseAlarm`/`clearAlarm`, which the
    /// AUDIO queue calls, so it only takes leaf locks: the sessions' heartbeat / generation, and the
    /// driver's cached last gate reading — no HAL read, no `audioQueue.sync`. Empty when not capturing.
    private func trackHealth() -> [TrackHealthSnapshot] {
        let (mic, tap, h) = stateLock.sync { (micSession, tapSession, handler) }
        guard let mic else { return [] }
        let now = DispatchTime.now().uptimeNanoseconds
        func age(_ stamp: UInt64) -> Double? { stamp == 0 ? nil : Double(now > stamp ? now - stamp : 0) / 1e9 }
        // Tap: its callback heartbeat. SCK: the arrival stamp, as the watchdog uses.
        let systemStamp = tap?.lastHeartbeatNanos() ?? h?.lastSystemBufferArrivalNanos() ?? 0
        return [
            TrackHealthSnapshot(track: .mic, expected: true, heartbeatAgeSeconds: age(mic.lastHeartbeatNanos()),
                                generation: mic.generationValue()),
            TrackHealthSnapshot(track: .system, expected: livenessWatchdog.lastGateOpen, heartbeatAgeSeconds: age(systemStamp),
                                generation: tap?.generationValue() ?? 0),
        ]
    }

    // MARK: - Coverage (§7.1)

    /// Expected seconds accumulate by ELAPSED time between gate observations (capped at 2 s), never
    /// "+1 per call": a late or coalesced tick (a busy queue, sleep) must neither over- nor under-count.
    private func accountGate(open: Bool, nowNanos: UInt64) {
        let previous = lastGateTickNanos.withLock { p in defer { p = nowNanos }; return p }
        guard previous != 0, nowNanos > previous else { return }
        let dt = min(2.0, Double(nowNanos - previous) / 1e9)
        coverage.withLock { c in
            c[.mic, default: TrackAccounting()].expectedSeconds += dt
            if open { c[.system, default: TrackAccounting()].expectedSeconds += dt }
        }
    }

    private func noteGap(track: CaptureTrack, seconds: Double) {
        coverage.withLock { c in
            c[track, default: TrackAccounting()].gapCount += 1
            c[track, default: TrackAccounting()].longestGapSeconds = max(c[track, default: TrackAccounting()].longestGapSeconds, seconds)
        }
    }

    private func noteRebuild() {
        coverage.withLock { $0[.system, default: TrackAccounting()].rebuilds += 1 }
    }

    /// Per-track coverage as `remote_*` / `local_*` detail keys, for `.captureStop` and every rotation's
    /// `.trackCoverage`. Uses `audioQueue.sync`, so it must NEVER be called from a block running on
    /// `audioQueue` (it would deadlock): only `stopCapture`, `stopAndFinalize` and `rotateChunk`, on XPC threads.
    private func coverageFacts() -> [String: String] {
        let (h, mic, tap) = stateLock.sync { (handler, micSession, tapSession) }
        let totals = audioQueue.sync { h?.trackTotals() }
        // The guard only sees tap samples; on SCK (or a stale guard from an earlier tap session) it says nothing.
        let zeros: Int64 = tap == nil ? 0 : audioQueue.sync { tapGuard.exactZeroFrames }
        var (remote, local) = coverage.withLock { c in (c[.system] ?? TrackAccounting(), c[.mic] ?? TrackAccounting()) }
        let rate = AudioConverter.outputSampleRate   // both WAVs are 48 kHz mono
        if let totals {
            local.deliveredSeconds = Double(totals.micDelivered) / rate
            local.paddedSeconds = Double(totals.micPad) / rate
            local.exactZeroSeconds = Double(totals.micZero) / rate
            remote.deliveredSeconds = Double(totals.sysDelivered) / rate
            remote.paddedSeconds = Double(totals.sysPad) / rate
        }
        remote.exactZeroSeconds = Double(zeros) / rate
        local.heartbeatCallbacks = mic?.heartbeatCount() ?? 0
        remote.heartbeatCallbacks = tap?.heartbeatCount() ?? 0
        return remote.asDetail(prefix: "remote").merging(local.asDetail(prefix: "local")) { a, _ in a }
    }

    /// Both may be called from the audio queue (write failure, exact zeros, permission verdicts) and
    /// from the watchdog / config queues — never from inside `stateLock.sync`, and they do no HAL
    /// read and no `audioQueue.sync` (a push encodes a handful of alarms; that is all).
    private func raiseAlarm(_ kind: AlarmKind, _ message: String) {
        let changed = stateLock.sync { alarms.raise(kind, message: message, now: Date()) }
        guard changed else { return }
        record(.alarmRaised, .anomaly, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot(tracks: trackHealth()).encoded())
    }

    private func clearAlarm(_ kind: AlarmKind) {
        guard stateLock.sync(execute: { alarms.clear(kind) }) != nil else { return }
        record(.alarmCleared, .info, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot(tracks: trackHealth()).encoded())
    }

    /// Start the off-audio-queue liveness watchdog (§4.2) on the sessions' heartbeats, and re-arm a
    /// track on every (re)build of its source. Both tracks are armed now: first frames are due in 5 s.
    private func startLivenessWatchdog(handler: AudioOutputHandler, mic: MicCaptureSession, tap: SystemTapSession?) {
        livenessWatchdog.lastMicHeartbeatNanos = { [weak mic] in mic?.lastHeartbeatNanos() ?? 0 }
        // Tap: the callback's own heartbeat. SCK: the arrival stamp (gotcha #63) — SCK keeps the watchdog (§13).
        livenessWatchdog.lastSystemHeartbeatNanos = tap.map { tap in { [weak tap] in tap?.lastHeartbeatNanos() ?? 0 } }
            ?? { [weak handler] in handler?.lastSystemBufferArrivalNanos() ?? 0 }
        livenessWatchdog.onVerdict = { [weak self] track, verdict in self?.handleLiveness(track: track, verdict: verdict) }
        livenessWatchdog.onGate = { [weak self] open, now in self?.accountGate(open: open, nowNanos: now) }
        // A new session starts a new mic episode; on the watchdog queue, like every other use.
        livenessWatchdog.queue.async { [weak self] in self?.micHealPolicy = MicHealPolicy() }
        mic.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: .mic) }
        tap?.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: .system) }
        livenessWatchdog.start()
        livenessWatchdog.arm(track: .mic)
        livenessWatchdog.arm(track: .system)
    }

    /// Verdicts arrive on the watchdog queue. Every verdict is recorded and first frames go to the app
    /// as evidence. The mic heals before it alarms (`MicHealPolicy`); the tap's verdicts drive the
    /// healing ladder, which alarms only once it has given up (§5). An SCK system stream has no ladder
    /// (its #86 restart path is separate), so its verdicts alarm directly — SCK keeps the watchdog and
    /// its alarms (§13). `helperSessionId` reads `stateLock`; this never runs inside a `stateLock.sync`.
    private func handleLiveness(track: CaptureTrack, verdict: TrackLivenessMonitor.Verdict) {
        let t = track.rawValue
        switch verdict {
        case .firstFrames:
            record(.firstFrames, .info, ["track": t])
            onFirstFrames?(track, helperSessionId)
        case .neverDelivered(let s):
            record(.neverDelivered, .anomaly, ["track": t, "seconds": "\(Int(s))"])
            noteGap(track: track, seconds: s)
        case .stalled(let s):
            // An accelerator's early stall opens the monitor's episode, so each gap is counted once.
            record(.livenessGap, .anomaly, ["track": t, "seconds": "\(Int(s))"])
            noteGap(track: track, seconds: s)
        case .cleared(let reason):
            record(.livenessRecovered, .info, ["track": t, "reason": "\(reason)"])
        case .healthy:
            return
        }
        switch track {
        case .mic:
            handleMicLiveness(verdict)
        case .system:
            if stateLock.sync(execute: { tapSession != nil }) { handleTapLiveness(verdict) } else { handleStreamLiveness(verdict) }
        }
    }

    /// The transient banner for a silence verdict (the alarm, if any, is separate).
    private func livenessBanner(track: CaptureTrack, verdict: TrackLivenessMonitor.Verdict) -> (CaptureEventKind, String)? {
        switch verdict {
        case .neverDelivered:
            return (.neverDelivered, track == .mic
                ? "The microphone isn’t delivering any audio." : "The other side of the call isn’t reaching Parley although audio is playing.")
        case .stalled(let s):
            return (.livenessGap, track == .mic
                ? "The microphone stopped delivering audio \(Int(s))s ago." : "System audio stopped delivering \(Int(s))s ago.")
        default:
            return nil
        }
    }

    /// Mic: heal on the first silence verdict of an episode, heal AND alarm on the second (C5).
    private func handleMicLiveness(_ verdict: TrackLivenessMonitor.Verdict) {
        if let (kind, message) = livenessBanner(track: .mic, verdict: verdict) { onQualityAnomaly?(kind.rawValue, message) }
        let alarmMessage = "The microphone isn’t delivering any audio. Try another microphone from the menu."
        switch micHealPolicy.onVerdict(verdict) {
        case .heal:
            stateLock.sync { micSession }?.heal()
        case .healAndAlarm:
            stateLock.sync { micSession }?.heal()
            raiseAlarm(.micNotDelivering, alarmMessage)
        case .alarm:
            raiseAlarm(.micNotDelivering, alarmMessage)
        case .clear:
            clearAlarm(.micNotDelivering)
        case .none:
            break
        }
    }

    /// Tap: the ladder heals; `TapHealer.onGiveUp` raises `remoteNotDelivering`, `onRecovered` clears it.
    private func handleTapLiveness(_ verdict: TrackLivenessMonitor.Verdict) {
        switch verdict {
        case .neverDelivered:
            tapHealer.trigger(.neverDelivered)
        case .stalled:
            tapHealer.trigger(.stalled)
        case .firstFrames:
            tapHealer.heartbeatObserved()
            // First frames disprove the delivery kinds (never the permission kinds, which clear on real audio).
            clearAlarm(.remoteNotDelivering)
            clearAlarm(.remoteRecoveryFailed)
        case .cleared(.heartbeat):
            tapHealer.heartbeatObserved()
        case .cleared(.gateClosed):
            tapHealer.gateClosed()
            clearAlarm(.remoteNotDelivering)
        case .healthy:
            break
        }
    }

    /// SCK system stream: no ladder here, so a silence verdict alarms at once and a heartbeat clears it.
    private func handleStreamLiveness(_ verdict: TrackLivenessMonitor.Verdict) {
        if let (kind, message) = livenessBanner(track: .system, verdict: verdict) {
            onQualityAnomaly?(kind.rawValue, message)
            raiseAlarm(.remoteNotDelivering, message)
            return
        }
        switch verdict {
        case .firstFrames:
            clearAlarm(.remoteNotDelivering)
            clearAlarm(.remoteRecoveryFailed)
        case .cleared:
            clearAlarm(.remoteNotDelivering)
        default:
            break
        }
    }

    func startCapture(
        outputDirectory: String,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard !stateLock.sync(execute: { isCapturing }) else {
            reply(false, "Capture already in progress")
            return
        }
        // Unrecognized raw values fall back to the shipped SCK path, never a hard failure.
        let source: SystemAudioSource
        if let parsed = SystemAudioSource(rawValue: systemAudioSource) {
            source = parsed
        } else {
            // Say so. A helper/app version skew or a corrupted config silently downgrades a user who
            // chose the tap *because* SCK records silence for their Continuity calls — producing a
            // structurally valid recording whose remote track is empty. Exactly this bug class.
            source = .screenCaptureKit
            Logger.audio.error(
                "Unrecognized system_audio_source '\(systemAudioSource, privacy: .public)' — falling back to ScreenCaptureKit; a Core Audio tap selection will NOT be honoured"
            )
            diagnostics.record(CaptureEvent(
                timestamp: Date(), origin: .helper,
                kind: .captureSourceFallback, severity: .anomaly,
                detail: [
                    "reason": "unrecognized system_audio_source — fell back to sck",
                    "requested": systemAudioSource,
                ]
            ))
        }

        // Per-session reset (#101): a skipped finalize (crash) leaves stale events in the helper ring,
        // which would otherwise be drained into the next session's provenance. Clear them up front.
        diagnostics.clear()
        coverage.withLock { $0 = [.mic: TrackAccounting(), .system: TrackAccounting()] }
        lastGateTickNanos.withLock { $0 = 0 }
        let options: CaptureOptions = stateLock.sync {
            let configured = pendingOptions
            pendingOptions = CaptureOptions()
            return configured
        }

        Logger.audio.info("Starting capture — dir: \(outputDirectory, privacy: .private), base: \(baseName, privacy: .private), mic: \(microphoneDeviceId ?? "default", privacy: .public)")

        let sysPath = (outputDirectory as NSString).appendingPathComponent(baseName + ".wav")
        let micFilePath = (outputDirectory as NSString).appendingPathComponent(baseName + "_mic.wav")

        do {
            try FileManager.default.createDirectory(
                atPath: outputDirectory, withIntermediateDirectories: true
            )
            let systemWriter = try WavFileWriter(path: sysPath)
            let micWriter = try WavFileWriter(path: micFilePath)
            wireWriteFailure(systemWriter, track: "system")
            wireWriteFailure(micWriter, track: "mic")
            let outputHandler = AudioOutputHandler(
                systemWriter: systemWriter, micWriter: micWriter
            )
            outputHandler.diagnostics = diagnostics
            outputHandler.systemExpectedSeconds = { [weak self] in
                self?.coverage.withLock { $0[.system]?.expectedSeconds ?? 0 } ?? 0
            }
            outputHandler.onStreamStopped = { [weak self] error in
                self?.handleStreamStopped(error)
            }
            // Already recorded into `diagnostics` by AudioOutputHandler itself — this is purely the
            // live, user-facing surface (#193/#196).
            outputHandler.onLiveAnomaly = { [weak self] kind, message in
                self?.onQualityAnomaly?(kind.rawValue, message)
                if kind == .exactZeroMic { self?.raiseAlarm(.micDigitalSilence, message) }
            }
            outputHandler.onMicAudioResumed = { [weak self] in self?.clearAlarm(.micDigitalSilence) }
            // On the audio queue; `helperSessionId` takes `stateLock`, a leaf lock never held there.
            outputHandler.onRealAudio = { [weak self] track in
                guard let self else { return }
                self.onRealAudio?(track, self.helperSessionId)
            }

            self.stateLock.sync {
                self.systemPath = sysPath
                self.micPath = micFilePath
                self.handler = outputHandler
                self.isUserStopping = false
                self.restartAttempts = 0
                self.isRestarting = false
                self.hasFailedFatally = false
                self.systemStreamGivenUp = false
                self.tapSession = nil
            }

            Task {
                do {
                    // System audio (SCStream) and the mic (AVCaptureSession) are independent sources
                    // now (#96). Start the MIC FIRST: it is the likelier failure (Microphone TCC), and
                    // starting it before the system stream means a mic-start failure can't delete an
                    // already-recording system WAV (council F2). A mic-start failure fails the start
                    // loudly so the user fixes permissions before the meeting — mid-session mic loss
                    // degrades to system-only instead, which is handled separately.
                    let (micSession, resolvedMic) = try self.startMicSession(
                        handler: outputHandler, microphoneDeviceId: microphoneDeviceId
                    )
                    // Record capture-start provenance with the mic that ACTUALLY resolved — not the
                    // requested id, which may have silently fallen back to the system default if the
                    // pinned device couldn't be opened (council CONV-1). Recorded after a successful mic
                    // start (not on a failed one, which tears down with no provenance consumer).
                    self.record(.captureStart, .info, [
                        "mic": resolvedMic ?? "default", "system_source": source.rawValue,
                        "tap_auto_start": "\(options.tapAutoStart)",
                    ])
                    // So finalizeAll()'s frame-count-plausibility backstop can apply the same
                    // gotcha-#66 gate the liveness watchdog already applies mid-recording.
                    outputHandler.isUsingSystemTap = (source == .coreAudioTap)
                    switch source {
                    case .screenCaptureKit:
                        try await self.buildAndStartStream(handler: outputHandler)
                    case .coreAudioTap:
                        // Core Audio output tap (#103): captures Continuity/telephony + VoIP that SCK
                        // misses. No SCStream is created, so `stream` stays nil and the #86 SCK
                        // restart path is dormant — the tap self-heals output switches internally.
                        try self.startSystemTap(handler: outputHandler, options: options)
                    }
                    Logger.audio.info("Capture started — mic AVCaptureSession + system source \(source.rawValue, privacy: .public); awaiting frames")
                    self.stateLock.sync { self.isCapturing = true }
                    self.startLivenessWatchdog(handler: outputHandler, mic: micSession, tap: self.stateLock.sync { self.tapSession })
                    if source == .coreAudioTap { self.startTapGuardTimer() }
                    reply(true, nil)
                } catch {
                    self.cleanupAfterFailure()
                    Logger.audio.error("Capture failed: \(error, privacy: .public)")
                    let desc = "\(error)"
                    if desc.contains("permission") || desc.contains("denied")
                        || desc.contains("notAuthorized") || desc.contains("Microphone access") {
                        reply(false, "Permission denied — grant Screen Recording and Microphone access in System Settings")
                    } else {
                        reply(false, "Capture failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            Logger.audio.error("Failed to open output files: \(error, privacy: .public)")
            reply(false, "Failed to open output files: \(error.localizedDescription)")
        }
    }

    func stopCapture(
        reply: @escaping (String?, String?, String?) -> Void
    ) {
        // Set isUserStopping FIRST, then snapshot the stream, atomically. Ordering matters:
        // an in-flight in-place restart commits its new stream into `self.stream` and bails only
        // if it sees isUserStopping at commit time — so we must mark stopping before we read the
        // stream, guaranteeing we stop whatever stream is (or is about to be) live (council F1).
        let (capturing, captureStream, micSess, tapSess) = stateLock.sync { () -> (Bool, SCStream?, MicCaptureSession?, SystemTapSession?) in
            if isCapturing { isUserStopping = true }
            return (isCapturing, stream, micSession, tapSession)
        }
        guard capturing else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Stopping capture")
        // Read BEFORE the sessions are stopped below, so frames delivered in that short window (well
        // under a second) are not in these facts: the delivered/zero seconds can understate by that margin.
        record(.captureStop, .info, coverageFacts())
        livenessWatchdog.stop()
        tapHealer.cancelAll()
        stopTapGuardTimer()
        // Stop mic + tap delivery before finalize so no buffer lands on the audio queue after the WAV
        // headers are sealed (a late buffer would be a no-op anyway — finalize is idempotent).
        micSess?.stop()
        tapSess?.stop()

        Task {
            if let captureStream {
                do {
                    try await captureStream.stopCapture()
                    Logger.audio.debug("SCStream stopped")
                } catch {
                    // Stream may already be stopped — proceed with finalization
                }
            }
            // Drain the audio queue (persistent constant) outside stateLock to avoid lock-order
            // inversion with rotateChunk; serializes with any callbacks on the same queue.
            let handler = self.stateLock.sync { self.handler }
            self.audioQueue.sync { handler?.finalizeAll() }
            let (sys, mic) = self.stateLock.sync {
                let result = (self.systemPath, self.micPath)
                self.isCapturing = false
                self.stream = nil
                self.handler = nil
                self.micSession = nil
                self.tapSession = nil
                self.systemPath = nil
                self.micPath = nil
                self.alarms = CaptureAlarmRegistry()
                self.registryResets += 1
                return result
            }
            reply(sys, mic, nil)
        }
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        reply(stateLock.sync { isCapturing }, nil)
    }

    /// The app's pull (§6.2): the helper's alarm registry and per-track health, one snapshot.
    func captureStatus(reply: @escaping (Data?) -> Void) {
        reply(snapshot(tracks: trackHealth()).encoded())
    }

    /// Replies false ("not understood") for a payload it cannot read, and leaves `pendingOptions` as is.
    func configureCapture(optionsJSON: Data, reply: @escaping (Bool) -> Void) {
        guard let options = CaptureOptions.decodeStrict(optionsJSON) else {
            Logger.audio.warning("Capture options not understood — ignored")
            reply(false)
            return
        }
        stateLock.sync { pendingOptions = options }
        Logger.audio.info("Capture options: tap_auto_start=\(options.tapAutoStart, privacy: .public) soft_alarm=\(options.remoteExactZeroSoftAlarmSeconds.map(String.init) ?? "off", privacy: .public) debug_drop=\(options.debugDropTapFrames, privacy: .public)")
        reply(true)
    }

    /// The app forwards sleep/wake (§8.10): nothing is judged while the machine sleeps, and on wake
    /// both tracks are re-armed and healed; the re-armed monitors are the heartbeat check.
    func systemPowerEvent(kind: String, reply: @escaping () -> Void) {
        defer { reply() }
        guard stateLock.sync(execute: { isCapturing }) else { return }
        switch kind {
        case "sleep":
            Logger.audio.info("System sleep: liveness paused")
            livenessWatchdog.pause()
            tapHealer.cancelAll()   // paired with trigger(.wake) below (C4)
        case "wake":
            Logger.audio.info("System wake: re-arming both tracks, healing the tap and the mic")
            tapHealer.trigger(.wake)   // forgets the episode; never rebuilds blind — the re-armed monitor decides
            livenessWatchdog.arm(track: .mic)
            livenessWatchdog.arm(track: .system)
            stateLock.sync { micSession }?.heal()
        default:
            Logger.audio.warning("Unknown power event \(kind, privacy: .public)")
        }
    }

    func updateMicrophone(
        deviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    ) {
        let (capturing, micSess) = stateLock.sync { (isCapturing, micSession) }
        guard capturing, let micSess else {
            reply(false, "No capture in progress")
            return
        }

        Logger.audio.info("Switching mic to: \(deviceId ?? "system default", privacy: .public)")

        // Retarget the decoupled mic AVCaptureSession (#96). startRunning can block briefly, so do it
        // off the XPC reply thread.
        Task {
            do {
                try micSess.updateDevice(deviceId)
                // Record provenance with the RESOLVED device, on success only — symmetric with
                // .captureStart (council CONV-1): a switch that fell back to default or failed must not
                // claim the requested device in mic_device.
                self.record(.micSwitch, .info, ["mic": micSess.resolvedDeviceId ?? "default"])
                Logger.audio.info("Mic switched successfully to: \(deviceId ?? "system default", privacy: .public)")
                reply(true, nil)
            } catch {
                Logger.audio.error("Mic switch failed: \(error, privacy: .public)")
                reply(false, "Mic switch failed: \(error.localizedDescription)")
            }
        }
    }

    func rotateChunk(
        outputDirectory: String,
        newBaseName: String,
        reply: @escaping (String?, String?, String?) -> Void
    ) {
        let (capturing, currentHandler) = stateLock.sync { (isCapturing, handler) }
        guard capturing, let currentHandler else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Rotating chunk — new base: \(newBaseName, privacy: .private)")

        let newSysPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + ".wav")
        let newMicPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + "_mic.wav")

        do {
            let newSystemWriter = try WavFileWriter(path: newSysPath)
            let newMicWriter = try WavFileWriter(path: newMicPath)
            wireWriteFailure(newSystemWriter, track: "system")
            wireWriteFailure(newMicWriter, track: "mic")

            // Swap on the persistent audio queue for zero-gap guarantee, then update
            // state outside to avoid lock-order inversion with stopCapture.
            var oldPaths: (systemPath: String, micPath: String)!
            audioQueue.sync {
                oldPaths = currentHandler.swapWriters(
                    newSystemWriter: newSystemWriter,
                    newMicWriter: newMicWriter
                )
            }
            self.stateLock.sync {
                self.systemPath = newSysPath
                self.micPath = newMicPath
            }
            Logger.audio.info("Chunk rotated — old: \(oldPaths.systemPath, privacy: .private)")
            // Coverage survives in the record even if the ring evicts older events (§7.1). On this XPC
            // thread, outside the `audioQueue.sync` above.
            record(.trackCoverage, .info, ["chunk": newBaseName].merging(coverageFacts()) { a, _ in a })
            reply(oldPaths.systemPath, oldPaths.micPath, nil)
        } catch {
            Logger.audio.error("Chunk rotation failed: \(error, privacy: .public)")
            reply(nil, nil, "Rotation failed: \(error.localizedDescription)")
        }
    }

    /// Drain and clear the helper's diagnostic ring for transport to the app (#95). The app merges
    /// these helper-origin events with its own and flushes `<session>.diag.jsonl` if anomalous.
    func drainDiagnostics(reply: @escaping (Data?) -> Void) {
        reply(diagnostics.drainData())
    }

    // MARK: - #220 System Audio Recording permission

    func systemAudioPermissionStatus(reply: @escaping (String) -> Void) {
        reply(SystemAudioRecordingPermission.wireValue(SystemAudioRecordingPermission.preflight()))
    }

    /// The app saw the permission granted (its repair window resolved). Treated as one more permission
    /// check: the guard rebuilds only if the helper itself sees the grant AND the tap needs it.
    func restartSystemAudio(reply: @escaping (Bool, String?) -> Void) {
        guard stateLock.sync(execute: { tapSession != nil && !isUserStopping }) else {
            reply(false, "System audio is not being captured with the Core Audio tap")
            return
        }
        // Read the epoch on audioQueue asynchronously: a stalled audio queue must not block this XPC thread.
        audioQueue.async { [weak self] in
            guard let self else { reply(false, nil); return }
            let epoch = self.tapGuardEpoch
            self.tccQueue.async {
                let status = SystemAudioRecordingPermission.preflight()
                self.audioQueue.async {
                    guard epoch == self.tapGuardEpoch else { reply(false, "Capture session changed"); return }
                    let actions = self.tapGuard.permissionChecked(status, evidence: .none, now: self.guardNow())
                    self.apply(actions)
                    let rebuilt = actions.contains { if case .rebuildTap = $0 { return true }; return false }
                    reply(rebuilt, rebuilt ? nil : "No rebuild needed (permission \(SystemAudioRecordingPermission.wireValue(status)))")
                }
            }
        }
    }

    // MARK: - Tap permission guard plumbing (all on audioQueue unless noted)

    private func startTapGuardTimer() {
        audioQueue.async {
            self.tapGuardTimer?.cancel()
            self.tapGuardTimer = nil
            // A stop queued its cancel before this ran: don't arm a timer that outlives the session.
            guard self.stateLock.sync(execute: { self.isCapturing && !self.isUserStopping && self.tapSession != nil })
            else { return }
            let t = DispatchSource.makeTimerSource(queue: self.audioQueue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.apply(self.tapGuard.tick(now: self.guardNow()))
            }
            t.resume()
            self.tapGuardTimer = t
        }
    }

    private func stopTapGuardTimer() {
        audioQueue.async {
            self.tapGuardTimer?.cancel()
            self.tapGuardTimer = nil
        }
    }

    /// Called from `SystemTapSession` after every successful (re)build, on its config queue. The
    /// grant is decided when the aggregate starts, so this is when to ask.
    private func tapDidBuild() {
        // Off the caller's queue: a slow TCC read must not hold up the next rebuild.
        tccQueue.async { [weak self] in
            let status = SystemAudioRecordingPermission.preflight()
            guard let self else { return }
            self.audioQueue.async {
                self.apply(self.tapGuard.tapBuilt(status: status, now: self.guardNow()))
            }
        }
    }

    private func apply(_ actions: [TapPermissionGuard.Action]) {
        for action in actions {
            switch action {
            case .checkPermission(let evidence):
                // A TCC IPC round-trip: never on the audio queue.
                let epoch = tapGuardEpoch
                tccQueue.async { [weak self] in
                    let status = SystemAudioRecordingPermission.preflight()
                    guard let self else { return }
                    self.audioQueue.async {
                        guard epoch == self.tapGuardEpoch else { return }   // a previous session's check
                        self.apply(self.tapGuard.permissionChecked(status, evidence: evidence, now: self.guardNow()))
                    }
                }
            case .rebuildTap(let reason):
                guard stateLock.sync(execute: { tapSession != nil && !isUserStopping }) else { continue }
                Logger.audio.info("System tap: rebuilding for the System Audio Recording permission (\(reason == .grant ? "grant" : "insurance", privacy: .public))")
                // Through the ladder, so it counts against the episode's budget (§5).
                tapHealer.trigger(reason == .grant ? .permissionGrant : .permissionInsurance)
            case .reportDenied(let status):
                guard stateLock.sync(execute: { tapSession != nil && !isUserStopping }) else { continue }
                Logger.audio.error("System tap: System Audio Recording permission \(SystemAudioRecordingPermission.wireValue(status), privacy: .public) — the other side is not being captured")
                record(.systemAudioPermissionDenied, .anomaly, [
                    "status": status == nil ? "unconfirmed" : SystemAudioRecordingPermission.wireValue(status),
                ])
                let message = status == nil
                    ? "Parley can’t confirm it’s capturing the other side of the call: system audio has been completely silent. If they’re talking, check System Audio Recording."
                    : "Parley isn’t allowed to record system audio, so the other side of the call is not being captured. Your microphone is still recording. Grant System Audio Recording to fix it."
                onQualityAnomaly?(CaptureEventKind.systemAudioPermissionDenied.rawValue, message)
                raiseAlarm(status == nil ? .remoteCantConfirm : .remotePermissionDenied, message)
            case .reportRestored:
                Logger.audio.info("System tap: real audio is arriving again — remote side restored")
                record(.systemAudioPermissionRestored, .info)
                onQualityAnomaly?(
                    CaptureEventKind.systemAudioPermissionRestored.rawValue,
                    "The other side of the call is being recorded again."
                )
                clearAlarm(.remotePermissionDenied)
                clearAlarm(.remoteCantConfirm)
            }
        }
    }

    func stopAndFinalize() {
        // Mark stopping before snapshotting the stream so an in-flight restart bails / is torn
        // down (council F1), mirroring stopCapture.
        let (capturing, captureStream, micSess, tapSess) = stateLock.sync { () -> (Bool, SCStream?, MicCaptureSession?, SystemTapSession?) in
            if isCapturing { isUserStopping = true }
            return (isCapturing, stream, micSession, tapSession)
        }
        guard capturing else { return }
        Logger.audio.info("Stopping capture due to client disconnect")
        // Same coverage as a clean stop, so a recording the app crashed out of still reports how much
        // of each side was captured (and, on the tap, how much of it was exact zeros, #220).
        record(.captureStop, .info, coverageFacts())
        livenessWatchdog.stop()
        tapHealer.cancelAll()
        stopTapGuardTimer()

        // Stop mic + tap delivery, then finalize synchronously on the persistent audio queue so WAV
        // headers are written before the XPC service exits (I5 fix).
        micSess?.stop()
        tapSess?.stop()
        audioQueue.sync { self.handler?.finalizeAll() }

        if let captureStream {
            Task {
                try? await captureStream.stopCapture()
                self.stateLock.sync {
                    self.isCapturing = false
                    self.stream = nil
                    self.handler = nil
                    self.micSession = nil
                    self.tapSession = nil
                    self.alarms = CaptureAlarmRegistry()
                    self.registryResets += 1
                }
                Logger.audio.info("Capture finalized after client disconnect")
            }
        } else {
            stateLock.sync {
                self.isCapturing = false
                self.handler = nil
                self.micSession = nil
                self.tapSession = nil
                self.alarms = CaptureAlarmRegistry()
                self.registryResets += 1
            }
        }
    }

    private func cleanupAfterFailure() {
        livenessWatchdog.stop()
        tapHealer.cancelAll()
        stopTapGuardTimer()
        // Snapshot and clear state under the lock, then run the blocking teardown (mic stopRunning,
        // writer finalize, file deletes) OUTSIDE the lock so we never hold stateLock across a blocking
        // call. Not called under stateLock, so the snapshot-then-act split is safe.
        let (h, micSess, tapSess, sys, mic) = stateLock.sync {
            () -> (AudioOutputHandler?, MicCaptureSession?, SystemTapSession?, String?, String?) in
            let snapshot = (handler, micSession, tapSession, systemPath, micPath)
            stream = nil
            handler = nil
            micSession = nil
            tapSession = nil
            systemPath = nil
            micPath = nil
            alarms = CaptureAlarmRegistry()
            registryResets += 1
            return snapshot
        }
        micSess?.stop()
        tapSess?.stop()
        audioQueue.sync { h?.finalizeAll() }
        if let sys { try? FileManager.default.removeItem(atPath: sys) }
        if let mic { try? FileManager.default.removeItem(atPath: mic) }
    }

    /// Build and start the decoupled mic capture session (#96), wiring its diagnostics + recovery
    /// callbacks into the service. Throws — failing the whole start — if the mic can't be brought up,
    /// since the user expects their own voice recorded. Mid-session mic loss is handled separately by
    /// MicCaptureSession and is NOT fatal (system audio keeps recording).
    /// Returns the session and the device the mic ACTUALLY resolved to (`nil` = system default), so the
    /// caller can record honest `.captureStart` provenance even when the requested device fell back
    /// (council CONV-1), and wire the session's heartbeat into the liveness watchdog.
    private func startMicSession(handler: AudioOutputHandler, microphoneDeviceId: String?) throws -> (session: MicCaptureSession, deviceId: String?) {
        let mic = MicCaptureSession(deliveryQueue: audioQueue) { [weak handler] buffer in
            handler?.appendMicSampleBuffer(buffer)
        }
        mic.onEvent = { [weak self] kind, severity, detail in
            self?.record(kind, severity, detail)
        }
        mic.onRecovered = { [weak self] deviceId in
            // Mic self-healed a route change — system audio never stopped.
            // No "Recording Resumed" banner (routine switch); just update the label via onMicDeviceChanged.
            self?.onMicDeviceChanged?(deviceId)
        }
        mic.onUnavailable = { [weak self] reason in
            // Mic loss is NOT fatal: system audio keeps recording and the partial mic WAV stays valid.
            // Record the anomaly so the session is flagged and diagnostics flush.
            Logger.audio.error("Microphone unavailable mid-session: \(reason, privacy: .public)")
            self?.record(.restartFailed, .anomaly, ["source": "mic", "reason": reason])
            // The heal gave up, so no second verdict will come: alarm now (scan C11).
            self?.livenessWatchdog.queue.async {
                guard let self else { return }
                if self.micHealPolicy.healFailed() == .alarm {
                    self.raiseAlarm(.micNotDelivering, "The microphone stopped delivering audio and could not be reopened. Try another microphone from the menu.")
                }
            }
        }
        try mic.start(deviceId: microphoneDeviceId)
        // Commit-or-abort against a stop that raced in during start (mirrors buildAndStartStream's
        // council-F1 guard): if the app began stopping while the mic was coming up, tear it down
        // rather than leak a running session past stop.
        let stopping = stateLock.sync { () -> Bool in
            if isUserStopping { return true }
            self.micSession = mic
            return false
        }
        if stopping { mic.stop() }
        return (mic, mic.resolvedDeviceId)
    }

    /// Start the Core Audio output-tap system source (#103), wiring its diagnostics + rebuild-result
    /// callbacks into the service. Throws — failing the whole start — if the tap can't be created (most
    /// likely a missing System Audio Recording TCC grant), so the user fixes permissions before the
    /// meeting, symmetric with the SCK path's start failure. Mid-session tap loss (a rebuild failing)
    /// is NOT fatal: the mic keeps recording and the system track is silence-padded — surfaced as the
    /// `remoteRecoveryFailed` alarm, never a teardown.
    /// `options` is the start's own copy (`startCapture` consumes `pendingOptions`, F4 round 1).
    private func startSystemTap(handler: AudioOutputHandler, options: CaptureOptions) throws {
        audioQueue.sync {
            tapGuard = TapPermissionGuard(softAlarmSeconds: options.remoteExactZeroSoftAlarmSeconds.map(Double.init))
            tapGuardEpoch += 1
        }
        let tap = SystemTapSession(
            deliveryQueue: audioQueue, tapAutoStart: options.tapAutoStart,
            dropFramesForDiagnostics: options.debugDropTapFrames
        ) { [weak self, weak handler] samples, pts in
            handler?.appendSystemSamples(samples, pts: pts)
            // Already on audioQueue.
            guard let self else { return }
            self.apply(self.tapGuard.samples(samples, rate: 48_000, now: self.guardNow()))
        }
        tap.onBuilt = { [weak self] in self?.tapDidBuild() }
        tap.onEvent = { [weak self] kind, severity, detail in
            self?.record(kind, severity, detail)
        }
        wireTapHealer(to: tap)
        // srst: the ladder forgets the episode and runs one immediate `rebuildTap` rung, whose rebuild
        // re-registers the system listeners; the mic's AVCaptureSession is reopened too. The output
        // probe needs nothing — it reads the process list afresh every tick.
        tap.onServiceRestarted = { [weak self] in
            guard let self else { return }
            self.tapHealer.trigger(.serviceRestarted)
            self.stateLock.sync { self.micSession }?.heal()
        }
        try tap.start()
        // Commit-or-abort against a stop that raced in during start (mirrors startMicSession's council-F1
        // guard): if the app began stopping while the tap was coming up, tear it down rather than leak a
        // running capture past stop.
        let stopping = stateLock.sync { () -> Bool in
            if isUserStopping { return true }
            self.tapSession = tap
            return false
        }
        if stopping { tap.stop() }
    }

    /// The tap's rebuild results and aggregate events feed the healer; the healer's verdicts feed the
    /// alarms (§5, §6.1): `remoteRecoveryFailed` raised when a rung threw or got stuck and cleared by the
    /// next successful rung (scan C8), `remoteNotDelivering` raised on give-up and cleared on recovery.
    private func wireTapHealer(to tap: SystemTapSession) {
        tapHealer.tap = tap
        // A new session starts a new episode: forget the previous session's budget, exhaustion and
        // dead-gate memory (its timers were cancelled at its stop). Tokens stay monotonic.
        tapHealer.trigger(.wake)
        tap.onRebuildResult = { [weak self] rung, token, ok, _ in
            // A rebuild the ladder did not order (output change, rate drift) is still a rebuild (§7.1).
            if token == 0, ok { self?.noteRebuild() }
            self?.tapHealer.rebuildResult(rung: rung, token: token, succeeded: ok)
        }
        tap.onAggregateEvent = { [weak self] _ in self?.livenessWatchdog.accelerate(track: .system) }
        tapHealer.onEvent = { [weak self] k, s, d in
            if k == .tapRecoveryRung { self?.noteRebuild() }
            self?.record(k, s, d)
        }
        tapHealer.onGiveUp = { [weak self] in
            self?.raiseAlarm(.remoteNotDelivering, "The other side of the call isn’t reaching Parley although audio is playing. Parley keeps retrying; if this persists, check the output device in the call app.")
        }
        tapHealer.onRecovered = { [weak self] in self?.clearAlarm(.remoteNotDelivering) }
        tapHealer.onStuck = { [weak self] in
            self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.")
        }
        tapHealer.onRungFailed = { [weak self] rung in
            self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture (\(rung.rawValue)). The other side may not be recorded.")
        }
        tapHealer.onRungSucceeded = { [weak self] in self?.clearAlarm(.remoteRecoveryFailed) }
    }

    /// Build a fresh system-audio SCStream around the given handler and start it. Used both for the
    /// initial start and for #86 in-place restarts: because the SAME handler (and therefore the same
    /// WavFileWriters / output files) is reused, a restart resumes the existing recording with no file
    /// rotation and no lost audio. The mic is captured separately (AVCaptureSession, #96) and is no
    /// longer part of this stream — so a mic route change never stops it.
    private func buildAndStartStream(handler: AudioOutputHandler) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw NSError(
                domain: "AudioCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display found"]
            )
        }

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = false  // mic is captured via AVCaptureSession (#96)
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000
        Logger.audio.debug("System audio capture rate: 48000 Hz (fixed)")
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let captureStream = SCStream(
            filter: filter, configuration: config, delegate: handler
        )

        try captureStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: audioQueue)
        try captureStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: audioQueue)

        // Commit the new stream and re-validate the session atomically: if a stop/disconnect began
        // while we were awaiting (SCShareableContent + addStreamOutput), bail instead of resurrecting
        // a stream into finalized writers (council F1). isUserStopping (not !isCapturing) is the
        // correct gate — initial startCapture sets isCapturing only AFTER this returns.
        let committed = stateLock.sync { () -> Bool in
            if isUserStopping { return false }
            self.stream = captureStream
            return true
        }
        guard committed else {
            try? await captureStream.stopCapture()
            throw CancellationError()
        }
        try await captureStream.startCapture()
    }

    // MARK: - #86 in-place restart on benign stream stop

    /// SCStream `didStopWithError` handoff. Decides whether the stop is a user stop (ignore), a
    /// recoverable route change (restart in place), or a terminal fault (surface fatal).
    private func handleStreamStopped(_ error: Error) {
        let (capturing, userStopping, attempts, givenUp) = stateLock.sync {
            (isCapturing, isUserStopping, restartAttempts, systemStreamGivenUp)
        }
        // Already declared the system stream unrecoverable: the lingering silent stream may keep
        // firing didStopWithError. Ignore them — the mic is recording and must not be torn down.
        guard !givenUp else { return }
        let decision = RestartDecision.evaluate(
            isUserStopped: userStopping, isCapturing: capturing,
            attempts: attempts, maxAttempts: maxRestartAttempts
        )
        switch decision {
        case .ignore:
            Logger.audio.info("Stream stop ignored — user stop or capture already inactive")
        case .failFatal:
            // Budget exhausted. A system-stream death must NOT failFatally (that stops the mic, which
            // runs on a separate AVCaptureSession and is recording fine). If a restart loop is active,
            // let IT own exhaustion via attemptRestart; otherwise declare unrecoverable here.
            // The `!isRestarting` check is only an optimisation — `handleSystemStreamUnrecoverable` is
            // latched on `systemStreamGivenUp`, so it stays correct even if attemptRestart races in and
            // fires it first (the second call is a no-op).
            let shouldDeclare = stateLock.sync { !isRestarting }
            if shouldDeclare { handleSystemStreamUnrecoverable() }
        case .restart:
            // Atomic check-and-set so two concurrent didStopWithError callbacks can't both launch
            // a restart loop (council F10).
            let shouldStart = stateLock.sync { () -> Bool in
                if isRestarting { return false }
                isRestarting = true
                return true
            }
            guard shouldStart else { return }
            Task { await self.attemptRestart() }
        }
    }

    /// Finalize writers and clear all capture state after an unrecoverable stream failure, then
    /// notify the app exactly once. Clearing isCapturing lets the app's recovery start() succeed on
    /// the same XPC connection (council F2); the one-shot latch makes the fatal notification
    /// at-most-once even if both emitters race (council F8).
    private func failFatally(_ reason: String) {
        // Latch (at-most-once), CLAIM the handler, and clear capture state in ONE critical section,
        // so a concurrent rotateChunk/stop sees isCapturing=false and bails rather than operating on
        // the handler we're about to finalize (council FV1). The finalize itself is idempotent, which
        // is the real guard against a double-finalize crash; this claim just narrows the window.
        let (won, h, micSess, tapSess): (Bool, AudioOutputHandler?, MicCaptureSession?, SystemTapSession?) = stateLock.sync {
            if hasFailedFatally { return (false, nil, nil, nil) }
            hasFailedFatally = true
            let handlerToFinalize = handler
            let micToStop = micSession
            let tapToStop = tapSession
            isCapturing = false
            stream = nil
            handler = nil
            micSession = nil
            tapSession = nil
            systemPath = nil
            micPath = nil
            alarms = CaptureAlarmRegistry()
            registryResets += 1
            return (true, handlerToFinalize, micToStop, tapToStop)
        }
        guard won else { return }
        livenessWatchdog.stop()
        stopTapGuardTimer()
        record(.restartFailed, .anomaly, ["reason": reason])
        // Stop the decoupled mic + tap sessions too, otherwise they keep running after the system
        // stream is declared dead (council CONC-2). Stop before finalize so no buffer lands on the
        // audio queue after the WAV headers are sealed. (failFatally is an SCK-restart-budget path; a
        // tap session won't reach it, but stopping a nil tap is a harmless no-op.)
        micSess?.stop()
        tapSess?.stop()
        // Flush the partial WAV (pre-fault audio) on the persistent queue; finalize is idempotent so
        // a rotation's swapWriters finalizing the same writers first is harmless.
        audioQueue.sync { h?.finalizeAll() }
        onFailFatally?("Capture stream failed and could not be restarted")
    }

    /// Rebuild and restart the dead stream into the SAME handler/writers, re-pinning the mic.
    /// Loops on transient failures up to the restart budget. A rebuild that "starts" but delivers no
    /// frames counts as a failed attempt (#86 verified autoheal), and budget exhaustion surfaces a
    /// system-only warning WITHOUT tearing down the mic.
    private func attemptRestart() async {
        defer { stateLock.sync { isRestarting = false } }
        while true {
            let (userStopping, capturing, attempts, currentHandler, oldStream) = stateLock.sync {
                (isUserStopping, isCapturing, restartAttempts, handler, stream)
            }
            let decision = RestartDecision.evaluate(
                isUserStopped: userStopping, isCapturing: capturing,
                attempts: attempts, maxAttempts: maxRestartAttempts
            )
            guard decision == .restart, let currentHandler else {
                // Budget exhausted MID-RECORDING. Do NOT failFatally — that tears down the mic + whole
                // session, but the mic runs on a separate AVCaptureSession and is still recording fine.
                // Warn the app, keep the mic, stop retrying; the system track is silence-padded (#86).
                if decision == .failFatal { handleSystemStreamUnrecoverable() }
                return
            }
            do {
                if let oldStream { try? await oldStream.stopCapture() }  // tear down the dead stream
                // Snapshot the probe start BEFORE the rebuild so only buffers delivered AFTER this
                // point count as "frames resumed".
                let probeStartNanos = DispatchTime.now().uptimeNanoseconds
                try await buildAndStartStream(handler: currentHandler)
                // Drop any stale in-flight buffer the just-stopped stream may have left on the audio
                // queue, so the probe below only counts frames from the rebuilt stream. (If the old
                // stopCapture() silently failed and its stream still delivers, systemStreamGivenUp
                // still caps the downstream harm — full stream-identity gating is a future hardening.)
                currentHandler.resetSystemBufferArrival()
                // A stop may have begun during the restart's awaits; if so, don't claim success or
                // notify — the stop path owns teardown now (council F1).
                if stateLock.sync(execute: { isUserStopping }) { return }

                // Liveness probe (#86): buildAndStartStream returning only means SCStream ACCEPTED the
                // config — not that it delivers audio. The original false-success bug declared the
                // restart healed here and lost 47 min of a real call when the rebuilt stream produced
                // no frames. Wait, then verify a real system buffer arrived AFTER the rebuild before
                // trusting it. (CancellationError from this sleep is handled by the catch below.)
                try await Task.sleep(nanoseconds: livenessProbeNanos)
                if stateLock.sync(execute: { isUserStopping }) { return }
                let resumed = SystemStreamLiveness.framesResumed(
                    lastArrivalNanos: currentHandler.lastSystemBufferArrivalNanos(),
                    probeStartNanos: probeStartNanos
                )
                if resumed {
                    stateLock.sync { restartAttempts = 0 }
                    Logger.audio.info("System-audio stream restarted in place — frames resumed")
                    record(.restartInPlace, .warning, ["source": "system"])
                    onRestartInPlace?()
                    return
                }
                // Rebuilt stream produced NO frames — count it as a failed attempt and retry within
                // budget (the loop re-evaluates the budget at the top).
                stateLock.sync { restartAttempts += 1 }
                record(.restartFailed, .anomaly, ["reason": "no frames after restart"])
                Logger.audio.error("In-place restart produced no frames — retrying")
                try? await Task.sleep(nanoseconds: restartBackoffNanos)
            } catch is CancellationError {
                // buildAndStartStream (or the probe sleep) bailed because a stop began — abandon silently.
                Logger.audio.info("In-place restart aborted — session stopping")
                return
            } catch {
                stateLock.sync { restartAttempts += 1 }
                Logger.audio.error("In-place restart attempt failed: \(error, privacy: .public)")
                try? await Task.sleep(nanoseconds: restartBackoffNanos)
            }
        }
    }

    /// Budget exhausted for the MID-RECORDING system-stream restart (#86). Unlike `failFatally`, this
    /// does NOT stop the mic, finalize, or tear down the session: the mic runs on a separate
    /// AVCaptureSession and is still recording (a real call captured 47 good mic minutes while the
    /// system stream was dead). Record the anomaly, warn the app over the reverse channel, and stop
    /// retrying — the system track is silence-padded but the local audio is preserved.
    ///
    /// Reachable from BOTH the `attemptRestart` loop-top exhaustion AND `handleStreamStopped`'s
    /// `.failFatal`, so it latches on `systemStreamGivenUp` to fire exactly once per give-up, and it
    /// stops + clears the lingering silent stream so its further `didStopWithError` callbacks stop
    /// arriving (which `handleStreamStopped`'s `givenUp` guard also ignores).
    private func handleSystemStreamUnrecoverable() {
        let shouldWarn = stateLock.sync { () -> Bool in
            if systemStreamGivenUp { return false }
            systemStreamGivenUp = true
            return true
        }
        guard shouldWarn else { return }
        // Stop and drop the zombie (silent) SCStream so it stops firing callbacks. Keep the handler,
        // writers, and mic untouched — finalize uses the writers, not the stream.
        let zombie = stateLock.sync { () -> SCStream? in let s = stream; stream = nil; return s }
        if let zombie { Task { try? await zombie.stopCapture() } }
        Logger.audio.error("System-audio stream unrecoverable after \(self.maxRestartAttempts) restarts — mic still recording")
        record(.systemAudioUnrecovered, .anomaly, [
            "reason": "system stream produced no frames after \(maxRestartAttempts) restarts"
        ])
        onSystemAudioUnrecoverable?("Remote audio couldn’t be recovered — only your microphone is recording.")
        raiseAlarm(.remoteRecoveryFailed, "Remote audio couldn’t be recovered — only your microphone is recording.")
    }
}
