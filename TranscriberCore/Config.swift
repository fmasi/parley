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

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        lastMicrophoneDeviceId: nil,
        engine: .resolvedDefault
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        lastMicrophoneDeviceId: String? = nil,
        engine: EngineID = .resolvedDefault
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
        self.engine = engine
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
    }
}
