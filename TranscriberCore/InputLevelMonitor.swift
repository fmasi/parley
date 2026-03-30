import AVFoundation
import Observation

/// Log file for diagnostics (visible even when launched via `open`).
private let logFile: FileHandle? = {
    let dir = NSHomeDirectory() + "/.audio-transcribe/logs"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/input-level-monitor.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

private func log(_ msg: String) {
    guard let logFile else { return }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    logFile.seekToEndOfFile()
    logFile.write(Data(line.utf8))
}

/// Monitors audio input level from a specified device (or system default).
/// Uses AVCaptureSession which handles all device types including USB webcams.
/// Publishes `level` (0.0–1.0) suitable for driving a level meter UI.
@Observable
public final class InputLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var level: Float = 0.0
    public private(set) var isMonitoring = false

    private var session: AVCaptureSession?
    private let processingQueue = DispatchQueue(label: "input-level-monitor")

    public override init() {}

    /// Start monitoring the given device. Pass `nil` for system default.
    /// If already monitoring, stops the previous session first.
    public func start(deviceId: String?) {
        stop()

        let device: AVCaptureDevice?
        if let deviceId {
            device = AVCaptureDevice(uniqueID: deviceId)
            log("Requested device: \(deviceId) -> \(device?.localizedName ?? "NOT FOUND")")
        } else {
            device = AVCaptureDevice.default(for: .audio)
            log("Using system default device: \(device?.localizedName ?? "NONE")")
        }

        guard let device else {
            log("ERROR: no audio device available")
            return
        }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                log("ERROR: cannot add input for \(device.localizedName)")
                return
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else {
                log("ERROR: cannot add audio output")
                return
            }
            output.setSampleBufferDelegate(self, queue: processingQueue)
            session.addOutput(output)

            session.startRunning()
            self.session = session
            self.isMonitoring = true
            log("Capture session started for \(device.localizedName)")
        } catch {
            log("ERROR: failed to create input: \(error)")
        }
    }

    /// Stop monitoring and reset level to zero.
    public func stop() {
        if let session {
            session.stopRunning()
        }
        session = nil
        isMonitoring = false
        level = 0.0
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    private var rmsLogCounter = 0

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Determine format to compute RMS correctly
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let asbd else { return }

        let rawRMS: Float
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 samples
            let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(
                to: Float.self, capacity: lengthAtOffset / MemoryLayout<Float>.size
            )
            let sampleCount = lengthAtOffset / MemoryLayout<Float>.size
            rawRMS = computeRMSFloat(floatPtr, count: sampleCount)
        } else {
            // Int16 samples (common for USB devices)
            let int16Ptr = UnsafeRawPointer(dataPointer).bindMemory(
                to: Int16.self, capacity: lengthAtOffset / MemoryLayout<Int16>.size
            )
            let sampleCount = lengthAtOffset / MemoryLayout<Int16>.size
            rawRMS = computeRMSInt16(int16Ptr, count: sampleCount)
        }

        // Log periodically
        rmsLogCounter += 1
        if rmsLogCounter % 47 == 1 {
            let db = rawRMS > 0 ? 20.0 * log10(rawRMS) : -999.0
            log("RMS: raw=\(rawRMS), dB=\(db), format=\(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int16"), rate=\(asbd.mSampleRate)")
        }

        let normalized = dBNormalize(rawRMS)
        DispatchQueue.main.async {
            self.level = normalized
        }
    }

    // MARK: - Private

    private func computeRMSFloat(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<count {
            let s = samples[i]
            sum += s * s
        }
        return sqrt(sum / Float(count))
    }

    private func computeRMSInt16(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<count {
            let s = Float(samples[i]) / 32768.0
            sum += s * s
        }
        return sqrt(sum / Float(count))
    }

    private func dBNormalize(_ rawRMS: Float) -> Float {
        guard rawRMS > 0 else { return 0.0 }
        let db = 20.0 * log10(rawRMS)
        let minDb: Float = -50.0
        let normalized = (db - minDb) / (0.0 - minDb)
        return min(max(normalized, 0.0), 1.0)
    }
}
