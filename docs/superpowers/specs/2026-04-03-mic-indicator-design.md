# Mic Indicator in Menu Bar — Design Spec

**Date:** 2026-04-03
**Branch:** feature/mic-indicator (to be created)

## Overview

Add an always-visible microphone indicator to the menu bar dropdown. It shows the active/default mic device name at all times and opens the familiar mic picker (with live level meter) on click. Replaces the recording-only "Change Microphone..." button.

## Goals

- Show active mic name in all states (idle, recording, transcribing)
- Clicking always opens the same mic picker panel
- Panel does a live XPC hot-swap when recording, config-only save when idle/transcribing
- Reuse the existing `MicSwitchDialog` / `MicSwitchWindowController` with minimal changes

## Menu Layout

```
Start/Stop Recording
Mic: [device name]          ← new, always visible (replaces "Change Microphone...")
────────────────────
Open Recordings Folder
Rename Speakers...
Settings...
────────────────────
Quit
```

The item uses `Label(activeMicName, systemImage: "mic")` — the same `"mic"` SF Symbol as the idle menu bar icon.

## Components

### 1. `MenuView` — mic name resolution

New computed property `activeMicName: String`:

```swift
private var activeMicName: String {
    AudioDeviceEnumerator.availableDevices()
        .first(where: { $0.id == configManager.config.lastMicrophoneDeviceId })?.name
        ?? "System Default"
}
```

Called at menu render time (menu is only rendered when opened — no performance concern).

### 2. `MenuView` — mic item + routing

Replace the recording-only `"Change Microphone..."` button with:

```swift
Button { openMicPicker() } label: {
    Label(activeMicName, systemImage: "mic")
}
```

`openMicPicker()` branches on `appState.isRecording`:

**Recording — live XPC hot-swap:**
```swift
MicSwitchWindowController.shared.show(
    currentDeviceId: configManager.config.lastMicrophoneDeviceId,
    buttonLabel: "Switch"
) { newDeviceId in
    try await captureClient.updateMicrophone(deviceId: newDeviceId)
    await MainActor.run {
        configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
    }
}
```

**Idle / transcribing — config-only save:**
```swift
MicSwitchWindowController.shared.show(
    currentDeviceId: configManager.config.lastMicrophoneDeviceId,
    buttonLabel: "Set Default"
) { newDeviceId in
    await MainActor.run {
        configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
    }
}
```

### 3. `MicSwitchDialog` — `buttonLabel` parameter

Add one parameter `buttonLabel: String`. Replace hardcoded `"Switch"` button text:

```swift
// Before
Button("Switch") { performSwitch() }

// After
Button(buttonLabel) { performSwitch() }
```

All other logic unchanged.

### 4. `MicSwitchWindowController` — thread `buttonLabel` through

`show()` gains `buttonLabel: String` parameter, passes it to `MicSwitchDialog` initializer.

## Error Handling

No changes needed. `MicSwitchDialog` already displays XPC errors inline. The idle/transcribing path uses a non-throwing closure — the `async throws` signature is satisfied trivially.

## Files Changed

| File | Change |
|------|--------|
| `TranscriberApp/Views/MenuView.swift` | Add `activeMicName`, add mic `Button`, remove `"Change Microphone..."`, add `openMicPicker()` |
| `TranscriberApp/Views/MicSwitchDialog.swift` | Add `buttonLabel: String` parameter |
| `TranscriberApp/Services/MicSwitchWindowController.swift` | Add `buttonLabel: String` parameter, thread through |

## Test Checklist Additions

- [ ] Mic indicator visible when idle
- [ ] Mic indicator visible while recording
- [ ] Mic indicator visible while transcribing
- [ ] Shows correct device name (or "System Default" when none saved)
- [ ] Clicking when idle: panel shows "Set Default" button, saves to config, no XPC call
- [ ] Clicking when recording: panel shows "Switch" button, live-switches mic
- [ ] Level meter active in both idle and recording panels
- [ ] "Change Microphone..." button no longer appears during recording
