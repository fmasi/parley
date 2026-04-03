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

    func startCapture(
        outputDirectory: String,
        baseName: String,
        microphoneDeviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard !isCapturing else {
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

            self.systemPath = sysPath
            self.micPath = micFilePath
            self.handler = outputHandler

            Task {
                do {
                    try await self.configureAndStart(handler: outputHandler, microphoneDeviceId: microphoneDeviceId)
                    Logger.audio.info("SCStream started, awaiting frames")
                    self.isCapturing = true
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
        guard isCapturing, let stream = stream else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Logger.audio.info("Stopping capture")

        Task {
            do {
                try await stream.stopCapture()
                Logger.audio.debug("SCStream stopped")
            } catch {
                // Stream may already be stopped — proceed with finalization
            }
            self.handler?.finalizeAll()
            self.isCapturing = false
            let sys = self.systemPath
            let mic = self.micPath
            self.stream = nil
            self.handler = nil
            self.systemPath = nil
            self.micPath = nil
            reply(sys, mic, nil)
        }
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        reply(isCapturing, nil)
    }

    func updateMicrophone(
        deviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard isCapturing, let stream else {
            reply(false, "No capture in progress")
            return
        }

        Logger.audio.info("Switching mic to: \(deviceId ?? "system default", privacy: .public)")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        if let deviceId {
            config.microphoneCaptureDeviceID = deviceId
        }
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        Task {
            do {
                try await stream.updateConfiguration(config)
                Logger.audio.info("Mic switched successfully to: \(deviceId ?? "system default", privacy: .public)")
                reply(true, nil)
            } catch {
                Logger.audio.error("Mic switch failed: \(error, privacy: .public)")
                reply(false, "Mic switch failed: \(error.localizedDescription)")
            }
        }
    }

    func stopAndFinalize() {
        guard isCapturing else { return }
        Logger.audio.info("Stopping capture due to client disconnect")

        if let stream = stream {
            Task {
                try? await stream.stopCapture()
                self.handler?.finalizeAll()
                self.isCapturing = false
                self.stream = nil
                self.handler = nil
                Logger.audio.info("Capture finalized after client disconnect")
            }
        } else {
            handler?.finalizeAll()
            isCapturing = false
            handler = nil
        }
    }

    private func cleanupAfterFailure() {
        handler?.finalizeAll()
        if let sys = systemPath { try? FileManager.default.removeItem(atPath: sys) }
        if let mic = micPath { try? FileManager.default.removeItem(atPath: mic) }
        stream = nil
        handler = nil
        systemPath = nil
        micPath = nil
    }

    private func configureAndStart(handler: AudioOutputHandler, microphoneDeviceId: String?) async throws {
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
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let captureStream = SCStream(
            filter: filter, configuration: config, delegate: handler
        )
        try captureStream.addStreamOutput(
            handler, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.audio")
        )
        try captureStream.addStreamOutput(
            handler, type: .microphone,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.microphone")
        )
        try captureStream.addStreamOutput(
            handler, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.screen")
        )

        self.stream = captureStream
        try await captureStream.startCapture()
    }
}
