import Foundation

public struct Config: Codable, Equatable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var lastMicrophoneDeviceId: String?
    public var engine: EngineID
    public var vadSpeechThreshold: Double?
    public var archiveBitrateKbps: Int
    public var audioArchiveLimitHours: Int
    public var chunkDurationMinutes: Int
    public var chunkProcessingQos: String

    /// Returns `chunkDurationMinutes` clamped to a minimum of 10.
    public var validatedChunkDuration: Int {
        max(chunkDurationMinutes, 10)
    }

    /// Maps `chunkProcessingQos` string to a `DispatchQoS.QoSClass`.
    /// Falls back to `.utility` for unrecognised values.
    public var resolvedQos: DispatchQoS.QoSClass {
        switch chunkProcessingQos {
        case "userInteractive": return .userInteractive
        case "userInitiated":   return .userInitiated
        case "utility":         return .utility
        case "background":      return .background
        default:                return .utility
        }
    }

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        lastMicrophoneDeviceId: nil,
        engine: .resolvedDefault,
        vadSpeechThreshold: nil,
        archiveBitrateKbps: 64,
        audioArchiveLimitHours: 15,
        chunkDurationMinutes: 30,
        chunkProcessingQos: "utility"
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        lastMicrophoneDeviceId: String? = nil,
        engine: EngineID = .resolvedDefault,
        vadSpeechThreshold: Double? = nil,
        archiveBitrateKbps: Int = 64,
        audioArchiveLimitHours: Int = 15,
        chunkDurationMinutes: Int = 30,
        chunkProcessingQos: String = "utility"
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
        self.engine = engine
        self.vadSpeechThreshold = vadSpeechThreshold
        self.archiveBitrateKbps = archiveBitrateKbps
        self.audioArchiveLimitHours = audioArchiveLimitHours
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunkProcessingQos = chunkProcessingQos
    }

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case silenceTimeoutMinutes = "silence_timeout_minutes"
        case silenceDetectionEnabled = "silence_detection_enabled"
        case outputFormat = "output_format"
        case launchOnStartup = "launch_on_startup"
        case suppressCaptureWarning = "suppress_capture_warning"
        case lastMicrophoneDeviceId = "last_microphone_device_id"
        case engine
        case vadSpeechThreshold = "vad_speech_threshold"
        case archiveBitrateKbps = "archive_bitrate_kbps"
        case audioArchiveLimitHours = "audio_archive_limit_hours"
        case chunkDurationMinutes = "chunk_duration_minutes"
        case chunkProcessingQos = "chunk_processing_qos"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingDirectory = try c.decode(String.self, forKey: .recordingDirectory)
        silenceTimeoutMinutes = try c.decode(Int.self, forKey: .silenceTimeoutMinutes)
        silenceDetectionEnabled = try c.decode(Bool.self, forKey: .silenceDetectionEnabled)
        outputFormat = try c.decode(String.self, forKey: .outputFormat)
        launchOnStartup = try c.decode(Bool.self, forKey: .launchOnStartup)
        suppressCaptureWarning = try c.decode(Bool.self, forKey: .suppressCaptureWarning)
        lastMicrophoneDeviceId = try c.decodeIfPresent(String.self, forKey: .lastMicrophoneDeviceId)
        engine = try c.decodeIfPresent(EngineID.self, forKey: .engine) ?? .resolvedDefault
        vadSpeechThreshold = try c.decodeIfPresent(Double.self, forKey: .vadSpeechThreshold)
        archiveBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .archiveBitrateKbps) ?? 64
        audioArchiveLimitHours = try c.decodeIfPresent(Int.self, forKey: .audioArchiveLimitHours) ?? 15
        chunkDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .chunkDurationMinutes) ?? 30
        chunkProcessingQos = try c.decodeIfPresent(String.self, forKey: .chunkProcessingQos) ?? "utility"
    }
}
