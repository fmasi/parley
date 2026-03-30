import Foundation
import ScreenCaptureKit

// MARK: - WAV file writer

/// Writes 16-bit PCM mono audio to a WAV file at the detected native sample rate.
/// Call finalize() before exit to patch the RIFF/data chunk sizes.
final class WavFileWriter {
    private let fileHandle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        // Placeholder header — rewritten on finalize() with actual rate and sizes.
        writeHeader(sampleRate: 16000, dataSize: 0)
    }

    func setSampleRate(_ rate: UInt32) {
        sampleRate = rate
    }

    func append(_ samples: UnsafeBufferPointer<Float32>) {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let bytes = pcm.withUnsafeBytes { Data($0) }
        fileHandle.write(bytes)
        dataByteCount += UInt32(bytes.count)
    }

    func finalize() {
        let rate = sampleRate > 0 ? sampleRate : 16000
        fileHandle.seek(toFileOffset: 0)
        writeHeader(sampleRate: rate, dataSize: dataByteCount)
        fileHandle.seekToEndOfFile()
        fileHandle.closeFile()
    }

    private func writeHeader(sampleRate: UInt32, dataSize: UInt32) {
        let byteRate = sampleRate * 2  // mono, 16-bit
        var h = Data()
        h += "RIFF".data(using: .ascii)!;  h += le32(36 + dataSize)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!;  h += le32(16)
        h += le16(1);  h += le16(1)       // PCM, mono
        h += le32(sampleRate);  h += le32(byteRate)
        h += le16(2);  h += le16(16)      // blockAlign=2, bitsPerSample=16
        h += "data".data(using: .ascii)!;  h += le32(dataSize)
        fileHandle.write(h)
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}

// MARK: - Stream output handler

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let systemWriter: WavFileWriter
    private let micWriter: WavFileWriter
    private var detectedSystemRate = false
    private var detectedMicRate = false

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter
    }

    func finalizeAll() {
        systemWriter.finalize()
        micWriter.finalize()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let writer: WavFileWriter
        if type == .audio {
            if !detectedSystemRate {
                detectedSystemRate = true
                if let rate = sampleRate(from: sampleBuffer) {
                    systemWriter.setSampleRate(UInt32(rate))
                    fputs("audio-capture-helper: system audio: \(Int(rate)) Hz\n", stderr)
                }
            }
            writer = systemWriter
        } else if type == .microphone {
            if !detectedMicRate {
                detectedMicRate = true
                if let rate = sampleRate(from: sampleBuffer) {
                    micWriter.setSampleRate(UInt32(rate))
                    fputs("audio-capture-helper: microphone: \(Int(rate)) Hz\n", stderr)
                }
            }
            writer = micWriter
        } else {
            return  // discard .screen frames
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let count = totalLength / MemoryLayout<Float32>.size
        ptr.withMemoryRebound(to: Float32.self, capacity: count) { floatPtr in
            writer.append(UnsafeBufferPointer(start: floatPtr, count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("audio-capture-helper: stream stopped with error: \(error)\n", stderr)
    }

    private func sampleRate(from buf: CMSampleBuffer) -> Double? {
        guard let fmt = CMSampleBufferGetFormatDescription(buf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        return asbd.pointee.mSampleRate
    }
}

// MARK: - Entry point

// Parse arguments
var basePath: String?
var micDeviceId: String?
var args = CommandLine.arguments.dropFirst() // skip program name
while let arg = args.first {
    args = args.dropFirst()
    if arg == "--mic-device", let next = args.first {
        micDeviceId = next
        args = args.dropFirst()
    } else if basePath == nil {
        basePath = arg
    }
}
guard let basePath else {
    fputs("Usage: audio-capture-helper [--mic-device <id>] <output_base.wav>\n", stderr)
    fputs("  Writes <base>.wav (system audio) and <base>_mic.wav (microphone)\n", stderr)
    fputs("  --mic-device <id>  Use specific microphone (AVCaptureDevice.uniqueID)\n", stderr)
    exit(1)
}
let micPath: String = {
    if basePath.hasSuffix(".wav") {
        return String(basePath.dropLast(4)) + "_mic.wav"
    }
    return basePath + "_mic.wav"
}()

let systemWriter: WavFileWriter
let micWriter: WavFileWriter
do {
    systemWriter = try WavFileWriter(path: basePath)
    micWriter = try WavFileWriter(path: micPath)
} catch {
    fputs("audio-capture-helper: failed to open output files: \(error)\n", stderr)
    exit(1)
}

var captureHandler: AudioOutputHandler?
var captureStream: SCStream?

func startCapture() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
        fputs("audio-capture-helper: no display found\n", stderr)
        exit(1)
    }

    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.captureMicrophone = true
    if let micDeviceId {
        config.microphoneCaptureDeviceID = micDeviceId
    }
    config.excludesCurrentProcessAudio = true
    config.channelCount = 1
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let handler = AudioOutputHandler(systemWriter: systemWriter, micWriter: micWriter)
    captureHandler = handler

    let stream = SCStream(filter: filter, configuration: config, delegate: handler)
    try stream.addStreamOutput(handler, type: .audio,
        sampleHandlerQueue: DispatchQueue(label: "audio-capture.audio"))
    try stream.addStreamOutput(handler, type: .microphone,
        sampleHandlerQueue: DispatchQueue(label: "audio-capture.microphone"))
    try stream.addStreamOutput(handler, type: .screen,
        sampleHandlerQueue: DispatchQueue(label: "audio-capture.screen"))

    captureStream = stream
    try await stream.startCapture()
}

let stopAndExit: @convention(c) (Int32) -> Void = { _ in
    captureStream?.stopCapture { _ in }
    captureHandler?.finalizeAll()
    exit(0)
}
signal(SIGTERM, stopAndExit)
signal(SIGINT, stopAndExit)

Task {
    do {
        try await startCapture()
        fputs("audio-capture-helper: recording → \(basePath) + \(micPath)\n", stderr)
    } catch {
        fputs("audio-capture-helper: capture failed: \(error)\n", stderr)
        let desc = "\(error)"
        if desc.contains("permission") || desc.contains("denied") || desc.contains("notAuthorized") {
            exit(2)
        }
        exit(1)
    }
}

dispatchMain()
