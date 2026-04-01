import Foundation

public struct Config: Codable, Equatable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var lastMicrophoneDeviceId: String?
    public var whisperModel: String
    public var modelStoragePath: String
    public var modelUnloadTimeout: Int

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        lastMicrophoneDeviceId: nil,
        whisperModel: "large-v3-turbo",
        modelStoragePath: "~/.audio-transcribe/models",
        modelUnloadTimeout: 60
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        lastMicrophoneDeviceId: String? = nil,
        whisperModel: String = "large-v3-turbo",
        modelStoragePath: String = "~/.audio-transcribe/models",
        modelUnloadTimeout: Int = 60
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
        self.whisperModel = whisperModel
        self.modelStoragePath = modelStoragePath
        self.modelUnloadTimeout = modelUnloadTimeout
    }

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case silenceTimeoutMinutes = "silence_timeout_minutes"
        case silenceDetectionEnabled = "silence_detection_enabled"
        case outputFormat = "output_format"
        case launchOnStartup = "launch_on_startup"
        case suppressCaptureWarning = "suppress_capture_warning"
        case lastMicrophoneDeviceId = "last_microphone_device_id"
        case whisperModel = "whisper_model"
        case modelStoragePath = "model_storage_path"
        case modelUnloadTimeout = "model_unload_timeout"
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
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? "large-v3-turbo"
        modelStoragePath = try c.decodeIfPresent(String.self, forKey: .modelStoragePath) ?? "~/.audio-transcribe/models"
        modelUnloadTimeout = try c.decodeIfPresent(Int.self, forKey: .modelUnloadTimeout) ?? 60
    }
}
