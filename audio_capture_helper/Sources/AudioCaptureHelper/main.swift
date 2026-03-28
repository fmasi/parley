import Foundation
import ScreenCaptureKit

// MARK: - WAV file writer

/// Writes 16-bit PCM mono audio samples to a WAV file in real-time.
/// Call finalize() before exit to patch the RIFF/data chunk sizes.
final class WavFileWriter {
    private let fileHandle: FileHandle
    private var dataByteCount: UInt32 = 0
    private let sampleRate: UInt32
    private let channels: UInt16 = 1
    private let bitsPerSample: UInt16 = 16

    init(path: String, sampleRate: UInt32) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        self.sampleRate = sampleRate
        writeHeader(dataSize: 0) // placeholder — patched on finalize()
    }

    /// Append Float32 samples (range −1…1), converting to Int16 PCM.
    func append(floatSamples: UnsafeBufferPointer<Float32>) {
        var pcm = [Int16](repeating: 0, count: floatSamples.count)
        for i in 0..<floatSamples.count {
            let clamped = max(-1.0, min(1.0, floatSamples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let bytes = pcm.withUnsafeBytes { Data($0) }
        fileHandle.write(bytes)
        dataByteCount += UInt32(bytes.count)
    }

    /// Patch RIFF/data chunk sizes and close the file.
    func finalize() {
        fileHandle.seek(toFileOffset: 4)
        fileHandle.write(le32(36 + dataByteCount))
        fileHandle.seek(toFileOffset: 40)
        fileHandle.write(le32(dataByteCount))
        fileHandle.closeFile()
    }

    // MARK: Private

    private func writeHeader(dataSize: UInt32) {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        var h = Data()
        h += "RIFF".data(using: .ascii)!
        h += le32(36 + dataSize)        // RIFF chunk size (placeholder)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!
        h += le32(16)                   // fmt chunk size
        h += le16(1)                    // PCM format
        h += le16(UInt16(channels))
        h += le32(sampleRate)
        h += le32(byteRate)
        h += le16(blockAlign)
        h += le16(bitsPerSample)
        h += "data".data(using: .ascii)!
        h += le32(dataSize)             // data chunk size (placeholder)
        fileHandle.write(h)
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}

// MARK: - Stream output handler

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: WavFileWriter

    init(writer: WavFileWriter) {
        self.writer = writer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }

        // SCStream delivers Float32 interleaved PCM in CMSampleBuffer.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let floatCount = totalLength / MemoryLayout<Float32>.size
        ptr.withMemoryRebound(to: Float32.self, capacity: floatCount) { floatPtr in
            writer.append(floatSamples: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("audio-capture-helper: stream stopped with error: \(error)\n", stderr)
    }
}

// MARK: - Entry point

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: audio-capture-helper <output.wav>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]
let sampleRate: UInt32 = 16000

let writer: WavFileWriter
do {
    writer = try WavFileWriter(path: outputPath, sampleRate: sampleRate)
} catch {
    fputs("audio-capture-helper: failed to open '\(outputPath)': \(error)\n", stderr)
    exit(1)
}

// Request shareable content — triggers the permission prompt on first run.
var captureStream: SCStream?
let ready = DispatchSemaphore(value: 0)
var captureStartError: Error?

SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
    if let error = error {
        fputs("audio-capture-helper: ScreenCaptureKit permission denied: \(error)\n", stderr)
        exit(2)
    }
    guard let display = content?.displays.first else {
        fputs("audio-capture-helper: no display found\n", stderr)
        exit(1)
    }

    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

    let config = SCStreamConfiguration()
    // Audio capture: system audio output + microphone (macOS 14.0+)
    config.capturesAudio = true
    config.captureMicrophone = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = Int(sampleRate)
    config.channelCount = 1
    // SCStream requires a video configuration even for audio-only capture.
    // Use the smallest valid size to minimise CPU overhead.
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps

    let handler = AudioOutputHandler(writer: writer)
    let stream = SCStream(filter: filter, configuration: config, delegate: handler)

    do {
        try stream.addStreamOutput(
            handler, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.audio")
        )
        // Screen output is required by SCStream; we discard the video frames in the handler.
        try stream.addStreamOutput(
            handler, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.screen")
        )
    } catch {
        fputs("audio-capture-helper: addStreamOutput failed: \(error)\n", stderr)
        exit(1)
    }

    captureStream = stream
    stream.startCapture { err in
        captureStartError = err
        ready.signal()
    }
}

ready.wait()
if let err = captureStartError {
    fputs("audio-capture-helper: startCapture failed: \(err)\n", stderr)
    exit(1)
}

fputs("audio-capture-helper: recording → \(outputPath)\n", stderr)

// Signal handlers for clean shutdown:
// Python sends SIGTERM when the user stops recording.
// We stop the stream, finalize the WAV, then exit 0.
let stopAndExit: @convention(c) (Int32) -> Void = { _ in
    captureStream?.stopCapture { _ in }
    writer.finalize()
    exit(0)
}
signal(SIGTERM, stopAndExit)
signal(SIGINT, stopAndExit)

// Block this thread forever — audio arrives on a dispatch queue.
dispatchMain()
