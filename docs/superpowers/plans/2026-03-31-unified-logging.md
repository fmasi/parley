# Unified Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace silent failures and ad-hoc print/fputs with Apple's unified logging (`os.Logger`), instrument pain-point areas, forward Python output into the unified log, and replace the broken `--console` dev flag with `--debug`.

**Architecture:** Single subsystem `com.audio-transcribe.app` with 6 categories (audio, transcription, state, config, permissions, files). Logger extension in TranscriberCore; XPC service gets its own copy (separate process). TranscriptionRunner forwards Python stdout/stderr line-by-line into unified log. `logLevel` config field removed as dead code.

**Tech Stack:** `os.Logger` (macOS 14+), Swift Testing, Python argparse

**Spec:** `docs/superpowers/specs/2026-03-31-unified-logging-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `TranscriberCore/Log.swift` | Logger extension with 6 category statics |
| ~~Create~~ | ~~`AudioCaptureHelper/XPC/Log.swift`~~ | Not needed — XPC service links TranscriberCore (see Package.swift:30) and can use Logger extension directly |
| Modify | `TranscriberCore/Config.swift` | Remove `logLevel` property |
| Modify | `TranscriberCore/ConfigManager.swift` | Log config load/save |
| Modify | `TranscriberCore/AppState.swift` | Log phase transitions and error message lifecycle |
| Modify | `TranscriberCore/WavFileWriter.swift` | Log WAV lifecycle (init, first write, finalize) — add `path` property |
| Modify | `TranscriberCore/PermissionManager.swift` | Log permission check results |
| Modify | `AudioCaptureHelper/XPC/AudioCaptureService.swift` | Log capture start/stop/errors |
| Modify | `AudioCaptureHelper/XPC/AudioOutputHandler.swift` | Log format detection, frame batches, stream errors |
| Modify | `TranscriberApp/Services/TranscriptionRunner.swift` | Real-time stdout/stderr forwarding via readabilityHandler |
| Modify | `TranscriberApp/Views/MenuView.swift` | Log recording actions, error dismiss, notifications |
| Modify | `TranscriberApp/Services/SessionNameWindowController.swift` | Log panel shown/closed |
| Modify | `TranscriberApp/Services/RenameWindowController.swift` | Log panel shown/closed |
| Modify | `scripts/dev.py` | Replace `--console` with `--debug` |
| Modify | `scripts/test-checklist.md` | Add logging verification items |
| Modify | `SwiftTests/TranscriberTests/ConfigTests.swift` | Remove logLevel expectations |
| Modify | `SwiftTests/TranscriberTests/ConfigManagerTests.swift` | Remove logLevel references |
| Modify | `CLAUDE.md` | Add debugging cheat sheet section |

---

### Task 1: Logger Infrastructure (TranscriberCore)

**Files:**
- Create: `TranscriberCore/Log.swift`

- [ ] **Step 1: Create the Logger extension**

Create `TranscriberCore/Log.swift`:

```swift
import os

extension Logger {
    private static let subsystem = "com.audio-transcribe.app"

    /// Audio capture: stream lifecycle, format detection, device selection
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Transcription: Python process launch, output forwarding, completion
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// App state: phase transitions, error message lifecycle
    static let state = Logger(subsystem: subsystem, category: "state")
    /// Config: load, save, parse failures
    static let config = Logger(subsystem: subsystem, category: "config")
    /// Permissions: check results, grant/deny
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Files: WAV lifecycle, output path resolution
    static let files = Logger(subsystem: subsystem, category: "files")
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TranscriberCore 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/Log.swift
git commit -m "feat: add os.Logger extension with category-based logging"
```

---

### Task 2: Remove logLevel from Config

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigManagerTests.swift`
- Modify: `service/config_manager.py`

Note: Swift's `JSONDecoder` silently ignores unknown keys when using explicit `CodingKeys`. Existing `config.json` files with `log_level` will decode fine — the key is simply skipped. The Python side already filters to valid field names (`{f.name for f in fields(Config)}`), so removing `log_level` from the Python dataclass is also safe.

- [ ] **Step 1: Update tests to remove logLevel expectations**

In `SwiftTests/TranscriberTests/ConfigTests.swift`:

- In `defaultValues()` (line 16): remove `#expect(config.logLevel == "info")`
- In `memberWiseInit()` (lines 31, 38): remove `logLevel: "debug"` from init call and `#expect(config.logLevel == "debug")`
- In `encodeDecodeRoundTrip()` (line 51): remove `logLevel: "warning"` from init call
- In `snakeCaseKeys()` (line 71): remove `#expect(json["log_level"] != nil)`
- In `decodesFromSnakeCaseJSON()` (line 88): remove `"log_level": "debug"` from JSON string

In `SwiftTests/TranscriberTests/ConfigManagerTests.swift`:

- In `updateAppliesTransformAndPersists()` (line 83-84): remove `config.logLevel = "debug"` and `#expect(manager.config.logLevel == "debug")`

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests 2>&1 | grep -E '(error:|Test run)' | head -10`
Expected: Compilation errors — `logLevel` references in test don't match because tests reference a property that still exists. Actually, at this point the tests should still compile and pass because we only removed test assertions, not the property. Let's proceed to remove the property.

- [ ] **Step 3: Remove logLevel from Config.swift**

In `TranscriberCore/Config.swift`:

- Remove line 9: `public var logLevel: String`
- Remove from `static let default` (line 20): `logLevel: "info",`
- Remove from `public init(...)` parameter list (line 32): `logLevel: String = "info",`
- Remove from init body (line 42): `self.logLevel = logLevel`
- Remove from `CodingKeys` (line 54): `case logLevel = "log_level"`

- [ ] **Step 4: Remove log_level from Python Config**

In `service/config_manager.py`, remove line 16: `log_level: str = "info"`

- [ ] **Step 5: Run all tests to verify they pass**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ 2>&1 | tail -10`
Expected: All tests pass

Run: `python -m pytest tests/ -q 2>&1 | tail -5`
Expected: All Python tests pass

- [ ] **Step 6: Verify existing config.json still loads**

This is a sanity check — since JSONDecoder ignores unknown keys with explicit CodingKeys, an existing config.json with `log_level` should decode without error. The tests already cover this implicitly (the `partialJSONDecodesAllFields` test has `log_level` in its JSON fixture — after removing logLevel from Config, that JSON will have an extra key that gets ignored).

Actually, we need to update that test fixture too. In `ConfigManagerTests.swift`, the `partialJSONDecodesAllFields` test (line 100-113) has `"log_level": "info"` in its JSON. Leave it in place — this serves as a regression test confirming that old config files with `log_level` still decode correctly.

- [ ] **Step 7: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift SwiftTests/TranscriberTests/ConfigManagerTests.swift service/config_manager.py
git commit -m "refactor: remove unused logLevel config field"
```

---

### Task 3: Add Logging to ConfigManager

**Files:**
- Modify: `TranscriberCore/ConfigManager.swift`

- [ ] **Step 1: Add logging to load and save**

In `TranscriberCore/ConfigManager.swift`, add `import os` at the top (line 1, after `import Foundation`).

Replace the `load(from:)` method (lines 19-26) with:

```swift
    private static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            Logger.config.info("Config not found or invalid, using defaults")
            return .default
        }
        Logger.config.info("Config loaded — format: \(config.outputFormat, privacy: .public), hfToken: \(config.hfToken.isEmpty ? "not set" : "set", privacy: .public)")
        return config
    }
```

Add logging to `save()` (line 28). After `try? data.write(...)` (line 35), add:

```swift
        Logger.config.debug("Config saved")
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TranscriberCore 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/ConfigManager.swift
git commit -m "feat: add unified logging to ConfigManager"
```

---

### Task 4: Add Logging to AppState

**Files:**
- Modify: `TranscriberCore/AppState.swift`

`@Observable` supports `didSet` — the observation registrar wraps access, but `didSet` still fires. `String(describing:)` on Swift enums produces readable output like `idle`, `recording(since: ...)`, so no `CustomStringConvertible` conformance needed.

- [ ] **Step 1: Add phase transition and error logging**

In `TranscriberCore/AppState.swift`, add `import os` after `import Observation` (line 2).

Replace the `phase` and `errorMessage` declarations (lines 12-15):

```swift
    public var phase: Phase = .idle {
        didSet {
            if oldValue != phase {
                Logger.state.info("State: \(String(describing: oldValue), privacy: .public) -> \(String(describing: phase), privacy: .public)")
            }
        }
    }
    public var lastTranscriptPath: String?
    public var lastJsonPath: String?
    public var errorMessage: String? {
        didSet {
            if let msg = errorMessage {
                Logger.state.info("Error set: \(msg, privacy: .public)")
            } else if oldValue != nil {
                Logger.state.info("Error cleared")
            }
        }
    }
```

- [ ] **Step 2: Run tests to verify nothing broke**

Run: `swift test --filter TranscriberTests/AppStateTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ 2>&1 | tail -10`
Expected: All AppState tests pass

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/AppState.swift
git commit -m "feat: add unified logging to AppState phase transitions and error lifecycle"
```

---

### Task 5: Add Logging to WavFileWriter

**Files:**
- Modify: `TranscriberCore/WavFileWriter.swift`

WavFileWriter currently doesn't store its path, but we need it for logging finalize. Add a `path` property.

- [ ] **Step 1: Add path storage and logging**

In `TranscriberCore/WavFileWriter.swift`, add `import os` after `import Foundation` (line 1).

Add a `path` property and a `firstWriteLogged` flag. Replace the top of the class (lines 3-13):

```swift
public final class WavFileWriter {
    private let fileHandle: FileHandle
    private let path: String
    private var dataByteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0
    private var channelCount: UInt16 = 1
    private var firstWriteLogged = false

    public init(path: String) throws {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader(sampleRate: 16000, channels: 1, dataSize: 0)
        Logger.files.debug("WAV writer created: \(path, privacy: .private)")
    }
```

Add first-write logging to `append(_:)`. After `dataByteCount += UInt32(bytes.count)` (line 31), add:

```swift
        logFirstWrite()
```

Add first-write logging to `appendInt16(_:)`. After `dataByteCount += UInt32(bytes.count)` (line 38), add:

```swift
        logFirstWrite()
```

Add the `logFirstWrite()` helper and update `finalize()`. After `appendInt16` method, add:

```swift
    private func logFirstWrite() {
        guard !firstWriteLogged else { return }
        firstWriteLogged = true
        let rate = sampleRate > 0 ? sampleRate : 16000
        Logger.files.info("WAV first write — sampleRate: \(rate), channels: \(self.channelCount), path: \(self.path, privacy: .private)")
    }
```

In `finalize()` (line 41), after `fileHandle.closeFile()` (line 47), add:

```swift
        Logger.files.info("WAV finalized: \(self.path, privacy: .private), size: \(self.dataByteCount) bytes")
```

- [ ] **Step 2: Run WavFileWriter tests**

Run: `swift test --filter TranscriberTests/WavFileWriterTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/WavFileWriter.swift
git commit -m "feat: add unified logging to WavFileWriter lifecycle"
```

---

### Task 6: Add Logging to AudioCaptureService (XPC)

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift`

- [ ] **Step 1: Add logging to startCapture, stopCapture, and errors**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`, add `import os` after `import Foundation` (line 2).

In `startCapture(...)`, after the `guard !isCapturing` check (line 19-22), add before `let sysPath = ...` (line 24):

```swift
        Logger.audio.info("Starting capture — dir: \(outputDirectory, privacy: .private), base: \(baseName, privacy: .public), mic: \(microphoneDeviceId ?? "default", privacy: .public)")
```

In the `Task { do { ... } }` block, after `try await self.configureAndStart(...)` (line 43), before `self.isCapturing = true`, add:

```swift
                    Logger.audio.info("SCStream started, awaiting frames")
```

In the catch block (line 46-54), after `self.cleanupAfterFailure()`, add:

```swift
                    Logger.audio.error("Capture failed: \(error, privacy: .public)")
```

In the outer catch (line 57-59), add:

```swift
            Logger.audio.error("Failed to open output files: \(error, privacy: .public)")
```

In `stopCapture(...)`, after the guard (line 65-68), add:

```swift
        Logger.audio.info("Stopping capture")
```

After `try await stream.stopCapture()` succeeds (line 72), add inside the do block:

```swift
                Logger.audio.debug("SCStream stopped")
```

In `configureAndStart(...)`, after filtering for display, add logging for the mic device. After `config.microphoneCaptureDeviceID = microphoneDeviceId` (line 120), add:

```swift
            Logger.audio.debug("Mic capture device override: \(microphoneDeviceId, privacy: .public)")
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target AudioCaptureHelperXPC 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "feat: add unified logging to AudioCaptureService"
```

---

### Task 7: Add Logging to AudioOutputHandler (XPC)

**Files:**
- Modify: `AudioCaptureHelper/XPC/AudioOutputHandler.swift`

- [ ] **Step 1: Add logging to format detection, frame batches, and stream errors**

In `AudioCaptureHelper/XPC/AudioOutputHandler.swift`, add `import os` after `import Foundation` (line 2).

In the `stream(_:didOutputSampleBuffer:of:)` method:

In the system audio first-detection block (lines 29-34), after `systemWriter.setChannelCount(...)`, add:

```swift
                    Logger.audio.info("System audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
```

In the mic first-detection block (lines 39-43), after `micWriter.setChannelCount(...)`, add:

```swift
                    Logger.audio.info("Mic audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
```

After writing samples (after the `if isFloat { ... } else { ... }` block, around line 71), add:

```swift
        Logger.audio.debug("\(type == .audio ? "System" : "Mic", privacy: .public) frame: \(totalLength) bytes")
```

In `stream(_:didStopWithError:)` (line 74-76), replace the comment body:

```swift
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.audio.error("Stream stopped with error: \(error, privacy: .public)")
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target AudioCaptureHelperXPC 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add AudioCaptureHelper/XPC/AudioOutputHandler.swift
git commit -m "feat: add unified logging to AudioOutputHandler format detection and frame delivery"
```

---

### Task 8: Add Logging to TranscriptionRunner (Real-Time Forwarding)

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

This is the most complex change. We switch from `readDataToEndOfFile()` at termination to `readabilityHandler` for real-time line-by-line forwarding, while still accumulating stderr for the error message on failure.

- [ ] **Step 1: Add logging and real-time forwarding**

Add imports at the top of the file: `import os` and `import TranscriberCore` (needed for the Logger extension). TranscriberApp depends on TranscriberCore in Package.swift.

Replace the entire `run(...)` method body. This is the full replacement for lines 23-116:

```swift
    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputFormat: String,
        outputDirectory: URL,
        hfToken: String = ""
    ) async throws -> TranscriptionResult {
        let resources = Bundle.main.resourceURL!
        let pythonHome = resources.appendingPathComponent("python")
        let pythonBin = pythonHome.appendingPathComponent("bin/python3")
        let sitePackages = pythonHome
            .appendingPathComponent("lib/python3.11/site-packages")
        let transcribeScript = resources
            .appendingPathComponent("Python/transcribe.py")

        guard FileManager.default.fileExists(atPath: pythonBin.path) else {
            throw RunnerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RunnerError.scriptNotFound
        }

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputFile = outputDirectory
            .appendingPathComponent(baseName + "." + outputFormat)

        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", outputFormat]
        arguments += ["-o", outputFile.path]
        if !hfToken.isEmpty {
            arguments += ["--hf-token", hfToken]
        }

        let inputCount = micAudio != nil ? 2 : 1
        Logger.transcription.info("Launching transcription — format: \(outputFormat, privacy: .public), inputs: \(inputCount)")
        Logger.transcription.debug("Python args: \(arguments, privacy: .private)")

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = arguments
        process.environment = [
            "PYTHONHOME": pythonHome.path,
            "PYTHONPATH": sitePackages.path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": [
                pythonHome.appendingPathComponent("bin").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ].joined(separator: ":"),
        ]

        Logger.transcription.debug("Python env — PYTHONHOME: \(pythonHome.path, privacy: .private), PATH: \(process.environment?["PATH"] ?? "", privacy: .private)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate stderr for error reporting on failure
        let stderrAccumulator = StderrAccumulator()

        // Real-time forwarding of Python output to unified log
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                Logger.transcription.info("[python] \(line, privacy: .public)")
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrAccumulator] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrAccumulator.append(data)
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    Logger.transcription.error("[python-err] \(line, privacy: .public)")
                }
            }
        }

        let startTime = ContinuousClock.now

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { [stderrAccumulator] proc in
                // Clean up handlers to avoid retain cycles
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let elapsed = ContinuousClock.now - startTime
                let seconds = elapsed.components.seconds

                if proc.terminationStatus != 0 {
                    let stderr = stderrAccumulator.string
                    // Read any remaining stdout
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let output = stderr.isEmpty ? stdout : stderr
                    Logger.transcription.error("Transcription failed — exit code: \(proc.terminationStatus), duration: \(seconds)s")
                    cont.resume(throwing: RunnerError.failed(
                        "transcribe.py exited with code \(proc.terminationStatus): \(output)"
                    ))
                    return
                }

                Logger.transcription.info("Transcription complete — exit code: 0, duration: \(seconds)s")

                let jsonFile = outputDirectory
                    .appendingPathComponent(baseName + ".json")
                cont.resume(returning: TranscriptionResult(
                    outputPath: outputFile,
                    jsonPath: jsonFile
                ))
            }

            do {
                try process.run()
            } catch {
                Logger.transcription.error("Failed to launch Python: \(error, privacy: .public)")
                cont.resume(throwing: RunnerError.failed(
                    "Failed to launch transcribe.py: \(error.localizedDescription)"
                ))
            }
        }
    }
```

Add the `StderrAccumulator` helper class at the bottom of the file, after the closing brace of `TranscriptionRunner`:

```swift
/// Thread-safe accumulator for stderr data from the Python process.
private final class StderrAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TranscriberApp 2>&1 | tail -10`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: add real-time Python output forwarding to unified log in TranscriptionRunner"
```

---

### Task 9: Add Logging to MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add logging to recording actions, error dismiss, and notifications**

In `TranscriberApp/Views/MenuView.swift`, add `import os` after `import UserNotifications` (line 4).

In the `body` computed property, in the "Dismiss Error" button action (line 17-19), add before `appState.errorMessage = nil`:

```swift
                Logger.state.debug("User dismissed error")
```

In `startRecording(...)` (line 75), add at the start of the method:

```swift
        Logger.state.info("Recording started — session: \(sessionName, privacy: .public)")
```

In `stopRecording()` (line 109), add at the start:

```swift
        Logger.state.info("Recording stopped")
```

In `sendNotification(...)` (line 138), add after the `guard` (line 139):

```swift
        Logger.state.debug("Sending notification: \(title, privacy: .public)")
```

Replace the `UNUserNotificationCenter.current().add(request)` call (line 148) to capture errors:

```swift
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.state.error("Notification failed: \(error, privacy: .public)")
            }
        }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TranscriberApp 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: add unified logging to MenuView recording actions and notifications"
```

---

### Task 10: Add Logging to PermissionManager

**Files:**
- Modify: `TranscriberCore/PermissionManager.swift`

- [ ] **Step 1: Add logging to permission checks**

In `TranscriberCore/PermissionManager.swift`, add `import os` after `import Observation` (line 2).

In `checkAll()` (line 45-50), add at the end of the method:

```swift
        Logger.permissions.info("Permissions — mic: \(String(describing: self.microphone), privacy: .public), screen: \(String(describing: self.screenRecording), privacy: .public), calendar: \(String(describing: self.calendar), privacy: .public), notifications: \(String(describing: self.notifications), privacy: .public)")
```

In each `request*` method, add a debug log after the assignment. For example, in `requestMicrophone()` (line 52-54), after `microphone = await checker.requestMicrophone()`:

```swift
        Logger.permissions.debug("Microphone permission: \(String(describing: self.microphone), privacy: .public)")
```

Do the same for `requestScreenRecording()`, `requestCalendar()`, and `requestNotifications()`:

```swift
        Logger.permissions.debug("Screen recording permission: \(String(describing: self.screenRecording), privacy: .public)")
```

```swift
        Logger.permissions.debug("Calendar permission: \(String(describing: self.calendar), privacy: .public)")
```

```swift
        Logger.permissions.debug("Notifications permission: \(String(describing: self.notifications), privacy: .public)")
```

- [ ] **Step 2: Run PermissionManager tests**

Run: `swift test --filter TranscriberTests/PermissionManagerTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/PermissionManager.swift
git commit -m "feat: add unified logging to PermissionManager"
```

---

### Task 11: Add Logging to Window Controllers

**Files:**
- Modify: `TranscriberApp/Services/SessionNameWindowController.swift`
- Modify: `TranscriberApp/Services/RenameWindowController.swift`

- [ ] **Step 1: Add panel lifecycle logging to SessionNameWindowController**

In `TranscriberApp/Services/SessionNameWindowController.swift`, add `import os` after `import TranscriberCore` (line 3).

After `self.panel = newPanel` (line 58), add:

```swift
        Logger.state.debug("Panel shown: SessionName")
```

In the `closePanel` closure (lines 22-25), add before `self?.panel?.close()`:

```swift
            Logger.state.debug("Panel closed: SessionName")
```

- [ ] **Step 2: Add panel lifecycle logging to RenameWindowController**

In `TranscriberApp/Services/RenameWindowController.swift`, add `import os` and `import TranscriberCore` after `import SwiftUI` (line 2).

After `self.panel = newPanel` (line 55), add:

```swift
        Logger.state.debug("Panel shown: RenameSpeakers")
```

In the `closePanel` closure (lines 18-21), add before `self?.panel?.close()`:

```swift
            Logger.state.debug("Panel closed: RenameSpeakers")
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build --target TranscriberApp 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/SessionNameWindowController.swift TranscriberApp/Services/RenameWindowController.swift
git commit -m "feat: add unified logging to window controller panel lifecycle"
```

---

### Task 12: Replace --console with --debug in dev.py

**Files:**
- Modify: `scripts/dev.py`

- [ ] **Step 1: Replace --console with --debug**

In `scripts/dev.py`:

Replace the `--console` argument (lines 58-59):

```python
    mods.add_argument("--debug", action="store_true",
                      help="Launch app normally, then tail unified log (Ctrl+C to stop)")
```

In `resolve_steps()` (lines 66-80), replace the `--console` handling:

```python
def resolve_steps(args: argparse.Namespace) -> set[str]:
    """Determine which steps to run based on flags."""
    explicit = {f for f in STEP_FLAGS if getattr(args, f)}

    if explicit:
        steps = explicit
    else:
        steps = set(DEFAULT_STEPS)

    # Modifier: --debug adds log tailing after launch
    if args.debug:
        steps.add("debug")

    return steps
```

Replace the `do_console()` function (lines 147-163) with `do_debug()`:

```python
def do_debug() -> None:
    step("Tailing unified log (Ctrl+C to stop)")
    print(f"   Subsystem: {BUNDLE_ID}")
    print(f"   Level: debug\n")
    try:
        subprocess.run([
            "log", "stream",
            "--predicate", f'subsystem == "{BUNDLE_ID}"',
            "--level", "debug",
            "--style", "compact",
        ])
    except KeyboardInterrupt:
        print("\n   Log stream stopped.")
```

In the docstring (lines 2-17), update the examples:

```python
"""Developer iteration tool for AudioTranscribe.

Build, install, and launch the app for manual testing.

Default (no flags): kill -> build -> install -> launch + print checklist.
Step flags (--kill, --build, --install, --launch, --reset-tcc) switch to explicit mode.
Modifier flags (--debug, --skip-embed) layer on top of default or explicit steps.

Examples:
    python scripts/dev.py                          # full cycle
    python scripts/dev.py --debug                  # full cycle + tail unified log
    python scripts/dev.py --reset-tcc              # just reset TCC permissions
    python scripts/dev.py --reset-tcc --launch     # reset + launch
    python scripts/dev.py --build --install        # build + install only
    python scripts/dev.py --kill --launch          # relaunch existing install
    python scripts/dev.py --skip-embed             # full cycle, skip Python embedding
"""
```

In `main()` (lines 175-198), replace the launch/console block at the end:

```python
    if "launch" in steps:
        do_launch()
        print_checklist()
    if "debug" in steps:
        do_debug()  # blocking — runs after launch
```

Note: `--debug` does NOT replace `--launch`. It adds log tailing after launch. If the user runs `python scripts/dev.py --debug`, the default steps include `launch`, and then `debug` tails the log. If they run `python scripts/dev.py --launch --debug`, same thing.

- [ ] **Step 2: Verify the script parses correctly**

Run: `python scripts/dev.py --help 2>&1 | head -20`
Expected: Shows `--debug` in modifiers, no `--console`

- [ ] **Step 3: Commit**

```bash
git add scripts/dev.py
git commit -m "feat: replace --console with --debug flag that tails unified log"
```

---

### Task 13: Update test-checklist.md

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add logging verification items**

Append to `scripts/test-checklist.md`:

```markdown

## Unified Logging
- [ ] Run `python scripts/dev.py --debug` — log stream starts after app launches
- [ ] Start recording — see "Recording started" and "Starting capture" in log stream
- [ ] Observe "System audio: ...Hz" and "Mic audio: ...Hz" format detection lines
- [ ] Stop recording — see "Stopping capture" and "Launching transcription" lines
- [ ] Python progress lines appear as `[python] Transcribing audio...` etc.
- [ ] Transcription completes — see duration in "Transcription complete" line
- [ ] Ctrl+C stops log stream; app keeps running
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add unified logging items to test checklist"
```

---

### Task 14: Update CLAUDE.md with Debugging Cheat Sheet

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add debugging section to CLAUDE.md**

Add after the `## Key Gotchas` section (after gotcha 23):

```markdown

## Debugging with Unified Logging
All Swift components log via `os.Logger` with subsystem `com.audio-transcribe.app`. Categories: `audio`, `transcription`, `state`, `config`, `permissions`, `files`.

```bash
# All logs (debug + info + error) — use during development
log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug

# Only errors
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND messageType == error'

# Only audio capture (format detection, frame delivery)
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND category == "audio"' --level debug

# Only Python transcription output
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND category == "transcription"'

# Historical (last 5 minutes)
log show --predicate 'subsystem == "com.audio-transcribe.app"' --last 5m

# Via dev.py (launches app + tails log)
python scripts/dev.py --debug
```
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add unified logging debugging cheat sheet to CLAUDE.md"
```

---

### Task 15: Final Build and Test Verification

- [ ] **Step 1: Run full Swift test suite**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ 2>&1 | tail -15`
Expected: All tests pass (102 tests minus logLevel-related ones that were removed, plus any that referenced logLevel in fixtures)

- [ ] **Step 2: Run full Python test suite**

Run: `python -m pytest tests/ -q 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 3: Build all targets**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded for all targets

- [ ] **Step 4: Commit any remaining fixes**

If any tests or builds failed, fix and commit.
