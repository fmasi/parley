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
        #expect(config.suppressCaptureWarning == false)
        #expect(config.engine == .resolvedDefault)
        #expect(config.whisperCppModelPath == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        var config = Config.default
        config.engine = .fluidAudio
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.engine == .fluidAudio)
    }

    @Test func newFieldsSnakeCaseKeys() throws {
        let config = Config.default
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["engine"] != nil)
    }

    @Test func decodesLegacyConfigWithoutNewFields() throws {
        let json = """
        {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
        "output_format":"txt","launch_on_startup":true,\
        "suppress_capture_warning":false}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.engine == .resolvedDefault)
        #expect(config.whisperCppModelPath == nil)
    }

    @Test func memberWiseInit() {
        let config = Config(
            recordingDirectory: "/tmp/test",
            silenceTimeoutMinutes: 10,
            silenceDetectionEnabled: false,
            outputFormat: "srt",
            launchOnStartup: false,
            suppressCaptureWarning: true,
            engine: .fluidAudio
        )
        #expect(config.recordingDirectory == "/tmp/test")
        #expect(config.silenceTimeoutMinutes == 10)
        #expect(config.silenceDetectionEnabled == false)
        #expect(config.outputFormat == "srt")
        #expect(config.launchOnStartup == false)
        #expect(config.suppressCaptureWarning == true)
        #expect(config.engine == .fluidAudio)
    }

    // MARK: - Codable round-trip

    @Test func encodeDecodeRoundTrip() throws {
        let original = Config(
            recordingDirectory: "/tmp/recordings",
            silenceTimeoutMinutes: 3,
            silenceDetectionEnabled: false,
            outputFormat: "json",
            launchOnStartup: false,
            suppressCaptureWarning: true
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
        #expect(json["suppress_capture_warning"] != nil)
        #expect(json["engine"] != nil)
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
            "suppress_capture_warning": true,
            "engine": "fluid_audio"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.recordingDirectory == "/custom/path")
        #expect(config.silenceTimeoutMinutes == 8)
        #expect(config.outputFormat == "srt")
        #expect(config.engine == .fluidAudio)
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
        "suppress_capture_warning":false}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.lastMicrophoneDeviceId == nil)
    }

    // MARK: - Engine

    @Test func decodesUnknownEngineToDefault() throws {
        let json = """
        {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
        "output_format":"txt","launch_on_startup":true,\
        "suppress_capture_warning":false,"engine":"some_future_engine"}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.engine == .resolvedDefault)
    }

    @Test func whisperCppModelPathDefaultsToNil() {
        let config = Config.default
        #expect(config.whisperCppModelPath == nil)
    }

    @Test func whisperCppModelPathRoundTrips() throws {
        var config = Config.default
        config.whisperCppModelPath = "~/.audio-transcribe/models/ggml-large-v3.bin"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.whisperCppModelPath == "~/.audio-transcribe/models/ggml-large-v3.bin")
    }

    @Test func whisperCppModelPathSnakeCaseKey() throws {
        var config = Config.default
        config.whisperCppModelPath = "/some/path"
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["whisper_cpp_model_path"] != nil)
        #expect(json["whisperCppModelPath"] == nil)
    }
}
