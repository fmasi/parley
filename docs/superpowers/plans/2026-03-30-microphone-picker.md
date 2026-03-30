# Microphone Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users choose which microphone to record from in the pre-recording dialog, with a live input level meter, so the app captures the correct mic even when conferencing apps use a non-default device.

**Architecture:** Add a mic device picker dropdown + real-time level meter to `SessionNameDialog`. The selected device ID flows through `AudioCaptureClient` → XPC → `AudioCaptureService` where it sets `SCStreamConfiguration.microphoneCaptureDeviceID`. The last-used device is persisted in `config.json` and pre-selected next time.

**Tech Stack:** AVFoundation (`AVCaptureDevice.DiscoverySession`), AVFAudio (`AVAudioEngine` for level metering), ScreenCaptureKit (`microphoneCaptureDeviceID`), SwiftUI

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TranscriberCore/AudioDeviceEnumerator.swift` | Enumerate input devices, provide `AudioInputDevice` model |
| Create | `TranscriberCore/InputLevelMonitor.swift` | Tap an audio device and report RMS level via `@Observable` |
| Create | `TranscriberApp/Views/MicrophonePicker.swift` | SwiftUI dropdown + level meter bar, extracted component |
| Modify | `TranscriberCore/Config.swift` | Add `lastMicrophoneDeviceId: String?` field |
| Modify | `AudioCaptureProtocol/AudioCaptureProtocol.swift` | Add `microphoneDeviceId` param to `startCapture` |
| Modify | `AudioCaptureHelper/XPC/AudioCaptureService.swift` | Set `microphoneCaptureDeviceID` on `SCStreamConfiguration` |
| Modify | `TranscriberApp/Services/AudioCaptureClient.swift` | Pass `microphoneDeviceId` through XPC call |
| Modify | `TranscriberApp/Views/SessionNameDialog.swift` | Embed `MicrophonePicker`, pass selection to `onStart` |
| Modify | `TranscriberApp/Services/SessionNameWindowController.swift` | Widen panel for new content |
| Modify | `TranscriberApp/Views/MenuView.swift` | Thread mic device ID from dialog → `startRecording` → XPC |
| Create | `SwiftTests/TranscriberTests/AudioDeviceEnumeratorTests.swift` | Unit tests for device enumeration logic |
| Create | `SwiftTests/TranscriberTests/InputLevelMonitorTests.swift` | Unit tests for level monitor lifecycle |
| Modify | `SwiftTests/TranscriberTests/ConfigTests.swift` | Test new field round-trips through JSON |

---

### Task 1: Add `lastMicrophoneDeviceId` to Config

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write the failing test for the new field**

In `SwiftTests/TranscriberTests/ConfigTests.swift`, add a test that round-trips the new field:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests/ConfigTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: Compilation error — `lastMicrophoneDeviceId` does not exist on Config.

- [ ] **Step 3: Add the field to Config**

In `TranscriberCore/Config.swift`, add the property, default, init parameter, and coding key:

```swift
// Add property (after hfToken):
public var lastMicrophoneDeviceId: String?

// In Config.default — add:
lastMicrophoneDeviceId: nil

// In init — add parameter:
lastMicrophoneDeviceId: String? = nil

// In init body — add:
self.lastMicrophoneDeviceId = lastMicrophoneDeviceId

// In CodingKeys — add:
case lastMicrophoneDeviceId = "last_microphone_device_id"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests/ConfigTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: All ConfigTests pass.

- [ ] **Step 5: Run full test suite for regression**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: All 70+ tests pass.

- [ ] **Step 6: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: add lastMicrophoneDeviceId to Config for mic picker persistence"
```

---

### Task 2: Create AudioDeviceEnumerator

**Files:**
- Create: `TranscriberCore/AudioDeviceEnumerator.swift`
- Create: `SwiftTests/TranscriberTests/AudioDeviceEnumeratorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `SwiftTests/TranscriberTests/AudioDeviceEnumeratorTests.swift`:

```swift
import Testing
@testable import TranscriberCore

/// Protocol-based testing — we test the logic without requiring real hardware.
struct AudioDeviceEnumeratorTests {

    @Test func systemDefaultIsAlwaysFirst() {
        let devices = AudioDeviceEnumerator.availableDevices()
        guard let first = devices.first else {
            Issue.record("Expected at least the System Default entry")
            return
        }
        #expect(first.id == AudioInputDevice.systemDefaultID)
        #expect(first.name == "System Default")
    }

    @Test func systemDefaultIDIsNil() {
        #expect(AudioInputDevice.systemDefaultID == nil)
    }

    @Test func audioInputDeviceEquatable() {
        let a = AudioInputDevice(id: "abc", name: "Mic A")
        let b = AudioInputDevice(id: "abc", name: "Mic A")
        let c = AudioInputDevice(id: "xyz", name: "Mic B")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func resolveDeviceIdReturnsNilForSystemDefault() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: nil, available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == nil)
    }

    @Test func resolveDeviceIdPreselectsLastUsed() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: "usb-mic", available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == "usb-mic")
    }

    @Test func resolveDeviceIdFallsBackWhenLastUsedMissing() {
        let resolved = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: "unplugged-mic", available: [
                AudioInputDevice(id: nil, name: "System Default"),
                AudioInputDevice(id: "usb-mic", name: "USB Mic"),
            ]
        )
        #expect(resolved == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests/AudioDeviceEnumeratorTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: Compilation error — `AudioDeviceEnumerator` and `AudioInputDevice` do not exist.

- [ ] **Step 3: Implement AudioDeviceEnumerator**

Create `TranscriberCore/AudioDeviceEnumerator.swift`:

```swift
import AVFoundation

/// Represents an audio input device. `id` is `nil` for the "System Default" sentinel.
public struct AudioInputDevice: Equatable, Identifiable {
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }

    /// The sentinel ID representing "use system default input device."
    public static let systemDefaultID: String? = nil
}

public enum AudioDeviceEnumerator {

    /// Returns all available audio input devices, with "System Default" as the first entry.
    public static func availableDevices() -> [AudioInputDevice] {
        var result = [AudioInputDevice(id: nil, name: "System Default")]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        for device in discovery.devices {
            result.append(AudioInputDevice(id: device.uniqueID, name: device.localizedName))
        }
        return result
    }

    /// Given the last-used device ID and the currently available devices,
    /// return the device ID to pre-select. Returns `nil` (system default)
    /// if the last-used device is no longer available.
    public static func resolveDeviceId(
        lastUsed: String?,
        available: [AudioInputDevice]
    ) -> String? {
        guard let lastUsed else { return nil }
        if available.contains(where: { $0.id == lastUsed }) {
            return lastUsed
        }
        return nil // fall back to system default
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests/AudioDeviceEnumeratorTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AudioDeviceEnumerator.swift SwiftTests/TranscriberTests/AudioDeviceEnumeratorTests.swift
git commit -m "feat: add AudioDeviceEnumerator with device listing and last-used resolution"
```

---

### Task 3: Create InputLevelMonitor

**Files:**
- Create: `TranscriberCore/InputLevelMonitor.swift`
- Create: `SwiftTests/TranscriberTests/InputLevelMonitorTests.swift`

- [ ] **Step 1: Write failing tests for lifecycle**

Create `SwiftTests/TranscriberTests/InputLevelMonitorTests.swift`:

```swift
import Testing
@testable import TranscriberCore

struct InputLevelMonitorTests {

    @Test func initialLevelIsZero() {
        let monitor = InputLevelMonitor()
        #expect(monitor.level == 0.0)
    }

    @Test func isNotMonitoringInitially() {
        let monitor = InputLevelMonitor()
        #expect(monitor.isMonitoring == false)
    }

    @Test func stopWhenNotMonitoringIsNoOp() {
        let monitor = InputLevelMonitor()
        monitor.stop()
        #expect(monitor.isMonitoring == false)
        #expect(monitor.level == 0.0)
    }

    @Test func stopResetsLevel() {
        let monitor = InputLevelMonitor()
        // Simulate that level was set (in real use, the audio tap sets it)
        monitor.level = 0.75
        monitor.stop()
        #expect(monitor.level == 0.0)
        #expect(monitor.isMonitoring == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests/InputLevelMonitorTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: Compilation error — `InputLevelMonitor` does not exist.

- [ ] **Step 3: Implement InputLevelMonitor**

Create `TranscriberCore/InputLevelMonitor.swift`:

```swift
import AVFoundation
import Observation

/// Monitors audio input level from a specified device (or system default).
/// Publishes `level` (0.0–1.0) suitable for driving a level meter UI.
@Observable
public final class InputLevelMonitor {
    public var level: Float = 0.0
    public private(set) var isMonitoring = false

    private var engine: AVAudioEngine?

    public init() {}

    /// Start monitoring the given device. Pass `nil` for system default.
    /// If already monitoring, stops the previous session first.
    public func start(deviceId: String?) {
        stop()

        let engine = AVAudioEngine()

        // Select input device if specified
        if let deviceId,
           let audioDeviceID = audioDeviceID(for: deviceId) {
            setInputDevice(audioDeviceID, on: engine)
        }
        // else: system default — no configuration needed

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            return // no valid input format
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = self.computeRMS(buffer: buffer)
            DispatchQueue.main.async {
                self.level = rms
            }
        }

        do {
            try engine.start()
            self.engine = engine
            self.isMonitoring = true
        } catch {
            // Failed to start — leave in non-monitoring state
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Stop monitoring and reset level to zero.
    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isMonitoring = false
        level = 0.0
    }

    // MARK: - Private

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let channelSamples = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelSamples[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        // Clamp to 0...1
        return min(max(rms * 3.0, 0.0), 1.0) // scale up for visibility
    }

    /// Convert AVCaptureDevice.uniqueID to CoreAudio AudioDeviceID.
    private func audioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        let device = AVCaptureDevice(uniqueID: uniqueID)
        guard let device else { return nil }

        // AVCaptureDevice doesn't expose AudioDeviceID directly.
        // Use CoreAudio to find the device by UID.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr {
                if uid as String == uniqueID {
                    return id
                }
            }
        }
        return nil
    }

    /// Set the input device on an AVAudioEngine via CoreAudio.
    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
        var devID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests/InputLevelMonitorTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/InputLevelMonitor.swift SwiftTests/TranscriberTests/InputLevelMonitorTests.swift
git commit -m "feat: add InputLevelMonitor with AVAudioEngine tap and device selection"
```

---

### Task 4: Create MicrophonePicker SwiftUI component

**Files:**
- Create: `TranscriberApp/Views/MicrophonePicker.swift`

- [ ] **Step 1: Create the MicrophonePicker view**

Create `TranscriberApp/Views/MicrophonePicker.swift`:

```swift
import SwiftUI
import TranscriberCore

struct MicrophonePicker: View {
    @Binding var selectedDeviceId: String?
    let devices: [AudioInputDevice]

    @State private var levelMonitor = InputLevelMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("", selection: $selectedDeviceId) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()

                // Level meter — matches System Settings style
                LevelMeterView(level: levelMonitor.level)
                    .frame(width: 80, height: 6)
            }
        }
        .onAppear {
            levelMonitor.start(deviceId: selectedDeviceId)
        }
        .onDisappear {
            levelMonitor.stop()
        }
        .onChange(of: selectedDeviceId) { _, newValue in
            levelMonitor.start(deviceId: newValue)
        }
    }
}

/// A simple horizontal level meter bar.
struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var meterColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MicrophonePicker.swift
git commit -m "feat: add MicrophonePicker view with level meter"
```

---

### Task 5: Integrate MicrophonePicker into SessionNameDialog

**Files:**
- Modify: `TranscriberApp/Views/SessionNameDialog.swift`
- Modify: `TranscriberApp/Services/SessionNameWindowController.swift`

- [ ] **Step 1: Update SessionNameDialog to include mic picker and emit device ID**

Replace the contents of `TranscriberApp/Views/SessionNameDialog.swift` with:

```swift
import SwiftUI
import TranscriberCore

struct SessionNameDialog: View {
    @State private var name: String
    @State private var selectedDeviceId: String?
    @FocusState private var focused: Bool

    let devices: [AudioInputDevice]
    let onStart: (String, String?) -> Void  // (sessionName, micDeviceId?)
    let onCancel: () -> Void

    init(
        suggestedName: String,
        initialDeviceId: String?,
        devices: [AudioInputDevice],
        onStart: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._name = State(initialValue: suggestedName)
        self._selectedDeviceId = State(initialValue: initialDeviceId)
        self.devices = devices
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name This Recording")
                .font(.headline)

            TextField("e.g. Weekly standup", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { start() }

            Text("Leave blank to use a timestamp.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MicrophonePicker(
                selectedDeviceId: $selectedDeviceId,
                devices: devices
            )

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 12).glassEffect()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
            }
        }
        .onAppear { focused = true }
    }

    private func start() {
        onStart(
            name.trimmingCharacters(in: .whitespaces),
            selectedDeviceId
        )
    }
}
```

- [ ] **Step 2: Update SessionNameWindowController to pass devices and handle new callback**

In `TranscriberApp/Services/SessionNameWindowController.swift`, update the `show` method:

```swift
import AppKit
import SwiftUI
import TranscriberCore

@MainActor
final class SessionNameWindowController {
    static let shared = SessionNameWindowController()
    private var panel: NSPanel?

    func show(
        suggestedName: String?,
        lastMicrophoneDeviceId: String?,
        onStart: @escaping (String, String?) -> Void  // (sessionName, micDeviceId?)
    ) {
        panel?.close()

        let devices = AudioDeviceEnumerator.availableDevices()
        let initialDeviceId = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: lastMicrophoneDeviceId, available: devices
        )

        let closePanel = { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = SessionNameDialog(
            suggestedName: suggestedName ?? "",
            initialDeviceId: initialDeviceId,
            devices: devices,
            onStart: { name, deviceId in
                closePanel()
                onStart(name, deviceId)
            },
            onCancel: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "New Recording"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        newPanel.contentView = hostingView
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Compilation errors in `MenuView.swift` (calling `show` with old signature). This is expected — we fix it in the next task.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/SessionNameDialog.swift TranscriberApp/Services/SessionNameWindowController.swift
git commit -m "feat: integrate MicrophonePicker into SessionNameDialog"
```

---

### Task 6: Thread mic device ID through XPC protocol

**Files:**
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift`

- [ ] **Step 1: Add microphoneDeviceId parameter to the XPC protocol**

In `AudioCaptureProtocol/AudioCaptureProtocol.swift`, replace the `startCapture` method:

```swift
/// Start capturing system audio + microphone to WAV files in the given directory.
/// `microphoneDeviceId` selects a specific mic (AVCaptureDevice.uniqueID);
/// pass nil to use the system default input device.
/// Reply: (success: Bool, errorMessage: String?)
func startCapture(
    outputDirectory: String,
    baseName: String,
    microphoneDeviceId: String?,
    reply: @escaping (Bool, String?) -> Void
)
```

- [ ] **Step 2: Update AudioCaptureService to accept and use the device ID**

In `AudioCaptureHelper/XPC/AudioCaptureService.swift`:

Update the `startCapture` signature to match:

```swift
func startCapture(
    outputDirectory: String,
    baseName: String,
    microphoneDeviceId: String?,
    reply: @escaping (Bool, String?) -> Void
) {
```

Store `microphoneDeviceId` and pass it to `configureAndStart`:

```swift
// In startCapture, change the Task call to:
try await self.configureAndStart(handler: outputHandler, microphoneDeviceId: microphoneDeviceId)
```

Update `configureAndStart` signature and set the device ID:

```swift
private func configureAndStart(handler: AudioOutputHandler, microphoneDeviceId: String?) async throws {
```

After `config.captureMicrophone = true`, add:

```swift
if let microphoneDeviceId {
    config.microphoneCaptureDeviceID = microphoneDeviceId
}
```

- [ ] **Step 3: Update AudioCaptureClient to pass mic device ID**

In `TranscriberApp/Services/AudioCaptureClient.swift`, update the `start` method:

```swift
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
```

- [ ] **Step 4: Verify it compiles (except MenuView which we fix next)**

Run: `swift build 2>&1 | tail -10`
Expected: Only errors in `MenuView.swift` — the XPC chain should compile.

- [ ] **Step 5: Commit**

```bash
git add AudioCaptureProtocol/AudioCaptureProtocol.swift AudioCaptureHelper/XPC/AudioCaptureService.swift TranscriberApp/Services/AudioCaptureClient.swift
git commit -m "feat: thread microphoneDeviceId through XPC protocol to SCStreamConfiguration"
```

---

### Task 7: Wire everything together in MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Update MenuView to thread mic device ID and persist last-used**

In `TranscriberApp/Views/MenuView.swift`:

Update `promptAndStartRecording`:

```swift
private func promptAndStartRecording() {
    let suggestedName = calendarService.currentEventTitle()
    let lastMicId = configManager.config.lastMicrophoneDeviceId
    SessionNameWindowController.shared.show(
        suggestedName: suggestedName,
        lastMicrophoneDeviceId: lastMicId
    ) { sessionName, micDeviceId in
        Task { await startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
    }
}
```

Update `startRecording` signature and body:

```swift
private func startRecording(sessionName: String, microphoneDeviceId: String?) async {
    // Persist the mic choice for next time
    configManager.update { $0.lastMicrophoneDeviceId = microphoneDeviceId }

    let config = configManager.config
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dayDir = dateFormatter.string(from: Date())

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HHmmss"
    let timestamp = timeFormatter.string(from: Date())

    let sanitized = sanitizeFilename(sessionName)
    let baseName = sanitized.isEmpty ? timestamp : "\(timestamp)-\(sanitized)"

    let outputDir = URL(fileURLWithPath: config.recordingDirectory)
        .appendingPathComponent(dayDir)

    do {
        try await captureClient.start(
            outputDirectory: outputDir,
            baseName: baseName,
            microphoneDeviceId: microphoneDeviceId
        )
        appState.phase = .recording(since: Date())
    } catch {
        appState.errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 2: Build the full project**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Run the full test suite**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: All tests pass (existing + new).

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: wire mic picker through MenuView, persist last-used device in config"
```

---

### Task 8: Update legacy standalone CLI (audio_capture_helper)

**Files:**
- Modify: `audio_capture_helper/Sources/AudioCaptureHelper/main.swift`

- [ ] **Step 1: Check if the standalone CLI also needs the mic device ID option**

The standalone CLI at `audio_capture_helper/Sources/AudioCaptureHelper/main.swift:171` also sets `config.captureMicrophone = true`. For consistency, add an optional `--mic-device` CLI flag.

Add argument parsing after the existing argument handling:

```swift
// After existing argument parsing, add:
var micDeviceId: String? = nil
if let micIdx = CommandLine.arguments.firstIndex(of: "--mic-device"),
   micIdx + 1 < CommandLine.arguments.count {
    micDeviceId = CommandLine.arguments[micIdx + 1]
}
```

After `config.captureMicrophone = true` (line 171), add:

```swift
if let micDeviceId {
    config.microphoneCaptureDeviceID = micDeviceId
}
```

Update the usage output to mention the new flag:

```swift
fputs("  --mic-device <id>  Use specific microphone (AVCaptureDevice.uniqueID)\n", stderr)
```

- [ ] **Step 2: Build the standalone CLI**

Run: `cd /Users/fmasi/Git/Transcriber/audio_capture_helper && bash build.sh`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add audio_capture_helper/Sources/AudioCaptureHelper/main.swift
git commit -m "feat: add --mic-device flag to standalone audio capture CLI"
```

---

### Task 9: Manual integration test

- [ ] **Step 1: Build the full app bundle**

Run: `cd /Users/fmasi/Git/Transcriber && swift build`

- [ ] **Step 2: Manual test checklist**

Test the following scenarios manually:

1. Open the session name dialog — verify mic dropdown appears with "System Default" + real devices
2. Select different mics — verify the level meter responds to the selected device only
3. Start a recording with a non-default mic — verify the `_mic.wav` file contains audio from the selected device
4. Close and reopen the dialog — verify the last-used mic is pre-selected
5. Unplug the last-used mic, reopen dialog — verify it falls back to "System Default"

- [ ] **Step 3: Final commit (if any adjustments needed)**

```bash
git add -A
git commit -m "fix: adjustments from manual integration testing"
```

---

## Update CLAUDE.md

After all tasks are complete, update the following sections in `CLAUDE.md`:

- **Architecture > TranscriberCore**: Add entries for `AudioDeviceEnumerator.swift` and `InputLevelMonitor.swift`
- **Architecture > TranscriberApp/Views**: Update `SessionNameDialog.swift` description, add `MicrophonePicker.swift`
- **Key Gotchas**: Add gotcha about `microphoneCaptureDeviceID` and conferencing app mic independence
- **Build & Test**: Update test count
