import Foundation
import AudioCaptureProtocol
import TranscriberCore
import os

struct AudioPaths {
    let systemAudio: URL
    let micAudio: URL
}

@MainActor
final class AudioCaptureClient {
    private var connection: NSXPCConnection?
    private var crashHandlerFired = false
    private var reverseChannel: ReverseChannel?

    /// Anomaly-gated diagnostic ring (app side). Merges helper-origin events drained over XPC with
    /// the app's own (interruptions, retries, launch recovery) and is flushed to disk only when the
    /// session was anomalous (#95).
    private(set) var diagnostics = CaptureDiagnostics()

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

    func connect() {
        crashHandlerFired = false
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
                guard let self, !self.crashHandlerFired else { return }
                // An XPC interruption is only a "crash" if a fresh crash report names the helper.
                // A benign route-change blip writes no .ips — classify before tearing down (#86).
                let classification = CrashReportScanner.classifyLive()
                self.record(.xpcInterruption,
                    classification == .likelyCrash ? .anomaly : .warning,
                    ["classification": classification == .likelyCrash ? "crash" : "blip"])
                if classification == .likelyCrash {
                    self.crashHandlerFired = true
                    Logger.audio.warning("XPC interrupted — crash report present, treating as crash")
                    self.onServiceCrash?()
                    return
                }
                // No crash report: verify the helper is still capturing before trusting the blip.
                Logger.audio.warning("XPC interrupted — no crash report; verifying capture is alive")
                let stillCapturing = await self.isCapturing()
                if stillCapturing {
                    self.onBriefInterruption?()
                } else if !self.crashHandlerFired {
                    self.crashHandlerFired = true
                    Logger.audio.warning("XPC interrupted — helper not capturing, escalating to crash recovery")
                    self.onServiceCrash?()
                }
            }
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                Logger.audio.warning("XPC connection invalidated")
                guard let self else { return }
                self.connection = nil
                self.record(.xpcInvalidation, .anomaly)
                if !self.crashHandlerFired {
                    self.crashHandlerFired = true
                    self.onServiceCrash?()
                }
            }
        }
        conn.resume()
        Logger.audio.debug("XPC connection established")
        connection = conn
    }

    private func record(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        _ detail: [String: String] = [:]
    ) {
        diagnostics.record(CaptureEvent(
            timestamp: Date(), origin: .app, kind: kind, severity: severity, detail: detail
        ))
    }

    /// Record an XPC-retry event (a relaunch/reconnect attempt after a crash) (#95).
    func recordRetry(_ detail: [String: String] = [:]) {
        record(.retry, .warning, detail)
    }

    /// Record that the app re-attached to or relaunched a recording on launch (crash recovery) (#95).
    func recordLaunchRecovery(_ detail: [String: String] = [:]) {
        record(.launchRecovery, .warning, detail)
    }

    /// Pull and clear the helper's diagnostic ring over XPC, merging its events into the app ring.
    func drainHelperDiagnostics() async {
        guard let conn = connection else { return }
        let data: Data? = await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                cont.resume(returning: nil)
            } as! AudioCaptureProtocol
            proxy.drainDiagnostics { cont.resume(returning: $0) }
        }
        if let data {
            let events = CaptureDiagnostics.events(from: data)
            if !events.isEmpty { diagnostics.merge(events) }
        }
    }

    /// Drain the helper, build the transcript provenance stamp, and — only when the session was
    /// anomalous — flush the full event ring to `<sessionId>.diag.jsonl` beside the recording (#95).
    /// A clean session writes no log, only the ~200-byte provenance stamp the caller embeds.
    func finalizeSessionDiagnostics(
        sessionId: String,
        engine: String,
        recordingDirectory: URL
    ) async -> CaptureProvenance {
        await drainHelperDiagnostics()

        func formatString(_ kind: CaptureEventKind) -> String? {
            guard let e = diagnostics.events.last(where: { $0.kind == kind }) else { return nil }
            return "\(e.detail["rate"] ?? "?")Hz/\(e.detail["channels"] ?? "?")ch"
        }
        // The mic device is whatever the most recent start / switch event pinned.
        let micDevice = diagnostics.events.last { $0.kind == .micSwitch || $0.kind == .captureStart }?
            .detail["mic"]

        if diagnostics.isAnomalous {
            let url = recordingDirectory.appendingPathComponent("\(sessionId).diag.jsonl")
            do {
                try diagnostics.jsonlData().write(to: url, options: .atomic)
                Logger.files.info("Flushed capture diagnostics: \(url.lastPathComponent, privacy: .public) (\(self.diagnostics.events.count) events)")
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

    func start(outputDirectory: URL, baseName: String, microphoneDeviceId: String? = nil) async throws {
        // crashHandlerFired is reset only in connect() — its sole reset point (#54). Resetting it
        // here would re-arm the dedup latch on a restart that reuses an about-to-be-invalidated
        // connection, letting the trailing invalidation re-fire onServiceCrash (a spurious retry).
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.startFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
            ) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.startFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    func stop() async throws -> AudioPaths {
        let conn = try getConnection()
        return try await withCheckedThrowingContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.stopFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.stopCapture { systemPath, micPath, errorMessage in
                if let sys = systemPath, let mic = micPath {
                    cont.resume(returning: AudioPaths(
                        systemAudio: URL(fileURLWithPath: sys),
                        micAudio: URL(fileURLWithPath: mic)
                    ))
                } else {
                    cont.resume(throwing: CaptureError.stopFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    func rotateChunk(
        outputDirectory: String,
        newBaseName: String
    ) async throws -> (systemPath: String, micPath: String) {
        let conn = try getConnection()
        return try await withCheckedThrowingContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.rotateChunkFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.rotateChunk(outputDirectory: outputDirectory, newBaseName: newBaseName) { oldSystemPath, oldMicPath, errorMessage in
                if let sys = oldSystemPath, let mic = oldMicPath {
                    cont.resume(returning: (systemPath: sys, micPath: mic))
                } else {
                    cont.resume(throwing: CaptureError.rotateChunkFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    func updateMicrophone(deviceId: String?) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.micSwitchFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.updateMicrophone(deviceId: deviceId) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.micSwitchFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
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

    private func pingStatus(_ conn: NSXPCConnection) async -> Bool {
        await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                cont.resume(returning: false)
            } as! AudioCaptureProtocol
            proxy.status { isCapturing, _ in
                cont.resume(returning: isCapturing)
            }
        }
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
}

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
