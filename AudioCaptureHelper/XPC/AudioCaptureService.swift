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
    typealias StopReply = (String?, String?, String?) -> Void
    typealias Lifecycle = CaptureLifecycle<StopReply>
    /// The session claim (H2 council, B-I1/I2/I3; round 2): idle → starting → capturing → stopping → idle,
    /// with a token per start and the stops that arrive during a start. Guarded by `stateLock`, like the
    /// two views of it below (read them inside `stateLock` only).
    private var lifecycle = Lifecycle()
    /// Capturing or stopping: what `status` and the snapshot report.
    private var isCapturing: Bool { lifecycle.isCapturing }
    /// A stop (or a disconnect) owns teardown now — including one that aborted a start in flight — so
    /// a stop-induced `didStopWithError` is classified as `.ignore` rather than a route-change restart,
    /// and every commit-or-abort guard tears down instead of committing.
    private var isUserStopping: Bool { lifecycle.isStopping }
    /// The mic and the tap a start is opening right now, before its commit-or-abort registers them: the
    /// start's deadline stops them even when their `start()` never returns (round 2 item 1). `stateLock`.
    private var startingMic: MicCaptureSession?
    private var startingTap: SystemTapSession?
    /// This process's start, in ms on the system's monotonic clock (boot-relative, never steps back),
    /// so a helper started later always names a newer `HelperSessionId` — a wall-clock start could
    /// step backwards and make the replacement look older than the helper it replaced.
    private let processStartMillis = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
    /// Alarm-registry resets in this process. Guarded by `stateLock`. Incremented on every registry
    /// reset (stop, stopAndFinalize, a start that ends without committing), so each reset names a strictly
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
    /// Consecutive failed in-place restarts; reset to 0 on a restart that starts cleanly.
    private var restartAttempts = 0
    /// Guards against overlapping restart loops from rapid repeated stop errors.
    private var isRestarting = false
    /// One-shot latch: the system stream exhausted its restart budget and was declared unrecoverable.
    /// Once set, the lingering silent stream's further `didStopWithError` callbacks are ignored, the
    /// "unrecoverable" warning fires at most once, and — critically — a system-stream death NEVER
    /// tears down the still-good mic. Reset on a fresh startCapture.
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
    /// The helper's own sleep/wake from IOKit (round 2 item 18), delivered on the watchdog's queue.
    /// Created at the first start and kept for the process: power messages cost nothing while idle.
    private var powerObserver: SystemPowerObserver?
    /// Runs the tap's healing ladder from the system track's liveness verdicts (§5).
    private let tapHealer = TapHealer(scheduler: DispatchHealerScheduler(label: "audio-capture.tap-healer"))
    /// Mic side of "heal, then alarm" (§6.1), with the reopen deadline (A-C2). Touched on the watchdog
    /// queue only.
    private var micHealPolicy = MicHealPolicy()
    /// Per-track write progress (A-I3). Touched on the watchdog queue only.
    private var writeMonitors: [CaptureTrack: WriteProgressMonitor] = [:]
    /// Per track, which clears its delivery alarm may take: one raised while the track is called but
    /// writes nothing, or within 5 s of that, clears on write progress only (A-I3, round 2 item 16).
    /// Lock-only: the audio, watchdog and healer queues all raise or clear through it.
    private let deliveryGates = OSAllocatedUnfairLock<[CaptureTrack: DeliveryAlarmGate]>(initialState: [:])
    /// Per-track coverage (§7.1) accumulated as it happens: expected seconds from the gate, rebuilds
    /// from the healer (gaps live in `gaps`). Delivered / padded / zero / heartbeat counts
    /// are merged in when read (`coverageFacts`). Lock-only, so the audio queue may read it too.
    private let coverage = OSAllocatedUnfairLock<[CaptureTrack: TrackAccounting]>(
        initialState: [.mic: TrackAccounting(), .system: TrackAccounting()])
    /// The previous gate observation, for elapsed-time accounting (0 = none yet this session).
    private let lastGateTickNanos = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Real gap durations per track, from the liveness verdicts (review round 1: not the detection threshold).
    private let gaps = OSAllocatedUnfairLock<GapTracker>(initialState: GapTracker())

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
            // (A late seal of an abandoned session detaches these first: it reports into no session, M1.)
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
    private func snapshot(tracks: [TrackHealthSnapshot], coverage: [String: String]? = nil) -> CaptureStatusSnapshot {
        stateLock.sync {
            snapshotSequence += 1
            let id = HelperSessionId(processStartMillis: processStartMillis, registryResets: registryResets).description
            return CaptureStatusSnapshot(helperSessionId: id, sequence: snapshotSequence, isCapturing: isCapturing,
                                         alarms: alarms.sorted, tracks: tracks, coverage: coverage)
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

    private func noteRebuild() {
        coverage.withLock { $0[.system, default: TrackAccounting()].rebuilds += 1 }
    }

    /// The audio-queue half of per-track coverage: the handler's frame totals and the tap guard's
    /// exact-zero count. Read ON the audio queue only, inside a block that is already there (the bounded
    /// seal, a rotation's swap, the tick's async refresh) — never with an `audioQueue.sync` of its own,
    /// which a stalled audio queue would turn into a hung Stop (round 4 N2).
    private struct CoverageCounts: Sendable {
        let micDelivered, micPad, micZero, sysDelivered, sysPad: Int64
        let tapZeros: Int64?
    }

    private func coverageCountsOnAudioQueue(_ h: AudioOutputHandler, tapActive: Bool) -> CoverageCounts {
        let t = h.trackTotals()
        // The guard only sees tap samples; on SCK it says nothing.
        return CoverageCounts(micDelivered: t.micDelivered, micPad: t.micPad, micZero: t.micZero,
                              sysDelivered: t.sysDelivered, sysPad: t.sysPad,
                              tapZeros: tapActive ? tapGuard.exactZeroFrames : nil)
    }

    /// The last counts read on the audio queue, refreshed every tick (asynchronously): what `.captureStop`
    /// falls back to when the seal timed out (round 4 N2). Keyed by the session's start token, so a refresh
    /// queued before a stall that lands after the next start is ignored (round 5 item 3).
    private let lastCoverageCounts = OSAllocatedUnfairLock(initialState: SessionScopedCache<CoverageCounts>())

    /// Per-track coverage as `remote_*` / `local_*` detail keys, for `.captureStop` and every rotation's
    /// `.trackCoverage` and the status pull's snapshot, from counts read on the audio queue plus the
    /// lock-only counters. Any queue: no audio-queue wait. `incomplete`: the counts are the last cached
    /// ones (the seal timed out). Reads `helperSessionId` (`stateLock`): never call it inside a `stateLock.sync`.
    private func coverageFacts(_ counts: CoverageCounts?, mic: MicCaptureSession?, tap: SystemTapSession?,
                               incomplete: Bool = false, helperSession: String? = nil) -> [String: String] {
        // Which helper session these facts are: a `captureStop` supersedes the app's last pulled snapshot
        // of the SAME helper session (L11). `helperSession`: read by the caller with the capture session it counted.
        let session = helperSession ?? helperSessionId
        var (remote, local) = coverage.withLock { c in (c[.system] ?? TrackAccounting(), c[.mic] ?? TrackAccounting()) }
        let now = DispatchTime.now().uptimeNanoseconds
        let gapTracker = gaps.withLock { $0 }
        local.gapCount = gapTracker.gapCount(.mic)
        local.longestGapSeconds = gapTracker.longestGapSeconds(.mic, nowNanos: now)   // a gap still open counts
        remote.gapCount = gapTracker.gapCount(.system)
        remote.longestGapSeconds = gapTracker.longestGapSeconds(.system, nowNanos: now)
        let rate = AudioConverter.outputSampleRate   // both WAVs are 48 kHz mono
        if let counts {
            local.deliveredSeconds = Double(counts.micDelivered) / rate
            local.paddedSeconds = Double(counts.micPad) / rate
            local.exactZeroSeconds = Double(counts.micZero) / rate
            remote.deliveredSeconds = Double(counts.sysDelivered) / rate
            remote.paddedSeconds = Double(counts.sysPad) / rate
            remote.exactZeroSeconds = Double(counts.tapZeros ?? 0) / rate
        }
        local.heartbeatCallbacks = mic?.heartbeatCount() ?? 0
        remote.heartbeatCallbacks = tap?.heartbeatCount() ?? 0
        var remoteDetail = remote.asDetail(prefix: "remote")
        if tap == nil {
            // SCK: neither is measured (no tap guard, no callback count) — say nothing rather than 0.
            remoteDetail["remote_exact_zero_seconds"] = nil
            remoteDetail["remote_heartbeat_callbacks"] = nil
        }
        var facts = remoteDetail.merging(local.asDetail(prefix: "local")) { a, _ in a }
        facts["helper_session"] = session
        if incomplete { facts["coverage_incomplete"] = "true" }
        return facts
    }

    /// Both may be called from the audio queue (write failure, exact zeros, permission verdicts) and
    /// from the watchdog / config / healer queues — never from inside `stateLock.sync`, and they do no
    /// HAL read and no `audioQueue.sync` (a push encodes a handful of alarms; that is all).
    /// `raiseAlarm` is a no-op outside a live session (review round 1, defense in depth): nothing late from a stopped
    /// session — a healer timer, a finalize-time write — can land in the NEXT session's fresh registry.
    /// "Live" is `handler != nil && !isUserStopping`, not `isCapturing`: the writers run from the mic's
    /// first buffer, before `isCapturing` is set, and a write failure latches (it is reported once per
    /// episode), so dropping one there would leave a full disk unalarmed for the whole recording.
    /// Returns true when newly raised.
    @discardableResult
    private func raiseAlarm(_ kind: AlarmKind, _ message: String) -> Bool {
        let (changed, active, h) = stateLock.sync { () -> (Bool, Bool, AudioOutputHandler?) in
            guard handler != nil, !isUserStopping else { return (false, false, nil) }
            return (alarms.raise(kind, message: message, now: Date()), true, handler)
        }
        // A delivery alarm raised during (or just after) a write stall clears on write progress only.
        if active, let track = Self.deliveryTrack(of: kind) {
            let frames = h?.writtenFrames(track) ?? 0
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            deliveryGates.withLock { $0[track, default: DeliveryAlarmGate()].alarmRaised(now: now, frames: frames) }
        }
        guard changed else { return false }
        record(.alarmRaised, .anomaly, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot(tracks: trackHealth()).encoded())
        return true
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
        livenessWatchdog.onTick = { [weak self] now, gateOpen in self?.checkProgress(nowNanos: now, gateOpen: gateOpen) }
        livenessWatchdog.onResumed = { [weak self] work, reason in self?.resumeAfterSleep(work, reason: reason) }
        livenessWatchdog.fullWakeProbe = { SystemPowerObserver.isFullWake() }
        deliveryGates.withLock { $0 = [:] }
        // A new session starts a new mic episode and fresh write checks; on the watchdog queue, like
        // every other use.
        livenessWatchdog.queue.async { [weak self] in
            self?.micHealPolicy = MicHealPolicy()
            self?.writeMonitors = [:]
        }
        livenessWatchdog.start { [weak self] in
            guard let self else { return false }
            return self.stateLock.sync { self.lifecycle.isLive }
        }
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
        case .stalled(let s):
            record(.livenessGap, .anomaly, ["track": t, "seconds": "\(Int(s))"])
        case .cleared(let reason):
            record(.livenessRecovered, .info, ["track": t, "reason": "\(reason)"])
        case .healthy:
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        gaps.withLock { $0.note(verdict, track: track, nowNanos: now) }
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
        switch micHealPolicy.onVerdict(verdict, now: Double(DispatchTime.now().uptimeNanoseconds) / 1e9) {
        case .heal:
            healMic()
        case .healAndAlarm:
            healMic()
            raiseAlarm(.micNotDelivering, alarmMessage)
        case .alarm:
            raiseAlarm(.micNotDelivering, alarmMessage)
        case .clear:
            clearDeliveryAlarm(.micNotDelivering)
        case .reopenStuck, .followFailed, .none:
            break   // tick / healFailed only
        }
    }

    /// Every mic reopen goes through here — a silence verdict, wake, a coreaudiod restart — so each one
    /// is held to the reopen deadline (A-C2), including a heal that is a no-op behind a recovery already
    /// in flight.
    /// `restartingDeadline`: the wake's reopen, whose deadline replaces one that ran before the sleep.
    private func healMic(restartingDeadline: Bool = false) {
        guard let mic = stateLock.sync(execute: { micSession }) else { return }
        let heartbeat = mic.lastHeartbeatNanos()
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        livenessWatchdog.queue.async { [weak self] in
            self?.micHealPolicy.reopenRequested(now: now, heartbeat: heartbeat, restartingDeadline: restartingDeadline)
        }
        mic.heal()
    }

    /// The not-delivering kind whose clears `DeliveryAlarmGate` decides.
    private static func deliveryTrack(of kind: AlarmKind) -> CaptureTrack? {
        switch kind {
        case .micNotDelivering: return .mic
        case .remoteNotDelivering: return .system
        default: return nil
        }
    }

    /// A heartbeat must not clear a track's not-delivering alarm that is write-bound — raised while the
    /// track is called but writes nothing, or within 5 s of that (A-I3, round 2 item 16): only write
    /// progress, or the track no longer being expected, clears that one.
    private func clearDeliveryAlarm(_ kind: AlarmKind, reason: DeliveryAlarmGate.ClearReason = .heartbeat) {
        if let track = Self.deliveryTrack(of: kind),
           !deliveryGates.withLock({ $0[track, default: DeliveryAlarmGate()].mayClear(reason) }) { return }
        clearAlarm(kind)
    }

    /// Every 1 Hz tick, on the watchdog queue: the mic reopen deadline (A-C2) and each track's write
    /// progress (A-I3). Lock-only reads — the heartbeats and the handler's written-frame counters.
    private func checkProgress(nowNanos: UInt64, gateOpen: Bool) {
        let (mic, tap, h) = stateLock.sync { (micSession, tapSession, handler) }
        guard let mic, let h else { return }
        let micHeartbeat = mic.lastHeartbeatNanos()
        let deadline = Int(MicHealPolicy.reopenDeadlineSeconds)
        switch micHealPolicy.tick(now: Double(nowNanos) / 1e9, heartbeat: micHeartbeat, reopenInFlight: mic.recoveryInFlight()) {
        case .reopenStuck:
            // The reopen itself has not returned (gotcha #68): the mic's analog of the tap's stuck rung.
            Logger.audio.error("Microphone reopen still running after \(deadline, privacy: .public)s — alarming")
            record(.recoveryStuck, .anomaly, ["track": CaptureTrack.mic.rawValue, "seconds": "\(deadline)"])
            raiseAlarm(.micNotDelivering, "The microphone could not be reopened and isn’t delivering any audio. Try another microphone from the menu.")
        case .alarm:
            // It returned, so the re-armed monitor records its own verdict; only the alarm is ours (item 15).
            Logger.audio.error("Microphone reopened but delivered nothing within \(deadline, privacy: .public)s — alarming")
            raiseAlarm(.micNotDelivering, "The microphone was reopened but isn’t delivering any audio. Try another microphone from the menu.")
        case .clear:
            clearDeliveryAlarm(.micNotDelivering)
        default:
            break
        }
        // Refresh the coverage cache for a Stop whose seal times out (round 4 N2): asynchronously, so a
        // stalled audio queue never holds the tick either.
        let tapActive = tap != nil
        let session = stateLock.sync { lifecycle.session }
        audioQueue.async { [weak self, weak h] in
            guard let self, let h else { return }
            let counts = self.coverageCountsOnAudioQueue(h, tapActive: tapActive)
            self.lastCoverageCounts.withLock { $0.update(session: session, value: counts) }
        }
        // Tap: its callback heartbeat. SCK: the arrival stamp, as the liveness watchdog uses.
        let systemHeartbeat = tap?.lastHeartbeatNanos() ?? h.lastSystemBufferArrivalNanos()
        for (track, heartbeat, expected) in [(CaptureTrack.mic, micHeartbeat, true), (.system, systemHeartbeat, gateOpen)] {
            let frames = h.writtenFrames(track)
            var monitor = writeMonitors[track] ?? WriteProgressMonitor()
            let verdict = monitor.check(nowNanos: nowNanos, lastHeartbeatNanos: heartbeat, expected: expected,
                                        writtenFrames: frames)
            writeMonitors[track] = monitor
            handleWriteProgress(track: track, verdict: verdict, frames: frames)
            // A write-bound alarm raised outside a write-stall episode clears on write progress (item 16).
            if deliveryGates.withLock({ $0[track, default: DeliveryAlarmGate()].tick(frames: frames) }) {
                clearAlarm(track == .mic ? .micNotDelivering : .remoteNotDelivering)
            }
        }
    }

    /// The track's own not-delivering alarm, detail "audio arrives but can't be recorded", and a
    /// quality event for the record (A-I3). Cleared on write progress.
    private func handleWriteProgress(track: CaptureTrack, verdict: WriteProgressMonitor.Verdict, frames: Int64) {
        let kind: AlarmKind = track == .mic ? .micNotDelivering : .remoteNotDelivering
        switch verdict {
        case .stuck(let s):
            deliveryGates.withLock { $0[track, default: DeliveryAlarmGate()].writeStuck(frames: frames) }
            let message = track == .mic
                ? "The microphone’s audio arrives but can’t be recorded. Try another microphone from the menu."
                : "The other side’s audio arrives but can’t be recorded."
            Logger.audio.error("\(track.rawValue, privacy: .public) track: called for \(Int(s), privacy: .public)s with nothing written — audio arrives but can't be recorded")
            record(.livenessGap, .anomaly, ["track": track.rawValue, "reason": "audio arrives but can't be recorded", "seconds": "\(Int(s))"])
            onQualityAnomaly?(CaptureEventKind.livenessGap.rawValue, message)
            raiseAlarm(kind, message)
        case .cleared:
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            deliveryGates.withLock { $0[track, default: DeliveryAlarmGate()].writeRecovered(now: now) }
            record(.livenessRecovered, .info, ["track": track.rawValue, "reason": "writing again, or no longer expected"])
            clearAlarm(kind)
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
            clearDeliveryAlarm(.remoteNotDelivering)
            clearAlarm(.remoteRecoveryFailed)
        case .cleared(.heartbeat):
            tapHealer.heartbeatObserved()
        case .cleared(.gateClosed):
            tapHealer.gateClosed()
            clearDeliveryAlarm(.remoteNotDelivering, reason: .notExpected)
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
            clearDeliveryAlarm(.remoteNotDelivering)
            clearAlarm(.remoteRecoveryFailed)
        case .cleared(let reason):
            clearDeliveryAlarm(.remoteNotDelivering, reason: reason == .gateClosed ? .notExpected : .heartbeat)
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
        // A CLAIM, not only a check (B-I2): a second start while this one is still coming up is refused
        // too, instead of overwriting the handler, the paths and the tap and orphaning the first session.
        // The calling connection owns what this start builds: only its invalidation stops it (round 5 item 5).
        let owner = NSXPCConnection.current().map(ObjectIdentifier.init)
        guard let token = stateLock.sync(execute: { lifecycle.claimStart(owner: owner) }) else {
            reply(false, CaptureReplies.alreadyInProgress)
            return
        }
        // Exactly one reply, whichever of the start and its deadline answers first (round 2 item 1).
        let replyOnce = OnceFlag()
        let answer: (Bool, String?) -> Void = { ok, message in if replyOnce.claim() { reply(ok, message) } }
        // The start's own deadline: a start stuck in the OS (the mic's `startRunning` on a HAL lock,
        // gotcha #68) is abandoned, so the reservation is released and waiting stops are answered.
        let deadline = DispatchWorkItem { [weak self] in self?.startTimedOut(token, answer: answer) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Lifecycle.startTimeoutSeconds, execute: deadline)

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
        // which would otherwise be drained into the next session's provenance. Clear them up front, with
        // the out-of-ring dedup keys, which otherwise grow for the helper's lifetime (council B-M14a).
        diagnostics.resetSession()
        coverage.withLock { $0 = [.mic: TrackAccounting(), .system: TrackAccounting()] }
        lastCoverageCounts.withLock { $0.reset(session: token) }
        lastGateTickNanos.withLock { $0 = 0 }
        gaps.withLock { $0 = GapTracker() }
        let options: CaptureOptions = stateLock.sync {
            let configured = pendingOptions
            pendingOptions = CaptureOptions()
            return configured
        }

        Logger.audio.info("Starting capture — dir: \(outputDirectory, privacy: .private), base: \(baseName, privacy: .private), mic: \(microphoneDeviceId ?? "default", privacy: .private)")

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
            // Lock-only: the watchdog's cached last gate reading, for counting the frames written while the
            // remote was expected (round 2 item 17).
            outputHandler.systemGateOpen = { [weak self] in self?.livenessWatchdog.lastGateOpen ?? true }
            outputHandler.onStreamStopped = { [weak self, weak outputHandler] error in
                self?.handleStreamStopped(error, from: outputHandler)
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

            // The file open above is synchronous and can outlast the start's deadline: install only while
            // this start may still proceed (round 3 C). Otherwise its writers are its own to close.
            let installed = self.stateLock.sync { () -> Bool in
                guard lifecycle.startMayProceed(token) else { return false }
                self.systemPath = sysPath
                self.micPath = micFilePath
                self.handler = outputHandler
                self.restartAttempts = 0
                self.isRestarting = false
                self.systemStreamGivenUp = false
                self.tapSession = nil
                return true
            }
            guard installed else {
                systemWriter.finalize()
                micWriter.finalize()
                abandonUninstalledStart(token, files: [sysPath, micFilePath], answer: answer, deadline: deadline)
                return
            }

            if powerObserver == nil {
                powerObserver = SystemPowerObserver(queue: livenessWatchdog.queue) { [weak self] event in
                    self?.handlePowerEvent(event)
                }
            }

            Task {
                do {
                    // A stop or disconnect that arrived before this Task ran: open nothing (round 2 item 9).
                    guard self.stateLock.sync(execute: { self.lifecycle.startMayProceed(token) }) else { throw CancellationError() }
                    // System audio (SCStream) and the mic (AVCaptureSession) are independent sources
                    // now (#96). Start the MIC FIRST: it is the likelier failure (Microphone TCC), and
                    // starting it before the system stream means a mic-start failure can't delete an
                    // already-recording system WAV (council F2). A mic-start failure fails the start
                    // loudly so the user fixes permissions before the meeting — mid-session mic loss
                    // degrades to system-only instead, which is handled separately.
                    let (micSession, resolvedMic) = try self.startMicSession(
                        handler: outputHandler, microphoneDeviceId: microphoneDeviceId, token: token
                    )
                    // Record capture-start provenance with the mic that ACTUALLY resolved — not the
                    // requested id, which may have silently fallen back to the system default if the
                    // pinned device couldn't be opened (council CONV-1). Recorded after a successful mic
                    // start (not on a failed one, which tears down with no provenance consumer).
                    self.record(.captureStart, .info, [
                        "mic": resolvedMic ?? "default", "system_source": source.rawValue,
                        "tap_auto_start": "\(options.tapAutoStart)",
                    ])
                    switch source {
                    case .screenCaptureKit:
                        try await self.buildAndStartStream(handler: outputHandler, startToken: token)
                    case .coreAudioTap:
                        // Core Audio output tap (#103): captures Continuity/telephony + VoIP that SCK
                        // misses. No SCStream is created, so `stream` stays nil and the #86 SCK
                        // restart path is dormant — the tap self-heals output switches internally.
                        try self.startSystemTap(handler: outputHandler, options: options, token: token)
                    }
                    // Commit-or-abort for the whole start (B-I2): a stop, a disconnect or the deadline
                    // that arrived while the sources came up makes this fail, and the catch tears down.
                    guard self.stateLock.sync(execute: { self.lifecycle.commitStart(token) }) else { throw CancellationError() }
                    deadline.cancel()
                    Logger.audio.info("Capture started — mic AVCaptureSession + system source \(source.rawValue, privacy: .public); awaiting frames")
                    self.startLivenessWatchdog(handler: outputHandler, mic: micSession, tap: self.stateLock.sync { self.tapSession })
                    if source == .coreAudioTap { self.startTapGuardTimer() }
                    answer(true, nil)
                } catch {
                    deadline.cancel()
                    // A stop or disconnect during the start is what aborted it (the commit, or a source's
                    // own commit-or-abort guard, threw): not a capture failure.
                    let (aborted, owns) = self.stateLock.sync {
                        (self.lifecycle.startAborted, self.lifecycle.beginEndingStart(token))
                    }
                    // The deadline already abandoned this start, tore it down and answered: nothing left.
                    guard owns else { return }
                    let waitingStops = self.tearDownStart(token)
                    if aborted {
                        Logger.audio.info("Capture start cancelled — a stop or disconnect arrived while starting")
                        answer(false, CaptureReplies.cancelledWhileStarting)
                    } else {
                        // `.private`: an AVFoundation device error can name the microphone.
                        Logger.audio.error("Capture failed: \(error, privacy: .private)")
                        let desc = "\(error)"
                        if desc.contains("permission") || desc.contains("denied")
                            || desc.contains("notAuthorized") || desc.contains("Microphone access") {
                            answer(false, "Permission denied — grant Screen Recording and Microphone access in System Settings")
                        } else {
                            answer(false, "Capture failed: \(error.localizedDescription)")
                        }
                    }
                    self.answerStopsAwaitingStart(waitingStops)
                }
            }
        } catch {
            deadline.cancel()
            // The error names the WAV, whose name is the meeting's: `.private` in the log, and never in the
            // reply, which the app logs and may show (round 2 item 7).
            Logger.audio.error("Failed to open output files: \(error, privacy: .private)")
            let waitingStops = stateLock.sync { () -> [StopReply] in
                _ = lifecycle.beginEndingStart(token)
                return lifecycle.startEnded(token)
            }
            let ns = error as NSError
            answer(false, "Failed to open output files (\(ns.domain) \(ns.code))")
            answerStopsAwaitingStart(waitingStops)
        }
    }

    /// A start stopped (or timed out) before it installed anything: delete its own files — unless a newer
    /// start exists, which may be writing the same paths — and, if no one else ended it, end it here.
    private func abandonUninstalledStart(_ token: Int, files: [String], answer: (Bool, String?) -> Void,
                                         deadline: DispatchWorkItem) {
        let (owns, aborted) = stateLock.sync { (lifecycle.beginEndingStart(token), lifecycle.startAborted) }
        guard owns else {
            // The deadline ended it (and answered), so a retried start may be creating these very paths
            // (same base name): re-check just before each delete, and delete only while no newer start
            // exists. A narrow window remains; leaving a header-only stub is the safe side of it (M2).
            for path in files where stateLock.sync(execute: { lifecycle.isCurrentStart(token) }) {
                try? FileManager.default.removeItem(atPath: path)
            }
            return
        }
        // This start owns its ending: it stays the current start until `tearDownStart` ends it, so no newer
        // start can be writing these paths while they are deleted (round 4 M2).
        for path in files { try? FileManager.default.removeItem(atPath: path) }
        deadline.cancel()
        let waitingStops = tearDownStart(token)
        answer(false, aborted ? CaptureReplies.cancelledWhileStarting : CaptureReplies.startCancelled)
        answerStopsAwaitingStart(waitingStops)
    }

    /// The start's deadline fired (round 2 item 1). If the start is still coming up — stuck in the OS —
    /// abandon it: tear down what it built (its stuck source is abandoned, as a stop does), free the
    /// session, reply, and answer the stops that waited on it. The start itself, if it ever returns,
    /// finds it may not proceed and backs out.
    private func startTimedOut(_ token: Int, answer: (Bool, String?) -> Void) {
        guard stateLock.sync(execute: { lifecycle.beginEndingStart(token) }) else { return }
        let limit = Int(Lifecycle.startTimeoutSeconds)
        Logger.audio.error("Capture start did not finish within \(limit, privacy: .public)s — abandoning it and freeing the session")
        let waitingStops = tearDownStart(token)
        answer(false, CaptureReplies.startTimedOut)
        answerStopsAwaitingStart(waitingStops)
    }

    /// The stops that arrived during a start that has now ended (aborted, failed or timed out): nothing
    /// was recorded, and the session is free again.
    private func answerStopsAwaitingStart(_ replies: [StopReply]) {
        for reply in replies { reply(nil, nil, CaptureReplies.startCancelled) }
    }

    func stopCapture(
        reply: @escaping StopReply
    ) {
        // Claim the stop and snapshot the sources in ONE critical section. Ordering matters: an
        // in-flight in-place restart commits its new stream into `self.stream` and bails only if it
        // sees the stop at commit time — so we mark stopping before we read the stream, guaranteeing we
        // stop whatever stream is (or is about to be) live (council F1). A stop during a START aborts
        // it (B-I2): the lifecycle keeps this reply, and the start's teardown answers it.
        let (decision, captureStream, micSess, tapSess, h, session) = stateLock.sync {
            () -> (Lifecycle.StopDecision, SCStream?, MicCaptureSession?, SystemTapSession?, AudioOutputHandler?, Int) in
            (lifecycle.requestStop(reply), stream, micSession, tapSession, handler, lifecycle.session)
        }
        switch decision {
        case .notCapturing:
            reply(nil, nil, CaptureReplies.noCaptureInProgress)
            return
        case .alreadyStopping:
            reply(nil, nil, CaptureReplies.refusedStopping)
            return
        case .abortStart:
            Logger.audio.info("Stop during start — the start aborts, then answers this stop")
            return
        case .notOwner:   // only a disconnect asks by owner
            return
        case .stop:
            break
        }

        Logger.audio.info("Stopping capture")
        quiesceSession()
        // Seal FIRST (bounded, reading the coverage in the same audio-queue block), stop the sources
        // bounded, END the session whatever they did (`StopSequence`). No unbounded wait anywhere (N2).
        var paths: (String?, String?) = (nil, nil)
        // `.captureStop` is recorded BEFORE the session ends, while it is still the current one (round 5 item 4).
        runStopSequence(handler: h, mic: micSess, tap: tapSess) { counts in
            self.recordCaptureStop(counts, session: session, mic: micSess, tap: tapSess)
            paths = self.endStoppedSession()
        }
        // The files are sealed and the session is over: reply NOW. An SCStream's stop is async and
        // unbounded, so it runs after the reply, in the background (round 2 item 5).
        reply(paths.0, paths.1, nil)
        if let captureStream { stopStreamInBackground(captureStream) }
    }

    /// Nothing judges, heals or ticks once a session is ending.
    private func quiesceSession() {
        livenessWatchdog.stop()
        tapHealer.endSession()
        stopTapGuardTimer()
    }

    /// Seal the WAVs, then stop the mic and the tap concurrently under ONE bound, then `end` — whatever
    /// the sources did (B-I1, A-I6, round 2 item 4). A source whose teardown blocks is abandoned: it was
    /// told to stop, so it drops any late completion itself (its `isStopping`), and the WAVs are already
    /// sealed. Blocks up to `sourceStopTimeoutSeconds`: never call it on the audio queue or under `stateLock`.
    /// `end` gets the coverage counts the seal read on the audio queue — nil when there was no handler or
    /// the seal timed out. No handler, no seal: nothing waits on the audio queue (round 4 M4).
    private func runStopSequence(handler h: AudioOutputHandler?, mic: MicCaptureSession?, tap: SystemTapSession?,
                                 end: (CoverageCounts?) -> Void) {
        let limit = Lifecycle.sourceStopTimeoutSeconds
        let tapActive = tap != nil
        let (outcome, _) = StopSequence.run(
            sealing: { [weak self] () -> CoverageCounts? in
                guard let self, let h else { return nil }
                return self.audioQueue.sync {
                    let counts = self.coverageCountsOnAudioQueue(h, tapActive: tapActive)
                    h.finalizeAll()
                    return counts
                }
            },
            stopMic: mic.map { mic in { mic.stop() } },
            stopTap: tap.map { tap in { tap.stop() } },
            timeout: limit, end: { end($0 ?? nil) })
        if outcome.sealAbandoned {
            // The audio queue is wedged (a disk stall): the session ended anyway. Its writers are never
            // reused, and whatever reaches them before the late seal runs is dropped (round 3 E).
            h?.abandon()
            Logger.audio.error("Sealing the recording did not finish within \(Int(limit), privacy: .public)s (the audio queue is stalled) — the session ended; the files are sealed when the queue frees")
            record(.writeFailure, .anomaly, ["track": "both", "reason": "seal timed out — audio queue stalled"])
        }
        if outcome.micAbandoned {
            Logger.audio.error("Microphone stop did not return within \(Int(limit), privacy: .public)s — abandoned; the recording is already sealed")
            record(.streamStopError, .anomaly, ["source": "mic", "reason": "stop timed out — abandoned"])
        }
        if outcome.tapAbandoned {
            Logger.audio.error("System tap stop did not return within \(Int(limit), privacy: .public)s (a rebuild is stuck) — abandoned; the recording is already sealed")
            record(.streamStopError, .anomaly, ["source": "system-tap", "reason": "stop timed out — abandoned"])
        }
    }

    /// `.captureStop` with the seal's counts, or — when the seal timed out on a stalled audio queue — the
    /// last cached ones, marked `coverage_incomplete` (round 4 N2).
    private func recordCaptureStop(_ counts: CoverageCounts?, session: Int, mic: MicCaptureSession?, tap: SystemTapSession?) {
        let fallback = counts == nil ? lastCoverageCounts.withLock { $0.value(for: session) } : nil
        record(.captureStop, .info, coverageFacts(counts ?? fallback, mic: mic, tap: tap, incomplete: counts == nil))
    }

    /// Stop an SCStream after the session has ended and replied (round 2 item 5): its files are sealed,
    /// so nothing waits on it. A stop still pending after the bound is logged, and left to finish.
    private func stopStreamInBackground(_ captureStream: SCStream) {
        let finished = OSAllocatedUnfairLock(initialState: false)
        Task {
            try? await captureStream.stopCapture()   // may already be stopped — the files are sealed either way
            finished.withLock { $0 = true }
        }
        let limit = Lifecycle.sourceStopTimeoutSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            guard !finished.withLock({ $0 }) else { return }
            Logger.audio.error("SCStream stop did not return within \(Int(limit), privacy: .public)s — abandoned; the recording was already sealed")
        }
    }

    /// A stop's last step, whatever its sources did: the session is free again, so the next Record is
    /// never refused because of a stuck source (B-I1). Returns the final chunk's paths.
    private func endStoppedSession() -> (String?, String?) {
        stateLock.sync {
            let result = (systemPath, micPath)
            lifecycle.stopEnded()
            stream = nil
            handler = nil
            micSession = nil
            tapSession = nil
            systemPath = nil
            micPath = nil
            alarms = CaptureAlarmRegistry()
            registryResets += 1
            return result
        }
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        reply(stateLock.sync { lifecycle.isCapturing }, nil)
    }

    /// The app's pull (§6.2): the helper's alarm registry and per-track health, one snapshot — plus,
    /// while capturing, this helper session's cumulative coverage, which the app keeps so a crash of this
    /// helper cannot erase it (L11, council A-I4). The counts are the tick's cached ones for THIS session
    /// (at most a tick old): the pull never waits on the audio queue, so a stalled queue cannot hold this
    /// XPC thread (L11 review 64). No cached counts yet for this session: the snapshot carries no coverage,
    /// never a bogus "nothing delivered".
    func captureStatus(reply: @escaping (Data?) -> Void) {
        // The helper session in the SAME `stateLock` section as the capture session (L review 154): a registry reset
        // between the two reads can never stamp this session's counts with another helper session.
        let (capturing, session, mic, tap, helper) = stateLock.sync {
            (isCapturing, lifecycle.session, micSession, tapSession,
             HelperSessionId(processStartMillis: processStartMillis, registryResets: registryResets).description)
        }
        let counts = capturing ? lastCoverageCounts.withLock { $0.value(for: session) } : nil
        let facts = counts.map { coverageFacts($0, mic: mic, tap: tap, helperSession: helper) }
        reply(snapshot(tracks: trackHealth(), coverage: facts).encoded())
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
        // A live session only: a wake during a stop must not re-arm monitors or heal a stopping mic (B-M5).
        guard stateLock.sync(execute: { lifecycle.isLive }) else { return }
        switch kind {
        case "sleep":
            enterSleep(from: .app)
        case "wake":
            livenessWatchdog.wake()   // idempotent: a no-op if IOKit's full wake or the expiry got there first
        default:
            Logger.audio.warning("Unknown power event \(kind, privacy: .public)")
        }
    }

    /// Sleep, from the app or from IOKit's will-sleep (idempotent): nothing is judged, healed or deadlined
    /// until the pause ends. A pending mic reopen's deadline goes with it (round 2 item 11).
    /// Only IOKit's will-sleep starts a new cycle; the app's "sleep" starts one only if none is running
    /// (round 5 item 2).
    private func enterSleep(from source: SleepPauseClock.SleepSource) {
        Logger.audio.info("System sleep (\(source == .system ? "IOKit" : "app", privacy: .public)): liveness paused")
        livenessWatchdog.pause(expiryStartsNow: !(powerObserver?.isRegistered ?? false), from: source)
        tapHealer.cancelAll()   // paired with trigger(.wake) in resumeAfterSleep (C4)
        livenessWatchdog.queue.async { [weak self] in self?.micHealPolicy.slept() }
    }

    /// The pause ended, once, by its first exit — the app's wake, IOKit's full wake, a promotion, or the
    /// expiry (the driver has re-armed both monitors), on the watchdog queue: the healer resumes, running
    /// a coreaudiod restart or a grant that arrived while asleep (B-M1); the mic's deferred restart runs
    /// (item 11); the mic reopens under a FRESH deadline.
    private func resumeAfterSleep(_ micWork: Set<SleepPauseClock.MicWork>, reason: String) {
        guard stateLock.sync(execute: { lifecycle.isLive }) else { return }
        Logger.audio.info("Resuming after sleep (\(reason, privacy: .public)): re-arming both tracks, healing the tap and the mic")
        tapHealer.trigger(.wake)   // forgets the episode; never rebuilds blind — the re-armed monitor decides
        if micWork.contains(.serviceRestart) { stateLock.sync { micSession }?.reregisterDeviceMonitoring() }
        healMic(restartingDeadline: true)
    }

    /// IOKit power messages, on the watchdog queue (round 2 item 18). Live sessions only.
    private func handlePowerEvent(_ event: SystemPowerObserver.Event) {
        guard stateLock.sync(execute: { lifecycle.isLive }) else { return }
        switch event {
        case .willSleep: enterSleep(from: .system)
        case .poweredOn(let fullWake): livenessWatchdog.poweredOn(fullWake: fullWake)
        }
    }

    func updateMicrophone(
        deviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    ) {
        let (live, micSess) = stateLock.sync { (lifecycle.isLive, micSession) }
        guard live, let micSess else {
            reply(false, CaptureReplies.noCaptureInProgress)
            return
        }

        Logger.audio.info("Switching mic to: \(deviceId ?? "system default", privacy: .private)")

        // Retarget the decoupled mic AVCaptureSession (#96). startRunning can block briefly, so do it
        // off the XPC reply thread.
        Task {
            do {
                try micSess.updateDevice(deviceId)
                // Record provenance with the RESOLVED device, on success only — symmetric with
                // .captureStart (council CONV-1): a switch that fell back to default or failed must not
                // claim the requested device in mic_device.
                self.record(.micSwitch, .info, ["mic": micSess.resolvedDeviceId ?? "default"])
                self.clearAlarm(.micFollowFailed)
                Logger.audio.info("Mic switched successfully to: \(deviceId ?? "system default", privacy: .private)")
                reply(true, nil)
            } catch {
                Logger.audio.error("Mic switch failed: \(error, privacy: .private)")
                reply(false, "Mic switch failed: \(error.localizedDescription)")
            }
        }
    }

    func rotateChunk(
        outputDirectory: String,
        newBaseName: String,
        reply: @escaping (String?, String?, String?) -> Void
    ) {
        // A rotation during a start or a stop is REFUSED, not dead (B-I3): the app treats
        // "No capture in progress" as a dead capture (§8.7), and a Stop racing the rotation timer is not one.
        let (gate, currentHandler, session) = stateLock.sync { (lifecycle.rotationGate, handler, lifecycle.session) }
        switch gate {
        case .refusedStopping:
            reply(nil, nil, CaptureReplies.refusedStopping)
            return
        case .notCapturing:
            reply(nil, nil, CaptureReplies.noCaptureInProgress)
            return
        case .allowed:
            break
        }
        guard let currentHandler else {
            reply(nil, nil, CaptureReplies.noCaptureInProgress)
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

            // Swap on the persistent audio queue for zero-gap guarantee. The gate is checked AGAIN in
            // the same audio-queue block, and the paths move there too (B-I3): a stop claims itself under
            // `stateLock` before it enqueues its finalize on this queue, so either this swap lands first
            // (and the stop seals and returns the NEW chunk) or it sees the stop and backs out — never new
            // writers installed after the seal, never the stop returning a chunk this rotate returns too.
            // Checked against this rotate's own SESSION and handler, not only the phase: a stop and a new
            // start in between leave the phase `capturing` again (round 2 item 10).
            var oldPaths: (systemPath: String, micPath: String)?
            var counts: CoverageCounts?
            let (mic, tap) = stateLock.sync { (micSession, tapSession) }
            // Bounded (round 5 item 1): a swap stuck behind a stalled audio queue must not hold this XPC
            // connection — and a Stop queued behind it — past 3 s. Abandoned means it never applies late.
            let swap = AbandonableStep.run(timeout: AbandonableStep.rotationTimeoutSeconds, on: audioQueue) { () -> Bool in
                guard self.stateLock.sync(execute: {
                    self.lifecycle.allowsRotation(of: session) && self.handler === currentHandler
                }) else { return false }
                oldPaths = currentHandler.swapWriters(
                    newSystemWriter: newSystemWriter,
                    newMicWriter: newMicWriter
                )
                // Coverage read in the same block: no second `audioQueue.sync` (round 4 N2).
                counts = self.coverageCountsOnAudioQueue(currentHandler, tapActive: tap != nil)
                self.stateLock.sync {
                    self.systemPath = newSysPath
                    self.micPath = newMicPath
                }
                return true
            }
            switch swap {
            case .done:
                break
            case .abandoned:
                // Never ran, never will: the current chunk keeps recording; its would-be successor goes.
                Logger.audio.error("Chunk rotation timed out on a stalled audio queue — abandoned; the current chunk keeps recording")
                newSystemWriter.finalize()
                newMicWriter.finalize()
                try? FileManager.default.removeItem(atPath: newSysPath)
                try? FileManager.default.removeItem(atPath: newMicPath)
                reply(nil, nil, CaptureReplies.rotationTimedOut)
                return
            case .overran:
                // The swap started but has not finished (a disk stall inside it): it may still complete, and
                // then Stop returns the new chunk's paths — the old chunk is sealed on disk, not handed over.
                Logger.audio.error("Chunk rotation started but did not finish in time — it may complete late; the old chunk stays on disk")
                reply(nil, nil, CaptureReplies.rotationTimedOut)
                return
            }
            guard let oldPaths else {
                // A stop began after the gate above: nobody will write these, so leave no stub behind.
                newSystemWriter.finalize()
                newMicWriter.finalize()
                try? FileManager.default.removeItem(atPath: newSysPath)
                try? FileManager.default.removeItem(atPath: newMicPath)
                reply(nil, nil, CaptureReplies.refusedStopping)
                return
            }
            Logger.audio.info("Chunk rotated — old: \(oldPaths.systemPath, privacy: .private)")
            // Coverage survives in the record even if the ring evicts older events (§7.1). On this XPC
            // thread, outside the `audioQueue.sync` above.
            record(.trackCoverage, .info, ["chunk": newBaseName].merging(coverageFacts(counts, mic: mic, tap: tap)) { a, _ in a })
            reply(oldPaths.systemPath, oldPaths.micPath, nil)
        } catch {
            // The error names the new WAV, whose name is the meeting's: `.private` here, and never in the
            // reply, which the app logs and may show (council C-M1).
            Logger.audio.error("Chunk rotation failed: \(error, privacy: .private)")
            let ns = error as NSError
            reply(nil, nil, "Rotation failed: the next chunk's files could not be created (\(ns.domain) \(ns.code))")
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
        guard stateLock.sync(execute: { tapSession != nil && lifecycle.isLive }) else {
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
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.tapGuardTimer?.cancel()
            self.tapGuardTimer = nil
            // A stop queued its cancel before this ran: don't arm a timer that outlives the session.
            guard self.stateLock.sync(execute: { self.lifecycle.isLive && self.tapSession != nil })
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
    /// grant is decided when the aggregate starts, so this is when to ask. `epoch` is the tap session's
    /// guard epoch: a late build from a previous session can't land in the next session's guard (B-M8).
    private func tapDidBuild(epoch: Int) {
        // Off the caller's queue: a slow TCC read must not hold up the next rebuild.
        tccQueue.async { [weak self] in
            let status = SystemAudioRecordingPermission.preflight()
            guard let self else { return }
            self.audioQueue.async {
                guard epoch == self.tapGuardEpoch else { return }
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

    /// `connection` was invalidated. Stops only the capture (or start) it owns (round 5 item 5): the app
    /// drops a connection on a stop timeout and may already be recording through a new one.
    func stopAndFinalize(disconnectOf connection: ObjectIdentifier) {
        // Claim the stop before snapshotting the stream so an in-flight restart bails / is torn down
        // (council F1), mirroring stopCapture. A disconnect during a start aborts it (B-I2): the start
        // tears down what it built, so no capture is left running without a client. Nobody waits for an
        // answer, so the lifecycle's pending reply is a no-op.
        let (decision, captureStream, micSess, tapSess, h, session) = stateLock.sync {
            () -> (Lifecycle.StopDecision, SCStream?, MicCaptureSession?, SystemTapSession?, AudioOutputHandler?, Int) in
            (lifecycle.requestStop({ _, _, _ in }, disconnectOf: connection), stream, micSession, tapSession, handler, lifecycle.session)
        }
        switch decision {
        case .abortStart:
            Logger.audio.info("Client disconnected during start — the start aborts and tears down")
            return
        case .notOwner:
            Logger.audio.info("A connection that does not own the current capture was invalidated — capture left running")
            return
        case .notCapturing, .alreadyStopping:
            return
        case .stop:
            break
        }
        Logger.audio.info("Stopping capture due to client disconnect")
        quiesceSession()
        // Seal synchronously, so the headers are written before the XPC service exits (I5 fix); stop the
        // sources bounded; end the session; then the SCStream, in the background (round 2 item 5). Same
        // coverage as a clean stop, so a recording the app crashed out of still reports how much of each
        // side was captured (and, on the tap, how much of it was exact zeros, #220).
        runStopSequence(handler: h, mic: micSess, tap: tapSess) { counts in
            self.recordCaptureStop(counts, session: session, mic: micSess, tap: tapSess)
            _ = self.endStoppedSession()
        }
        if let captureStream { stopStreamInBackground(captureStream) }
        Logger.audio.info("Capture finalized after client disconnect")
    }

    /// Start `token` failed, was aborted, or hit its deadline, and the caller won `beginEndingStart`: tear
    /// down everything it built — mic and tap (registered or still opening, abandoned if stuck), stream,
    /// files — then free the session. Returns the stops that arrived during the start, to be answered after
    /// the start's own reply: only now is the session free for the app's next Record.
    private func tearDownStart(_ token: Int) -> [StopReply] {
        quiesceSession()
        // Snapshot and clear state under the lock, then run the blocking teardown (mic stopRunning,
        // writer finalize, file deletes) OUTSIDE the lock so we never hold stateLock across a blocking
        // call. The lifecycle stays `starting` (ending) meanwhile, so no other start can begin.
        let (h, captureStream, micSess, tapSess, sys, mic) = stateLock.sync {
            () -> (AudioOutputHandler?, SCStream?, MicCaptureSession?, SystemTapSession?, String?, String?) in
            let snapshot = (handler, stream, micSession ?? startingMic, tapSession ?? startingTap, systemPath, micPath)
            stream = nil
            handler = nil
            micSession = nil
            tapSession = nil
            startingMic = nil
            startingTap = nil
            systemPath = nil
            micPath = nil
            alarms = CaptureAlarmRegistry()
            registryResets += 1
            return snapshot
        }
        runStopSequence(handler: h, mic: micSess, tap: tapSess) { _ in }
        // A stream the start had already committed and started (the abort came after it).
        if let captureStream { stopStreamInBackground(captureStream) }
        if let sys { try? FileManager.default.removeItem(atPath: sys) }
        if let mic { try? FileManager.default.removeItem(atPath: mic) }
        return stateLock.sync { lifecycle.startEnded(token) }
    }

    /// Build and start the decoupled mic capture session (#96), wiring its diagnostics + recovery
    /// callbacks into the service. Throws — failing the whole start — if the mic can't be brought up,
    /// since the user expects their own voice recorded. Mid-session mic loss is handled separately by
    /// MicCaptureSession and is NOT fatal (system audio keeps recording).
    /// Returns the session and the device the mic ACTUALLY resolved to (`nil` = system default), so the
    /// caller can record honest `.captureStart` provenance even when the requested device fell back
    /// (council CONV-1), and wire the session's heartbeat into the liveness watchdog.
    private func startMicSession(handler: AudioOutputHandler, microphoneDeviceId: String?, token: Int) throws -> (session: MicCaptureSession, deviceId: String?) {
        let mic = MicCaptureSession(deliveryQueue: audioQueue) { [weak handler] buffer in
            handler?.appendMicSampleBuffer(buffer)
        }
        mic.onEvent = { [weak self] kind, severity, detail in
            self?.record(kind, severity, detail)
        }
        // Before `start`: a rebuild between the start and the watchdog's wiring must still re-arm.
        mic.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: .mic) }
        mic.onRecovered = { [weak self] deviceId in
            // Mic self-healed a route change — system audio never stopped.
            // No "Recording Resumed" banner (routine switch); just update the label via onMicDeviceChanged.
            self?.onMicDeviceChanged?(deviceId)
            self?.clearAlarm(.micFollowFailed)   // a later successful follow (round 2 item 12)
        }
        mic.onUnavailable = { [weak self, weak mic] info in
            // Judged on the watchdog queue, with the mic's heartbeat at that moment (A-I5).
            self?.livenessWatchdog.queue.async {
                guard let self else { return }
                // Paused for sleep: the devices may be off. The wake's reopen re-evaluates it — with the
                // budget spent, that reopen reports back at once, awake (round 2 item 11).
                if self.livenessWatchdog.isPausedForSleep {
                    Logger.audio.info("Microphone recovery gave up while paused for sleep — re-evaluated at the wake")
                    return
                }
                let stamp = mic?.lastHeartbeatNanos() ?? 0
                let now = DispatchTime.now().uptimeNanoseconds
                let age: Double? = stamp == 0 ? nil : Double(now > stamp ? now - stamp : 0) / 1e9
                switch self.micHealPolicy.healFailed(heartbeatAgeSeconds: age, currentDevicePresent: info.currentDevicePresent) {
                case .followFailed:
                    // The switch failed before the session swap and the current mic is still recording: an
                    // acknowledgeable alarm, never `micNotDelivering`, which nothing would clear (round 2
                    // item 12). Device names only in the log, `.private`.
                    let target = info.attemptedName ?? "the new microphone"
                    let current = info.currentName ?? "the current microphone"
                    Logger.audio.warning("Mic switch failed (\(info.reason, privacy: .public)) — still recording from \(current, privacy: .private); could not switch to \(target, privacy: .private)")
                    self.record(.streamStopError, .anomaly, ["source": "mic", "reason": "switch failed — still recording from the current microphone"])
                    self.raiseAlarm(.micFollowFailed, "Couldn’t switch to the new microphone — still recording from the previous one.")
                default:
                    // Mic loss is NOT fatal: system audio keeps recording and the partial mic WAV stays
                    // valid. Record the anomaly so the session is flagged and diagnostics flush.
                    Logger.audio.error("Microphone unavailable mid-session: \(info.reason, privacy: .public)")
                    self.record(.restartFailed, .anomaly, ["source": "mic", "reason": info.reason])
                    // The heal gave up, so no second verdict will come: alarm now (scan C11).
                    self.raiseAlarm(.micNotDelivering, "The microphone stopped delivering audio and could not be reopened. Try another microphone from the menu.")
                }
            }
        }
        // Known to the start's deadline BEFORE it opens: a `startRunning` that never returns is still
        // stopped (abandoned) when the deadline fires (round 2 item 1).
        guard stateLock.sync(execute: { () -> Bool in
            guard lifecycle.startMayProceed(token) else { return false }
            startingMic = mic
            return true
        }) else { throw CancellationError() }
        try mic.start(deviceId: microphoneDeviceId)
        // Commit-or-abort against a stop, a disconnect or the deadline that raced in during start
        // (mirrors buildAndStartStream's council-F1 guard): tear the mic down rather than leak a running
        // session past them.
        let proceed = stateLock.sync { () -> Bool in
            guard lifecycle.startMayProceed(token) else { return false }
            startingMic = nil
            self.micSession = mic
            return true
        }
        if !proceed {
            runStopSequence(handler: nil, mic: mic, tap: nil) { _ in }
            throw CancellationError()   // the start aborts; its teardown owns the rest (B-I2)
        }
        return (mic, mic.resolvedDeviceId)
    }

    /// Start the Core Audio output-tap system source (#103), wiring its diagnostics + rebuild-result
    /// callbacks into the service. Throws — failing the whole start — if the tap can't be created (most
    /// likely a missing System Audio Recording TCC grant), so the user fixes permissions before the
    /// meeting, symmetric with the SCK path's start failure. Mid-session tap loss (a rebuild failing)
    /// is NOT fatal: the mic keeps recording and the system track is silence-padded — surfaced as the
    /// `remoteRecoveryFailed` alarm, never a teardown.
    /// `options` is the start's own copy (`startCapture` consumes `pendingOptions`, F4 round 1).
    private func startSystemTap(handler: AudioOutputHandler, options: CaptureOptions, token: Int) throws {
        // Only while this start may proceed (round 3 C): a start whose deadline fired must not reset the
        // guard of the session that followed. Checked inside the audio-queue block, so a newer session's
        // own reset (also on this queue, after its claim) always lands after this one.
        let epoch = audioQueue.sync { () -> Int? in
            guard stateLock.sync(execute: { lifecycle.startMayProceed(token) }) else { return nil }
            tapGuard = TapPermissionGuard(softAlarmSeconds: options.remoteExactZeroSoftAlarmSeconds.map(Double.init))
            tapGuardEpoch += 1
            return tapGuardEpoch
        }
        guard let epoch else { throw CancellationError() }
        let tap = SystemTapSession(
            deliveryQueue: audioQueue, tapAutoStart: options.tapAutoStart,
            dropFramesForDiagnostics: options.debugDropTapFrames
        ) { [weak self, weak handler] samples, pts in
            handler?.appendSystemSamples(samples, pts: pts)
            // Already on audioQueue.
            guard let self else { return }
            self.apply(self.tapGuard.samples(samples, rate: 48_000, now: self.guardNow()))
        }
        tap.onBuilt = { [weak self] in self?.tapDidBuild(epoch: epoch) }
        tap.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: .system) }
        tap.onEvent = { [weak self] kind, severity, detail in
            self?.record(kind, severity, detail)
        }
        try wireTapHealer(to: tap, token: token)
        // srst: the ladder forgets the episode and runs one immediate `rebuildTap` rung, whose rebuild
        // re-registers the system listeners; the mic's AVCaptureSession is reopened too. The output
        // probe needs nothing — it reads the process list afresh every tick.
        tap.onServiceRestarted = { [weak self] in
            guard let self else { return }
            self.tapHealer.trigger(.serviceRestarted)   // kept for the wake if it lands while asleep (B-M1)
            // The mic's HAL listeners died with coreaudiod too: without them auto-follow and re-pin stay
            // dead for the rest of the session (B-M2). Not while paused for sleep: the reopen's deadline
            // would run across the sleep and fire falsely at the wake — the wake runs it (round 2 item 11).
            self.livenessWatchdog.deferMicWork(.serviceRestart) { [weak self] in
                guard let self else { return }
                self.stateLock.sync { self.micSession }?.reregisterDeviceMonitoring()
                self.healMic()
            }
        }
        guard stateLock.sync(execute: { () -> Bool in
            guard lifecycle.startMayProceed(token) else { return false }
            startingTap = tap
            return true
        }) else { throw CancellationError() }
        try tap.start()
        // Commit-or-abort against a stop, a disconnect or the deadline that raced in during start (mirrors
        // startMicSession's council-F1 guard): tear the tap down rather than leak a running capture.
        let proceed = stateLock.sync { () -> Bool in
            guard lifecycle.startMayProceed(token) else { return false }
            startingTap = nil
            self.tapSession = tap
            return true
        }
        if !proceed {
            runStopSequence(handler: nil, mic: nil, tap: tap) { _ in }
            throw CancellationError()   // the start aborts; its teardown owns the rest (B-I2)
        }
    }

    /// The tap's rebuild results and aggregate events feed the healer; the healer's verdicts feed the
    /// alarms (§5, §6.1): on give-up `remoteNotDelivering` (plus `remoteRecoveryFailed` when a rebuild
    /// threw), `remoteRecoveryFailed` when a rung got stuck, both cleared by recovery / the next
    /// successful rung (scan C8).
    private func wireTapHealer(to tap: SystemTapSession, token: Int) throws {
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
        // Heal first, then alarm (review round 1): an intermediate failed rung with another one queued
        // raises nothing; the ladder's give-up does.
        tapHealer.onGiveUp = { [weak self] rebuildFailed in
            guard let self else { return }
            let newlyGivenUp = self.raiseAlarm(.remoteNotDelivering, "The other side of the call isn’t reaching Parley although audio is playing. Parley keeps retrying; if this persists, check the output device in the call app.")
            if newlyGivenUp {
                // Once per give-up episode: sets `system_audio_unrecovered` in provenance for tap sessions.
                self.record(.systemAudioUnrecovered, .anomaly, ["source": "system-tap", "reason": "healing ladder gave up"])
            }
            if rebuildFailed {
                self.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.")
            }
        }
        tapHealer.onRecovered = { [weak self] in self?.clearDeliveryAlarm(.remoteNotDelivering) }
        tapHealer.onStuck = { [weak self] in
            self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.")
        }
        tapHealer.onRungSucceeded = { [weak self] in self?.clearAlarm(.remoteRecoveryFailed) }
        // A rung's heartbeat deadline that passes while nothing plays cannot judge the tap: it must not
        // climb to a false "although audio is playing" (final review H-I1). Lock-only: safe on the healer's queue.
        tapHealer.gateOpen = { [weak self] in self?.livenessWatchdog.lastGateOpen ?? true }
        // Last: reset the healer and target this tap in one step on the healer's queue (review round 1) —
        // enqueued under `stateLock` with the token check, so a start whose deadline fired can never
        // retarget the healer of the session that followed: that one's claim comes after (round 3 C).
        let targeted = stateLock.sync { () -> Bool in
            guard lifecycle.startMayProceed(token) else { return false }
            tapHealer.startSession(tap: tap)   // an async hop onto the healer's queue: no call-out under the lock
            return true
        }
        guard targeted else { throw CancellationError() }
    }

    /// Build a fresh system-audio SCStream around the given handler and start it. Used both for the
    /// initial start and for #86 in-place restarts: because the SAME handler (and therefore the same
    /// WavFileWriters / output files) is reused, a restart resumes the existing recording with no file
    /// rotation and no lost audio. The mic is captured separately (AVCaptureSession, #96) and is no
    /// longer part of this stream — so a mic route change never stops it.
    /// `startToken`: the start this builds for (nil = an in-place restart of a running capture).
    private func buildAndStartStream(handler: AudioOutputHandler, startToken: Int? = nil) async throws {
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
            if let startToken { guard lifecycle.startMayProceed(startToken) else { return false } }
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
    private func handleStreamStopped(_ error: Error, from source: AudioOutputHandler?) {
        let (capturing, userStopping, attempts, givenUp, current) = stateLock.sync {
            (isCapturing, isUserStopping, restartAttempts, systemStreamGivenUp, handler)
        }
        // A stream stopped in the background after its session ended (round 2 item 5) reports into
        // whatever session is running now: never let it drive that session's restart.
        guard let source, source === current else { return }
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
            // Budget exhausted. A system-stream death must NOT stop the session (the mic runs on a
            // separate AVCaptureSession and is recording fine). If a restart loop is active,
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
                // Budget exhausted MID-RECORDING. Do NOT stop the session — that tears down the mic,
                // but the mic runs on a separate AVCaptureSession and is still recording fine.
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
                // That zeroed SCK's heartbeat source: re-arm, or the monitor (first frames already
                // reported, no episode open) reads it as never-delivered since the gate opened. This is
                // SCK's generation bump: the rebuilt stream gets a fresh 5 s never-delivered clock.
                livenessWatchdog.arm(track: .system)
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

    /// Budget exhausted for the MID-RECORDING system-stream restart (#86). This does NOT stop the mic,
    /// finalize, or tear down the session: the mic runs on a separate AVCaptureSession and is still
    /// recording (a real call captured 47 good mic minutes while the system stream was dead). Record the anomaly, warn the app over the reverse channel, and stop
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

/// The healer (TranscriberCore) rebuilds the tap through this; results come back via `onRebuildResult`.
extension SystemTapSession: TapRebuilding {}
