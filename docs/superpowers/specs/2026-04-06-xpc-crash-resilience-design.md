# XPC Crash Resilience + Critical Error Visibility

**Date:** 2026-04-06
**Trigger:** XPC service crashed on first mic audio callback due to force-unwrap of `AVAudioFormat(streamDescription:)` returning nil. No recovery engaged, no visible alert — user lost entire recording without knowing.

## Problem

1. `AudioOutputHandler.swift:117` force-unwrapped a nil `AVAudioFormat`, crashing the XPC service
2. Crash happened before sentinel file was written → no recovery on relaunch
3. Existing `.timeSensitive` notification got buried in Notification Center → user didn't notice during meeting

## Design

### 1. Auto-Retry on XPC Crash

- On XPC connection invalidation while `appState.phase == .recording`, increment a retry counter (stored on the crash handler, not persisted)
- **Max retries: 1** — if it fails twice, the problem isn't transient
- Retry flow: tear down dead connection → create fresh `AudioCaptureClient` → call `startCapture`
- On retry success: send existing "Recording Resumed" `.timeSensitive` notification, write new sentinel, continue as today
- On retry failure: escalate to critical error (see Section 2)
- Reset retry counter to 0 on every successful `stopCapture`

**Startup crash coverage:** The same retry logic applies when the XPC crashes during the initial `startCapture` sequence (before any audio is captured). The crash handler is installed before `startCapture` is called.

### 2. Critical Error Alert

**New state property:** `appState.criticalError: String?` — separate from `interruptionWarning` (higher severity).

**Menu bar icon:**
- When `criticalError != nil`: icon changes to `exclamationmark.triangle.fill`
- Icon stays in error state until user clicks the menu and taps "Dismiss"
- Clicking shows the error message in the dropdown (e.g. "Recording failed — microphone capture crashed after retry. Your recording was lost.")
- Dismissing sets `criticalError = nil`, icon returns to normal idle state

**Critical notification:**
- `UNNotificationContent` with `interruptionLevel: .critical` and `sound: .defaultCritical`
- Bypasses Focus mode, DND, plays sound even when muted
- Title: "Recording Failed"
- Body: contextual (e.g. "Microphone capture crashed. No audio was saved.")

**Triggers:**
- XPC crash during recording with failed retry
- XPC crash on startup with failed retry
- Any future unrecoverable recording error

**Does NOT trigger on:**
- Successful crash recovery (stays as existing `.timeSensitive` "Recording Resumed")
- Normal stop/start transitions

### 3. Sentinel Write Timing

**Current:** Sentinel written after `startCapture` succeeds.
**Fix:** Write sentinel **before** calling `startCapture`. If `startCapture` fails and retry is exhausted, delete the sentinel to prevent false recovery on next launch.

### 4. AudioOutputHandler Hardening (Done)

`AudioOutputHandler.swift:117` — replaced `AVAudioFormat(streamDescription: asbd)!` with `guard let` + diagnostic logging of rate/channels/flags. Unexpected mic formats are now skipped, not fatal.

Audited rest of handler: no other force-unwraps. All other paths use `guard` returns.

## Files to Modify

- `TranscriberCore/AppState.swift` — add `criticalError: String?` property, update `menuBarIcon` computed property
- `TranscriberApp/TranscriberApp.swift` — retry logic in `setupCrashHandler()`, sentinel write timing, critical notification sender
- `TranscriberApp/Views/MenuView.swift` — critical error display + dismiss button in dropdown
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` — already done (guard let fix)

## Out of Scope

- Floating NSPanel alert (potential future escalation)
- Auto-clear on timeout (potential future enhancement)
- Retry on non-XPC errors (transcription engine failures etc.)
