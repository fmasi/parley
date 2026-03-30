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
        if let deviceId,
           let audioDeviceID = audioDeviceID(for: deviceId) {
            setInputDevice(audioDeviceID, on: engine)
        }
        // else: system default — no configuration needed

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            return // no valid input format
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
            // Failed to start — leave in non-monitoring state
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
        // Clamp to 0...1
        return min(max(rms * 3.0, 0.0), 1.0) // scale up for visibility
    }

    /// Convert AVCaptureDevice.uniqueID to CoreAudio AudioDeviceID.
    private func audioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        let device = AVCaptureDevice(uniqueID: uniqueID)
        guard let _ = device else { return nil }

        // Use CoreAudio to find the device by UID.
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
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr {
                if uid as String == uniqueID {
                    return id
                }
            }
        }
        return nil
    }

    /// Set the input device on an AVAudioEngine via CoreAudio.
    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
        var devID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
