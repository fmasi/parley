import Foundation
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
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard !isCapturing else {
            reply(false, "Capture already in progress")
            return
        }

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
                    try await self.configureAndStart(handler: outputHandler)
                    self.isCapturing = true
                    reply(true, nil)
                } catch {
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

        Task {
            do {
                try await stream.stopCapture()
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

    private func configureAndStart(handler: AudioOutputHandler) async throws {
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
