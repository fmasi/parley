# SwiftUI Native UI Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all Python UI code (rumps/PyObjC) with a native SwiftUI menu bar app that orchestrates audio capture via XPC and Python transcription via subprocess.

**Architecture:** SwiftUI host app (`MenuBarExtra` + `Settings` scene) + XPC audio capture service (existing ScreenCaptureKit code with new entry point) + Python transcription via `Process` subprocess. Config stored in `~/.audio-transcribe/config.json`, compatible with existing Python CLI.

**Tech Stack:** Swift 5.9+, SwiftUI, ScreenCaptureKit, XPC, macOS 15.0+

**Branch:** `feature/swiftui-native-ui`

**Spec:** `docs/superpowers/specs/2026-03-29-swiftui-native-rewrite-design.md`

---

## File Map

### New Files (Swift)

| File | Responsibility |
|------|---------------|
| `TranscriberApp/TranscriberApp.swift` | `@main` — MenuBarExtra + Settings scenes |
| `TranscriberApp/Models/AppState.swift` | Observable state machine (idle/recording/transcribing) |
| `TranscriberApp/Models/Config.swift` | Codable struct mirroring Python config.json |
| `TranscriberApp/Services/ConfigManager.swift` | Read/write ~/.audio-transcribe/config.json |
| `TranscriberApp/Services/AudioCaptureClient.swift` | XPC connection + async Swift API |
| `TranscriberApp/Services/TranscriptionRunner.swift` | Launch transcribe.py via Process |
| `TranscriberApp/Views/MenuView.swift` | Menu bar dropdown content |
| `TranscriberApp/Views/SettingsView.swift` | Settings Form |
| `TranscriberApp/Views/RenameDialog.swift` | Speaker rename sheet |
| `AudioCaptureProtocol/AudioCaptureProtocol.swift` | Shared XPC `@objc` protocol |
| `AudioCaptureHelper/XPC/main.swift` | XPC listener entry point |
| `AudioCaptureHelper/XPC/AudioCaptureService.swift` | XPC protocol implementation, delegates to existing capture logic |
| `TranscriberApp.xcodeproj` or `Package.swift` | Xcode project with 3 targets |
| `Packaging/embed_python.sh` | Embeds relocatable conda env into build output |
| `Packaging/Info.plist` | Updated for new binary name + XPC service |
| `Packaging/AudioCaptureHelper-Info.plist` | XPC service Info.plist |

### Existing Files Modified

| File | Change |
|------|--------|
| `audio_capture_helper/Sources/AudioCaptureHelper/main.swift` | Extract `WavFileWriter`, `AudioOutputHandler`, `startCapture()` into separate files; old main.swift kept for standalone CLI use |

### Existing Files Unchanged

| File | Why |
|------|-----|
| `transcribe.py` | Called via subprocess, no changes |
| `rename_speakers.py` | Called via subprocess, no changes |
| `service/config_manager.py` | Python CLI still uses it |
| `service/logger.py` | Python CLI still uses it |

---

## Task 1: Xcode Project Scaffold + Shared XPC Protocol

**Goal:** Create the Xcode project structure with three targets (app, XPC service, shared protocol) and define the XPC protocol that both targets import.

**Files:**
- Create: `Package.swift` (root — SPM workspace with 3 targets)
- Create: `AudioCaptureProtocol/AudioCaptureProtocol.swift`
- Create: `TranscriberApp/TranscriberApp.swift` (minimal placeholder)
- Create: `AudioCaptureHelper/XPC/main.swift` (minimal placeholder)

- [ ] **Step 1: Create root Package.swift with three targets**

We use Swift Package Manager instead of `.xcodeproj` — it's simpler and Xcode opens it natively via `open Package.swift`.

```swift
// Package.swift (project root)
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "AudioTranscribe", targets: ["TranscriberApp"]),
        .executable(name: "audio-capture-helper-xpc", targets: ["AudioCaptureHelperXPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/SettingsAccess", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AudioCaptureProtocol",
            path: "AudioCaptureProtocol"
        ),
        .executableTarget(
            name: "TranscriberApp",
            dependencies: ["AudioCaptureProtocol", "SettingsAccess"],
            path: "TranscriberApp"
        ),
        .executableTarget(
            name: "AudioCaptureHelperXPC",
            dependencies: ["AudioCaptureProtocol"],
            path: "AudioCaptureHelper/XPC"
        ),
    ]
)
```

Note: The existing `audio_capture_helper/` SPM package stays intact for standalone CLI builds. The new `AudioCaptureHelper/XPC/` target is the XPC-adapted version.

- [ ] **Step 2: Create the shared XPC protocol**

```swift
// AudioCaptureProtocol/AudioCaptureProtocol.swift
import Foundation

/// XPC protocol for communication between the SwiftUI app and the audio capture service.
/// Both the app target and the XPC service target import this.
@objc public protocol AudioCaptureProtocol {
    /// Start capturing system audio + microphone to WAV files in the given directory.
    /// Reply: (success: Bool, errorMessage: String?)
    func startCapture(
        outputDirectory: String,
        baseName: String,
        reply: @escaping (Bool, String?) -> Void
    )

    /// Stop the current capture session and finalize WAV files.
    /// Reply: (systemAudioPath: String?, micAudioPath: String?, errorMessage: String?)
    /// Both paths are non-nil on success; errorMessage is non-nil on failure.
    func stopCapture(
        reply: @escaping (String?, String?, String?) -> Void
    )

    /// Query whether a capture session is currently active.
    /// Reply: (isCapturing: Bool, errorMessage: String?)
    func status(
        reply: @escaping (Bool, String?) -> Void
    )
}

/// The XPC service name — must match the bundle identifier in the XPC service's Info.plist.
public let audioCaptureServiceName = "com.audio-transcribe.capture-helper"
```

- [ ] **Step 3: Create minimal app entry point placeholder**

```swift
// TranscriberApp/TranscriberApp.swift
import SwiftUI

@main
struct TranscriberApp: App {
    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: "mic") {
            Text("Transcriber is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 4: Create minimal XPC service placeholder**

```swift
// AudioCaptureHelper/XPC/main.swift
import Foundation
import AudioCaptureProtocol

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        // AudioCaptureService will be implemented in Task 3
        // newConnection.exportedObject = AudioCaptureService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 5: Verify the project builds**

```bash
cd /Users/fmasi/Git/Transcriber
swift build 2>&1 | tail -20
```

Expected: Build succeeds (the XPC listener won't have a real exported object yet, but it compiles).

- [ ] **Step 6: Commit**

```bash
git add Package.swift AudioCaptureProtocol/ TranscriberApp/TranscriberApp.swift AudioCaptureHelper/XPC/
git commit -m "feat: scaffold Xcode project with 3 SPM targets + XPC protocol"
```

---

## Task 2: Config Model + ConfigManager (Swift)

**Goal:** Create the Swift `Config` struct and `ConfigManager` that reads/writes the same `~/.audio-transcribe/config.json` as the Python side.

**Files:**
- Create: `TranscriberApp/Models/Config.swift`
- Create: `TranscriberApp/Services/ConfigManager.swift`
- Create: `TranscriberApp/Tests/ConfigManagerTests.swift` (if SPM test target added)

- [ ] **Step 1: Create Config.swift — Codable struct matching Python dataclass**

Field names must match the Python `Config` dataclass exactly (snake_case in JSON, camelCase in Swift with `CodingKeys`).

```swift
// TranscriberApp/Models/Config.swift
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
```

- [ ] **Step 2: Create ConfigManager.swift**

```swift
// TranscriberApp/Services/ConfigManager.swift
import Foundation

final class ConfigManager {
    static let shared = ConfigManager()

    private let configDir: URL
    private let configFile: URL

    private(set) var config: Config

    init(configDir: URL? = nil) {
        let dir = configDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".audio-transcribe")
        self.configDir = dir
        self.configFile = dir.appendingPathComponent("config.json")
        self.config = Self.load(from: self.configFile)
    }

    private static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFile, options: .atomic)
    }

    func update(_ transform: (inout Config) -> Void) {
        transform(&config)
        save()
    }
}
```

- [ ] **Step 3: Write a test to verify JSON round-trip compatibility with Python**

Create a test config JSON matching what Python produces, verify Swift can decode it, re-encode it, and the field names stay snake_case.

```swift
// Tests/ConfigManagerTests.swift (or inline test)
// For now, verify manually:
```

```bash
# Create a test config matching Python output:
cat > /tmp/test_config.json << 'EOF'
{
  "recording_directory": "/Users/test/Documents/Recordings",
  "silence_timeout_minutes": 5,
  "silence_detection_enabled": true,
  "output_format": "txt",
  "launch_on_startup": true,
  "log_level": "info",
  "suppress_capture_warning": false,
  "hf_token": "hf_test123"
}
EOF

# We'll verify in Step 5 that the app reads this correctly
```

- [ ] **Step 4: Build and verify**

```bash
cd /Users/fmasi/Git/Transcriber
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Models/Config.swift TranscriberApp/Services/ConfigManager.swift
git commit -m "feat: add Config model + ConfigManager with JSON round-trip compatibility"
```

---

## Task 3: AppState Observable Model

**Goal:** Create the central observable state machine that drives the entire UI.

**Files:**
- Create: `TranscriberApp/Models/AppState.swift`

- [ ] **Step 1: Create AppState.swift**

```swift
// TranscriberApp/Models/AppState.swift
import Foundation
import SwiftUI

@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(progress: String)
    }

    var phase: Phase = .idle
    var lastTranscriptPath: String?
    var errorMessage: String?
    var showRenameSheet = false

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    var menuBarIcon: String {
        switch phase {
        case .idle: return "mic"
        case .recording: return "record.circle"
        case .transcribing: return "hourglass"
        }
    }

    var recordingToggleLabel: String {
        switch phase {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing..."
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Models/AppState.swift
git commit -m "feat: add AppState observable with phase state machine"
```

---

## Task 4: XPC Audio Capture Service

**Goal:** Adapt the existing ScreenCaptureKit capture logic into an XPC service that implements `AudioCaptureProtocol`.

**Files:**
- Create: `AudioCaptureHelper/XPC/AudioCaptureService.swift`
- Create: `AudioCaptureHelper/XPC/WavFileWriter.swift` (extracted from existing main.swift)
- Create: `AudioCaptureHelper/XPC/AudioOutputHandler.swift` (extracted from existing main.swift)
- Modify: `AudioCaptureHelper/XPC/main.swift` (wire up exported object)

The existing `audio_capture_helper/Sources/AudioCaptureHelper/main.swift` is NOT modified — the standalone CLI binary stays intact for direct use.

- [ ] **Step 1: Extract WavFileWriter into its own file**

Copy the `WavFileWriter` class from the existing `main.swift` verbatim:

```swift
// AudioCaptureHelper/XPC/WavFileWriter.swift
import Foundation

final class WavFileWriter {
    private let fileHandle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader(sampleRate: 16000, dataSize: 0)
    }

    func setSampleRate(_ rate: UInt32) {
        sampleRate = rate
    }

    func append(_ samples: UnsafeBufferPointer<Float32>) {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        let bytes = pcm.withUnsafeBytes { Data($0) }
        fileHandle.write(bytes)
        dataByteCount += UInt32(bytes.count)
    }

    func finalize() {
        let rate = sampleRate > 0 ? sampleRate : 16000
        fileHandle.seek(toFileOffset: 0)
        writeHeader(sampleRate: rate, dataSize: dataByteCount)
        fileHandle.seekToEndOfFile()
        fileHandle.closeFile()
    }

    private func writeHeader(sampleRate: UInt32, dataSize: UInt32) {
        let byteRate = sampleRate * 2
        var h = Data()
        h += "RIFF".data(using: .ascii)!;  h += le32(36 + dataSize)
        h += "WAVE".data(using: .ascii)!
        h += "fmt ".data(using: .ascii)!;  h += le32(16)
        h += le16(1);  h += le16(1)
        h += le32(sampleRate);  h += le32(byteRate)
        h += le16(2);  h += le16(16)
        h += "data".data(using: .ascii)!;  h += le32(dataSize)
        fileHandle.write(h)
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}
```

- [ ] **Step 2: Extract AudioOutputHandler into its own file**

```swift
// AudioCaptureHelper/XPC/AudioOutputHandler.swift
import Foundation
import ScreenCaptureKit

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let systemWriter: WavFileWriter
    private let micWriter: WavFileWriter
    private var detectedSystemRate = false
    private var detectedMicRate = false

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter
    }

    func finalizeAll() {
        systemWriter.finalize()
        micWriter.finalize()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let writer: WavFileWriter
        if type == .audio {
            if !detectedSystemRate {
                detectedSystemRate = true
                if let rate = sampleRate(from: sampleBuffer) {
                    systemWriter.setSampleRate(UInt32(rate))
                }
            }
            writer = systemWriter
        } else if type == .microphone {
            if !detectedMicRate {
                detectedMicRate = true
                if let rate = sampleRate(from: sampleBuffer) {
                    micWriter.setSampleRate(UInt32(rate))
                }
            }
            writer = micWriter
        } else {
            return
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let count = totalLength / MemoryLayout<Float32>.size
        ptr.withMemoryRebound(to: Float32.self, capacity: count) { floatPtr in
            writer.append(UnsafeBufferPointer(start: floatPtr, count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Log or propagate error
    }

    private func sampleRate(from buf: CMSampleBuffer) -> Double? {
        guard let fmt = CMSampleBufferGetFormatDescription(buf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        return asbd.pointee.mSampleRate
    }
}
```

- [ ] **Step 3: Create AudioCaptureService.swift — the XPC protocol implementation**

```swift
// AudioCaptureHelper/XPC/AudioCaptureService.swift
import Foundation
import ScreenCaptureKit
import AudioCaptureProtocol

final class AudioCaptureService: NSObject, AudioCaptureProtocol {
    private var handler: AudioOutputHandler?
    private var stream: SCStream?
    private var systemPath: String?
    private var micPath: String?
    private var isCapturing = false

    func startCapture(
        outputDirectory: String,
        baseName: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        guard !isCapturing else {
            reply(false, "Capture already in progress")
            return
        }

        let sysPath = (outputDirectory as NSString).appendingPathComponent(baseName + ".wav")
        let micFilePath = (outputDirectory as NSString).appendingPathComponent(baseName + "_mic.wav")

        do {
            try FileManager.default.createDirectory(
                atPath: outputDirectory, withIntermediateDirectories: true
            )
            let systemWriter = try WavFileWriter(path: sysPath)
            let micWriter = try WavFileWriter(path: micFilePath)
            let outputHandler = AudioOutputHandler(
                systemWriter: systemWriter, micWriter: micWriter
            )

            self.systemPath = sysPath
            self.micPath = micFilePath
            self.handler = outputHandler

            Task {
                do {
                    try await self.configureAndStart(handler: outputHandler)
                    self.isCapturing = true
                    reply(true, nil)
                } catch {
                    let desc = "\(error)"
                    if desc.contains("permission") || desc.contains("denied")
                        || desc.contains("notAuthorized") {
                        reply(false, "Permission denied — grant Screen Recording access in System Settings")
                    } else {
                        reply(false, "Capture failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            reply(false, "Failed to open output files: \(error.localizedDescription)")
        }
    }

    func stopCapture(
        reply: @escaping (String?, String?, String?) -> Void
    ) {
        guard isCapturing, let stream = stream else {
            reply(nil, nil, "No capture in progress")
            return
        }

        Task {
            do {
                try await stream.stopCapture()
            } catch {
                // Stream may already be stopped — proceed with finalization
            }
            self.handler?.finalizeAll()
            self.isCapturing = false
            let sys = self.systemPath
            let mic = self.micPath
            self.stream = nil
            self.handler = nil
            self.systemPath = nil
            self.micPath = nil
            reply(sys, mic, nil)
        }
    }

    func status(reply: @escaping (Bool, String?) -> Void) {
        reply(isCapturing, nil)
    }

    private func configureAndStart(handler: AudioOutputHandler) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw NSError(
                domain: "AudioCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display found"]
            )
        }

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let captureStream = SCStream(
            filter: filter, configuration: config, delegate: handler
        )
        try captureStream.addStreamOutput(
            handler, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.audio")
        )
        try captureStream.addStreamOutput(
            handler, type: .microphone,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.microphone")
        )
        try captureStream.addStreamOutput(
            handler, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "audio-capture.screen")
        )

        self.stream = captureStream
        try await captureStream.startCapture()
    }
}
```

- [ ] **Step 4: Wire up the XPC listener in main.swift**

Replace the placeholder with the real exported object:

```swift
// AudioCaptureHelper/XPC/main.swift
import Foundation
import AudioCaptureProtocol

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        newConnection.exportedObject = AudioCaptureService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 5: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds. (XPC service won't be testable until embedded in an .app — functional testing comes later.)

- [ ] **Step 6: Commit**

```bash
git add AudioCaptureHelper/XPC/
git commit -m "feat: XPC audio capture service with ScreenCaptureKit integration"
```

---

## Task 5: AudioCaptureClient (App-Side XPC Client)

**Goal:** Create the Swift async wrapper around the XPC connection that the SwiftUI app uses to start/stop capture.

**Files:**
- Create: `TranscriberApp/Services/AudioCaptureClient.swift`

- [ ] **Step 1: Create AudioCaptureClient.swift**

```swift
// TranscriberApp/Services/AudioCaptureClient.swift
import Foundation
import AudioCaptureProtocol

struct AudioPaths {
    let systemAudio: URL
    let micAudio: URL
}

final class AudioCaptureClient {
    private var connection: NSXPCConnection?

    func connect() {
        let conn = NSXPCConnection(serviceName: audioCaptureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        conn.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        conn.resume()
        connection = conn
    }

    func start(outputDirectory: URL, baseName: String) async throws {
        let proxy = try proxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName
            ) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.startFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    func stop() async throws -> AudioPaths {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.stopCapture { systemPath, micPath, errorMessage in
                if let sys = systemPath, let mic = micPath {
                    cont.resume(returning: AudioPaths(
                        systemAudio: URL(fileURLWithPath: sys),
                        micAudio: URL(fileURLWithPath: mic)
                    ))
                } else {
                    cont.resume(throwing: CaptureError.stopFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    private func proxy() throws -> AudioCaptureProtocol {
        if connection == nil { connect() }
        guard let conn = connection else {
            throw CaptureError.notConnected
        }
        guard let proxy = conn.remoteObjectProxy as? AudioCaptureProtocol else {
            throw CaptureError.notConnected
        }
        return proxy
    }
}

enum CaptureError: LocalizedError {
    case notConnected
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection not available"
        case .startFailed(let msg): return msg
        case .stopFailed(let msg): return msg
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: async AudioCaptureClient wrapping XPC connection"
```

---

## Task 6: TranscriptionRunner (Python Subprocess)

**Goal:** Create the service that launches `transcribe.py` as a subprocess and returns the output path.

**Files:**
- Create: `TranscriberApp/Services/TranscriptionRunner.swift`

- [ ] **Step 1: Create TranscriptionRunner.swift**

The runner finds Python and the script inside the app bundle's Resources directory. It sets `PYTHONHOME` and `PYTHONPATH` exactly like the current `packaging/launcher.sh` does.

```swift
// TranscriberApp/Services/TranscriptionRunner.swift
import Foundation

struct TranscriptionResult {
    let outputPath: URL
    let jsonPath: URL?
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case pythonNotFound
        case scriptNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound: return "Embedded Python not found in app bundle"
            case .scriptNotFound: return "transcribe.py not found in app bundle"
            case .failed(let msg): return msg
            }
        }
    }

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputFormat: String,
        outputDirectory: URL
    ) async throws -> TranscriptionResult {
        let resources = Bundle.main.resourceURL!
        let pythonHome = resources
            .appendingPathComponent("python/Python.framework/Versions/3.11")
        let pythonBin = pythonHome.appendingPathComponent("bin/python3")
        let sitePackages = resources
            .appendingPathComponent("python/lib/python3.11/site-packages")
        let transcribeScript = resources
            .appendingPathComponent("Python/transcribe.py")

        guard FileManager.default.fileExists(atPath: pythonBin.path) else {
            throw RunnerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RunnerError.scriptNotFound
        }

        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", outputFormat]
        arguments += ["-o", outputDirectory.path]

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = arguments
        process.environment = [
            "PYTHONHOME": pythonHome.path,
            "PYTHONPATH": sitePackages.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(throwing: RunnerError.failed(
                        "transcribe.py exited with code \(proc.terminationStatus): \(stderr)"
                    ))
                    return
                }

                // transcribe.py outputs JSON to stdout with output path info
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                // Parse the JSON output path from stdout
                if let data = stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let outputFile = json["output_file"] as? String {
                    let jsonFile = json["json_file"] as? String
                    cont.resume(returning: TranscriptionResult(
                        outputPath: URL(fileURLWithPath: outputFile),
                        jsonPath: jsonFile.map { URL(fileURLWithPath: $0) }
                    ))
                } else {
                    // Fallback: derive output path from input
                    let baseName = systemAudio.deletingPathExtension().lastPathComponent
                    let outputFile = outputDirectory
                        .appendingPathComponent(baseName + "." + outputFormat)
                    cont.resume(returning: TranscriptionResult(
                        outputPath: outputFile, jsonPath: nil
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: RunnerError.failed(
                    "Failed to launch transcribe.py: \(error.localizedDescription)"
                ))
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: TranscriptionRunner — launches transcribe.py via Process"
```

---

## Task 7: MenuView + Recording Flow

**Goal:** Build the menu bar dropdown with all menu items and wire up the start/stop recording flow through AppState, AudioCaptureClient, and TranscriptionRunner.

**Files:**
- Create: `TranscriberApp/Views/MenuView.swift`
- Modify: `TranscriberApp/TranscriberApp.swift` (replace placeholder)

- [ ] **Step 1: Create MenuView.swift**

```swift
// TranscriberApp/Views/MenuView.swift
import SwiftUI
import SettingsAccess

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager

    var body: some View {
        Button(appState.recordingToggleLabel) {
            Task { await toggleRecording() }
        }
        .disabled(appState.isTranscribing)

        Divider()

        Button("Open Recordings Folder") {
            let dir = URL(fileURLWithPath: configManager.config.recordingDirectory)
            NSWorkspace.shared.open(dir)
        }

        SettingsLink {
            Text("Settings...")
        } preAction: {
        } postAction: {
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await stopRecording()
        } else if appState.isIdle {
            await startRecording()
        }
    }

    private func startRecording() async {
        let config = configManager.config
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let baseName = timeFormatter.string(from: Date())

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(dayDir)

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName
            )
            appState.phase = .recording(since: Date())
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let paths = try await captureClient.stop()
            appState.phase = .transcribing(progress: "Transcribing...")

            let config = configManager.config
            let result = try await transcriptionRunner.run(
                systemAudio: paths.systemAudio,
                micAudio: paths.micAudio,
                outputFormat: config.outputFormat,
                outputDirectory: paths.systemAudio.deletingLastPathComponent()
            )

            appState.lastTranscriptPath = result.outputPath.path
            appState.phase = .idle
            sendNotification(path: result.outputPath)
        } catch {
            appState.errorMessage = error.localizedDescription
            appState.phase = .idle
        }
    }

    private func sendNotification(path: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = path.lastPathComponent
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Update TranscriberApp.swift with real wiring**

```swift
// TranscriberApp/TranscriberApp.swift
import SwiftUI

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            MenuView(
                appState: appState,
                captureClient: captureClient,
                transcriptionRunner: transcriptionRunner,
                configManager: configManager
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }
}
```

- [ ] **Step 3: Add UserNotifications import and request permission on launch**

Add to `TranscriberApp.swift` init or an `onAppear` modifier:

```swift
import UserNotifications

// Add to TranscriberApp:
init() {
    UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound]
    ) { _, _ in }
}
```

- [ ] **Step 4: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds (SettingsView not yet created — add a placeholder if needed).

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift TranscriberApp/TranscriberApp.swift
git commit -m "feat: MenuView with recording flow, notifications, and app entry point"
```

---

## Task 8: SettingsView

**Goal:** Build the settings window as a SwiftUI Form that reads/writes config.

**Files:**
- Create: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Create SettingsView.swift**

```swift
// TranscriberApp/Views/SettingsView.swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let configManager: ConfigManager
    @State private var config: Config
    @State private var saveStatus: String?

    init(configManager: ConfigManager) {
        self.configManager = configManager
        self._config = State(initialValue: configManager.config)
    }

    var body: some View {
        Form {
            Section("Recording") {
                TextField("Recording Directory", text: $config.recordingDirectory)
                Picker("Output Format", selection: $config.outputFormat) {
                    Text("txt").tag("txt")
                    Text("srt").tag("srt")
                    Text("json").tag("json")
                }
            }

            Section("Silence Detection") {
                Toggle("Enabled", isOn: $config.silenceDetectionEnabled)
                if config.silenceDetectionEnabled {
                    TextField(
                        "Timeout (minutes)",
                        value: $config.silenceTimeoutMinutes,
                        format: .number
                    )
                }
            }

            Section("Speaker Diarization") {
                SecureField("HuggingFace Token", text: $config.hfToken)
                    .textContentType(.password)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $config.launchOnStartup)
                    .onChange(of: config.launchOnStartup) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert on failure
                            config.launchOnStartup = !enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 380)
        .toolbar {
            ToolbarItem {
                if let status = saveStatus {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button("Save") {
                    configManager.update { $0 = config }
                    saveStatus = "Saved"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveStatus = nil
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: SettingsView with Form, config binding, and save feedback"
```

---

## Task 9: RenameDialog

**Goal:** Build the speaker rename sheet that shows detected speakers with audio preview and text fields for renaming.

**Files:**
- Create: `TranscriberApp/Views/RenameDialog.swift`
- Modify: `TranscriberApp/Views/MenuView.swift` (add Rename Speakers menu item + sheet trigger)

- [ ] **Step 1: Create RenameDialog.swift**

```swift
// TranscriberApp/Views/RenameDialog.swift
import SwiftUI
import AVFoundation

struct SpeakerEntry: Identifiable {
    let id: String  // "speaker_0", "speaker_1", etc.
    var displayName: String
    let samplePath: URL?
}

struct RenameDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var speakers: [SpeakerEntry]
    @State private var audioPlayer: AVAudioPlayer?

    let jsonPath: URL
    let onSave: ([String: String]) -> Void

    init(jsonPath: URL, speakers: [SpeakerEntry], onSave: @escaping ([String: String]) -> Void) {
        self.jsonPath = jsonPath
        self._speakers = State(initialValue: speakers)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speakers")
                .font(.headline)

            ForEach($speakers) { $speaker in
                HStack {
                    Text(speaker.id)
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $speaker.displayName)
                        .textFieldStyle(.roundedBorder)

                    if speaker.samplePath != nil {
                        Button {
                            playSample(speaker.samplePath!)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var mapping: [String: String] = [:]
                    for speaker in speakers {
                        if !speaker.displayName.isEmpty {
                            mapping[speaker.id] = speaker.displayName
                        }
                    }
                    onSave(mapping)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func playSample(_ url: URL) {
        audioPlayer?.stop()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }
}
```

- [ ] **Step 2: Add "Rename Speakers..." to MenuView**

In `TranscriberApp/Views/MenuView.swift`, add the menu item between "Open Recordings Folder" and the Settings divider:

```swift
// Add after "Open Recordings Folder" button, before the divider:
Button("Rename Speakers...") {
    appState.showRenameSheet = true
}
.disabled(!appState.isIdle)
```

Note: Wiring the sheet to open a file picker for selecting a transcript JSON file, then parsing speakers from it, and presenting `RenameDialog` as a sheet will require a `Window` scene or a floating panel. The exact presentation mechanism (sheet vs separate window) should be refined during implementation since `MenuBarExtra` with `.menu` style does not support `.sheet()`. A pragmatic approach is to use `NSPanel` presented programmatically, similar to how `SettingsAccess` works.

- [ ] **Step 3: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/RenameDialog.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat: RenameDialog with speaker list, audio preview, and save"
```

---

## Task 10: Packaging — Info.plist + embed_python.sh

**Goal:** Create the packaging artifacts so the app can be built and run as a proper .app bundle with the XPC service and embedded Python.

**Files:**
- Modify: `Packaging/Info.plist` (update for new binary)
- Create: `Packaging/AudioCaptureHelper-Info.plist` (XPC service plist)
- Create: `Packaging/embed_python.sh`

- [ ] **Step 1: Update Info.plist for the SwiftUI app**

The existing `Packaging/Info.plist` is mostly correct. Key changes:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.audio-transcribe.app</string>

    <key>CFBundleName</key>
    <string>Audio Transcribe</string>

    <key>CFBundleDisplayName</key>
    <string>Audio Transcribe</string>

    <key>CFBundleVersion</key>
    <string>2.0.0</string>

    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>

    <key>CFBundleExecutable</key>
    <string>AudioTranscribe</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>

    <key>LSUIElement</key>
    <true/>

    <key>NSScreenCaptureUsageDescription</key>
    <string>Audio Transcribe needs Screen Recording permission to capture system audio from meetings.</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>Audio Transcribe needs microphone access to record your voice.</string>
</dict>
</plist>
```

- [ ] **Step 2: Create XPC service Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.audio-transcribe.capture-helper</string>

    <key>CFBundleName</key>
    <string>AudioCaptureHelper</string>

    <key>CFBundleVersion</key>
    <string>2.0.0</string>

    <key>CFBundlePackageType</key>
    <string>XPC!</string>

    <key>CFBundleExecutable</key>
    <string>audio-capture-helper-xpc</string>

    <key>XPCService</key>
    <dict>
        <key>ServiceType</key>
        <string>Application</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 3: Create embed_python.sh**

```bash
#!/usr/bin/env bash
# embed_python.sh — Embeds the relocatable conda Python environment into the
# Xcode build output so the app can launch transcribe.py.
#
# Usage: bash Packaging/embed_python.sh [BUILD_DIR]
#   BUILD_DIR defaults to .build/debug (SPM) or the Xcode DerivedData path.
#
# Run once after cloning, or whenever Python dependencies change.

set -euo pipefail

CONDA_ENV="${CONDA_PREFIX:?Error: activate your conda environment first}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Determine build output directory
BUILD_DIR="${1:-.build/debug}"
RESOURCES_DIR="${BUILD_DIR}/AudioTranscribe.app/Contents/Resources"

echo "==> Embedding Python from: $CONDA_ENV"
echo "==> Into: $RESOURCES_DIR"

mkdir -p "$RESOURCES_DIR"

# 1. Copy relocatable Python framework
echo "  Copying Python framework..."
mkdir -p "$RESOURCES_DIR/python"
rsync -a --delete \
    "$CONDA_ENV/" \
    "$RESOURCES_DIR/python/" \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='pip*' \
    --exclude='setuptools*'

# 2. Copy Python application scripts
echo "  Copying Python scripts..."
mkdir -p "$RESOURCES_DIR/Python/service"
cp "$PROJECT_ROOT/transcribe.py" "$RESOURCES_DIR/Python/"
cp "$PROJECT_ROOT/rename_speakers.py" "$RESOURCES_DIR/Python/"
cp "$PROJECT_ROOT/service/config_manager.py" "$RESOURCES_DIR/Python/service/"
cp "$PROJECT_ROOT/service/logger.py" "$RESOURCES_DIR/Python/service/"
# Copy __init__.py if it exists
[ -f "$PROJECT_ROOT/service/__init__.py" ] && \
    cp "$PROJECT_ROOT/service/__init__.py" "$RESOURCES_DIR/Python/service/"

echo "==> Done. Python embedded successfully."
```

- [ ] **Step 4: Make embed_python.sh executable**

```bash
chmod +x Packaging/embed_python.sh
```

- [ ] **Step 5: Commit**

```bash
git add Packaging/Info.plist Packaging/AudioCaptureHelper-Info.plist Packaging/embed_python.sh
git commit -m "feat: packaging — Info.plists for app + XPC service, embed_python.sh"
```

---

## Task 11: Integration Test — Build, Launch, Click Through

**Goal:** Verify the complete app builds, launches as a menu bar icon, opens settings, and the XPC connection initializes.

**Files:** No new files — this is a manual verification task.

- [ ] **Step 1: Full build**

```bash
cd /Users/fmasi/Git/Transcriber
swift build 2>&1 | tail -20
```

Expected: Build succeeds with no errors.

- [ ] **Step 2: Run the app**

```bash
.build/debug/AudioTranscribe
```

Expected: A microphone icon appears in the menu bar. Clicking it shows: Start Recording, Open Recordings Folder, Settings..., Quit.

- [ ] **Step 3: Test Settings**

Click Settings... — a settings window should open with all fields (Recording Directory, Output Format, Silence Detection, HF Token, Launch at Login). Change a value, click Save, verify `~/.audio-transcribe/config.json` updates.

- [ ] **Step 4: Test recording flow (requires TCC permission)**

Click Start Recording — the menu icon should change to a recording indicator. Click Stop Recording — should transition to transcribing state (will fail if Python not embedded, which is expected at this stage).

- [ ] **Step 5: Verify XPC service connection**

Check Console.app for XPC-related messages. If the XPC service fails to connect, the error should appear in `appState.errorMessage`.

- [ ] **Step 6: Test Quit**

Click Quit — the app should terminate cleanly.

- [ ] **Step 7: Note any issues for follow-up**

Document any issues found during testing. Common issues:
- XPC service not found (needs to be embedded in .app bundle structure)
- TCC permissions not granted (expected on first run)
- Python not embedded (expected until embed_python.sh is run)

---

## Task 12: Clean Up Python UI Code

**Goal:** Remove the Python UI modules that have been replaced by SwiftUI. Keep only Python code that the CLI and transcription pipeline need.

**Files:**
- Delete: `service/menu_bar_app.py`
- Delete: `service/settings_window.py`
- Delete: `service/rename_dialog.py`
- Delete: `service/audio_capture.py`
- Delete: `service/pipeline.py`
- Delete: `service/job_queue.py`
- Delete: `service/login_item.py`
- Delete: `service/silence_detector.py`
- Delete: `packaging/launcher.sh`
- Delete: `packaging/build_app.sh`

**Important:** Do NOT delete until the SwiftUI app is verified working in Task 11. This task is intentionally last.

- [ ] **Step 1: Verify Python CLI still works independently**

```bash
python transcribe.py --help
```

Expected: Help text prints. The CLI doesn't depend on any of the files being deleted.

- [ ] **Step 2: Check for imports of deleted modules**

```bash
grep -r "from service.menu_bar_app\|from service.settings_window\|from service.rename_dialog\|from service.audio_capture\|from service.pipeline\|from service.job_queue\|from service.login_item\|from service.silence_detector" --include="*.py" .
```

Expected: Only hits in the files being deleted, not in `transcribe.py` or `rename_speakers.py`.

- [ ] **Step 3: Delete replaced Python files**

```bash
rm service/menu_bar_app.py
rm service/settings_window.py
rm service/rename_dialog.py
rm service/audio_capture.py
rm service/pipeline.py
rm service/job_queue.py
rm service/login_item.py
rm service/silence_detector.py
rm packaging/launcher.sh
rm packaging/build_app.sh
```

- [ ] **Step 4: Verify Python CLI still works after deletion**

```bash
python transcribe.py --help
```

Expected: Still works — no broken imports.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove Python UI code replaced by native SwiftUI app"
```

---

## Summary of Tasks

| # | Task | Files | Approx Effort |
|---|------|-------|--------------|
| 1 | Xcode project scaffold + XPC protocol | Package.swift, protocol, placeholders | 15 min |
| 2 | Config model + ConfigManager | Config.swift, ConfigManager.swift | 10 min |
| 3 | AppState observable model | AppState.swift | 5 min |
| 4 | XPC audio capture service | 4 files in AudioCaptureHelper/XPC/ | 25 min |
| 5 | AudioCaptureClient (app-side) | AudioCaptureClient.swift | 10 min |
| 6 | TranscriptionRunner | TranscriptionRunner.swift | 10 min |
| 7 | MenuView + recording flow | MenuView.swift, update TranscriberApp.swift | 20 min |
| 8 | SettingsView | SettingsView.swift | 10 min |
| 9 | RenameDialog | RenameDialog.swift | 15 min |
| 10 | Packaging | Info.plists, embed_python.sh | 10 min |
| 11 | Integration test | Manual verification | 20 min |
| 12 | Clean up Python UI code | Delete 10 files | 5 min |
