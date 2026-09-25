import Foundation

/// The two WAV files a stopped capture produced (system audio + microphone).
/// Lives in Core (moved from the app target's `AudioCaptureClient.swift`) so
/// `RecordingCoordinator` can consume a stop result without importing the XPC client. `Sendable`:
/// a bounded stop (`withDeadline`) returns it across tasks.
public struct AudioPaths: Sendable {
    public let systemAudio: URL
    public let micAudio: URL

    public init(systemAudio: URL, micAudio: URL) {
        self.systemAudio = systemAudio
        self.micAudio = micAudio
    }
}

/// A helper call that did not answer within its deadline (§8.8). Thrown by the XPC client for its own
/// deadlines and by the coordinator for its outer ones; a Core type, so the coordinator recognizes a
/// timeout and words it for the user.
public struct CaptureCallTimeout: Error, LocalizedError, Equatable, Sendable {
    public let call: String
    public let seconds: Double
    public init(call: String, seconds: Double) { self.call = call; self.seconds = seconds }
    public var errorDescription: String? {
        "the capture helper did not respond within \(max(1, Int(seconds.rounded()))) s"
    }
}

/// What a status ping learned (L9 review 49). A ping the helper did not answer within its deadline is
/// `unknown` — never "not capturing": a helper that is merely slow may still be writing the recording.
public enum HelperCaptureState: Sendable, Equatable {
    case capturing
    case notCapturing
    case unknown
}

/// The capabilities `RecordingCoordinator` needs from the XPC audio-capture client. Defined in
/// Core so the recording-lifecycle + crash-recovery orchestration can live in Core (and be
/// unit-tested with a fake) while the concrete NSXPC client stays in the app target — the same
/// seam pattern as `ChunkRotationClient`, which this protocol refines so the coordinator can
/// hand the client straight to `TranscriptionRunner.setupChunkedPipeline`.
/// `AudioCaptureClient` already has every one of these members with these exact signatures.
@MainActor
public protocol RecordingCaptureClient: ChunkRotationClient {
    /// Fired when the XPC service crashed mid-capture (deduplicated by the client).
    var onServiceCrash: (@Sendable () -> Void)? { get set }
    /// Fired when the helper auto-switched the mic device (label refresh only, no banner).
    var onMicDeviceChanged: (@Sendable (String?) -> Void)? { get set }
    /// Fired when the helper gave up on an in-place restart — escalates like a crash.
    var onFatalFailure: (@Sendable (String) -> Void)? { get set }
    /// Fired for a live, user-facing capture-quality anomaly (exact-zero mic, a liveness gap, a
    /// disk-full write failure) — surfaced WHILE the recording is still running (#193/#196).
    /// `kind` is the `CaptureEventKind` raw value; `message` is human-readable.
    var onQualityAnomaly: (@Sendable (String, String) -> Void)? { get set }
    /// Fired when the helper gave up on the remote (system) stream mid-recording; the mic keeps going.
    var onSystemAudioUnrecoverable: (@Sendable (String) -> Void)? { get set }
    /// Fired on an XPC interruption the helper survived (still capturing) — a benign blip (#86).
    var onBriefInterruption: (@Sendable () -> Void)? { get set }
    /// Fired when the helper restarted a stopped stream in place (#86).
    var onRestartInPlace: (@Sendable () -> Void)? { get set }
    /// Fired on the first heartbeat of a capture generation: (track, helperSessionId of the helper
    /// registry that saw it) — feeds `CaptureAlarmRegistry.noteFirstFrames(track:helperSessionId:)`.
    var onFirstFrames: (@Sendable (CaptureTrack, String) -> Void)? { get set }
    /// Fired when the helper pushes a changed alarm set (§6.2).
    var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)? { get set }
    /// The helper's real-audio evidence (§6.2): the first non-zero sample on a track, as
    /// (track, helperSessionId) — feeds `CaptureAlarmRegistry.noteRealAudio`.
    var onRealAudio: (@Sendable (CaptureTrack, String) -> Void)? { get set }
    /// The helper's write-succeeded evidence (§6.2): a successful write, as (helperSessionId) — feeds
    /// `CaptureAlarmRegistry.noteWriteSucceeded`.
    var onWriteSucceeded: (@Sendable (String) -> Void)? { get set }

    /// `sessionId` is the chunk session id (`SessionState.sessionId`: the chunk base name without its
    /// index, e.g. `143400-weekly-sync`), stable across in-session restarts whose base names change.
    /// L11 resets the diagnostics ring only when it changes.
    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: SystemAudioSource,
        options: CaptureOptions,
        sessionId: String
    ) async throws

    /// The helper's alarm state + per-track health, or `nil` when the helper is unreachable (§6.2).
    func captureStatus() async -> CaptureStatusSnapshot?
    /// Whether the helper reports an active capture session: `.unknown` when it did not answer in time.
    func captureState() async -> HelperCaptureState
    /// A helper call timed out and the helper may still be capturing (L9 review 45): drop the XPC
    /// connection. The helper's invalidation handler stops and finalizes its capture (§8.3); the next call
    /// reconnects.
    func dropConnection()
    /// Record that the app re-attached to or relaunched a recording on launch (crash recovery) (#95).
    func recordLaunchRecovery(_ detail: [String: String])
    /// A relaunch continues session `sessionId` (a re-attach or a resume): its evidence is this session's
    /// from now on, and the helper's events — a `captureStop` it sealed when the crashed app went, say — are
    /// drained into it BEFORE anything could reset them (L follow-up 43).
    func adoptSession(sessionId: String, directory: URL) async
    /// A start that never became a recording (L11 review 68): its evidence is dropped and its live log deleted.
    func discardSessionEvidence(sessionId: String, directory: URL)
    /// Bind the evidence to `sessionId` NOW, synchronously — a relaunch that re-attaches does it before it builds
    /// its pipeline, so nothing recorded meanwhile is reset by the adopt that follows (L review 121).
    func bindSession(sessionId: String, directory: URL)
    /// The session's transcript is on disk: its live log is deleted — never before (L review 97).
    func commitSessionDiagnostics(sessionId: String, directory: URL)
    /// A pending retry stopped a stray helper: drain it once and give its events to the pending session whose
    /// live log knows its helper session, or to none — never to whichever is salvaged first (L review 98).
    func attributeHelperDrain(toOneOf sessions: [(sessionId: String, directory: URL)]) async
    /// Every queued live-log write reaches the disk (L review 96). The caller bounds it.
    func flushEvidence() async
    /// Forward an `NSWorkspace` sleep / wake ("sleep" | "wake") to the helper (§8.10).
    func systemPowerEvent(_ kind: String) async
    /// Record an app-origin event into the diagnostic ring.
    func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String])

    func stop() async throws -> AudioPaths
    /// Switch the live capture to another microphone (`nil` = system default).
    func updateMicrophone(deviceId: String?) async throws

    /// Drain the helper's diagnostics, build the session's record — writing the anomaly-gated
    /// `<sessionId>.diag.jsonl` — and the transcript provenance stamp (#95). The live log stays until
    /// `commitSessionDiagnostics`, once the transcript exists (L review 97).
    func finalizeSessionDiagnostics(
        sessionId: String,
        engine: String,
        recordingDirectory: URL
    ) async -> CaptureProvenance

    /// Record an XPC-retry event (a relaunch/reconnect attempt after a crash) (#95).
    func recordRetry(_ detail: [String: String])

    /// The recording ended WITHOUT `stop()` — crash recovery gave up, or a relaunch salvaged instead
    /// of resuming. Disarms crash detection so the next helper idle-exit is not mistaken for a crash
    /// of a recording that no longer exists (C1).
    func captureEnded()
    /// The app re-attached at launch to a capture it did not `start()` (Flow A): arms crash detection
    /// for it, as `start` does — otherwise a crash of the re-attached recording reads as an idle-exit (C1).
    func captureReattached()
}
