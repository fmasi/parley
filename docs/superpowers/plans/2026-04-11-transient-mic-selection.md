# Transient Mic Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all mic pickers session-only (no config persistence) and add a persistent mic default to Settings.

**Architecture:** Add `@State selectedMicId` to MenuView initialized from config. All pickers read/write this state. Remove config writes from session-start and mic-switch flows. Add MicrophonePicker to SettingsView as the only persistent path.

**Tech Stack:** SwiftUI, TranscriberCore

---

### Task 1: Remove config persistence from MenuView mic flows

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add @State selectedMicId to MenuView**

In `TranscriberApp/Views/MenuView.swift`, add a new `@State` property after the existing `@State private var xpcRetryCount = 0` line:

```swift
@State private var selectedMicId: String?
```

Also add an `init` to seed it from config. Add this after the property declarations (after `@State private var selectedMicId: String?`):

```swift
init(
    appState: AppState,
    captureClient: AudioCaptureClient,
    transcriptionRunner: TranscriptionRunner,
    configManager: ConfigManager,
    calendarService: CalendarService
) {
    self.appState = appState
    self.captureClient = captureClient
    self.transcriptionRunner = transcriptionRunner
    self.configManager = configManager
    self.calendarService = calendarService
    self._selectedMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
}
```

Note: `MenuView` currently uses `@Bindable var appState` and `let` properties. The new `init` must preserve these. `@Bindable` properties are assigned directly (not via `_appState`). Check the existing property declarations:

```swift
@Bindable var appState: AppState
let captureClient: AudioCaptureClient
let transcriptionRunner: TranscriptionRunner
let configManager: ConfigManager
let calendarService: CalendarService
@State private var xpcRetryCount = 0
@State private var selectedMicId: String?
```

- [ ] **Step 2: Update activeMicName to read from selectedMicId**

Replace the `activeMicName` computed property (currently around line 324):

```swift
private var activeMicName: String {
    AudioDeviceEnumerator.availableDevices()
        .first(where: { $0.id == configManager.config.lastMicrophoneDeviceId })?.name
        ?? "System Default"
}
```

With:

```swift
private var activeMicName: String {
    AudioDeviceEnumerator.availableDevices()
        .first(where: { $0.id == selectedMicId })?.name
        ?? "System Default"
}
```

- [ ] **Step 3: Update promptAndStartRecording to use selectedMicId**

Replace `promptAndStartRecording()` (currently around line 98):

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

With:

```swift
private func promptAndStartRecording() {
    let suggestedName = calendarService.currentEventTitle()
    SessionNameWindowController.shared.show(
        suggestedName: suggestedName,
        lastMicrophoneDeviceId: selectedMicId
    ) { sessionName, micDeviceId in
        selectedMicId = micDeviceId
        Task { await startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
    }
}
```

- [ ] **Step 4: Remove config persistence from startRecording**

In `startRecording(sessionName:microphoneDeviceId:)` (currently around line 109), remove these two lines:

```swift
// Persist the mic choice for next time
configManager.update { $0.lastMicrophoneDeviceId = microphoneDeviceId }
```

- [ ] **Step 5: Update openMicPicker to be session-only**

Replace the entire `openMicPicker()` function (currently around line 330):

```swift
private func openMicPicker() {
    if appState.isRecording {
        MicSwitchWindowController.shared.show(
            currentDeviceId: configManager.config.lastMicrophoneDeviceId,
            buttonLabel: "Switch"
        ) { newDeviceId in
            try await captureClient.updateMicrophone(deviceId: newDeviceId)
            await MainActor.run {
                configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
            }
        }
    } else {
        MicSwitchWindowController.shared.show(
            currentDeviceId: configManager.config.lastMicrophoneDeviceId,
            buttonLabel: "Set Default"
        ) { newDeviceId in
            await MainActor.run {
                configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
            }
        }
    }
}
```

With:

```swift
private func openMicPicker() {
    if appState.isRecording {
        MicSwitchWindowController.shared.show(
            currentDeviceId: selectedMicId,
            buttonLabel: "Switch"
        ) { newDeviceId in
            try await captureClient.updateMicrophone(deviceId: newDeviceId)
            await MainActor.run {
                selectedMicId = newDeviceId
            }
        }
    } else {
        MicSwitchWindowController.shared.show(
            currentDeviceId: selectedMicId,
            buttonLabel: "Switch"
        ) { newDeviceId in
            await MainActor.run {
                selectedMicId = newDeviceId
            }
        }
    }
}
```

- [ ] **Step 6: Build to verify compilation**

Run:
```bash
swift build
```

Expected: build succeeds. There may be a warning about the `init` if SwiftUI synthesizes one — check and fix if needed.

- [ ] **Step 7: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "refactor: make mic selection session-only, remove config persistence from pickers

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Add MicrophonePicker to SettingsView

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Add mic state properties**

In `TranscriberApp/Views/SettingsView.swift`, add a new `@State` property after `@State private var summaryContextLength`:

```swift
@State private var settingsMicId: String?
@State private var settingsMicDevices: [AudioInputDevice] = []
```

In the `init`, after `self._summaryContextLength = ...`, add:

```swift
self._settingsMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
```

- [ ] **Step 2: Add Microphone section to the Form**

In the `body`, add a new section after the "Permissions" section and before "Transcription Engine":

```swift
Section("Default Microphone") {
    MicrophonePicker(
        selectedDeviceId: $settingsMicId,
        devices: settingsMicDevices
    )
    Text("Sessions will start with this microphone unless changed.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
.onAppear {
    settingsMicDevices = AudioDeviceEnumerator.availableDevices()
}
```

- [ ] **Step 3: Persist mic selection in the Save button**

In the Save button action (inside `.toolbar`), add before `configManager.update { $0 = config }`:

```swift
config.lastMicrophoneDeviceId = settingsMicId
```

This ensures the mic selection is persisted along with all other config changes when the user clicks Save.

- [ ] **Step 4: Build to verify compilation**

Run:
```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: add default microphone picker to Settings

The only place that persistently sets the default mic device.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Update test checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add mic selection test section**

Add a new section to `scripts/test-checklist.md` after the "Mic Name Update" section:

```markdown
## Mic Selection Persistence
- [ ] Open Settings — default mic picker shows current config default
- [ ] Change mic in Settings, click Save — restart app, verify new default persists
- [ ] Start recording dialog — pre-selects config default mic
- [ ] Change mic in start dialog — after recording, restart app, verify default unchanged
- [ ] Menu bar mic button (idle) — switch mic, restart app, verify default unchanged
- [ ] Menu bar mic button (recording) — switch mid-recording, restart app, verify default unchanged
```

- [ ] **Step 2: Remove old "Mic Name Update" section**

Remove the section that just tested the @Observable fix, since the new section above covers it more completely.

- [ ] **Step 3: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: update test checklist for transient mic selection

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
