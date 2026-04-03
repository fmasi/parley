# Crash Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recording survive UI and XPC crashes — auto-relaunch, silent re-attach, automatic restart, transcript stitching.

**Architecture:** A sentinel JSON file persists recording state to disk. The XPC service detects client death via `invalidationHandler` and finalizes WAV files. A LaunchAgent keeps the app running. On launch, the app checks for the sentinel and either re-attaches to a live XPC session or restarts recording. Multi-segment recordings are stitched at transcription time.

**Tech Stack:** Swift, NSXPCConnection, ScreenCaptureKit, launchctl, UNUserNotificationCenter

**Worktree:** `/Users/fmasi/Git/Transcriber-crash-recovery` (branch: `feature/crash-recovery`)

**Test command:**
```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery && swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `TranscriberCore/RecordingSentinel.swift` | Create | Codable sentinel struct, atomic write/read/delete |
| `TranscriberCore/LaunchAgentManager.swift` | Create | Install/unload/check LaunchAgent plist |
| `SwiftTests/TranscriberTests/RecordingSentinelTests.swift` | Create | Sentinel unit tests |
| `SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift` | Create | LaunchAgent manager unit tests |
| `AudioCaptureHelper/XPC/main.swift` | Modify | Add connection invalidation handler |
| `TranscriberApp/Services/AudioCaptureClient.swift` | Modify | XPC crash detection + auto-restart callback |
| `TranscriberApp/Views/MenuView.swift` | Modify | Sentinel write/delete around recording lifecycle, recovery on launch |
| `TranscriberApp/TranscriberApp.swift` | Modify | Recovery check on launch, LaunchAgent lifecycle |
| `TranscriberCore/AppState.swift` | Modify | Add `interruptionWarning` property for menu bar icon |
| `TranscriberApp/Services/TranscriptionRunner.swift` | Modify | Multi-segment transcription + stitching |
| `TranscriberCore/WavFileWriter.swift` | Already done | 0.5s periodic sync |

---

### Task 1: RecordingSentinel — Write/Read/Delete

**Files:**
- Create: `TranscriberCore/RecordingSentinel.swift`
- Test: `SwiftTests/TranscriberTests/RecordingSentinelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `SwiftTests/TranscriberTests/RecordingSentinelTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct RecordingSentinelTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentinelTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func writeAndReadRoundTrip() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let sentinel = RecordingSentinel(
            startedAt: Date(timeIntervalSince1970: 1000),
            sessionName: "Test Meeting",
            systemAudioPath: "/tmp/system.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: "BuiltInMic",
            segment: 1
        )

        try RecordingSentinel.write(sentinel, directory: dir)
        let loaded = RecordingSentinel.read(directory: dir)
        #expect(loaded != nil)
        #expect(loaded?.sessionName == "Test Meeting")
        #expect(loaded?.systemAudioPath == "/tmp/system.wav")
        #expect(loaded?.micAudioPath == "/tmp/mic.wav")
        #expect(loaded?.micDeviceUID == "BuiltInMic")
        #expect(loaded?.segment == 1)
    }

    @Test func readReturnsNilWhenNoFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let loaded = RecordingSentinel.read(directory: dir)
        #expect(loaded == nil)
    }

    @Test func deleteRemovesFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let sentinel = RecordingSentinel(
            startedAt: Date(),
            sessionName: "X",
            systemAudioPath: "/tmp/sys.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: nil,
            segment: 1
        )
        try RecordingSentinel.write(sentinel, directory: dir)
        #expect(RecordingSentinel.read(directory: dir) != nil)

        RecordingSentinel.delete(directory: dir)
        #expect(RecordingSentinel.read(directory: dir) == nil)
    }

    @Test func deleteIsNoOpWhenNoFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Should not throw
        RecordingSentinel.delete(directory: dir)
    }

    @Test func writeIsAtomic() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let sentinel = RecordingSentinel(
            startedAt: Date(),
            sessionName: "Atomic",
            systemAudioPath: "/tmp/sys.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: nil,
            segment: 1
        )
        try RecordingSentinel.write(sentinel, directory: dir)

        // File should exist at the canonical path
        let filePath = dir.appendingPathComponent("recording.json")
        #expect(FileManager.default.fileExists(atPath: filePath.path))
    }

    @Test func segmentIncrements() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let sentinel = RecordingSentinel(
            startedAt: Date(),
            sessionName: "Multi",
            systemAudioPath: "/tmp/sys.wav",
            micAudioPath: "/tmp/mic.wav",
            micDeviceUID: nil,
            segment: 1
        )
        try RecordingSentinel.write(sentinel, directory: dir)

        let bumped = RecordingSentinel.read(directory: dir)!.incrementedSegment(
            systemAudioPath: "/tmp/sys-2.wav",
            micAudioPath: "/tmp/mic-2.wav"
        )
        #expect(bumped.segment == 2)
        #expect(bumped.systemAudioPath == "/tmp/sys-2.wav")
        #expect(bumped.sessionName == "Multi")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift test --filter TranscriberTests 2>&1 | grep -E "(error|RecordingSentinel)" | head -20`

Expected: Compilation errors — `RecordingSentinel` type not found.

- [ ] **Step 3: Implement RecordingSentinel**

Create `TranscriberCore/RecordingSentinel.swift`:

```swift
import Foundation
import os

public struct RecordingSentinel: Codable, Equatable {
    public let startedAt: Date
    public let sessionName: String
    public let systemAudioPath: String
    public let micAudioPath: String
    public let micDeviceUID: String?
    public let segment: Int

    public init(
        startedAt: Date,
        sessionName: String,
        systemAudioPath: String,
        micAudioPath: String,
        micDeviceUID: String?,
        segment: Int
    ) {
        self.startedAt = startedAt
        self.sessionName = sessionName
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.micDeviceUID = micDeviceUID
        self.segment = segment
    }

    static let fileName = "recording.json"

    public static func write(_ sentinel: RecordingSentinel, directory: URL? = nil) throws {
        let dir = directory ?? defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sentinel)

        // Atomic write: write to temp file then rename
        let target = dir.appendingPathComponent(fileName)
        let temp = dir.appendingPathComponent(".\(fileName).tmp")
        try data.write(to: temp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)

        Logger.state.info("Sentinel written — session: \(sentinel.sessionName, privacy: .public), segment: \(sentinel.segment)")
    }

    public static func read(directory: URL? = nil) -> RecordingSentinel? {
        let dir = directory ?? defaultDirectory
        let path = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSentinel.self, from: data)
    }

    public static func delete(directory: URL? = nil) {
        let dir = directory ?? defaultDirectory
        let path = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: path)
        Logger.state.info("Sentinel deleted")
    }

    public func incrementedSegment(
        systemAudioPath: String,
        micAudioPath: String
    ) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: startedAt,
            sessionName: sessionName,
            systemAudioPath: systemAudioPath,
            micAudioPath: micAudioPath,
            micDeviceUID: micDeviceUID,
            segment: segment + 1
        )
    }

    private static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".audio-transcribe")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift test --filter TranscriberTests/RecordingSentinelTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberCore/RecordingSentinel.swift SwiftTests/TranscriberTests/RecordingSentinelTests.swift
git commit -m "feat: add RecordingSentinel for crash recovery state persistence"
```

---

### Task 2: XPC Connection-Drop Handler

When the UI process dies, the XPC service must stop capture and finalize WAV files instead of recording forever.

**Files:**
- Modify: `AudioCaptureHelper/XPC/main.swift:4-16`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift:7-12`

- [ ] **Step 1: Add invalidation handler to XPC connection**

Edit `AudioCaptureHelper/XPC/main.swift`. Replace the `ServiceDelegate` class:

```swift
import Foundation
import AudioCaptureProtocol
import os

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// Shared service instance — reused across connections so a reconnecting
    /// client can re-attach to a live capture session.
    let service = AudioCaptureService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        newConnection.exportedObject = service

        newConnection.invalidationHandler = { [weak self] in
            guard let self else { return }
            Logger.audio.warning("XPC client disconnected — stopping capture and finalizing")
            self.service.stopAndFinalize()
        }

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

- [ ] **Step 2: Add `stopAndFinalize()` to AudioCaptureService**

Edit `AudioCaptureHelper/XPC/AudioCaptureService.swift`. Add this method after `stopCapture`:

```swift
/// Called when the XPC client disconnects (crash or quit).
/// Stops capture and finalizes WAV files without needing a reply.
func stopAndFinalize() {
    guard isCapturing else { return }
    Logger.audio.info("Stopping capture due to client disconnect")

    if let stream = stream {
        Task {
            try? await stream.stopCapture()
            self.handler?.finalizeAll()
            self.isCapturing = false
            self.stream = nil
            self.handler = nil
            Logger.audio.info("Capture finalized after client disconnect")
        }
    } else {
        handler?.finalizeAll()
        isCapturing = false
        handler = nil
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add AudioCaptureHelper/XPC/main.swift AudioCaptureHelper/XPC/AudioCaptureService.swift
git commit -m "fix: XPC service stops capture when client disconnects

Prevents orphaned recordings when the UI process crashes."
```

---

### Task 3: AudioCaptureClient — XPC Crash Detection + Auto-Restart

When the XPC service crashes during recording, the client must detect it and trigger a restart callback.

**Files:**
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift`

- [ ] **Step 1: Add crash detection callback and status ping**

Replace the full content of `AudioCaptureClient.swift` with:

```swift
import Foundation
import AudioCaptureProtocol
import os
import TranscriberCore

struct AudioPaths {
    let systemAudio: URL
    let micAudio: URL
}

final class AudioCaptureClient {
    private var connection: NSXPCConnection?

    /// Called on the main actor when the XPC service dies during an active session.
    /// The closure receives no arguments — the caller is responsible for restarting.
    var onServiceCrash: (@Sendable () -> Void)?

    func connect() {
        let conn = NSXPCConnection(serviceName: audioCaptureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(
            with: AudioCaptureProtocol.self
        )
        conn.invalidationHandler = { [weak self] in
            guard let self else { return }
            Logger.audio.warning("XPC connection invalidated")
            self.connection = nil
            self.onServiceCrash?()
        }
        conn.resume()
        connection = conn
    }

    /// Ping the XPC service to check if a capture is active.
    /// Returns `true` if the service is alive and capturing.
    func isCapturing() async -> Bool {
        guard let conn = connection else {
            connect()
            guard let conn = connection else { return false }
            return await pingStatus(conn)
        }
        return await pingStatus(conn)
    }

    private func pingStatus(_ conn: NSXPCConnection) async -> Bool {
        await withCheckedContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                cont.resume(returning: false)
            } as! AudioCaptureProtocol

            proxy.status { isCapturing, _ in
                cont.resume(returning: isCapturing)
            }
        }
    }

    func start(outputDirectory: URL, baseName: String, microphoneDeviceId: String? = nil) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.startFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.startCapture(
                outputDirectory: outputDirectory.path,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
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
        let conn = try getConnection()
        return try await withCheckedThrowingContinuation { cont in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.stopFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

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

    func updateMicrophone(deviceId: String?) async throws {
        let conn = try getConnection()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: CaptureError.micSwitchFailed(
                    "XPC connection failed: \(error.localizedDescription)"
                ))
            } as! AudioCaptureProtocol

            proxy.updateMicrophone(deviceId: deviceId) { success, errorMessage in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: CaptureError.micSwitchFailed(
                        errorMessage ?? "Unknown error"
                    ))
                }
            }
        }
    }

    private func getConnection() throws -> NSXPCConnection {
        if connection == nil { connect() }
        guard let conn = connection else {
            throw CaptureError.notConnected
        }
        return conn
    }
}

enum CaptureError: LocalizedError {
    case notConnected
    case startFailed(String)
    case stopFailed(String)
    case micSwitchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "XPC connection not available — run as .app bundle"
        case .startFailed(let msg): return msg
        case .stopFailed(let msg): return msg
        case .micSwitchFailed(let msg): return msg
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: AudioCaptureClient detects XPC crash via onServiceCrash callback

Adds isCapturing() ping for recovery flow and crash notification hook."
```

---

### Task 4: LaunchAgentManager

**Files:**
- Create: `TranscriberCore/LaunchAgentManager.swift`
- Test: `SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct LaunchAgentManagerTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAgentTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func generatesPlistWithCorrectLabel() throws {
        let plist = LaunchAgentManager.generatePlist(bundlePath: "/Applications/Transcriber.app")
        #expect(plist.contains("com.audio-transcribe.app"))
        #expect(plist.contains("/Applications/Transcriber.app"))
        #expect(plist.contains("<key>KeepAlive</key>"))
    }

    @Test func installWritesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            bundlePath: "/Applications/Transcriber.app",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistPath = dir.appendingPathComponent("com.audio-transcribe.app.plist")
        #expect(FileManager.default.fileExists(atPath: plistPath.path))

        let content = try String(contentsOf: plistPath, encoding: .utf8)
        #expect(content.contains("KeepAlive"))
        #expect(content.contains("/Applications/Transcriber.app"))
    }

    @Test func uninstallRemovesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            bundlePath: "/Applications/Transcriber.app",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistPath = dir.appendingPathComponent("com.audio-transcribe.app.plist")
        #expect(FileManager.default.fileExists(atPath: plistPath.path))

        LaunchAgentManager.uninstall(launchAgentsDir: dir, unloadAgent: false)
        #expect(!FileManager.default.fileExists(atPath: plistPath.path))
    }

    @Test func isInstalledReturnsFalseWhenMissing() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        #expect(!LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }

    @Test func isInstalledReturnsTrueAfterInstall() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            bundlePath: "/test.app",
            launchAgentsDir: dir,
            loadAgent: false
        )
        #expect(LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compilation errors — `LaunchAgentManager` not found.

- [ ] **Step 3: Implement LaunchAgentManager**

Create `TranscriberCore/LaunchAgentManager.swift`:

```swift
import Foundation
import os

public enum LaunchAgentManager {
    static let label = "com.audio-transcribe.app"
    static let plistName = "\(label).plist"

    public static func generatePlist(bundlePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>BundlePath</key>
            <string>\(bundlePath)</string>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public static func install(
        bundlePath: String? = nil,
        launchAgentsDir: URL? = nil,
        loadAgent: Bool = true
    ) throws {
        let path = bundlePath ?? Bundle.main.bundlePath
        let dir = launchAgentsDir ?? defaultLaunchAgentsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist = generatePlist(bundlePath: path)
        let plistURL = dir.appendingPathComponent(plistName)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        Logger.config.info("LaunchAgent plist written to \(plistURL.path, privacy: .public)")

        if loadAgent {
            let result = Process()
            result.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            result.arguments = ["load", plistURL.path]
            try result.run()
            result.waitUntilExit()
            Logger.config.info("LaunchAgent loaded")
        }
    }

    public static func uninstall(
        launchAgentsDir: URL? = nil,
        unloadAgent: Bool = true
    ) {
        let dir = launchAgentsDir ?? defaultLaunchAgentsDir
        let plistURL = dir.appendingPathComponent(plistName)

        if unloadAgent {
            let result = Process()
            result.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            result.arguments = ["unload", plistURL.path]
            try? result.run()
            result.waitUntilExit()
            Logger.config.info("LaunchAgent unloaded")
        }

        try? FileManager.default.removeItem(at: plistURL)
        Logger.config.info("LaunchAgent plist removed")
    }

    public static func isInstalled(launchAgentsDir: URL? = nil) -> Bool {
        let dir = launchAgentsDir ?? defaultLaunchAgentsDir
        let plistURL = dir.appendingPathComponent(plistName)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static let defaultLaunchAgentsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift test --filter TranscriberTests/LaunchAgentManagerTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberCore/LaunchAgentManager.swift SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift
git commit -m "feat: add LaunchAgentManager for auto-relaunch on crash"
```

---

### Task 5: AppState — Interruption Warning

Add a property to AppState for the warning icon when recording was interrupted (Flow B/C).

**Files:**
- Modify: `TranscriberCore/AppState.swift`
- Modify: `SwiftTests/TranscriberTests/AppStateTests.swift`

- [ ] **Step 1: Read current AppStateTests**

Read `SwiftTests/TranscriberTests/AppStateTests.swift` to understand existing test patterns.

- [ ] **Step 2: Add failing test**

Append to `AppStateTests.swift`:

```swift
@Test func interruptionWarningChangesIcon() {
    let state = AppState()
    state.phase = .recording(since: Date())
    state.interruptionWarning = "Recording briefly interrupted"

    #expect(state.menuBarIcon == "exclamationmark.bubble")
}

@Test func clearingWarningRestoresRecordingIcon() {
    let state = AppState()
    state.phase = .recording(since: Date())
    state.interruptionWarning = "test"
    state.interruptionWarning = nil

    #expect(state.menuBarIcon == "microphone.and.signal.meter.fill")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Expected: `interruptionWarning` property not found.

- [ ] **Step 4: Add interruptionWarning to AppState**

Edit `TranscriberCore/AppState.swift`. Add the property after `errorMessage`:

```swift
/// Non-nil when recording was interrupted and auto-recovered.
/// Shown as a warning in the menu. Cleared when user opens the menu.
public var interruptionWarning: String?
```

Update `menuBarIcon` to show the warning icon during recording:

```swift
public var menuBarIcon: String {
    if errorMessage != nil { return "exclamationmark.triangle" }
    switch phase {
    case .idle: return "mic"
    case .recording:
        if interruptionWarning != nil { return "exclamationmark.bubble" }
        return "microphone.and.signal.meter.fill"
    case .transcribing: return "hourglass"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run full test suite to make sure nothing else broke.

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberCore/AppState.swift SwiftTests/TranscriberTests/AppStateTests.swift
git commit -m "feat: AppState.interruptionWarning for crash recovery UI feedback"
```

---

### Task 6: Recovery Logic — Sentinel Integration in MenuView

Wire the sentinel into the recording start/stop lifecycle, and add recovery-on-launch logic.

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`
- Modify: `TranscriberApp/TranscriberApp.swift`

- [ ] **Step 1: Add sentinel write/delete to MenuView recording lifecycle**

Edit `MenuView.swift`. In `startRecording()`, after `captureClient.start()` succeeds and before setting `appState.phase`, write the sentinel:

```swift
// After the try await captureClient.start(...) line and before appState.phase = .recording:
let sentinel = RecordingSentinel(
    startedAt: Date(),
    sessionName: sanitized.isEmpty ? "Recording" : sessionName,
    systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
    micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path,
    micDeviceUID: microphoneDeviceId,
    segment: 1
)
try RecordingSentinel.write(sentinel)
appState.phase = .recording(since: Date())
```

Update the `catch` block to also clean up the sentinel:

```swift
} catch {
    RecordingSentinel.delete()
    appState.errorMessage = error.localizedDescription
    sendNotification(title: "Recording Failed", body: error.localizedDescription)
}
```

In `stopRecording()`, delete the sentinel right after getting the paths (before transcription):

```swift
let paths = try await captureClient.stop()
RecordingSentinel.delete()
appState.phase = .transcribing(progress: "Transcribing...")
```

Also delete in the stop catch block:

```swift
} catch {
    RecordingSentinel.delete()
    appState.errorMessage = error.localizedDescription
    // ...existing error handling
}
```

- [ ] **Step 2: Add import for TranscriberCore at top of MenuView.swift (if not already present)**

Verify `import TranscriberCore` is present. It already is — no change needed.

- [ ] **Step 3: Wire `onServiceCrash` for Flow C — XPC crash restart**

In `MenuView.swift`, add a new method and wire it in the menu body. Add to `MenuView`:

```swift
private func setupCrashRecovery() {
    captureClient.onServiceCrash = { [appState, captureClient, configManager] in
        Task { @MainActor in
            guard appState.isRecording else { return }
            Logger.state.warning("XPC service crashed during recording — restarting capture")

            guard let sentinel = RecordingSentinel.read() else {
                Logger.state.error("No sentinel found during crash recovery")
                appState.errorMessage = "Recording interrupted — no recovery data"
                appState.phase = .idle
                return
            }

            // Increment segment
            let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
            let seg = sentinel.segment + 1
            let baseName = URL(fileURLWithPath: sentinel.systemAudioPath)
                .deletingPathExtension().lastPathComponent + "-\(seg)"

            let newSentinel = sentinel.incrementedSegment(
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
            )

            do {
                try await captureClient.start(
                    outputDirectory: outputDir,
                    baseName: baseName,
                    microphoneDeviceId: sentinel.micDeviceUID
                )
                try RecordingSentinel.write(newSentinel)
                appState.interruptionWarning = "Recording briefly interrupted. Resuming."
                sendNotification(
                    title: "Recording Resumed",
                    body: "Recording was briefly interrupted and has been restarted."
                )
            } catch {
                Logger.state.error("Failed to restart capture after XPC crash: \(error, privacy: .public)")
                appState.errorMessage = "Recording lost — failed to restart: \(error.localizedDescription)"
                appState.phase = .idle
                RecordingSentinel.delete()
            }
        }
    }
}
```

Call `setupCrashRecovery()` from the menu body using `.onAppear` or by calling it in `init`. Since `MenuView` is a `View` struct, add it as a task modifier on the top-level content. Add this after the Quit button, before the closing brace of `body`:

Actually, since `MenuView` is inside a `MenuBarExtra` with `.menu` style, modifiers like `.onAppear` or `.task` don't work reliably. Instead, move `setupCrashRecovery()` to `TranscriberApp.init()`.

- [ ] **Step 4: Move crash recovery setup to TranscriberApp.init**

Edit `TranscriberApp.swift`. In `init()`, after the `UNUserNotificationCenter` line:

```swift
captureClient.onServiceCrash = { [captureClient] in
    Task { @MainActor in
        await RecoveryCoordinator.handleXPCCrash(
            appState: /* need access */
        )
    }
}
```

Wait — the `appState` is a `@State` property, not available in `init`. The crash callback needs to be set up once the view hierarchy is alive. We need a different approach.

Instead, make `MenuView` call `setupCrashRecovery()` from `promptAndStartRecording()` — set the callback just before starting:

In `startRecording()`, right before the `do` block:

```swift
captureClient.onServiceCrash = {
    Task { @MainActor in
        guard appState.isRecording else { return }
        await self.handleXPCCrash()
    }
}
```

And add the `handleXPCCrash()` method to `MenuView`:

```swift
private func handleXPCCrash() async {
    Logger.state.warning("XPC service crashed during recording — restarting capture")

    guard let sentinel = RecordingSentinel.read() else {
        Logger.state.error("No sentinel found during crash recovery")
        appState.errorMessage = "Recording interrupted — no recovery data"
        appState.phase = .idle
        return
    }

    let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
    let seg = sentinel.segment + 1
    let origBase = URL(fileURLWithPath: sentinel.systemAudioPath)
        .deletingPathExtension().lastPathComponent
    // Strip any existing segment suffix before appending new one
    let cleanBase = origBase.replacingOccurrences(
        of: #"-\d+$"#, with: "", options: .regularExpression
    )
    let baseName = "\(cleanBase)-\(seg)"

    let newSentinel = sentinel.incrementedSegment(
        systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
        micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
    )

    do {
        try await captureClient.start(
            outputDirectory: outputDir,
            baseName: baseName,
            microphoneDeviceId: sentinel.micDeviceUID
        )
        try RecordingSentinel.write(newSentinel)
        appState.interruptionWarning = "Recording briefly interrupted. Resuming."
        sendNotification(
            title: "Recording Resumed",
            body: "Recording was briefly interrupted and has been restarted."
        )
    } catch {
        Logger.state.error("Failed to restart capture after XPC crash: \(error, privacy: .public)")
        appState.errorMessage = "Recording lost — failed to restart: \(error.localizedDescription)"
        appState.phase = .idle
        RecordingSentinel.delete()
    }
}
```

- [ ] **Step 5: Clear interruptionWarning when user opens menu**

In `MenuView` body, at the very top (before the error display), add:

```swift
if appState.interruptionWarning != nil {
    Button("⚠ \(appState.interruptionWarning!)") {}
        .disabled(true)
    Button("Dismiss") {
        appState.interruptionWarning = nil
    }
    Divider()
}
```

- [ ] **Step 6: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: sentinel integration in recording lifecycle + XPC crash auto-restart (Flow C)"
```

---

### Task 7: Recovery on Launch — Flows A and B

On app launch, check the sentinel and either re-attach to a live XPC session or restart recording.

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift`

- [ ] **Step 1: Add recovery method to TranscriberApp**

This is tricky because `@State` properties aren't accessible in `init`. We'll use a separate `.task` on the `MenuBarExtra`. But `.menu` style doesn't support modifiers well.

Alternative: Add recovery as an early step in `LaunchGate.checkAndGate()`, which already runs as a Task from init. But `LaunchGate` doesn't have access to `captureClient` or `appState`.

Best approach: Create a standalone recovery check that runs in `init()` using a static/global pattern. Since `captureClient` is not `@State` (it's a plain `let`), we can access it in `init`.

Edit `TranscriberApp.swift`. Add a recovery method and call it from `init()`:

```swift
init() {
    if let first = CommandLine.arguments.dropFirst().first,
       Self.cliSubcommands.contains(first) {
        CLIHandler.run()
    }

    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

    // Crash recovery: check sentinel before anything else
    let client = captureClient
    let state = appState
    Task { @MainActor in
        await Self.recoverIfNeeded(captureClient: client, appState: state)
    }

    let gate = launchGate
    Task { @MainActor in
        await gate.checkAndGate()
    }
}

@MainActor
private static func recoverIfNeeded(
    captureClient: AudioCaptureClient,
    appState: AppState
) async {
    guard let sentinel = RecordingSentinel.read() else { return }

    Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .public), segment: \(sentinel.segment))")

    // Check if sentinel is stale (from before last boot)
    let bootTime = ProcessInfo.processInfo.systemUptime
    let bootDate = Date().addingTimeInterval(-bootTime)
    if sentinel.startedAt < bootDate {
        Logger.state.info("Stale sentinel from before last boot — cleaning up")
        RecordingSentinel.delete()
        return
    }

    // Flow A: Is XPC service still alive and capturing?
    let isAlive = await captureClient.isCapturing()
    if isAlive {
        Logger.state.info("XPC service alive — re-attaching (Flow A)")
        appState.phase = .recording(since: sentinel.startedAt)
        return
    }

    // Flow B: XPC is dead — check for partial audio files
    let sysExists = FileManager.default.fileExists(atPath: sentinel.systemAudioPath)
    let sysSize = (try? FileManager.default.attributesOfItem(
        atPath: sentinel.systemAudioPath
    )[.size] as? Int) ?? 0

    if sysExists && sysSize > 44 {
        Logger.state.info("Partial audio found — restarting recording (Flow B)")

        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let seg = sentinel.segment + 1
        let origBase = URL(fileURLWithPath: sentinel.systemAudioPath)
            .deletingPathExtension().lastPathComponent
        let cleanBase = origBase.replacingOccurrences(
            of: #"-\d+$"#, with: "", options: .regularExpression
        )
        let baseName = "\(cleanBase)-\(seg)"

        let newSentinel = sentinel.incrementedSegment(
            systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
            micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
        )

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: sentinel.micDeviceUID
            )
            try RecordingSentinel.write(newSentinel)
            appState.phase = .recording(since: sentinel.startedAt)
            appState.interruptionWarning = "Recording was briefly interrupted. Some audio may have been lost."

            // Send notification
            let content = UNMutableNotificationContent()
            content.title = "Recording Resumed"
            content.body = "Recording was briefly interrupted. Some audio may have been lost."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.state.error("Flow B recovery failed: \(error, privacy: .public)")
            RecordingSentinel.delete()
        }
    } else {
        Logger.state.info("No usable audio files — cleaning up sentinel")
        RecordingSentinel.delete()
    }
}
```

- [ ] **Step 2: Add LaunchAgent lifecycle to quit handler**

Edit `MenuView.swift`. Replace the Quit button:

```swift
Button("Quit") {
    LaunchAgentManager.uninstall()
    NSApplication.shared.terminate(nil)
}
.keyboardShortcut("q")
```

- [ ] **Step 3: Install LaunchAgent on launch**

Edit `TranscriberApp.swift`. In `init()`, after the recovery task, add:

```swift
// Install LaunchAgent if not already present
if !LaunchAgentManager.isInstalled() {
    try? LaunchAgentManager.install()
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat: crash recovery on launch (Flow A re-attach, Flow B restart) + LaunchAgent lifecycle"
```

---

### Task 8: Multi-Segment Transcription Stitching

When a session has multiple audio segments from crash recovery, transcribe each segment and stitch results together.

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add segment discovery logic to TranscriptionRunner**

Edit `TranscriptionRunner.swift`. Add a helper method:

```swift
/// Discover all audio segment pairs in a session directory.
/// Returns pairs sorted by segment number: [(system, mic), ...]
static func discoverSegments(
    systemAudio: URL,
    micAudio: URL
) -> [(system: URL, mic: URL)] {
    let dir = systemAudio.deletingLastPathComponent()
    let baseName = systemAudio.deletingPathExtension().lastPathComponent

    var segments: [(system: URL, mic: URL)] = [(systemAudio, micAudio)]

    // Look for segment-2, segment-3, etc.
    var seg = 2
    while true {
        let sysName = "\(baseName)-\(seg).wav"
        let micName = "\(baseName)-\(seg)_mic.wav"
        let sysPath = dir.appendingPathComponent(sysName)
        let micPath = dir.appendingPathComponent(micName)

        if FileManager.default.fileExists(atPath: sysPath.path) {
            segments.append((sysPath, micPath))
            seg += 1
        } else {
            break
        }
    }

    return segments
}
```

- [ ] **Step 2: Update `run()` to handle multi-segment transcription**

Edit the `run()` method in `TranscriptionRunner.swift`. Replace the section that transcribes system + mic audio with a loop over segments:

```swift
let segments = Self.discoverSegments(systemAudio: systemAudio, micAudio: micAudio)
let isDualStream = micAudio != nil
var allSegments: [LabeledSegment] = []
var audioPaths: [URL] = []

for (index, segmentPair) in segments.enumerated() {
    if index > 0 {
        Logger.transcription.info("Transcribing recovery segment \(index + 1)")
    }

    let systemSegments = try await transcribeStream(
        audioPath: segmentPair.system,
        source: "remote",
        transcriber: transcriber,
        label: "system\(index > 0 ? "-\(index + 1)" : "")",
        audioSource: .system
    )
    allSegments.append(contentsOf: systemSegments)
    audioPaths.append(segmentPair.system)

    let micPath = segmentPair.mic
    if FileManager.default.fileExists(atPath: micPath.path) {
        let micSegments = try await transcribeStream(
            audioPath: micPath,
            source: "local",
            transcriber: transcriber,
            label: "mic\(index > 0 ? "-\(index + 1)" : "")",
            audioSource: .microphone
        )
        allSegments.append(contentsOf: micSegments)
        audioPaths.append(micPath)
    }
}
```

Remove the old `var audioPaths = [systemAudio]` and `if let mic = micAudio { audioPaths.append(mic) }` lines since `audioPaths` is now built in the loop.

Also remove the old `let isDualStream = micAudio != nil` line (moved above).

- [ ] **Step 3: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 4: Update stopRecording to pass all segments**

Edit `MenuView.swift` `stopRecording()`. The existing flow calls `captureClient.stop()` which returns paths for the current segment. For multi-segment, we need to read the sentinel to get the original (segment 1) paths for discovery:

```swift
private func stopRecording() async {
    Logger.state.info("Recording stopped")
    do {
        // Read sentinel before deleting — we need original paths for segment discovery
        let sentinel = RecordingSentinel.read()
        let paths = try await captureClient.stop()
        RecordingSentinel.delete()
        appState.phase = .transcribing(progress: "Transcribing...")

        // Use original segment-1 paths if available (for multi-segment discovery)
        let systemAudio: URL
        let micAudio: URL
        if let sentinel, sentinel.segment > 1 {
            systemAudio = URL(fileURLWithPath: sentinel.systemAudioPath)
                .deletingLastPathComponent()
                .appendingPathComponent(
                    URL(fileURLWithPath: sentinel.systemAudioPath)
                        .deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) + ".wav"
                )
            micAudio = URL(fileURLWithPath: sentinel.micAudioPath)
                .deletingLastPathComponent()
                .appendingPathComponent(
                    URL(fileURLWithPath: sentinel.micAudioPath)
                        .deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) + "_mic.wav"
                )
        } else {
            systemAudio = paths.systemAudio
            micAudio = paths.micAudio
        }

        let result = try await transcriptionRunner.run(
            systemAudio: systemAudio,
            micAudio: micAudio,
            outputDirectory: systemAudio.deletingLastPathComponent(),
            config: configManager.config
        )

        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
        appState.phase = .idle
        sendNotification(title: "Transcription Complete", body: result.jsonPath.lastPathComponent)

        RenameWindowController.shared.show(jsonPath: result.jsonPath)
    } catch {
        RecordingSentinel.delete()
        appState.errorMessage = error.localizedDescription
        sendNotification(title: "Transcription Failed", body: error.localizedDescription)
        appState.phase = .idle
    }
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift build 2>&1 | tail -5`

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberApp/Services/TranscriptionRunner.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat: multi-segment transcription stitching for crash recovery"
```

---

### Task 9: Run Full Test Suite + Manual Test Checklist

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/fmasi/Git/Transcriber-crash-recovery && swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`

Expected: All tests pass (existing + new RecordingSentinelTests + LaunchAgentManagerTests + AppStateTests additions).

- [ ] **Step 2: Fix any test failures**

If any tests fail, diagnose and fix. Common issues:
- Import paths for `RecordingSentinel` in tests
- `@MainActor` isolation on AppState tests

- [ ] **Step 3: Update manual test checklist**

Edit `scripts/test-checklist.md` to add crash recovery test scenarios:

```markdown
## Crash Recovery

- [ ] Start recording, then `kill -9` the UI process PID — verify:
  - XPC service finalizes WAV files (check file sizes grow then stop)
  - App relaunches within ~2s (LaunchAgent)
  - Menu bar icon shows recording state (re-attach, Flow A)
  - No notification or alert (silent recovery)

- [ ] Start recording, then `kill -9` the XPC service PID — verify:
  - UI shows "Recording briefly interrupted" warning
  - Notification appears
  - New audio segment files appear in session directory
  - Recording continues (menu still shows recording state)

- [ ] Start recording, then `kill -9` both UI and XPC PIDs — verify:
  - App relaunches within ~2s
  - New recording segment starts automatically
  - Notification about interruption appears
  - Warning icon in menu bar

- [ ] Quit app normally (Cmd+Q) — verify it does NOT restart

- [ ] Start and stop recording normally — verify:
  - No sentinel file left behind (~/.audio-transcribe/recording.json)
  - Transcription works as before

- [ ] Kill XPC during recording, let it recover, then stop normally — verify:
  - Both segments are transcribed
  - Output JSON contains all text from both segments
```

- [ ] **Step 4: Commit**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add scripts/test-checklist.md
git commit -m "docs: add crash recovery manual test checklist"
```

---

### Task 10: Commit WavFileWriter Sync (already implemented)

The 0.5s periodic sync was already implemented at the start of this conversation but not yet committed in the worktree.

- [ ] **Step 1: Commit the WavFileWriter change**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add TranscriberCore/WavFileWriter.swift
git commit -m "feat: periodic WAV file sync every 0.5s to minimize data loss on crash"
```

- [ ] **Step 2: Commit the design spec**

```bash
cd /Users/fmasi/Git/Transcriber-crash-recovery
git add docs/superpowers/specs/2026-04-03-crash-recovery-design.md
git commit -m "docs: crash recovery design spec"
```
