import Foundation

struct Config: Codable, Equatable {
    var recordingDirectory: String
    var silenceTimeoutMinutes: Int
    var silenceDetectionEnabled: Bool
    var outputFormat: String
    var launchOnStartup: Bool
    var logLevel: String
    var suppressCaptureWarning: Bool
    var hfToken: String

    static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        logLevel: "info",
        suppressCaptureWarning: false,
        hfToken: ""
    )

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case silenceTimeoutMinutes = "silence_timeout_minutes"
        case silenceDetectionEnabled = "silence_detection_enabled"
        case outputFormat = "output_format"
        case launchOnStartup = "launch_on_startup"
        case logLevel = "log_level"
        case suppressCaptureWarning = "suppress_capture_warning"
        case hfToken = "hf_token"
    }
}
