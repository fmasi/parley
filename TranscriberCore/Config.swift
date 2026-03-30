import Foundation

public struct Config: Codable, Equatable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var hfToken: String
    public var lastMicrophoneDeviceId: String?

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        hfToken: "",
        lastMicrophoneDeviceId: nil
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        hfToken: String = "",
        lastMicrophoneDeviceId: String? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.hfToken = hfToken
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
    }

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case silenceTimeoutMinutes = "silence_timeout_minutes"
        case silenceDetectionEnabled = "silence_detection_enabled"
        case outputFormat = "output_format"
        case launchOnStartup = "launch_on_startup"
        case suppressCaptureWarning = "suppress_capture_warning"
        case hfToken = "hf_token"
        case lastMicrophoneDeviceId = "last_microphone_device_id"
    }
}
