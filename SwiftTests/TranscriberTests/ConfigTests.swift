import Testing
import Foundation
@testable import TranscriberCore

struct ConfigTests {

    // MARK: - Defaults

    @Test func defaultValues() {
        let config = Config.default
        #expect(config.recordingDirectory.hasSuffix("/Documents/Recordings"))
        #expect(config.silenceTimeoutMinutes == 5)
        #expect(config.silenceDetectionEnabled == true)
        #expect(config.outputFormat == "txt")
        #expect(config.launchOnStartup == true)
        #expect(config.logLevel == "info")
        #expect(config.suppressCaptureWarning == false)
        #expect(config.hfToken == "")
    }

    @Test func memberWiseInit() {
        let config = Config(
            recordingDirectory: "/tmp/test",
            silenceTimeoutMinutes: 10,
            silenceDetectionEnabled: false,
            outputFormat: "srt",
            launchOnStartup: false,
            logLevel: "debug",
            suppressCaptureWarning: true,
            hfToken: "hf_abc123"
        )
        #expect(config.recordingDirectory == "/tmp/test")
        #expect(config.silenceTimeoutMinutes == 10)
        #expect(config.silenceDetectionEnabled == false)
        #expect(config.outputFormat == "srt")
        #expect(config.launchOnStartup == false)
        #expect(config.logLevel == "debug")
        #expect(config.suppressCaptureWarning == true)
        #expect(config.hfToken == "hf_abc123")
    }

    // MARK: - Codable round-trip

    @Test func encodeDecodeRoundTrip() throws {
        let original = Config(
            recordingDirectory: "/tmp/recordings",
            silenceTimeoutMinutes: 3,
            silenceDetectionEnabled: false,
            outputFormat: "json",
            launchOnStartup: false,
            logLevel: "warning",
            suppressCaptureWarning: true,
            hfToken: "hf_token_value"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded == original)
    }

    @Test func snakeCaseKeys() throws {
        let config = Config.default
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["recording_directory"] != nil)
        #expect(json["silence_timeout_minutes"] != nil)
        #expect(json["silence_detection_enabled"] != nil)
        #expect(json["output_format"] != nil)
        #expect(json["launch_on_startup"] != nil)
        #expect(json["log_level"] != nil)
        #expect(json["suppress_capture_warning"] != nil)
        #expect(json["hf_token"] != nil)
        // camelCase keys should NOT be present
        #expect(json["recordingDirectory"] == nil)
        #expect(json["silenceTimeoutMinutes"] == nil)
    }

    @Test func decodesFromSnakeCaseJSON() throws {
        let json = """
        {
            "recording_directory": "/custom/path",
            "silence_timeout_minutes": 8,
            "silence_detection_enabled": false,
            "output_format": "srt",
            "launch_on_startup": false,
            "log_level": "debug",
            "suppress_capture_warning": true,
            "hf_token": "test_token"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.recordingDirectory == "/custom/path")
        #expect(config.silenceTimeoutMinutes == 8)
        #expect(config.outputFormat == "srt")
        #expect(config.hfToken == "test_token")
    }

    // MARK: - Equatable

    @Test func equalityForIdenticalConfigs() {
        let a = Config.default
        let b = Config.default
        #expect(a == b)
    }

    @Test func inequalityWhenFieldsDiffer() {
        var modified = Config.default
        modified.outputFormat = "srt"
        #expect(modified != Config.default)
    }

    // MARK: - lastMicrophoneDeviceId

    @Test func lastMicrophoneDeviceIdRoundTrips() throws {
        var config = Config.default
        config.lastMicrophoneDeviceId = "AppleUSBAudioEngine:Logitech:C920:1234"

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        #expect(decoded.lastMicrophoneDeviceId == "AppleUSBAudioEngine:Logitech:C920:1234")
    }

    @Test func lastMicrophoneDeviceIdDefaultsToNil() {
        let config = Config.default
        #expect(config.lastMicrophoneDeviceId == nil)
    }

    @Test func configDecodesWithoutLastMicrophoneDeviceId() throws {
        // Existing config.json files won't have this field — must still decode
        let json = """
        {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
        "output_format":"txt","launch_on_startup":true,"log_level":"info",\
        "suppress_capture_warning":false,"hf_token":""}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.lastMicrophoneDeviceId == nil)
    }
}
