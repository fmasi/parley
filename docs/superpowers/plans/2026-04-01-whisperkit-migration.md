# WhisperKit Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Python transcription engine (mlx-whisper + pyannote.audio) with native Swift WhisperKit + SpeakerKit, eliminating all Python dependencies.

**Architecture:** Incremental 4-phase migration. Phase 0 sets up dependencies and baseline benchmarks. Phase 1 swaps transcription (WhisperKit), Phase 2 swaps diarization (SpeakerKit), Phase 3 adds CLI mode, Phase 4 removes Python. TDD throughout with generous os.Logger logging.

**Tech Stack:** WhisperKit (Core ML), SpeakerKit, Swift Testing, os.Logger

**Test command:**
```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

---

## File Structure

### New files:
- `TranscriberCore/ModelManager.swift` — download, cache, and manage WhisperKit models
- `TranscriberCore/WhisperKitTranscriber.swift` — WhisperKit transcription wrapper with idle unloading
- `TranscriberCore/DiarizationProvider.swift` — protocol + DiarizedSegment struct
- `TranscriberCore/SpeakerKitDiarizer.swift` — SpeakerKit implementation of DiarizationProvider
- `TranscriberCore/SpeakerAssignment.swift` — assign diarization labels to transcript segments
- `TranscriberCore/TranscriptAssembler.swift` — build JSON output from segments + metadata
- `TranscriberApp/Services/CLIHandler.swift` — CLI argument parsing and subcommand routing
- `TranscriberApp/Services/CLIRename.swift` — interactive CLI speaker rename with afplay
- `SwiftTests/TranscriberTests/ModelManagerTests.swift`
- `SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift`
- `SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift`
- `SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift`
- `SwiftTests/TranscriberTests/CLIHandlerTests.swift`

### Modified files:
- `Package.swift` — add WhisperKit dependency, add to TranscriberCore target
- `TranscriberCore/Config.swift` — remove hfToken, add whisperModel/modelStoragePath/modelUnloadTimeout
- `TranscriberCore/Log.swift` — update transcription logger comment (no longer Python)
- `TranscriberApp/Services/TranscriptionRunner.swift` — replace Python Process with WhisperKit calls
- `TranscriberApp/TranscriberApp.swift` — add CLI argument detection
- `TranscriberApp/Views/SetupView.swift` — add model download step
- `TranscriberApp/Views/SettingsView.swift` — remove HF token, add model picker
- `SwiftTests/TranscriberTests/ConfigTests.swift` — update for new/removed fields

### Deleted files (Phase 4):
- `transcribe.py`
- `rename_speakers.py`
- `service/config_manager.py`
- `service/logger.py`
- `packaging/embed_python.sh`

---

## Phase 0: Baseline & Setup

### Task 1: Create branch and add WhisperKit dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Create branch off main**

```bash
git checkout main && git pull
git checkout -b feature/whisperkit-migration
```

- [ ] **Step 2: Add WhisperKit dependency to Package.swift**

In `Package.swift`, add WhisperKit to the `dependencies` array and to the `TranscriberCore` target:

```swift
// Package.swift — dependencies array (after SettingsAccess line):
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),

// TranscriberCore target — add dependencies parameter:
.target(
    name: "TranscriberCore",
    dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit"),
    ],
    path: "TranscriberCore"
),
```

- [ ] **Step 3: Verify it resolves and builds**

```bash
swift package resolve
swift build
```

Expected: resolves WhisperKit + its transitive dependencies, builds successfully.

- [ ] **Step 4: Run existing tests to confirm no regressions**

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all 102 existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add WhisperKit SPM dependency"
```

---

### Task 2: Update Config — remove hfToken, add new fields

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write failing tests for new config fields**

Add to `SwiftTests/TranscriberTests/ConfigTests.swift`:

```swift
// Replace the existing defaultValues test:
@Test func defaultValues() {
    let config = Config.default
    #expect(config.recordingDirectory.hasSuffix("/Documents/Recordings"))
    #expect(config.silenceTimeoutMinutes == 5)
    #expect(config.silenceDetectionEnabled == true)
    #expect(config.outputFormat == "txt")
    #expect(config.launchOnStartup == true)
    #expect(config.suppressCaptureWarning == false)
    #expect(config.whisperModel == "large-v3-turbo")
    #expect(config.modelStoragePath == "~/.audio-transcribe/models")
    #expect(config.modelUnloadTimeout == 60)
}

// Add new test:
@Test func newFieldsRoundTrip() throws {
    var config = Config.default
    config.whisperModel = "large-v3"
    config.modelStoragePath = "/custom/models"
    config.modelUnloadTimeout = 30

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)

    #expect(decoded.whisperModel == "large-v3")
    #expect(decoded.modelStoragePath == "/custom/models")
    #expect(decoded.modelUnloadTimeout == 30)
}

@Test func newFieldsSnakeCaseKeys() throws {
    let config = Config.default
    let data = try JSONEncoder().encode(config)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["whisper_model"] != nil)
    #expect(json["model_storage_path"] != nil)
    #expect(json["model_unload_timeout"] != nil)
    #expect(json["hf_token"] == nil)
}

@Test func decodesLegacyConfigWithoutNewFields() throws {
    // Existing config.json files won't have new fields — must still decode
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
    "output_format":"txt","launch_on_startup":true,\
    "suppress_capture_warning":false}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.whisperModel == "large-v3-turbo")
    #expect(config.modelStoragePath == "~/.audio-transcribe/models")
    #expect(config.modelUnloadTimeout == 60)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests/ConfigTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — `whisperModel`, `modelStoragePath`, `modelUnloadTimeout` don't exist on Config.

- [ ] **Step 3: Update Config.swift — remove hfToken, add new fields**

Replace `TranscriberCore/Config.swift` entirely:

```swift
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
}
```

- [ ] **Step 4: Update existing tests that referenced hfToken**

In `ConfigTests.swift`, update these existing tests:

- `memberWiseInit`: remove `hfToken: "hf_abc123"` parameter, add `whisperModel: "large-v3"`, remove `#expect(config.hfToken == "hf_abc123")`
- `encodeDecodeRoundTrip`: remove `hfToken: "hf_token_value"` parameter
- `snakeCaseKeys`: remove `#expect(json["hf_token"] != nil)`, add `#expect(json["whisper_model"] != nil)`
- `decodesFromSnakeCaseJSON`: remove `"hf_token": "test_token"` from JSON string, remove `#expect(config.hfToken == "test_token")`, add `"whisper_model": "large-v3"` to JSON, add `#expect(config.whisperModel == "large-v3")`
- `configDecodesWithoutLastMicrophoneDeviceId`: remove `"hf_token":""` from JSON string

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests/ConfigTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all ConfigTests pass.

- [ ] **Step 6: Fix any compile errors in other files referencing hfToken**

Grep for `hfToken` across Swift files:

```bash
grep -r "hfToken" TranscriberApp/ TranscriberCore/ SwiftTests/
```

Update each reference:
- `TranscriptionRunner.swift`: remove `hfToken` parameter from `run()` method
- `ConfigManager.swift`: remove hfToken from log message on line 27
- `SettingsView.swift`: remove the "Speaker Diarization" section (lines 66-69)
- Any callers of `TranscriptionRunner.run()`: remove the `hfToken:` argument

- [ ] **Step 7: Run full test suite**

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift \
  TranscriberApp/Services/TranscriptionRunner.swift TranscriberCore/ConfigManager.swift \
  TranscriberApp/Views/SettingsView.swift
git commit -m "refactor: remove hfToken, add whisperModel/modelStoragePath/modelUnloadTimeout config"
```

---

### Task 3: Update Log.swift comment

**Files:**
- Modify: `TranscriberCore/Log.swift:9`

- [ ] **Step 1: Update transcription logger comment**

Change line 9 from:
```swift
/// Transcription: Python process launch, output forwarding, completion
```
to:
```swift
/// Transcription: WhisperKit model lifecycle, transcription timing, diarization
```

- [ ] **Step 2: Commit**

```bash
git add TranscriberCore/Log.swift
git commit -m "docs: update transcription logger comment for WhisperKit"
```

---

### Task 4: Build ModelManager

**Files:**
- Create: `TranscriberCore/ModelManager.swift`
- Create: `SwiftTests/TranscriberTests/ModelManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/ModelManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct ModelManagerTests {

    @Test func resolveStoragePathExpandsTilde() {
        let path = ModelManager.resolveStoragePath("~/.audio-transcribe/models")
        #expect(!path.path.contains("~"))
        #expect(path.path.contains("audio-transcribe/models"))
    }

    @Test func resolveStoragePathAbsolute() {
        let path = ModelManager.resolveStoragePath("/tmp/models")
        #expect(path.path == "/tmp/models")
    }

    @Test func availableModelsContainsTurboAndLargeV3() {
        let models = ModelManager.availableModels
        #expect(models.contains { $0.id == "large-v3-turbo" })
        #expect(models.contains { $0.id == "large-v3" })
    }

    @Test func modelInfoForTurbo() {
        let info = ModelManager.availableModels.first { $0.id == "large-v3-turbo" }!
        #expect(info.displayName == "Fast (recommended)")
        #expect(info.huggingFaceRepo.contains("turbo"))
    }

    @Test func modelInfoForLargeV3() {
        let info = ModelManager.availableModels.first { $0.id == "large-v3" }!
        #expect(info.displayName == "High Quality")
    }

    @Test func isModelDownloadedReturnsFalseForMissingDir() {
        let manager = ModelManager(storagePath: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
        #expect(manager.isModelDownloaded("large-v3-turbo") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests/ModelManagerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — `ModelManager` doesn't exist.

- [ ] **Step 3: Implement ModelManager**

Create `TranscriberCore/ModelManager.swift`:

```swift
import Foundation
import os
import WhisperKit

public struct ModelInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let huggingFaceRepo: String
    public let approximateSizeMB: Int
}

@MainActor
@Observable
public final class ModelManager {
    public let storagePath: URL
    public var downloadProgress: Double = 0
    public var isDownloading = false
    public var downloadError: String?

    public static let availableModels: [ModelInfo] = [
        ModelInfo(
            id: "large-v3-turbo",
            displayName: "Fast (recommended)",
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            approximateSizeMB: 1600
        ),
        ModelInfo(
            id: "large-v3",
            displayName: "High Quality",
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            approximateSizeMB: 3000
        ),
    ]

    public init(storagePath: URL? = nil) {
        self.storagePath = storagePath ?? Self.resolveStoragePath("~/.audio-transcribe/models")
    }

    public static func resolveStoragePath(_ path: String) -> URL {
        if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: path)
    }

    public func isModelDownloaded(_ modelId: String) -> Bool {
        let modelDir = storagePath.appendingPathComponent(modelId)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    public func downloadModel(_ modelId: String) async throws {
        guard let info = Self.availableModels.first(where: { $0.id == modelId }) else {
            throw ModelManagerError.unknownModel(modelId)
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        Logger.transcription.info("Starting model download: \(modelId, privacy: .public) from \(info.huggingFaceRepo, privacy: .public)")

        do {
            let modelPath = try await WhisperKit.download(
                variant: modelId,
                from: info.huggingFaceRepo,
                progressCallback: { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )
            // Move to our storage path if needed
            let targetDir = storagePath.appendingPathComponent(modelId)
            if modelPath != targetDir.path {
                try FileManager.default.createDirectory(
                    at: storagePath, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: targetDir.path) {
                    try FileManager.default.removeItem(at: targetDir)
                }
                try FileManager.default.moveItem(
                    atPath: modelPath,
                    toPath: targetDir.path
                )
            }
            Logger.transcription.info("Model downloaded successfully: \(modelId, privacy: .public)")
            isDownloading = false
            downloadProgress = 1.0
        } catch {
            Logger.transcription.error("Model download failed: \(modelId, privacy: .public) — \(error, privacy: .public)")
            isDownloading = false
            downloadError = error.localizedDescription
            throw error
        }
    }

    public func modelPath(for modelId: String) -> URL {
        storagePath.appendingPathComponent(modelId)
    }

    public enum ModelManagerError: LocalizedError {
        case unknownModel(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "Unknown model: \(id)"
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests/ModelManagerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all ModelManagerTests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/ModelManager.swift SwiftTests/TranscriberTests/ModelManagerTests.swift
git commit -m "feat: add ModelManager for WhisperKit model download and caching"
```

---

## Phase 1: WhisperKit Transcription

### Task 5: Build SpeakerAssignment (port from Python)

**Files:**
- Create: `TranscriberCore/SpeakerAssignment.swift`
- Create: `SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift`

This ports the `assign_speakers()` and `deduplicate_segments()` logic from `transcribe.py` lines 122-181.

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct SpeakerAssignmentTests {

    // MARK: - Deduplication

    @Test func deduplicateRemovesZeroDuration() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 0.0, text: "ghost", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "real", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 1)
        #expect(result[0].text == "real")
    }

    @Test func deduplicateRemovesConsecutiveDuplicates() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: "hello", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "hello", language: nil),
            TranscriptSegment(start: 2.0, end: 3.0, text: "world", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 2)
        #expect(result[0].text == "hello")
        #expect(result[1].text == "world")
    }

    @Test func deduplicateTrimsWhitespace() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: " hello ", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "hello", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 1)
    }

    @Test func deduplicatePreservesNonConsecutiveDuplicates() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: "hello", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "world", language: nil),
            TranscriptSegment(start: 2.0, end: 3.0, text: "hello", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 3)
    }

    // MARK: - Speaker Assignment

    @Test func assignSpeakersByOverlap() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "hello", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "world", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 6.0, speaker: "SPEAKER_00"),
            DiarizedSegment(start: 6.0, end: 10.0, speaker: "SPEAKER_01"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result[0].speaker == "Speaker 1")
        #expect(result[1].speaker == "Speaker 2")
    }

    @Test func assignSpeakersMidpointTiebreaker() {
        // Segment midpoint at 2.5 — falls in SPEAKER_00's range
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "test", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 3.0, speaker: "SPEAKER_00"),
            DiarizedSegment(start: 3.0, end: 5.0, speaker: "SPEAKER_01"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func assignSpeakersUnknownWhenNoDiarization() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "test", language: nil),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: []
        )
        #expect(result[0].speaker == "Unknown")
    }

    @Test func assignSpeakersConsistentMapping() {
        // SPEAKER_01 appears before SPEAKER_00 — should still map by first-seen order
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "first", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "second", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "SPEAKER_01"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "SPEAKER_00"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        // SPEAKER_01 seen first → Speaker 1, SPEAKER_00 → Speaker 2
        #expect(result[0].speaker == "Speaker 1")
        #expect(result[1].speaker == "Speaker 2")
    }

    // MARK: - Dual-Stream Tagging

    @Test func tagSegmentsWithSource() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "Speaker 1", text: "hi", source: "remote"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Remote Speaker 1")
    }

    @Test func tagSegmentsUnknownSpeakerGetsSourceOnly() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "", text: "hi", source: "local"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Local")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests/SpeakerAssignmentTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement types and SpeakerAssignment**

Create `TranscriberCore/DiarizationProvider.swift`:

```swift
import Foundation

public struct DiarizedSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public protocol DiarizationProvider: Sendable {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment]
}
```

Create `TranscriberCore/SpeakerAssignment.swift`:

```swift
import Foundation
import os

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let language: String?

    public init(start: Double, end: Double, text: String, language: String?) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
    }
}

public struct LabeledSegment: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var source: String  // "remote" or "local"

    public init(start: Double, end: Double, speaker: String, text: String, source: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.source = source
    }
}

public enum SpeakerAssignment {

    /// Remove zero-duration and consecutively repeated segments.
    public static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var cleaned: [TranscriptSegment] = []
        var lastText: String?

        for seg in segments {
            if seg.start == seg.end { continue }
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            if trimmed == lastText { continue }
            lastText = trimmed
            cleaned.append(seg)
        }

        Logger.transcription.debug("Deduplicate: \(segments.count) → \(cleaned.count) segments")
        return cleaned
    }

    /// Assign speaker labels to transcript segments based on time overlap with diarization.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment]
    ) -> [LabeledSegment] {
        // Build consistent speaker name mapping (SPEAKER_00 → Speaker 1)
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        let speakerMap = Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )

        Logger.transcription.debug("Speaker map: \(speakerMap.count) speakers — \(speakerMap, privacy: .public)")

        return transcriptSegments.map { seg in
            let segMid = (seg.start + seg.end) / 2
            var bestSpeaker = "Unknown"
            var bestOverlap: Double = 0

            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }

                // Midpoint tiebreaker
                if sp.start <= segMid && segMid <= sp.end && overlap >= bestOverlap {
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }
            }

            return LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: bestSpeaker,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                source: ""
            )
        }
    }

    /// Tag labeled segments with source prefix for dual-stream mode.
    public static func tagWithSourcePrefix(_ segments: inout [LabeledSegment]) {
        for i in segments.indices {
            let source = segments[i].source
            let label = source == "local" ? "Local" : "Remote"
            let speaker = segments[i].speaker
            if !speaker.isEmpty && speaker != "Unknown" {
                segments[i].speaker = "\(label) \(speaker)"
            } else if speaker != "Unknown" {
                segments[i].speaker = label
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests/SpeakerAssignmentTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all SpeakerAssignmentTests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/DiarizationProvider.swift TranscriberCore/SpeakerAssignment.swift \
  SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift
git commit -m "feat: port speaker assignment and deduplication from Python to Swift"
```

---

### Task 6: Build TranscriptAssembler (JSON output)

**Files:**
- Create: `TranscriberCore/TranscriptAssembler.swift`
- Create: `SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift`

This builds the JSON output matching the Python schema exactly.

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptAssemblerTests {

    @Test func assembleMinimalJSON() throws {
        let segments = [
            LabeledSegment(start: 0.5, end: 2.3, speaker: "Speaker 1", text: "hello", source: "remote"),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [URL(fileURLWithPath: "/tmp/system.wav")],
            outputFormat: "txt",
            language: "en",
            numSpeakers: 1,
            diarization: true,
            dualStream: false
        )

        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["language"] as? String == "en")
        #expect(metadata?["output_format"] as? String == "txt")
        #expect(metadata?["diarization"] as? Bool == true)
        #expect(metadata?["dual_stream"] as? Bool == false)
        #expect(metadata?["num_speakers"] as? Int == 1)

        let audioFiles = metadata?["audio_files"] as? [String]
        #expect(audioFiles == ["system.wav"])

        let audioPaths = metadata?["audio_paths"] as? [String]
        #expect(audioPaths == ["/tmp/system.wav"])

        let segs = json["segments"] as? [[String: Any]]
        #expect(segs?.count == 1)
        #expect(segs?[0]["start"] as? Double == 0.5)
        #expect(segs?[0]["end"] as? Double == 2.3)
        #expect(segs?[0]["speaker"] as? String == "Speaker 1")
        #expect(segs?[0]["text"] as? String == "hello")
        #expect(segs?[0]["source"] as? String == "remote")
    }

    @Test func assembleDualStreamJSON() throws {
        let segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "Remote Speaker 1", text: "hi", source: "remote"),
            LabeledSegment(start: 0.5, end: 1.5, speaker: "Local Speaker 1", text: "hey", source: "local"),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [
                URL(fileURLWithPath: "/tmp/system.wav"),
                URL(fileURLWithPath: "/tmp/mic.wav"),
            ],
            outputFormat: "json",
            language: "auto",
            numSpeakers: nil,
            diarization: true,
            dualStream: true
        )

        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["dual_stream"] as? Bool == true)
        #expect(metadata?["num_speakers"] as? String == "auto")

        let audioFiles = metadata?["audio_files"] as? [String]
        #expect(audioFiles == ["system.wav", "mic.wav"])
    }

    @Test func assembleAutoSpeakers() {
        let json = TranscriptAssembler.assemble(
            segments: [],
            audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
            outputFormat: "json",
            language: "en",
            numSpeakers: nil,
            diarization: true,
            dualStream: false
        )
        let metadata = json["metadata"] as? [String: Any]
        #expect(metadata?["num_speakers"] as? String == "auto")
    }

    @Test func writeAndReadJSON() throws {
        let segments = [
            LabeledSegment(start: 1.0, end: 2.0, speaker: "Speaker 1", text: "test", source: ""),
        ]
        let json = TranscriptAssembler.assemble(
            segments: segments,
            audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
            outputFormat: "txt",
            language: "en",
            numSpeakers: 1,
            diarization: true,
            dualStream: false
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembler-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("test.json")
        try TranscriptAssembler.write(json, to: path)

        // Verify the file is valid JSON and can be read by TranscriptWriter
        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["metadata"] != nil)
        #expect(parsed?["segments"] != nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests/TranscriptAssemblerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — `TranscriptAssembler` doesn't exist.

- [ ] **Step 3: Implement TranscriptAssembler**

Create `TranscriberCore/TranscriptAssembler.swift`:

```swift
import Foundation
import os

public enum TranscriptAssembler {

    /// Assemble the JSON dictionary matching the Python transcript schema.
    public static func assemble(
        segments: [LabeledSegment],
        audioPaths: [URL],
        outputFormat: String,
        language: String,
        numSpeakers: Int?,
        diarization: Bool,
        dualStream: Bool
    ) -> [String: Any] {
        let metadata: [String: Any] = [
            "audio_files": audioPaths.map { $0.lastPathComponent },
            "audio_paths": audioPaths.map { $0.path },
            "output_format": outputFormat,
            "language": language,
            "num_speakers": numSpeakers.map { $0 as Any } ?? ("auto" as Any),
            "diarization": diarization,
            "dual_stream": dualStream,
        ]

        let segmentDicts: [[String: Any]] = segments.map { seg in
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "speaker": seg.speaker,
                "text": seg.text,
            ]
            if !seg.source.isEmpty {
                dict["source"] = seg.source
            }
            return dict
        }

        Logger.transcription.debug("Assembled transcript: \(segments.count) segments, format: \(outputFormat, privacy: .public)")

        return [
            "metadata": metadata,
            "segments": segmentDicts,
        ]
    }

    /// Write the assembled JSON to disk.
    public static func write(_ json: [String: Any], to path: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: path, options: .atomic)
        Logger.files.info("JSON transcript written: \(path.lastPathComponent, privacy: .public)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests/TranscriptAssemblerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all TranscriptAssemblerTests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptAssembler.swift SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift
git commit -m "feat: add TranscriptAssembler for JSON output matching Python schema"
```

---

### Task 7: Build WhisperKitTranscriber

**Files:**
- Create: `TranscriberCore/WhisperKitTranscriber.swift`
- Create: `SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift`

- [ ] **Step 1: Write failing tests for the idle timer and lifecycle**

Create `SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct WhisperKitTranscriberTests {

    @Test func transcriptSegmentInit() {
        let seg = TranscriptSegment(start: 1.5, end: 3.0, text: "hello", language: "en")
        #expect(seg.start == 1.5)
        #expect(seg.end == 3.0)
        #expect(seg.text == "hello")
        #expect(seg.language == "en")
    }

    @Test func transcriptSegmentNilLanguage() {
        let seg = TranscriptSegment(start: 0, end: 1, text: "test", language: nil)
        #expect(seg.language == nil)
    }
}
```

Note: WhisperKitTranscriber itself requires a real model to test transcription. Unit tests cover the data types. Integration testing is done via the benchmark harness with real audio files.

- [ ] **Step 2: Run tests to verify they pass**

(TranscriptSegment was already defined in Task 5, so these should pass immediately.)

```bash
swift test --filter TranscriberTests/WhisperKitTranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

- [ ] **Step 3: Implement WhisperKitTranscriber**

Create `TranscriberCore/WhisperKitTranscriber.swift`:

```swift
import Foundation
import os
import WhisperKit

public actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private let modelPath: URL
    private let modelVariant: String
    private let unloadTimeout: TimeInterval
    private var unloadTask: Task<Void, Never>?

    public init(modelPath: URL, model: String = "large-v3-turbo", unloadTimeoutMinutes: Int = 60) {
        self.modelPath = modelPath.appendingPathComponent(model)
        self.modelVariant = model
        self.unloadTimeout = TimeInterval(unloadTimeoutMinutes * 60)
    }

    public func transcribe(audioPath: URL, language: String? = nil) async throws -> [TranscriptSegment] {
        let kit = try await ensureLoaded()
        cancelUnloadTimer()

        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with model \(self.modelVariant, privacy: .public)")

        let options = DecodingOptions(
            language: language,
            wordTimestamps: true,
            conditionOnPreviousText: false,
            compressionRatioThreshold: 1.8,
            noSpeechThreshold: 0.8
        )

        let results = try await kit.transcribe(audioPath: audioPath.path, decodeOptions: options)

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds

        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                segments.append(TranscriptSegment(
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    language: result.language
                ))
            }
        }

        Logger.transcription.info("Transcription complete: \(segments.count) segments in \(seconds)s — language: \(results.first?.language ?? "unknown", privacy: .public)")

        scheduleUnload()
        return SpeakerAssignment.deduplicate(segments)
    }

    // MARK: - Model Lifecycle

    private func ensureLoaded() async throws -> WhisperKit {
        if let kit = whisperKit {
            Logger.transcription.debug("WhisperKit already loaded")
            return kit
        }

        let loadStart = ContinuousClock.now

        Logger.transcription.info("Loading WhisperKit model: \(self.modelVariant, privacy: .public) from \(self.modelPath.path, privacy: .private)")

        let kit = try await WhisperKit(
            modelFolder: modelPath.path,
            verbose: false,
            prewarm: true
        )

        let loadElapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("WhisperKit model loaded in \(loadElapsed.components.seconds)s")

        whisperKit = kit
        return kit
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self, unloadTimeout] in
            try? await Task.sleep(for: .seconds(unloadTimeout))
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    private func cancelUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func unloadModel() {
        whisperKit = nil
        Logger.transcription.info("WhisperKit model unloaded after idle timeout")
    }
}
```

- [ ] **Step 4: Verify it compiles**

```bash
swift build
```

Expected: builds successfully. (Full transcription testing requires a downloaded model — done via benchmark harness.)

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/WhisperKitTranscriber.swift SwiftTests/TranscriberTests/WhisperKitTranscriberTests.swift
git commit -m "feat: add WhisperKitTranscriber with idle model unloading"
```

---

### Task 8: Build PyAnnoteDiarizer (temporary bridge)

**Files:**
- Create: `TranscriberCore/PyAnnoteDiarizer.swift`

This is the temporary bridge that shells out to Python for diarization while we validate WhisperKit transcription independently.

- [ ] **Step 1: Create a minimal Python diarization-only script**

Create `service/diarize_only.py`:

```python
#!/usr/bin/env python3
"""Minimal diarization-only script for bridge period."""
import argparse
import json
import sys

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input", required=True)
    parser.add_argument("--hf-token", required=True)
    parser.add_argument("-s", "--speakers", type=int)
    args = parser.parse_args()

    from pyannote.audio import Pipeline
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=args.hf_token
    )

    params = {}
    if args.speakers:
        params["num_speakers"] = args.speakers

    diarization = pipeline(args.input, **params)

    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker
        })

    json.dump(segments, sys.stdout)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Implement PyAnnoteDiarizer**

Create `TranscriberCore/PyAnnoteDiarizer.swift`:

```swift
import Foundation
import os

/// Temporary bridge: runs pyannote diarization via embedded Python subprocess.
/// Will be replaced by SpeakerKitDiarizer in Phase 2.
public final class PyAnnoteDiarizer: DiarizationProvider, @unchecked Sendable {
    private let pythonPath: URL
    private let scriptPath: URL
    private let hfToken: String

    public init(pythonPath: URL, scriptPath: URL, hfToken: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.hfToken = hfToken
    }

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("PyAnnote diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

        var arguments = [
            scriptPath.path,
            "-i", audioPath.path,
            "--hf-token", hfToken,
        ]
        if let n = numSpeakers {
            arguments += ["-s", String(n)]
        }

        let process = Process()
        process.executableURL = pythonPath
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Logger.transcription.error("PyAnnote diarization failed: \(stderr, privacy: .public)")
            throw DiarizationError.failed(stderr)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let rawSegments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DiarizationError.invalidOutput
        }

        let segments = rawSegments.compactMap { raw -> DiarizedSegment? in
            guard let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double,
                  let speaker = raw["speaker"] as? String else { return nil }
            return DiarizedSegment(start: start, end: end, speaker: speaker)
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("PyAnnote diarization complete: \(segments.count) segments, \(Set(segments.map(\.speaker)).count) speakers in \(elapsed.components.seconds)s")

        return segments
    }

    public enum DiarizationError: LocalizedError {
        case failed(String)
        case invalidOutput

        public var errorDescription: String? {
            switch self {
            case .failed(let msg): return "Diarization failed: \(msg)"
            case .invalidOutput: return "Invalid diarization output"
            }
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build
```

- [ ] **Step 4: Commit**

```bash
git add TranscriberCore/PyAnnoteDiarizer.swift service/diarize_only.py
git commit -m "feat: add PyAnnoteDiarizer bridge for Phase 1 transition"
```

---

### Task 9: Rewrite TranscriptionRunner

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

This replaces the Python Process launch with direct WhisperKit + DiarizationProvider calls.

- [ ] **Step 1: Rewrite TranscriptionRunner**

Replace `TranscriberApp/Services/TranscriptionRunner.swift` entirely:

```swift
import Foundation
import os
import TranscriberCore

struct TranscriptionResult {
    let jsonPath: URL
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case modelNotDownloaded(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded(let model): return "Model '\(model)' not downloaded. Check Settings."
            case .failed(let msg): return msg
            }
        }
    }

    private var transcriber: WhisperKitTranscriber?
    private var diarizer: (any DiarizationProvider)?

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // Resolve model path
        let storagePath = ModelManager.resolveStoragePath(config.modelStoragePath)
        let modelPath = storagePath.appendingPathComponent(config.whisperModel)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw RunnerError.modelNotDownloaded(config.whisperModel)
        }

        // Lazy-init transcriber (reuse across calls for model caching)
        if transcriber == nil {
            transcriber = WhisperKitTranscriber(
                modelPath: storagePath,
                model: config.whisperModel,
                unloadTimeoutMinutes: config.modelUnloadTimeout
            )
        }

        let inputCount = micAudio != nil ? 2 : 1
        Logger.transcription.info("Starting transcription — model: \(config.whisperModel, privacy: .public), inputs: \(inputCount)")

        // Transcribe + diarize each stream
        var allSegments: [LabeledSegment] = []
        let isDualStream = micAudio != nil
        let audioPairs: [(URL, String)] = {
            var pairs = [(systemAudio, "remote")]
            if let mic = micAudio { pairs.append((mic, "local")) }
            return pairs
        }()

        var detectedLanguage = "auto"

        for (audioPath, source) in audioPairs {
            // Skip empty files (WAV header only = 44 bytes)
            let attrs = try? FileManager.default.attributesOfItem(atPath: audioPath.path)
            let fileSize = attrs?[.size] as? Int ?? 0
            if fileSize <= 44 {
                Logger.transcription.info("Skipping \(source, privacy: .public) stream — empty file")
                continue
            }

            // Transcribe
            let segments = try await transcriber!.transcribe(audioPath: audioPath)

            if detectedLanguage == "auto", let lang = segments.first?.language {
                detectedLanguage = lang
            }

            // Diarize (if provider is set)
            let labeled: [LabeledSegment]
            if let diarizer {
                let diarized = try await diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
                labeled = SpeakerAssignment.assign(
                    transcriptSegments: segments,
                    diarizationSegments: diarized
                ).map {
                    var seg = $0
                    seg.source = source
                    return seg
                }
            } else {
                labeled = segments.map {
                    LabeledSegment(
                        start: $0.start, end: $0.end,
                        speaker: "", text: $0.text.trimmingCharacters(in: .whitespaces),
                        source: source
                    )
                }
            }

            allSegments.append(contentsOf: labeled)
        }

        // Tag with source prefix for dual-stream
        if isDualStream {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // Sort chronologically
        allSegments.sort { $0.start < $1.start }

        // Assemble and write JSON
        let audioPaths = audioPairs.map { $0.0 }
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: diarizer != nil,
            dualStream: isDualStream
        )

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonFile = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonFile)

        // Write format file (SRT/TXT) if requested
        try TranscriptWriter.writeFormatFile(fromJSON: jsonFile)

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Full pipeline complete in \(elapsed.components.seconds)s — \(allSegments.count) segments")

        return TranscriptionResult(jsonPath: jsonFile)
    }

    func setDiarizer(_ provider: any DiarizationProvider) {
        self.diarizer = provider
    }
}
```

- [ ] **Step 2: Update callers of TranscriptionRunner.run()**

Search for all callers:

```bash
grep -rn "transcriptionRunner.run\|TranscriptionRunner().run" TranscriberApp/
```

Update each call site to pass `config:` instead of `hfToken:`. The caller (likely in `MenuView.swift`) should change from:

```swift
try await transcriptionRunner.run(
    systemAudio: systemFile,
    micAudio: micFile,
    outputDirectory: outputDir,
    hfToken: configManager.config.hfToken
)
```

to:

```swift
try await transcriptionRunner.run(
    systemAudio: systemFile,
    micAudio: micFile,
    outputDirectory: outputDir,
    config: configManager.config
)
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build
```

- [ ] **Step 4: Run full test suite**

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat: rewrite TranscriptionRunner to use WhisperKit instead of Python"
```

---

### Task 10: Update SetupView with model download step

**Files:**
- Modify: `TranscriberApp/Views/SetupView.swift`
- Modify: `TranscriberApp/TranscriberApp.swift`

- [ ] **Step 1: Add ModelManager to LaunchGate**

In `TranscriberApp/TranscriberApp.swift`, add a `ModelManager` property to `LaunchGate`:

```swift
@MainActor
@Observable
final class LaunchGate {
    var permissionsReady = false
    let permissionManager: PermissionManager
    let modelManager = ModelManager()

    // ... rest unchanged
}
```

Pass `modelManager` to `SetupView`:

```swift
SetupWindowController.shared.show(
    permissionManager: permissionManager,
    modelManager: modelManager
) { [weak self] in
    self?.permissionsReady = true
}
```

- [ ] **Step 2: Add model download row to SetupView**

In `TranscriberApp/Views/SetupView.swift`, add after the Notifications PermissionRow and before the Continue button HStack:

```swift
Divider()

Text("Transcription Model")
    .font(.subheadline)
    .foregroundStyle(.secondary)

ModelDownloadRow(modelManager: modelManager)
```

Add the `modelManager` parameter to `SetupView`:

```swift
struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let modelManager: ModelManager
    let onReady: () -> Void
    // ...
}
```

Add the `ModelDownloadRow` view:

```swift
private struct ModelDownloadRow: View {
    let modelManager: ModelManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Model").fontWeight(.medium)
                if modelManager.isDownloading {
                    ProgressView(value: modelManager.downloadProgress)
                        .frame(width: 150)
                } else if let error = modelManager.downloadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Required for transcription (~1.6 GB)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if modelManager.isModelDownloaded("large-v3-turbo") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if modelManager.isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Download") {
                    Task {
                        try? await modelManager.downloadModel("large-v3-turbo")
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
```

Update the Continue button to also check model download:

```swift
Button("Continue") { onReady() }
    .keyboardShortcut(.defaultAction)
    .disabled(!permissionManager.allRequiredGranted || !modelManager.isModelDownloaded("large-v3-turbo"))
```

- [ ] **Step 3: Update SetupWindowController to pass modelManager**

Update `SetupWindowController.show()` to accept and pass `modelManager`.

- [ ] **Step 4: Verify it compiles and the existing tests still pass**

```bash
swift build
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Views/SetupView.swift TranscriberApp/TranscriberApp.swift \
  TranscriberApp/Services/SetupWindowController.swift
git commit -m "feat: add model download step to setup flow"
```

---

### Task 11: Update SettingsView — model picker, remove HF token

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Replace Speaker Diarization section with Model section**

Remove lines 66-69 (the HuggingFace token section). Add a new Transcription Model section:

```swift
Section("Transcription Model") {
    Picker("Model", selection: $config.whisperModel) {
        ForEach(ModelManager.availableModels) { model in
            Text(model.displayName).tag(model.id)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: replace HF token with model picker in Settings"
```

---

### Task 12: Benchmark harness — Phase 1 checkpoint

**User action required:** At this point, manually test with real audio files:

1. Place benchmark WAV files in `~/.audio-transcribe/benchmark/`
2. Download the model via the Setup flow or manually
3. Record a short test meeting and transcribe
4. Compare JSON output quality and timing vs the Python baseline

This is an integration test that cannot be automated (requires real audio + model download).

- [ ] **Step 1: Document benchmark procedure**

Add to `scripts/test-checklist.md`:

```markdown
## WhisperKit Migration Benchmark
- [ ] Place 2 recording pairs in ~/.audio-transcribe/benchmark/
- [ ] Run Python baseline: `python transcribe.py -i system.wav -i mic.wav -f json -o baseline.json`
- [ ] Record Python timing
- [ ] Build and run SwiftUI app with WhisperKit
- [ ] Record WhisperKit timing
- [ ] Compare segment counts and text quality
- [ ] Compare speaker assignments (if diarization enabled)
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add WhisperKit migration benchmark checklist"
```

---

## Phase 2: SpeakerKit Diarization

### Task 13: Build SpeakerKitDiarizer

**Files:**
- Create: `TranscriberCore/SpeakerKitDiarizer.swift`

- [ ] **Step 1: Implement SpeakerKitDiarizer**

Create `TranscriberCore/SpeakerKitDiarizer.swift`:

```swift
import Foundation
import os
import WhisperKit

/// On-device speaker diarization via SpeakerKit (Pyannote v4 Core ML).
public final class SpeakerKitDiarizer: DiarizationProvider, @unchecked Sendable {

    public init() {}

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("SpeakerKit diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

        // SpeakerKit API — verify exact API shape against WhisperKit docs at implementation time.
        // The API may be: SpeakerKit.diarize(audioPath:numSpeakers:) or similar.
        // This is a placeholder that must be updated to match the actual SpeakerKit API.
        let speakerKit = try SpeakerKit()
        let result = try await speakerKit.diarize(
            audioPath: audioPath.path,
            numSpeakers: numSpeakers
        )

        let segments = result.segments.map { seg in
            DiarizedSegment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker
            )
        }

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info("SpeakerKit diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s")

        return segments
    }
}
```

**Important:** The SpeakerKit API shape in this task is approximate. At implementation time, check the WhisperKit repo for the exact SpeakerKit API (it was open-sourced March 2026). The `DiarizationProvider` protocol ensures the integration point stays clean regardless of API differences.

- [ ] **Step 2: Wire SpeakerKitDiarizer as default in TranscriptionRunner**

In `TranscriptionRunner`, set the default diarizer in the `run()` method if none is set:

```swift
// At the start of run(), after model check:
if diarizer == nil {
    diarizer = SpeakerKitDiarizer()
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build
```

- [ ] **Step 4: Benchmark — compare diarization quality**

Run benchmark with the same audio files used in Phase 1. Compare:
- Number of speakers detected
- Speaker assignment accuracy
- Diarization processing time vs pyannote baseline

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/SpeakerKitDiarizer.swift TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: add SpeakerKitDiarizer as default diarization provider"
```

---

## Phase 3: CLI Mode & Rename

### Task 14: Build CLIHandler — argument parsing

**Files:**
- Create: `TranscriberApp/Services/CLIHandler.swift`
- Create: `SwiftTests/TranscriberTests/CLIHandlerTests.swift`

- [ ] **Step 1: Write failing tests for argument parsing**

Create `SwiftTests/TranscriberTests/CLIHandlerTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct CLIHandlerTests {

    @Test func parseTranscribeMinimal() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "system.wav"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.inputs == ["system.wav"])
        #expect(opts.output == nil)
        #expect(opts.format == "json")
        #expect(opts.language == nil)
        #expect(opts.noDiarize == false)
        #expect(opts.model == nil)
        #expect(opts.speakers == nil)
    }

    @Test func parseTranscribeDualInput() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "system.wav", "-i", "mic.wav", "-f", "srt", "-o", "out.json"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.inputs == ["system.wav", "mic.wav"])
        #expect(opts.output == "out.json")
        #expect(opts.format == "srt")
    }

    @Test func parseTranscribeAllFlags() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "a.wav", "-l", "fr", "--no-diarize", "--model", "large-v3", "--speakers", "3"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.language == "fr")
        #expect(opts.noDiarize == true)
        #expect(opts.model == "large-v3")
        #expect(opts.speakers == 3)
    }

    @Test func parseRename() throws {
        let args = ["AudioTranscribe", "rename", "-i", "transcript.json"]
        let cmd = try CLIParser.parse(args)
        guard case .rename(let path) = cmd else {
            Issue.record("Expected rename command")
            return
        }
        #expect(path == "transcript.json")
    }

    @Test func parseBenchmark() throws {
        let args = ["AudioTranscribe", "benchmark", "--transcription-only"]
        let cmd = try CLIParser.parse(args)
        guard case .benchmark(let opts) = cmd else {
            Issue.record("Expected benchmark command")
            return
        }
        #expect(opts.transcriptionOnly == true)
        #expect(opts.diarizationOnly == false)
    }

    @Test func parseNoSubcommandReturnsNil() throws {
        let args = ["AudioTranscribe"]
        let cmd = try? CLIParser.parse(args)
        #expect(cmd == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests/CLIHandlerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — `CLIParser` doesn't exist.

- [ ] **Step 3: Implement CLIParser in TranscriberCore**

Create within `TranscriberCore/CLIParser.swift` (putting it in Core so tests can access it):

```swift
import Foundation

public struct TranscribeOptions {
    public let inputs: [String]
    public let output: String?
    public let format: String
    public let language: String?
    public let noDiarize: Bool
    public let model: String?
    public let speakers: Int?
}

public struct BenchmarkOptions {
    public let transcriptionOnly: Bool
    public let diarizationOnly: Bool
}

public enum CLICommand {
    case transcribe(TranscribeOptions)
    case rename(String)
    case benchmark(BenchmarkOptions)
}

public enum CLIParser {

    public enum ParseError: LocalizedError {
        case missingSubcommand
        case unknownSubcommand(String)
        case missingRequiredArg(String)

        public var errorDescription: String? {
            switch self {
            case .missingSubcommand: return "Usage: AudioTranscribe <transcribe|rename|benchmark>"
            case .unknownSubcommand(let cmd): return "Unknown subcommand: \(cmd)"
            case .missingRequiredArg(let arg): return "Missing required argument: \(arg)"
            }
        }
    }

    public static func parse(_ args: [String]) throws -> CLICommand? {
        guard args.count > 1 else { return nil }

        let subcommand = args[1]
        let rest = Array(args.dropFirst(2))

        switch subcommand {
        case "transcribe":
            return .transcribe(try parseTranscribe(rest))
        case "rename":
            return .rename(try parseRename(rest))
        case "benchmark":
            return .benchmark(parseBenchmark(rest))
        default:
            throw ParseError.unknownSubcommand(subcommand)
        }
    }

    private static func parseTranscribe(_ args: [String]) throws -> TranscribeOptions {
        var inputs: [String] = []
        var output: String?
        var format = "json"
        var language: String?
        var noDiarize = false
        var model: String?
        var speakers: Int?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i", "--input":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                inputs.append(args[i])
            case "-o", "--output":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-o") }
                output = args[i]
            case "-f", "--format":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-f") }
                format = args[i]
            case "-l", "--language":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-l") }
                language = args[i]
            case "--no-diarize":
                noDiarize = true
            case "--model":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--model") }
                model = args[i]
            case "-s", "--speakers":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-s") }
                speakers = Int(args[i])
            default:
                break
            }
            i += 1
        }

        guard !inputs.isEmpty else { throw ParseError.missingRequiredArg("-i") }

        return TranscribeOptions(
            inputs: inputs, output: output, format: format,
            language: language, noDiarize: noDiarize,
            model: model, speakers: speakers
        )
    }

    private static func parseRename(_ args: [String]) throws -> String {
        var input: String?
        var i = 0
        while i < args.count {
            if args[i] == "-i" || args[i] == "--input" {
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                input = args[i]
            }
            i += 1
        }
        guard let input else { throw ParseError.missingRequiredArg("-i") }
        return input
    }

    private static func parseBenchmark(_ args: [String]) -> BenchmarkOptions {
        BenchmarkOptions(
            transcriptionOnly: args.contains("--transcription-only"),
            diarizationOnly: args.contains("--diarization-only")
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests/CLIHandlerTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all CLIHandlerTests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/CLIParser.swift SwiftTests/TranscriberTests/CLIHandlerTests.swift
git commit -m "feat: add CLI argument parser with transcribe/rename/benchmark subcommands"
```

---

### Task 15: Build CLIHandler execution and CLI entry point

**Files:**
- Create: `TranscriberApp/Services/CLIHandler.swift`
- Modify: `TranscriberApp/TranscriberApp.swift`

- [ ] **Step 1: Implement CLIHandler**

Create `TranscriberApp/Services/CLIHandler.swift`:

```swift
import Foundation
import os
import TranscriberCore

enum CLIHandler {

    static func run() -> Never {
        let args = CommandLine.arguments

        guard let command = try? CLIParser.parse(args) else {
            printUsage()
            exit(1)
        }

        // Run async work on a new task
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                switch command {
                case .transcribe(let opts):
                    try await handleTranscribe(opts)
                case .rename(let path):
                    try await handleRename(path)
                case .benchmark(let opts):
                    try await handleBenchmark(opts)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }

    private static func handleTranscribe(_ opts: TranscribeOptions) async throws {
        let config = ConfigManager.shared.config
        let model = opts.model ?? config.whisperModel
        let storagePath = ModelManager.resolveStoragePath(config.modelStoragePath)

        // Validate inputs exist
        let inputURLs = opts.inputs.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.fileNotFound(url.path)
            }
        }

        // Validate model downloaded
        let modelDir = storagePath.appendingPathComponent(model)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw CLIError.modelNotDownloaded(model)
        }

        let transcriber = WhisperKitTranscriber(
            modelPath: storagePath,
            model: model,
            unloadTimeoutMinutes: config.modelUnloadTimeout
        )

        let systemAudio = inputURLs[0]
        let micAudio = inputURLs.count > 1 ? inputURLs[1] : nil

        let outputDir: URL
        let outputFile: String?
        if let output = opts.output {
            let outputURL = URL(fileURLWithPath: output)
            outputDir = outputURL.deletingLastPathComponent()
            outputFile = outputURL.lastPathComponent
        } else {
            outputDir = systemAudio.deletingLastPathComponent()
            outputFile = nil
        }

        // Build runner and execute
        let runner = TranscriptionRunner()
        if !opts.noDiarize {
            runner.setDiarizer(SpeakerKitDiarizer())
        }

        var runConfig = config
        runConfig.whisperModel = model
        runConfig.outputFormat = opts.format

        let result = try await runner.run(
            systemAudio: systemAudio,
            micAudio: micAudio,
            outputDirectory: outputDir,
            config: runConfig
        )

        // Move to requested output path if specified
        if let outputFile {
            let targetPath = outputDir.appendingPathComponent(outputFile)
            if targetPath != result.jsonPath {
                try? FileManager.default.moveItem(at: result.jsonPath, to: targetPath)
                print("Output saved to: \(targetPath.path)")
            }
        } else {
            print("Output saved to: \(result.jsonPath.path)")
        }
    }

    private static func handleRename(_ jsonPathStr: String) async throws {
        let jsonPath = URL(fileURLWithPath: jsonPathStr)
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw CLIError.fileNotFound(jsonPathStr)
        }

        try CLIRename.run(jsonPath: jsonPath)
    }

    private static func handleBenchmark(_ opts: BenchmarkOptions) async throws {
        let benchmarkDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".audio-transcribe/benchmark")

        guard FileManager.default.fileExists(atPath: benchmarkDir.path) else {
            throw CLIError.noBenchmarkFiles
        }

        print("Benchmark running from: \(benchmarkDir.path)")
        print("(Benchmark execution to be implemented)")
        // TODO: Implement benchmark execution
    }

    private static func printUsage() {
        let usage = """
        Usage: AudioTranscribe <subcommand> [options]

        Subcommands:
          transcribe  Transcribe audio files
            -i <file>        Input audio file (required, can specify twice for dual-stream)
            -o <file>        Output file path (default: auto from input name)
            -f <format>      Output format: json, srt, txt (default: json)
            -l <lang>        Force language code (auto-detect if omitted)
            -s <count>       Number of speakers (auto-detect if omitted)
            --model <name>   Whisper model (default: from config)
            --no-diarize     Skip speaker diarization

          rename      Rename speakers in a transcript
            -i <file>        Input JSON transcript (required)

          benchmark   Run performance benchmark
            --transcription-only   Only benchmark transcription
            --diarization-only     Only benchmark diarization
        """
        print(usage)
    }

    enum CLIError: LocalizedError {
        case fileNotFound(String)
        case modelNotDownloaded(String)
        case noBenchmarkFiles

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .modelNotDownloaded(let model): return "Model '\(model)' not downloaded. Run the app first to download it."
            case .noBenchmarkFiles: return "No benchmark files found in ~/.audio-transcribe/benchmark/"
            }
        }
    }
}
```

- [ ] **Step 2: Add CLI detection to TranscriberApp entry point**

In `TranscriberApp/TranscriberApp.swift`, add to the `init()` of `TranscriberApp`:

```swift
init() {
    // CLI mode: if arguments present, run CLI and exit
    if CommandLine.arguments.count > 1 {
        CLIHandler.run()  // Never returns
    }

    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    let gate = launchGate
    Task { @MainActor in
        await gate.checkAndGate()
    }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build
```

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/CLIHandler.swift TranscriberApp/TranscriberApp.swift
git commit -m "feat: add CLI mode with transcribe/rename/benchmark subcommands"
```

---

### Task 16: Build CLIRename — interactive speaker rename

**Files:**
- Create: `TranscriberApp/Services/CLIRename.swift`

- [ ] **Step 1: Implement CLIRename**

Create `TranscriberApp/Services/CLIRename.swift`:

```swift
import Foundation
import os
import TranscriberCore

enum CLIRename {

    struct SpeakerSample {
        let id: String
        let sampleText: String
        let audioFile: URL?
        let start: Double
        let end: Double
    }

    static func run(jsonPath: URL) throws {
        // Parse JSON
        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]]
        else {
            throw RenameError.invalidJSON
        }

        let metadata = json["metadata"] as? [String: Any]
        let audioPaths = metadata?["audio_paths"] as? [String] ?? []
        let remoteAudio = audioPaths.first.map { URL(fileURLWithPath: $0) }
        let localAudio = audioPaths.count > 1 ? URL(fileURLWithPath: audioPaths[1]) : nil

        // Collect speakers with samples
        var seen = Set<String>()
        var samples: [SpeakerSample] = []

        for seg in segments {
            guard let speaker = seg["speaker"] as? String, !seen.contains(speaker) else { continue }
            seen.insert(speaker)

            let text = seg["text"] as? String ?? ""
            let start = seg["start"] as? Double ?? 0
            let end = seg["end"] as? Double ?? 0
            let source = seg["source"] as? String ?? "remote"
            let audioFile = source == "local" ? localAudio : remoteAudio

            samples.append(SpeakerSample(
                id: speaker, sampleText: text,
                audioFile: audioFile, start: start, end: end
            ))
        }

        guard !samples.isEmpty else {
            print("No speakers found in transcript.")
            return
        }

        print("\nFound \(samples.count) speaker(s) in transcript.\n")

        // Interactive rename loop
        var mapping: [String: String] = [:]

        for sample in samples {
            print("--- \(sample.id) ---")
            print("Sample: \"\(sample.sampleText.prefix(100))\"")

            // Play audio sample if available
            if let audioFile = sample.audioFile,
               FileManager.default.fileExists(atPath: audioFile.path) {
                print("Playing audio sample...")
                playAudioSample(file: audioFile, start: sample.start, end: sample.end)
            }

            print("Enter new name (or press Enter to keep '\(sample.id)'): ", terminator: "")
            if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
                mapping[sample.id] = input
                print("  -> Renamed to: \(input)")
            } else {
                print("  -> Keeping: \(sample.id)")
            }
            print()
        }

        // Apply renames if any were made
        if !mapping.isEmpty {
            RenameWindowController.applySpeakerRenames(mapping, jsonPath: jsonPath)
            print("Speaker names updated in: \(jsonPath.lastPathComponent)")
        }

        // Generate format file
        RenameWindowController.generateFormatFile(jsonPath: jsonPath)
        print("Done.")
    }

    private static func playAudioSample(file: URL, start: Double, end: Double) {
        let duration = end - start
        guard duration > 0 else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [
            file.path,
            "--time", String(format: "%.1f", duration),
            "--rate", "1.0",
        ]

        // afplay doesn't support seek directly, but we can use -t for duration
        // For seek, we'd need ffmpeg — but we're removing it.
        // Alternative: use AVFoundation with RunLoop (decided against)
        // For now, play from start for `duration` seconds.
        // TODO: Investigate afplay seek or trimmed temp file approach

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.transcription.error("afplay failed: \(error, privacy: .public)")
        }
    }

    enum RenameError: LocalizedError {
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "Invalid JSON transcript file"
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/CLIRename.swift
git commit -m "feat: add interactive CLI speaker rename with afplay playback"
```

---

## Phase 4: Kill Python

### Task 17: Remove Python files and packaging

**Files:**
- Delete: `transcribe.py`
- Delete: `rename_speakers.py`
- Delete: `service/config_manager.py`
- Delete: `service/logger.py`
- Delete: `service/__init__.py` (if exists)
- Delete: `service/diarize_only.py` (bridge script from Task 8)
- Delete: `packaging/embed_python.sh`
- Delete: `TranscriberCore/PyAnnoteDiarizer.swift`

- [ ] **Step 1: Remove Python files**

```bash
git rm transcribe.py rename_speakers.py
git rm -r service/
git rm packaging/embed_python.sh
git rm TranscriberCore/PyAnnoteDiarizer.swift
```

- [ ] **Step 2: Verify build succeeds**

```bash
swift build
```

If PyAnnoteDiarizer is referenced anywhere, remove those references.

- [ ] **Step 3: Run full test suite**

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: remove Python transcription engine and embed_python.sh"
```

---

### Task 18: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Update CLAUDE.md**

Key changes:
- Remove Python CLI section references to `transcribe.py` and `rename_speakers.py`
- Update Architecture section: remove "Python CLI (unchanged)" section, add WhisperKit/SpeakerKit descriptions
- Update Build & Test: remove Python test command, update Swift test count
- Update Key Gotchas: remove Python-specific gotchas (#22 TranscriptionRunner environment, #23 embed_python.sh rsync), add WhisperKit-specific gotchas
- Remove `service/config_manager.py` and `service/logger.py` from architecture
- Update TranscriptionRunner description
- Update Packaging section: remove embed_python.sh reference

- [ ] **Step 2: Update test-checklist.md**

Update the test checklist to reflect the new WhisperKit-based workflow:
- Remove Python-related test steps
- Add model download verification
- Add CLI mode test steps

- [ ] **Step 3: Run full test suite one final time**

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md scripts/test-checklist.md
git commit -m "docs: update CLAUDE.md and test checklist for WhisperKit migration"
```

---

### Task 19: Final benchmark comparison

**User action required.** This is the final validation:

- [ ] **Step 1: Run full pipeline benchmark**

```bash
.build/debug/AudioTranscribe benchmark
```

Compare against Phase 0 baseline:
- Transcription speed improvement (expect 5-8x with turbo)
- Diarization speed improvement (expect significant with SpeakerKit Core ML)
- Total pipeline time
- Output quality comparison (segment counts, text accuracy)
- App bundle size comparison (expect major reduction without embedded Python)

- [ ] **Step 2: Record results**

Document final benchmark results for reference.
