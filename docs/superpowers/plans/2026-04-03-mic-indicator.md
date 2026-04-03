# Mic Indicator in Menu Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the active/default microphone name as an always-visible item in the menu bar dropdown; clicking it opens the existing mic picker panel (with level meter) in all app states.

**Architecture:** Thread a `buttonLabel` parameter through `MicSwitchDialog` and `MicSwitchWindowController`. In `MenuView`, replace the recording-only "Change Microphone..." button with an always-visible mic button that routes to a live XPC switch (recording) or config-only save (idle/transcribing).

**Tech Stack:** Swift 6, SwiftUI, `MenuBarExtra` (.menu style), `NSPanel`, `AVFoundation` (device enumeration)

---

## File Map

| File | Change |
|------|--------|
| `TranscriberApp/Views/MicSwitchDialog.swift` | Add `buttonLabel: String` stored property + init param; use it for button text |
| `TranscriberApp/Services/MicSwitchWindowController.swift` | Add `buttonLabel: String` param to `show()`; thread through to dialog |
| `TranscriberApp/Views/MenuView.swift` | Remove recording-only `"Change Microphone..."` block; add always-visible mic button + `activeMicName` + `openMicPicker()` |
| `scripts/test-checklist.md` | Add mic indicator manual test section |

No new files. No new unit tests (changes are UI routing — not unit-testable in isolation; manual checklist covers it).

---

## Task 1: Add `buttonLabel` to `MicSwitchDialog`

**Files:**
- Modify: `TranscriberApp/Views/MicSwitchDialog.swift`

- [ ] **Step 1: Add stored property and init param**

Open `TranscriberApp/Views/MicSwitchDialog.swift`. The current stored properties block is:

```swift
let currentDeviceId: String?
let devices: [AudioInputDevice]
let onSwitch: (String?) async throws -> Void
let onCancel: () -> Void
```

Change to:

```swift
let currentDeviceId: String?
let devices: [AudioInputDevice]
let buttonLabel: String
let onSwitch: (String?) async throws -> Void
let onCancel: () -> Void
```

The current `init` signature is:

```swift
init(
    currentDeviceId: String?,
    devices: [AudioInputDevice],
    onSwitch: @escaping (String?) async throws -> Void,
    onCancel: @escaping () -> Void
) {
    self._selectedDeviceId = State(initialValue: currentDeviceId)
    self.currentDeviceId = currentDeviceId
    self.devices = devices
    self.onSwitch = onSwitch
    self.onCancel = onCancel
}
```

Change to:

```swift
init(
    currentDeviceId: String?,
    devices: [AudioInputDevice],
    buttonLabel: String,
    onSwitch: @escaping (String?) async throws -> Void,
    onCancel: @escaping () -> Void
) {
    self._selectedDeviceId = State(initialValue: currentDeviceId)
    self.currentDeviceId = currentDeviceId
    self.devices = devices
    self.buttonLabel = buttonLabel
    self.onSwitch = onSwitch
    self.onCancel = onCancel
}
```

- [ ] **Step 2: Use `buttonLabel` for the action button**

In the `body`, find:

```swift
Button("Switch") { performSwitch() }
```

Change to:

```swift
Button(buttonLabel) { performSwitch() }
```

- [ ] **Step 3: Build to verify no compiler errors**

```bash
cd /Users/fmasi/Git/Transcriber && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: one or more `error:` lines about `MicSwitchWindowController` (it still passes the old init — that's expected; fix in Task 2). No errors in `MicSwitchDialog` itself.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/MicSwitchDialog.swift
git commit -m "feat: add buttonLabel param to MicSwitchDialog"
```

---

## Task 2: Thread `buttonLabel` through `MicSwitchWindowController`

**Files:**
- Modify: `TranscriberApp/Services/MicSwitchWindowController.swift`

- [ ] **Step 1: Add `buttonLabel` to `show()` signature**

Open `TranscriberApp/Services/MicSwitchWindowController.swift`. The current `show()` signature is:

```swift
func show(
    currentDeviceId: String?,
    onSwitch: @escaping (String?) async throws -> Void
) {
```

Change to:

```swift
func show(
    currentDeviceId: String?,
    buttonLabel: String,
    onSwitch: @escaping (String?) async throws -> Void
) {
```

- [ ] **Step 2: Pass `buttonLabel` to `MicSwitchDialog` initializer**

In the same method, find the `MicSwitchDialog` construction:

```swift
let dialog = MicSwitchDialog(
    currentDeviceId: resolvedId,
    devices: devices,
    onSwitch: { newDeviceId in
        try await onSwitch(newDeviceId)
        await MainActor.run { closePanel() }
    },
    onCancel: closePanel
)
```

Change to:

```swift
let dialog = MicSwitchDialog(
    currentDeviceId: resolvedId,
    devices: devices,
    buttonLabel: buttonLabel,
    onSwitch: { newDeviceId in
        try await onSwitch(newDeviceId)
        await MainActor.run { closePanel() }
    },
    onCancel: closePanel
)
```

- [ ] **Step 3: Build to verify no compiler errors**

```bash
cd /Users/fmasi/Git/Transcriber && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: one or more `error:` lines about `MenuView` (it still calls the old `show()` — fix in Task 3). No errors in `MicSwitchWindowController` or `MicSwitchDialog`.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/MicSwitchWindowController.swift
git commit -m "feat: thread buttonLabel through MicSwitchWindowController"
```

---

## Task 3: Update `MenuView`

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Remove the recording-only "Change Microphone..." block**

Open `TranscriberApp/Views/MenuView.swift`. Find and delete this entire block (lines ~39–50):

```swift
if appState.isRecording {
    Button("Change Microphone...") {
        MicSwitchWindowController.shared.show(
            currentDeviceId: configManager.config.lastMicrophoneDeviceId
        ) { newDeviceId in
            try await captureClient.updateMicrophone(deviceId: newDeviceId)
            await MainActor.run {
                configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
            }
        }
    }
}
```

- [ ] **Step 2: Add the always-visible mic button**

Immediately after the recording toggle button block (after `Button(appState.recordingToggleLabel) { ... }.disabled(appState.isTranscribing)`), add:

```swift
Button { openMicPicker() } label: {
    Label(activeMicName, systemImage: "mic")
}
```

- [ ] **Step 3: Add `activeMicName` computed property**

At the bottom of `MenuView`, before the closing `}`, add:

```swift
private var activeMicName: String {
    AudioDeviceEnumerator.availableDevices()
        .first(where: { $0.id == configManager.config.lastMicrophoneDeviceId })?.name
        ?? "System Default"
}
```

- [ ] **Step 4: Add `openMicPicker()` method**

Also at the bottom of `MenuView`, add:

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

- [ ] **Step 5: Build to verify clean compile**

```bash
cd /Users/fmasi/Git/Transcriber && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!` — no errors.

- [ ] **Step 6: Run existing tests**

```bash
cd /Users/fmasi/Git/Transcriber && swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ \
  2>&1 | tail -5
```

Expected: all ~219 tests pass, no regressions.

- [ ] **Step 7: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: always-visible mic indicator in menu bar"
```

---

## Task 4: Update test checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add mic indicator section**

Append this section to `scripts/test-checklist.md`:

```markdown
## Mic Indicator (menu bar)
- [ ] Mic indicator visible when idle — shows "System Default" or saved device name
- [ ] Mic indicator visible while recording
- [ ] Mic indicator visible while transcribing
- [ ] Shows correct device name after selecting a non-default mic in a prior session
- [ ] Clicking when idle: panel opens with "Set Default" button; selecting a different device + clicking "Set Default" persists to config (reopen menu to verify name updated)
- [ ] Clicking when idle: Cancel closes panel without changing config
- [ ] Clicking when recording: panel opens with "Switch" button; selecting a different device + clicking "Switch" hot-swaps the mic live
- [ ] Clicking when transcribing: panel opens with "Set Default" button (same as idle)
- [ ] Level meter is active in the picker panel (breathe into mic to verify)
- [ ] "Change Microphone..." menu item is gone (was recording-only, now replaced)
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add mic indicator test checklist"
```

---

## Self-Review

**Spec coverage:**
- [x] Always-visible in all states → Task 3 Step 2 (no `if appState.isRecording` guard)
- [x] `Label(name, systemImage: "mic")` → Task 3 Step 2
- [x] Position below Start/Stop Recording → Task 3 Step 2
- [x] `"Change Microphone..."` removed → Task 3 Step 1
- [x] `buttonLabel` param on dialog → Task 1
- [x] `buttonLabel` threaded through controller → Task 2
- [x] Live XPC when recording ("Switch") → Task 3 Step 4
- [x] Config-only when idle/transcribing ("Set Default") → Task 3 Step 4
- [x] `activeMicName` resolution → Task 3 Step 3
- [x] Test checklist → Task 4

**Placeholder scan:** None found.

**Type consistency:**
- `MicSwitchDialog.buttonLabel: String` defined in Task 1, consumed in Task 1 (button text) — consistent.
- `MicSwitchWindowController.show(buttonLabel:)` defined in Task 2, called in Task 3 — consistent.
- `openMicPicker()` defined and called in Task 3 — consistent.
- `activeMicName` defined and called in Task 3 — consistent.
