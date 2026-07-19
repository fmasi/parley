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

    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: SystemAudioSource
    ) async throws

    func stop() async throws -> AudioPaths

    /// Drain the helper's diagnostics, flush the anomaly-gated `<sessionId>.diag.jsonl`, and
    /// build the transcript provenance stamp (#95).
    func finalizeSessionDiagnostics(
        sessionId: String,
        engine: String,
        recordingDirectory: URL
    ) async -> CaptureProvenance

    /// Record an XPC-retry event (a relaunch/reconnect attempt after a crash) (#95).
    func recordRetry(_ detail: [String: String])
}
