# Transient Mic Selection Design

**Date:** 2026-04-11

## Overview

All mic pickers (session-start dialog, mid-recording switch, idle menu bar) become session-only — they never persist to config. The only way to change the persistent default mic is through Settings.

## Behavior

- **App launch:** `@State selectedMicId` initialized from `configManager.config.lastMicrophoneDeviceId`
- **Menu bar label:** reads `selectedMicId`, shows device name or "System Default"
- **Session-start dialog:** pre-fills from `selectedMicId`, selection flows back to `selectedMicId` and into `startRecording()` — no config write
- **Mid-recording switch:** updates `selectedMicId` + calls `captureClient.updateMicrophone()` — no config write
- **Idle menu bar pick:** updates `selectedMicId` only — no config write
- **Settings:** new `MicrophonePicker` bound to `config.lastMicrophoneDeviceId` — the only place that persists

## Changes

### MenuView.swift

- Add `@State private var selectedMicId: String?` initialized from config default
- `activeMicName` reads from `selectedMicId` instead of `configManager.config.lastMicrophoneDeviceId`
- `promptAndStartRecording()` passes `selectedMicId` as the initial device
- `startRecording()` removes `configManager.update { $0.lastMicrophoneDeviceId = ... }`
- `openMicPicker()` recording branch: updates `selectedMicId` + calls `captureClient.updateMicrophone()`, no config write
- `openMicPicker()` idle branch: updates `selectedMicId` only, no config write
- Both branches use "Switch" as button label

### SettingsView.swift

- Add `MicrophonePicker` section bound to config's `lastMicrophoneDeviceId`
- On change, persist via `configManager.update`

### No changes needed

- `SessionNameDialog` — already receives device ID as parameter
- `MicSwitchDialog` — already receives device ID as parameter
- `Config` — `lastMicrophoneDeviceId` field unchanged

## Testing

- Unit: no new logic to test (just wiring changes)
- Manual: verify menu bar label updates on pick, verify Settings persists across app restart, verify session picks don't persist
