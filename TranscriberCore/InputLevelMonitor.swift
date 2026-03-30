import AVFoundation
import CoreAudio
import Observation

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
            if let coreAudioID = coreAudioDeviceID(for: deviceId) {
                let status = setInputDevice(coreAudioID, on: engine)
                if status != noErr {
                    fputs("InputLevelMonitor: failed to set device \(deviceId), status=\(status)\n", stderr)
                }
            } else {
                fputs("InputLevelMonitor: no CoreAudio device found for uniqueID=\(deviceId)\n", stderr)
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            fputs("InputLevelMonitor: invalid format (rate=\(format.sampleRate), ch=\(format.channelCount))\n", stderr)
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
        } catch {
            fputs("InputLevelMonitor: engine.start() failed: \(error)\n", stderr)
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
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr {
                if let deviceUID = uid?.takeUnretainedValue() as String?, deviceUID == uniqueID {
                    return id
                }
            }
        }
        return nil
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
