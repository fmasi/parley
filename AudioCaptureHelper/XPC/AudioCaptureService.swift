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
    private let maxRestartAttempts = 3

    /// Reverse-channel callbacks to the app (wired in main.swift from the connection proxy).
    var onRestartInPlace: (() -> Void)?
    var onFailFatally: ((String) -> Void)?

    private func record(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        _ detail: [String: String] = [:]
    ) {
        diagnostics.record(CaptureEvent(
            timestamp: Date(), origin: .helper, kind: kind, severity: severity, detail: detail
        ))
    }

    func startCapture(
        outputDirectory: String,
        baseName: String,
        microphoneDeviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard !stateLock.sync(execute: { isCapturing }) else {
            reply(false, "Capture already in progress")
            return
        }

        Logger.audio.info("Starting capture — dir: \(outputDirectory, privacy: .private), base: \(baseName, privacy: .public), mic: \(microphoneDeviceId ?? "default", privacy: .public)")

        let sysPath = (outputDirectory as NSString).appendingPathComponent(baseName + ".wav")
        let micFilePath = (outputDirectory as NSString).appendingPathComponent(baseName + "_mic.wav")

        do {
            try FileManager.default.createDirectory(
                atPath: outputDirectory, withIntermediateDirectories: true
            )
            let systemWriter = try WavFileWriter(path: sysPath)
            let micWriter = try WavFileWriter(path: micFilePath)
            let outputHandler = AudioOutputHandler(
                systemWriter: systemWriter, micWriter: micWriter
            )
            outputHandler.diagnostics = diagnostics
            outputHandler.onStreamStopped = { [weak self] error in
                self?.handleStreamStopped(error)
            }

            self.stateLock.sync {
                self.systemPath = sysPath
                self.micPath = micFilePath
                self.handler = outputHandler
                self.isUserStopping = false
                self.restartAttempts = 0
                self.isRestarting = false
                self.hasFailedFatally = false
            }
            record(.captureStart, .info, ["mic": microphoneDeviceId ?? "default"])

            Task {
                do {
                    // System audio (SCStream) and the mic (AVCaptureSession) are independent sources
                    // now (#96). Start the MIC FIRST: it is the likelier failure (Microphone TCC), and
                    // starting it before the system stream means a mic-start failure can't delete an
                    // already-recording system WAV (council F2). A mic-start failure fails the start
                    // loudly so the user fixes permissions before the meeting — mid-session mic loss
                    // degrades to system-only instead, which is handled separately.
                    try self.startMicSession(handler: outputHandler, microphoneDeviceId: microphoneDeviceId)
                    try await self.buildAndStartStream(handler: outputHandler)
                    Logger.audio.info("Capture started — mic AVCaptureSession + system SCStream; awaiting frames")
                    self.stateLock.sync { self.isCapturing = true }
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
        let (capturing, captureStream, micSess) = stateLock.sync { () -> (Bool, SCStream?, MicCaptureSession?) in
            if isCapturing { isUserStopping = true }
            return (isCapturing, stream, micSession)
        }
        guard capturing else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Stopping capture")
        record(.captureStop, .info)
        // Stop mic delivery before finalize so no mic buffer lands on the audio queue after the WAV
        // headers are sealed (a late buffer would be a no-op anyway — finalize is idempotent).
        micSess?.stop()

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
                self.systemPath = nil
                self.micPath = nil
                return result
            }
            reply(sys, mic, nil)
        }
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        reply(stateLock.sync { isCapturing }, nil)
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
        record(.micSwitch, .info, ["mic": deviceId ?? "default"])

        // Retarget the decoupled mic AVCaptureSession (#96). startRunning can block briefly, so do it
        // off the XPC reply thread.
        Task {
            do {
                try micSess.updateDevice(deviceId)
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

        Logger.audio.info("Rotating chunk — new base: \(newBaseName, privacy: .public)")

        let newSysPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + ".wav")
        let newMicPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + "_mic.wav")

        do {
            let newSystemWriter = try WavFileWriter(path: newSysPath)
            let newMicWriter = try WavFileWriter(path: newMicPath)

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
            Logger.audio.info("Chunk rotated — old: \(oldPaths.systemPath, privacy: .public)")
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

    func stopAndFinalize() {
        // Mark stopping before snapshotting the stream so an in-flight restart bails / is torn
        // down (council F1), mirroring stopCapture.
        let (capturing, captureStream, micSess) = stateLock.sync { () -> (Bool, SCStream?, MicCaptureSession?) in
            if isCapturing { isUserStopping = true }
            return (isCapturing, stream, micSession)
        }
        guard capturing else { return }
        Logger.audio.info("Stopping capture due to client disconnect")

        // Stop mic delivery, then finalize synchronously on the persistent audio queue so WAV headers
        // are written before the XPC service exits (I5 fix).
        micSess?.stop()
        audioQueue.sync { self.handler?.finalizeAll() }

        if let captureStream {
            Task {
                try? await captureStream.stopCapture()
                self.stateLock.sync {
                    self.isCapturing = false
                    self.stream = nil
                    self.handler = nil
                    self.micSession = nil
                }
                Logger.audio.info("Capture finalized after client disconnect")
            }
        } else {
            stateLock.sync {
                self.isCapturing = false
                self.handler = nil
                self.micSession = nil
            }
        }
    }

    private func cleanupAfterFailure() {
        // Snapshot and clear state under the lock, then run the blocking teardown (mic stopRunning,
        // writer finalize, file deletes) OUTSIDE the lock so we never hold stateLock across a blocking
        // call. Not called under stateLock, so the snapshot-then-act split is safe.
        let (h, micSess, sys, mic) = stateLock.sync {
            () -> (AudioOutputHandler?, MicCaptureSession?, String?, String?) in
            let snapshot = (handler, micSession, systemPath, micPath)
            stream = nil
            handler = nil
            micSession = nil
            systemPath = nil
            micPath = nil
            return snapshot
        }
        micSess?.stop()
        audioQueue.sync { h?.finalizeAll() }
        if let sys { try? FileManager.default.removeItem(atPath: sys) }
        if let mic { try? FileManager.default.removeItem(atPath: mic) }
    }

    /// Build and start the decoupled mic capture session (#96), wiring its diagnostics + recovery
    /// callbacks into the service. Throws — failing the whole start — if the mic can't be brought up,
    /// since the user expects their own voice recorded. Mid-session mic loss is handled separately by
    /// MicCaptureSession and is NOT fatal (system audio keeps recording).
    private func startMicSession(handler: AudioOutputHandler, microphoneDeviceId: String?) throws {
        let mic = MicCaptureSession(deliveryQueue: audioQueue) { [weak handler] buffer in
            handler?.appendMicSampleBuffer(buffer)
        }
        mic.onEvent = { [weak self] kind, severity, detail in
            self?.record(kind, severity, detail)
        }
        mic.onRecovered = { [weak self] in
            // The mic self-healed a route change — surface the same calm "Recording Resumed" notice as
            // a system-stream in-place restart. System audio never stopped.
            self?.onRestartInPlace?()
        }
        mic.onUnavailable = { [weak self] reason in
            // Mic loss is NOT fatal: system audio keeps recording and the partial mic WAV stays valid.
            // Record the anomaly so the session is flagged and diagnostics flush.
            Logger.audio.error("Microphone unavailable mid-session: \(reason, privacy: .public)")
            self?.record(.restartFailed, .anomaly, ["source": "mic", "reason": reason])
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
        let (capturing, userStopping, attempts) = stateLock.sync {
            (isCapturing, isUserStopping, restartAttempts)
        }
        let decision = RestartDecision.evaluate(
            isUserStopped: userStopping, isCapturing: capturing,
            attempts: attempts, maxAttempts: maxRestartAttempts
        )
        switch decision {
        case .ignore:
            Logger.audio.info("Stream stop ignored — user stop or capture already inactive")
        case .failFatal:
            Logger.audio.error("Stream stop: restart budget exhausted — fatal")
            failFatally("restart budget exhausted")
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
        let (won, h, micSess): (Bool, AudioOutputHandler?, MicCaptureSession?) = stateLock.sync {
            if hasFailedFatally { return (false, nil, nil) }
            hasFailedFatally = true
            let handlerToFinalize = handler
            let micToStop = micSession
            isCapturing = false
            stream = nil
            handler = nil
            micSession = nil
            systemPath = nil
            micPath = nil
            return (true, handlerToFinalize, micToStop)
        }
        guard won else { return }
        record(.restartFailed, .anomaly, ["reason": reason])
        // Stop the decoupled mic session too, otherwise its AVCaptureSession keeps running after the
        // system stream is declared dead (council CONC-2). Stop it before finalize so no mic buffer
        // lands on the audio queue after the WAV headers are sealed.
        micSess?.stop()
        // Flush the partial WAV (pre-fault audio) on the persistent queue; finalize is idempotent so
        // a rotation's swapWriters finalizing the same writers first is harmless.
        audioQueue.sync { h?.finalizeAll() }
        onFailFatally?("Capture stream failed and could not be restarted")
    }

    /// Rebuild and restart the dead stream into the SAME handler/writers, re-pinning the mic.
    /// Loops on transient failures up to the restart budget, then surfaces a fatal failure.
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
                if decision == .failFatal { failFatally("restart budget exhausted") }
                return
            }
            do {
                if let oldStream { try? await oldStream.stopCapture() }  // tear down the dead stream
                try await buildAndStartStream(handler: currentHandler)
                // A stop may have begun during the restart's awaits; if so, don't claim success or
                // notify — the stop path owns teardown now (council F1).
                if stateLock.sync(execute: { isUserStopping }) { return }
                stateLock.sync { restartAttempts = 0 }
                Logger.audio.info("System-audio stream restarted in place")
                record(.restartInPlace, .warning, ["source": "system"])
                onRestartInPlace?()
                return
            } catch is CancellationError {
                // buildAndStartStream bailed because a stop began — abandon the restart silently.
                Logger.audio.info("In-place restart aborted — session stopping")
                return
            } catch {
                stateLock.sync { restartAttempts += 1 }
                Logger.audio.error("In-place restart attempt failed: \(error, privacy: .public)")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}
