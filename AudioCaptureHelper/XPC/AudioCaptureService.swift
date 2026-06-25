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
    private var audioQueue: DispatchQueue?
    private let stateLock = DispatchQueue(label: "audio-capture.state")

    // MARK: - #86 in-place restart + #95 diagnostics

    /// Anomaly-gated diagnostic ring, drained by the app over XPC (#95).
    private let diagnostics = LockedDiagnostics()
    /// The mic device pinned by the active session — re-applied on every in-place restart so a
    /// route change can't silently demote capture to the system-default input (#86).
    private var currentMicDeviceId: String?
    /// Set true while the app is deliberately stopping, so a stop-induced `didStopWithError`
    /// is classified as `.ignore` rather than a route-change restart.
    private var isUserStopping = false
    /// Consecutive failed in-place restarts; reset to 0 on a restart that starts cleanly.
    private var restartAttempts = 0
    /// Guards against overlapping restart loops from rapid repeated stop errors.
    private var isRestarting = false
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
                self.currentMicDeviceId = microphoneDeviceId
                self.isUserStopping = false
                self.restartAttempts = 0
                self.isRestarting = false
            }
            record(.captureStart, .info, ["mic": microphoneDeviceId ?? "default"])

            Task {
                do {
                    try await self.buildAndStartStream(handler: outputHandler, microphoneDeviceId: microphoneDeviceId)
                    Logger.audio.info("SCStream started, awaiting frames")
                    self.stateLock.sync { self.isCapturing = true }
                    reply(true, nil)
                } catch {
                    self.cleanupAfterFailure()
                    Logger.audio.error("Capture failed: \(error, privacy: .public)")
                    let desc = "\(error)"
                    if desc.contains("permission") || desc.contains("denied")
                        || desc.contains("notAuthorized") {
                        reply(false, "Permission denied — grant Screen Recording access in System Settings")
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
        let (capturing, captureStream) = stateLock.sync { (isCapturing, stream) }
        guard capturing, let captureStream else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Stopping capture")
        // Mark the stop as user-initiated so the SCStream's didStopWithError (which fires as a
        // consequence of our own stopCapture) is classified as `.ignore`, not a route change (#86).
        stateLock.sync { isUserStopping = true }
        record(.captureStop, .info)

        Task {
            do {
                try await captureStream.stopCapture()
                Logger.audio.debug("SCStream stopped")
            } catch {
                // Stream may already be stopped — proceed with finalization
            }
            // Snapshot under state lock, then drain audio queue outside it
            // to avoid lock-order inversion with rotateChunk.
            let (queue, handler) = self.stateLock.sync {
                (self.audioQueue, self.handler)
            }
            queue?.sync { handler?.finalizeAll() }
            let (sys, mic) = self.stateLock.sync {
                let result = (self.systemPath, self.micPath)
                self.isCapturing = false
                self.stream = nil
                self.handler = nil
                self.systemPath = nil
                self.micPath = nil
                self.audioQueue = nil
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
        let (capturing, captureStream) = stateLock.sync { (isCapturing, stream) }
        guard capturing, let captureStream else {
            reply(false, "No capture in progress")
            return
        }

        Logger.audio.info("Switching mic to: \(deviceId ?? "system default", privacy: .public)")
        // Remember the choice so an in-place restart re-pins THIS device, not the original (#86).
        stateLock.sync { currentMicDeviceId = deviceId }
        record(.micSwitch, .info, ["mic": deviceId ?? "default"])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        if let deviceId {
            config.microphoneCaptureDeviceID = deviceId
        }
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        Task {
            do {
                try await captureStream.updateConfiguration(config)
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
        let (capturing, currentHandler, queue) = stateLock.sync { (isCapturing, handler, audioQueue) }
        guard capturing, let currentHandler, let queue else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Rotating chunk — new base: \(newBaseName, privacy: .public)")

        let newSysPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + ".wav")
        let newMicPath = (outputDirectory as NSString).appendingPathComponent(newBaseName + "_mic.wav")

        do {
            let newSystemWriter = try WavFileWriter(path: newSysPath)
            let newMicWriter = try WavFileWriter(path: newMicPath)

            // Swap on the audio queue for zero-gap guarantee, then update
            // state outside to avoid lock-order inversion with stopCapture.
            var oldPaths: (systemPath: String, micPath: String)!
            queue.sync {
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
        let (capturing, captureStream, queue) = stateLock.sync { (isCapturing, stream, audioQueue) }
        guard capturing else { return }
        Logger.audio.info("Stopping capture due to client disconnect")
        stateLock.sync { isUserStopping = true }

        // Finalize synchronously on the audio queue so WAV headers are written
        // before the XPC service exits (I5 fix).
        queue?.sync { self.handler?.finalizeAll() }

        if let captureStream {
            Task {
                try? await captureStream.stopCapture()
                self.stateLock.sync {
                    self.isCapturing = false
                    self.stream = nil
                    self.handler = nil
                }
                Logger.audio.info("Capture finalized after client disconnect")
            }
        } else {
            stateLock.sync {
                self.isCapturing = false
                self.handler = nil
            }
        }
    }

    private func cleanupAfterFailure() {
        stateLock.sync {
            audioQueue?.sync { handler?.finalizeAll() }
            if let sys = systemPath { try? FileManager.default.removeItem(atPath: sys) }
            if let mic = micPath { try? FileManager.default.removeItem(atPath: mic) }
            stream = nil
            handler = nil
            systemPath = nil
            micPath = nil
            audioQueue = nil
        }
    }

    /// Build a fresh SCStream around the given handler and start it. Used both for the initial
    /// start and for #86 in-place restarts: because the SAME handler (and therefore the same
    /// WavFileWriters / output files) is reused, a restart resumes the existing recording with no
    /// file rotation and no lost audio. The pinned mic is re-applied on every call.
    private func buildAndStartStream(handler: AudioOutputHandler, microphoneDeviceId: String?) async throws {
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
        config.captureMicrophone = true
        if let microphoneDeviceId {
            config.microphoneCaptureDeviceID = microphoneDeviceId
            Logger.audio.debug("Mic capture device override: \(microphoneDeviceId, privacy: .public)")
        }
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
        let sharedQueue = DispatchQueue(label: "audio-capture.shared")

        try captureStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: sharedQueue)
        try captureStream.addStreamOutput(handler, type: .microphone, sampleHandlerQueue: sharedQueue)
        try captureStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: sharedQueue)

        self.stateLock.sync {
            self.stream = captureStream
            self.audioQueue = sharedQueue
        }
        try await captureStream.startCapture()
    }

    // MARK: - #86 in-place restart on benign stream stop

    /// SCStream `didStopWithError` handoff. Decides whether the stop is a user stop (ignore), a
    /// recoverable route change (restart in place), or a terminal fault (surface fatal).
    private func handleStreamStopped(_ error: Error) {
        let (capturing, userStopping, restarting, attempts) = stateLock.sync {
            (isCapturing, isUserStopping, isRestarting, restartAttempts)
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
            record(.restartFailed, .anomaly, ["reason": "budget exhausted"])
            onFailFatally?("Capture stream failed and could not be restarted")
        case .restart:
            guard !restarting else { return }
            stateLock.sync { isRestarting = true }
            Task { await self.attemptRestart() }
        }
    }

    /// Rebuild and restart the dead stream into the SAME handler/writers, re-pinning the mic.
    /// Loops on transient failures up to the restart budget, then surfaces a fatal failure.
    private func attemptRestart() async {
        defer { stateLock.sync { isRestarting = false } }
        while true {
            let (userStopping, capturing, attempts, currentHandler, micId, oldStream) = stateLock.sync {
                (isUserStopping, isCapturing, restartAttempts, handler, currentMicDeviceId, stream)
            }
            let decision = RestartDecision.evaluate(
                isUserStopped: userStopping, isCapturing: capturing,
                attempts: attempts, maxAttempts: maxRestartAttempts
            )
            guard decision == .restart, let currentHandler else {
                if decision == .failFatal {
                    record(.restartFailed, .anomaly, ["reason": "budget exhausted"])
                    onFailFatally?("Capture stream failed and could not be restarted")
                }
                return
            }
            do {
                if let oldStream { try? await oldStream.stopCapture() }  // tear down the dead stream
                try await buildAndStartStream(handler: currentHandler, microphoneDeviceId: micId)
                stateLock.sync { restartAttempts = 0 }
                Logger.audio.info("Stream restarted in place — mic re-pinned: \(micId ?? "default", privacy: .public)")
                record(.restartInPlace, .warning, ["mic": micId ?? "default"])
                onRestartInPlace?()
                return
            } catch {
                stateLock.sync { restartAttempts += 1 }
                Logger.audio.error("In-place restart attempt failed: \(error, privacy: .public)")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}
