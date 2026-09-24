import Foundation

/// The two WAV files a stopped capture produced (system audio + microphone).
/// Lives in Core (moved from the app target's `AudioCaptureClient.swift`) so
/// `RecordingCoordinator` can consume a stop result without importing the XPC client.
public struct AudioPaths {
    public let systemAudio: URL
    public let micAudio: URL

    public init(systemAudio: URL, micAudio: URL) {
        self.systemAudio = systemAudio
        self.micAudio = micAudio
    }
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
    /// Whether the helper reports an active capture session (`false` when unreachable).
    func isCapturing() async -> Bool
    /// Record that the app re-attached to or relaunched a recording on launch (crash recovery) (#95).
    func recordLaunchRecovery(_ detail: [String: String])
    /// Forward an `NSWorkspace` sleep / wake ("sleep" | "wake") to the helper (§8.10).
    func systemPowerEvent(_ kind: String) async
    /// Record an app-origin event into the diagnostic ring.
    func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String])

    func stop() async throws -> AudioPaths
    /// Switch the live capture to another microphone (`nil` = system default).
    func updateMicrophone(deviceId: String?) async throws

    /// Drain the helper's diagnostics, flush the anomaly-gated `<sessionId>.diag.jsonl`, and
    /// build the transcript provenance stamp (#95).
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
