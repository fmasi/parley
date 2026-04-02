# Engine Abstraction & Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded WhisperKit transcription engine with a registry of three swappable engines (SpeechAnalyzer, FluidAudio, WhisperCppKit) selectable by the user in Settings, defaulting to SpeechAnalyzer.

**Architecture:** An `EngineID` enum identifies engines. An `EngineDescriptor` struct holds static metadata (display name, OS requirements, download needs) for the Settings UI. The `TranscriptionEngine` protocol stays lean. `TranscriptionRunner` creates the selected engine from config. Config gains an `engine` field replacing `whisperModel`. WhisperKit code is removed entirely.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, FluidAudio, WhisperCppKit, Speech framework (macOS 26)

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `TranscriberCore/EngineID.swift` | Engine enum + descriptors |
| Modify | `TranscriberCore/Config.swift` | Replace `whisperModel` with `engine: EngineID` |
| Modify | `TranscriberCore/ConfigManager.swift` | Log engine instead of whisperModel |
| Modify | `TranscriberCore/FluidAudioEngine.swift` | Already created, adjust if needed |
| Modify | `TranscriberCore/WhisperCppEngine.swift` | Already created, adjust if needed |
| Modify | `TranscriberCore/SpeechAnalyzerEngine.swift` | Already created, adjust if needed |
| Modify | `TranscriberApp/Services/TranscriptionRunner.swift` | Engine selection from config |
| Modify | `TranscriberApp/Views/SettingsView.swift` | Engine picker replacing model picker |
| Modify | `TranscriberApp/TranscriberApp.swift` | Remove ModelManager from LaunchGate |
| Delete | `TranscriberCore/ModelManager.swift` | WhisperKit-specific, no longer needed |
| Delete | `TranscriberCore/WhisperKitTranscriber.swift` | Engine dropped |
| Modify | `SwiftTests/TranscriberTests/ConfigTests.swift` | Update for engine field |
| Create | `SwiftTests/TranscriberTests/EngineIDTests.swift` | Test EngineID, descriptors, factory |
| Delete | `SwiftTests/TranscriberTests/ModelManagerTests.swift` | Tests for removed code |
| Delete | `SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift` | Tests for removed code |

---

### Task 1: Create EngineID enum and descriptors

**Files:**
- Create: `TranscriberCore/EngineID.swift`
- Test: `SwiftTests/TranscriberTests/EngineIDTests.swift`

- [ ] **Step 1: Write failing tests for EngineID**

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct EngineIDTests {

    @Test func allCasesContainsThreeEngines() {
        #expect(EngineID.allCases.count == 3)
        #expect(EngineID.allCases.contains(.speechAnalyzer))
        #expect(EngineID.allCases.contains(.fluidAudio))
        #expect(EngineID.allCases.contains(.whisperCpp))
    }

    @Test func defaultIsSpeechAnalyzer() {
        #expect(EngineID.default == .speechAnalyzer)
    }

    @Test func codableRoundTrip() throws {
        for id in EngineID.allCases {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(EngineID.self, from: data)
            #expect(decoded == id)
        }
    }

    @Test func rawValuesAreSnakeCase() {
        #expect(EngineID.speechAnalyzer.rawValue == "speech_analyzer")
        #expect(EngineID.fluidAudio.rawValue == "fluid_audio")
        #expect(EngineID.whisperCpp.rawValue == "whisper_cpp")
    }

    @Test func descriptorExistsForEveryEngine() {
        for id in EngineID.allCases {
            let d = id.descriptor
            #expect(!d.displayName.isEmpty)
            #expect(!d.description.isEmpty)
        }
    }

    @Test func speechAnalyzerDescriptorNoDownload() {
        let d = EngineID.speechAnalyzer.descriptor
        #expect(d.requiresModelDownload == false)
        #expect(d.approximateSizeMB == 0)
        #expect(d.minimumMacOS == "26.0")
    }

    @Test func fluidAudioDescriptorDetails() {
        let d = EngineID.fluidAudio.descriptor
        #expect(d.requiresModelDownload == true)
        #expect(d.minimumMacOS == "15.0")
    }

    @Test func whisperCppDescriptorDetails() {
        let d = EngineID.whisperCpp.descriptor
        #expect(d.requiresModelDownload == true)
        #expect(d.minimumMacOS == "15.0")
    }

    @Test func availableEnginesExcludeUnavailable() {
        let available = EngineID.availableEngines
        // On any macOS version, at least FluidAudio and WhisperCpp are available
        #expect(available.contains(.fluidAudio))
        #expect(available.contains(.whisperCpp))
    }

    @Test func resolvedDefaultFallsBackWhenUnavailable() {
        // resolvedDefault should return an engine that is available on this OS
        let resolved = EngineID.resolvedDefault
        #expect(EngineID.availableEngines.contains(resolved))
    }

    @Test func decodesUnknownEngineToDefault() throws {
        let json = Data("\"some_future_engine\"".utf8)
        let decoded = try JSONDecoder().decode(EngineID.self, from: json)
        #expect(decoded == .default)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests.EngineIDTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -20`

Expected: compilation failure — `EngineID` not found.

- [ ] **Step 3: Implement EngineID**

Create `TranscriberCore/EngineID.swift`:

```swift
import Foundation

public struct EngineDescriptor: Sendable {
    public let displayName: String
    public let description: String
    public let requiresModelDownload: Bool
    public let approximateSizeMB: Int
    public let minimumMacOS: String

    public var isAvailableOnThisOS: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return minimumMacOS != "26.0"
    }
}

public enum EngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case speechAnalyzer = "speech_analyzer"
    case fluidAudio = "fluid_audio"
    case whisperCpp = "whisper_cpp"

    public var id: String { rawValue }

    public static let `default`: EngineID = .speechAnalyzer

    /// The default engine, falling back if the preferred default is unavailable on this OS.
    public static var resolvedDefault: EngineID {
        if EngineID.default.descriptor.isAvailableOnThisOS {
            return .default
        }
        return .fluidAudio
    }

    /// All engines available on the current OS version.
    public static var availableEngines: [EngineID] {
        allCases.filter { $0.descriptor.isAvailableOnThisOS }
    }

    public var descriptor: EngineDescriptor {
        switch self {
        case .speechAnalyzer:
            EngineDescriptor(
                displayName: "Apple Speech (recommended)",
                description: "Apple's built-in speech recognition. No download required.",
                requiresModelDownload: false,
                approximateSizeMB: 0,
                minimumMacOS: "26.0"
            )
        case .fluidAudio:
            EngineDescriptor(
                displayName: "FluidAudio",
                description: "Fast Parakeet model via CoreML. Downloads ~500MB on first use.",
                requiresModelDownload: true,
                approximateSizeMB: 500,
                minimumMacOS: "15.0"
            )
        case .whisperCpp:
            EngineDescriptor(
                displayName: "Whisper (whisper.cpp)",
                description: "OpenAI Whisper large-v3-turbo via whisper.cpp. Downloads ~1.6GB GGML model.",
                requiresModelDownload: true,
                approximateSizeMB: 1600,
                minimumMacOS: "15.0"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = EngineID(rawValue: raw) ?? .default
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests.EngineIDTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -20`

Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/EngineID.swift SwiftTests/TranscriberTests/EngineIDTests.swift
git commit -m "feat: add EngineID enum with descriptors for engine selection"
```

---

### Task 2: Update Config to use EngineID

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Update ConfigTests for engine field**

Replace all references to `whisperModel`, `modelStoragePath`, `modelUnloadTimeout` with `engine: EngineID`. Key changes:

In `defaultValues()`:
```swift
// Remove:
#expect(config.whisperModel == "large-v3-turbo")
#expect(config.modelStoragePath == "~/.audio-transcribe/models")
#expect(config.modelUnloadTimeout == 60)
// Add:
#expect(config.engine == .speechAnalyzer)
```

In `newFieldsRoundTrip()`:
```swift
// Replace body with:
var config = Config.default
config.engine = .fluidAudio
let data = try JSONEncoder().encode(config)
let decoded = try JSONDecoder().decode(Config.self, from: data)
#expect(decoded.engine == .fluidAudio)
```

In `newFieldsSnakeCaseKeys()`:
```swift
// Remove whisper_model, model_storage_path, model_unload_timeout checks
// Add:
#expect(json["engine"] != nil)
```

In `decodesLegacyConfigWithoutNewFields()`:
```swift
// After decoding legacy JSON (no engine key):
#expect(config.engine == .speechAnalyzer)
```

In `memberWiseInit()`:
```swift
// Remove whisperModel parameter, add engine:
let config = Config(
    recordingDirectory: "/tmp/test",
    silenceTimeoutMinutes: 10,
    silenceDetectionEnabled: false,
    outputFormat: "srt",
    launchOnStartup: false,
    suppressCaptureWarning: true,
    engine: .fluidAudio
)
#expect(config.engine == .fluidAudio)
```

In `snakeCaseKeys()`:
```swift
// Remove whisper_model check, add:
#expect(json["engine"] != nil)
```

Add new tests:
```swift
@Test func decodesUnknownEngineToDefault() throws {
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
    "output_format":"txt","launch_on_startup":true,\
    "suppress_capture_warning":false,"engine":"some_future_engine"}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.engine == .speechAnalyzer)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests.ConfigTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -20`

Expected: compilation failures — Config has no `engine` property.

- [ ] **Step 3: Update Config.swift**

Replace the three WhisperKit fields with `engine` and add an optional `whisperCppModelPath` for power users:

```swift
public struct Config: Codable, Equatable {
    public var recordingDirectory: String
    public var silenceTimeoutMinutes: Int
    public var silenceDetectionEnabled: Bool
    public var outputFormat: String
    public var launchOnStartup: Bool
    public var suppressCaptureWarning: Bool
    public var lastMicrophoneDeviceId: String?
    public var engine: EngineID
    /// Power-user config: path to a custom GGML model file for whisper.cpp engine.
    /// Not exposed in Settings UI. Edit ~/.audio-transcribe/config.json directly.
    /// Defaults to ~/.audio-transcribe/models/ggml-large-v3-turbo.bin if absent.
    public var whisperCppModelPath: String?

    public static let `default` = Config(
        recordingDirectory: NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: 5,
        silenceDetectionEnabled: true,
        outputFormat: "txt",
        launchOnStartup: true,
        suppressCaptureWarning: false,
        lastMicrophoneDeviceId: nil,
        engine: .speechAnalyzer,
        whisperCppModelPath: nil
    )

    public init(
        recordingDirectory: String = NSHomeDirectory() + "/Documents/Recordings",
        silenceTimeoutMinutes: Int = 5,
        silenceDetectionEnabled: Bool = true,
        outputFormat: String = "txt",
        launchOnStartup: Bool = true,
        suppressCaptureWarning: Bool = false,
        lastMicrophoneDeviceId: String? = nil,
        engine: EngineID = .speechAnalyzer,
        whisperCppModelPath: String? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.silenceTimeoutMinutes = silenceTimeoutMinutes
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.outputFormat = outputFormat
        self.launchOnStartup = launchOnStartup
        self.suppressCaptureWarning = suppressCaptureWarning
        self.lastMicrophoneDeviceId = lastMicrophoneDeviceId
        self.engine = engine
        self.whisperCppModelPath = whisperCppModelPath
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
        case whisperCppModelPath = "whisper_cpp_model_path"
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
        engine = try c.decodeIfPresent(EngineID.self, forKey: .engine) ?? .speechAnalyzer
        whisperCppModelPath = try c.decodeIfPresent(String.self, forKey: .whisperCppModelPath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests.ConfigTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -20`

Expected: all Config tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: replace whisperModel config fields with engine: EngineID"
```

---

### Task 3: Delete WhisperKit code and ModelManager

**Files:**
- Delete: `TranscriberCore/WhisperKitTranscriber.swift`
- Delete: `TranscriberCore/ModelManager.swift`
- Delete: `SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift`
- Delete: `SwiftTests/TranscriberTests/ModelManagerTests.swift`

- [ ] **Step 1: Read WhisperKitTranscriberTests.swift to confirm it only tests WhisperKit**

Verify the file contains only WhisperKitTranscriber tests and no shared test infrastructure.

- [ ] **Step 2: Delete the four files**

```bash
git rm TranscriberCore/WhisperKitTranscriber.swift
git rm TranscriberCore/ModelManager.swift
git rm SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift
git rm SwiftTests/TranscriberTests/ModelManagerTests.swift
```

- [ ] **Step 3: Remove WhisperKit from Package.swift dependencies**

In `Package.swift`, remove the WhisperKit package dependency and the two WhisperKit products from TranscriberCore:

```swift
// Remove from dependencies array:
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),

// Remove from TranscriberCore dependencies:
.product(name: "WhisperKit", package: "WhisperKit"),
.product(name: "SpeakerKit", package: "WhisperKit"),
```

Note: SpeakerKit (diarization) was bundled with WhisperKit. If `SpeakerKitDiarizer.swift` imports SpeakerKit, that file will need updating too. Check for any remaining `import WhisperKit` or `import SpeakerKit` references.

- [ ] **Step 4: Grep for remaining WhisperKit/ModelManager references and fix**

```bash
grep -rn "import WhisperKit\|import SpeakerKit\|ModelManager\|WhisperKitTranscriber\|whisperModel\|modelStoragePath\|modelUnloadTimeout" TranscriberCore/ TranscriberApp/ SwiftTests/ --include="*.swift"
```

Fix every hit. Key files likely affected:
- `TranscriberApp/TranscriberApp.swift` — `LaunchGate` uses `ModelManager`
- `TranscriberApp/Services/TranscriptionRunner.swift` — creates `WhisperKitTranscriber`
- `TranscriberApp/Views/SettingsView.swift` — model picker uses `ModelManager.availableModels`
- `TranscriberApp/Views/SetupView.swift` — may reference `ModelManager`
- `TranscriberCore/SpeakerKitDiarizer.swift` — imports `SpeakerKit`
- `TranscriberCore/ConfigManager.swift` — logs `whisperModel`

For `SpeakerKitDiarizer.swift`: SpeakerKit is being removed with WhisperKit. If diarization is needed, it should be addressed in a separate task. For now, keep the `DiarizationProvider` protocol and delete `SpeakerKitDiarizer.swift` (it depends on the removed package).

- [ ] **Step 5: Build to verify no compilation errors**

Run: `swift build 2>&1 | tail -20`

Expected: Build complete.

- [ ] **Step 6: Run all tests**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -30`

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: remove WhisperKit engine and ModelManager, drop SpeakerKit dependency"
```

---

### Task 4: Update TranscriptionRunner for engine selection

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

- [ ] **Step 1: Rewrite TranscriptionRunner to create engines from EngineID**

Replace the WhisperKit-specific engine creation with a factory method that reads `config.engine`:

```swift
import Foundation
import os
import TranscriberCore

struct TranscriptionResult {
    let jsonPath: URL
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case engineNotReady(String)
        case engineUnavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .engineNotReady(let name):
                return "Engine '\(name)' is not ready. It may need to download a model first."
            case .engineUnavailable(let name):
                return "Engine '\(name)' is not available on this version of macOS."
            case .failed(let msg):
                return msg
            }
        }
    }

    private var transcriber: (any TranscriptionEngine)?
    private var lastEngineID: EngineID?
    private var diarizer: (any DiarizationProvider)?

    /// Minimum WAV file size to consider non-empty (44 bytes = WAV header only).
    private let wavHeaderSize = 44

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // 1. Resolve engine, reuse if same engine for caching benefit
        let engineID = config.engine
        if transcriber == nil || lastEngineID != engineID {
            Logger.transcription.info("Creating engine: \(engineID.descriptor.displayName, privacy: .public)")
            transcriber = try createEngine(for: engineID, config: config)
            lastEngineID = engineID
        }

        guard let transcriber = transcriber else {
            throw RunnerError.failed("Failed to initialize transcription engine")
        }

        let isDualStream = micAudio != nil
        var allSegments: [LabeledSegment] = []

        // 2. Transcribe system audio (remote)
        let systemSegments = try await transcribeStream(
            audioPath: systemAudio,
            source: "remote",
            transcriber: transcriber,
            label: "system"
        )
        allSegments.append(contentsOf: systemSegments)

        // 3. Transcribe mic audio (local) if present
        if let micPath = micAudio {
            let micSegments = try await transcribeStream(
                audioPath: micPath,
                source: "local",
                transcriber: transcriber,
                label: "mic"
            )
            allSegments.append(contentsOf: micSegments)
        }

        // 4. If dual-stream, tag speakers with source prefix
        if isDualStream && !allSegments.isEmpty {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // 5. Sort all segments chronologically
        allSegments.sort { $0.start < $1.start }
        Logger.transcription.info("Total segments after merge: \(allSegments.count)")

        // 6. Build audio paths list for metadata
        var audioPaths = [systemAudio]
        if let mic = micAudio { audioPaths.append(mic) }

        let detectedLanguage = "en"  // TODO: capture from engine results in future

        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: diarizer != nil,
            dualStream: isDualStream
        )

        // 7. Write JSON output
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .public)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    func setDiarizer(_ provider: any DiarizationProvider) {
        self.diarizer = provider
    }

    // MARK: - Private

    private func createEngine(for id: EngineID, config: Config) throws -> any TranscriptionEngine {
        guard id.descriptor.isAvailableOnThisOS else {
            throw RunnerError.engineUnavailable(id.descriptor.displayName)
        }

        switch id {
        case .speechAnalyzer:
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerEngine()
            }
            // Fallback should not happen because isAvailableOnThisOS guards this
            throw RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")

        case .fluidAudio:
            return FluidAudioEngine()

        case .whisperCpp:
            let modelPath: URL
            if let custom = config.whisperCppModelPath {
                modelPath = URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
            } else {
                modelPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".audio-transcribe/models/ggml-large-v3-turbo.bin")
            }
            return WhisperCppEngine(modelPath: modelPath)
        }
    }

    private func transcribeStream(
        audioPath: URL,
        source: String,
        transcriber: any TranscriptionEngine,
        label: String
    ) async throws -> [LabeledSegment] {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return []
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .public) (\(fileSize) bytes)")

        let segments = try await transcriber.transcribe(audioPath: audioPath, language: nil)

        var labeled: [LabeledSegment]
        if let diarizer = diarizer {
            let diarizedSegments = try await diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
            labeled = SpeakerAssignment.assign(
                transcriptSegments: segments,
                diarizationSegments: diarizedSegments
            )
        } else {
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: ""
                )
            }
        }

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return labeled
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -20`

Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "refactor: TranscriptionRunner creates engines from config.engine EngineID"
```

---

### Task 5: Update Settings UI with engine picker

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Replace model picker with engine picker**

Replace the "Transcription Model" section with an engine selection section:

```swift
Section("Transcription Engine") {
    Picker("Engine", selection: $config.engine) {
        ForEach(EngineID.allCases) { engine in
            HStack {
                Text(engine.descriptor.displayName)
                if !engine.descriptor.isAvailableOnThisOS {
                    Text("(requires macOS \(engine.descriptor.minimumMacOS))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(engine)
        }
    }

    if config.engine.descriptor.requiresModelDownload {
        Text("First use will download ~\(config.engine.descriptor.approximateSizeMB)MB")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

Remove any imports or references to `ModelManager`.

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -20`

Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: replace model picker with engine selection in Settings"
```

---

### Task 6: Update LaunchGate and SetupView

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift`
- Modify: `TranscriberApp/Views/SetupView.swift` (if it references ModelManager)

- [ ] **Step 1: Read SetupView.swift**

Check if SetupView references ModelManager or model download status.

- [ ] **Step 2: Update LaunchGate in TranscriberApp.swift**

Remove `ModelManager` from `LaunchGate`. The model download check is no longer a launch gate — engines handle their own model management at transcription time.

```swift
@MainActor
@Observable
final class LaunchGate {
    var permissionsReady = false
    let permissionManager: PermissionManager

    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
    }

    func checkAndGate() async {
        await permissionManager.checkAll()
        if permissionManager.allRequiredGranted {
            permissionsReady = true
        } else {
            SetupWindowController.shared.show(
                permissionManager: permissionManager
            ) { [weak self] in
                self?.permissionsReady = true
            }
        }
    }
}
```

Note: `SetupWindowController.shared.show()` signature may need updating if it took a `modelManager` parameter. Check and remove that parameter.

- [ ] **Step 3: Update SetupView.swift and SetupWindowController.swift**

Remove ModelManager references from SetupWindowController.show() and SetupView if present. The setup flow should only gate on permissions, not model download.

- [ ] **Step 4: Update ConfigManager.swift log line**

In `ConfigManager.swift`, change the log line from:
```swift
Logger.config.info("Config loaded — format: \(config.outputFormat, privacy: .public), whisperModel: \(config.whisperModel, privacy: .public)")
```
to:
```swift
Logger.config.info("Config loaded — format: \(config.outputFormat, privacy: .public), engine: \(config.engine.rawValue, privacy: .public)")
```

- [ ] **Step 5: Build and run all tests**

```bash
swift build 2>&1 | tail -10
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -30
```

Expected: Build complete, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove ModelManager from LaunchGate, engines manage own models"
```

---

### Task 7: Grep cleanup and CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`
- Various files: any remaining stale references

- [ ] **Step 1: Final grep for stale references**

```bash
grep -rn "WhisperKit\|whisperModel\|whisper_model\|ModelManager\|modelStorage\|modelUnload\|SpeakerKit\|WhisperKitTranscriber" --include="*.swift" --include="*.md" TranscriberCore/ TranscriberApp/ SwiftTests/ CLAUDE.md
```

Fix any remaining hits. Expect hits in CLAUDE.md only at this point.

- [ ] **Step 2: Update CLAUDE.md**

Update the project instructions to reflect the new engine architecture:
- Replace WhisperKit references with the engine abstraction
- Update architecture section to list the three engines
- Update the "Key Gotchas" section (remove WhisperKit-specific items, add engine selection)
- Add `TranscriberCore/EngineID.swift` to the architecture listing
- Update config field descriptions

- [ ] **Step 3: Run full test suite one final time**

```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: update CLAUDE.md for engine abstraction, remove WhisperKit references"
```

---

## Post-Implementation Notes

After this plan is complete, the following remain as **separate future tasks** (not in scope):

1. **Multi-language benchmark** — download FLEURS test audio and run all 3 engines across FR/PT/ES/TR/FI/KO/JA to validate quality
2. **GGML model download UX** — WhisperCpp needs a download flow for the GGML model file (defaults to `~/.audio-transcribe/models/ggml-large-v3-turbo.bin`, overridable via `whisper_cpp_model_path` in config.json)
3. **Diarization replacement** — SpeakerKit was removed with WhisperKit. Evaluate FluidAudio's built-in diarization or Apple's SpeechAnalyzer capabilities as replacements
4. **Engine-specific Settings** — e.g., language override per engine, model variant for whisper.cpp
5. **Disable unavailable engines in picker** — grey out SpeechAnalyzer on macOS < 26 (currently shown but will fail at runtime)
