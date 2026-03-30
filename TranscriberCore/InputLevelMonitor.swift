import AVFoundation
import CoreAudio
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
/// Publishes `level` (0.0–1.0) suitable for driving a level meter UI.
@Observable
public final class InputLevelMonitor {
    public var level: Float = 0.0
    public private(set) var isMonitoring = false

    private var engine: AVAudioEngine?

    public init() {}

    /// Start monitoring the given device. Pass `nil` for system default.
    /// If already monitoring, stops the previous session first.
    public func start(deviceId: String?) {
        stop()

        let engine = AVAudioEngine()

        // Select input device if specified
        if let deviceId {
            log("Requested device: \(deviceId)")
            if let coreAudioID = coreAudioDeviceID(for: deviceId) {
                log("Found CoreAudio device ID: \(coreAudioID)")
                let status = setInputDevice(coreAudioID, on: engine)
                if status != noErr {
                    log("ERROR: AudioUnitSetProperty failed, status=\(status)")
                } else {
                    log("Device set successfully")
                }
            } else {
                log("ERROR: no CoreAudio device found for uniqueID=\(deviceId)")
                log("Available CoreAudio devices:")
                logAllCoreAudioDevices()
            }
        } else {
            log("Using system default device")
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        log("Input format: rate=\(format.sampleRate), channels=\(format.channelCount)")

        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("ERROR: invalid format, aborting")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = self.computeRMS(buffer: buffer)
            DispatchQueue.main.async {
                self.level = rms
            }
        }

        do {
            try engine.start()
            self.engine = engine
            self.isMonitoring = true
            log("Engine started OK")
        } catch {
            log("ERROR: engine.start() failed: \(error)")
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Stop monitoring and reset level to zero.
    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isMonitoring = false
        level = 0.0
    }

    // MARK: - Private

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let channelSamples = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelSamples[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        // Convert to dB-like scale for visual responsiveness (matches System Settings feel)
        // -50 dB floor, 0 dB ceiling, linear interpolation between
        guard rms > 0 else { return 0.0 }
        let db = 20.0 * log10(rms)
        let minDb: Float = -50.0
        let normalized = (db - minDb) / (0.0 - minDb) // 0..1
        return min(max(normalized, 0.0), 1.0)
    }

    /// Convert AVCaptureDevice.uniqueID to CoreAudio AudioDeviceID.
    private func coreAudioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else {
            log("ERROR: failed to get device list size")
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else {
            log("ERROR: failed to get device list")
            return nil
        }

        for id in deviceIDs {
            if let deviceUID = coreAudioDeviceUID(id), deviceUID == uniqueID {
                return id
            }
        }
        return nil
    }

    /// Get the UID string for a CoreAudio device.
    private func coreAudioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    /// Log all CoreAudio devices for diagnostics.
    private func logAllCoreAudioDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return }

        for id in deviceIDs {
            let uid = coreAudioDeviceUID(id) ?? "<no UID>"
            log("  CoreAudio device \(id): \(uid)")
        }
    }

    /// Set the input device on an AVAudioEngine via CoreAudio.
    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> OSStatus {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
        var devID = deviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
