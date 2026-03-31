# Mid-Recording Microphone Switch

**Date:** 2026-03-31
**Branch:** feature/mid-recording-mic-switch
**Status:** Approved design

## Problem

When a user starts recording on one microphone (e.g., laptop built-in mic) and later puts on headphones or switches to a different audio device, they must stop and restart the recording to use the new mic. This breaks transcription continuity and is a poor experience during real meetings.

## Solution

Allow switching the active microphone during a recording via a menu bar option, without stopping capture. Normalize all mic audio to a fixed output format so that device differences (sample rate, channel count, sample format) don't corrupt the WAV file.

## Design

### 1. Audio Normalization Layer

**Location:** `AudioCaptureHelper/XPC/AudioOutputHandler.swift`

**Fixed output format:** 48kHz, mono (1 channel), Int16 — consistent regardless of input device.

**Mechanism:** `AVAudioConverter` converts every `.microphone` CMSampleBuffer to the fixed output format before writing to `WavFileWriter`.

**Flow:**
```
CMSampleBuffer (.microphone)
  -> detect source format from ASBD (CMAudioFormatDescriptionGetStreamBasicDescription)
  -> if source format differs from cached format:
       create new AVAudioConverter(from: sourceFormat, to: fixedOutputFormat)
  -> extract AVAudioPCMBuffer from CMSampleBuffer
  -> convert via AVAudioConverter -> normalized AVAudioPCMBuffer (48kHz mono Int16)
  -> write Int16 samples to WavFileWriter
```

**Format change detection:** On every `.microphone` callback, compare the incoming `(sampleRate, channelCount, isFloat)` tuple against cached values. Rebuild the converter only when the tuple changes. The first frame always triggers converter creation.

**System audio (.audio type):** Unchanged. ScreenCaptureKit already normalizes system audio via `SCStreamConfiguration.sampleRate` and `channelCount`.

**WavFileWriter changes:** With normalization, the mic writer always receives 48kHz mono Int16. The `setSampleRate` / `setChannelCount` calls and the `detectedMicRate` flag can be simplified — the mic writer is initialized with the known fixed format. The `append(Float32)` path for mic audio becomes unused (converter outputs Int16), but remains available for system audio.

**Side benefit:** Fixes an existing fragility where the WAV header is written based on the first frame's format and never updated. If the source format changed mid-stream without this feature, the WAV file would be silently corrupted.

### 2. XPC Protocol Extension

**New method on `AudioCaptureProtocol`:**
```swift
@objc func updateMicrophone(deviceId: String, reply: @escaping (Error?) -> Void)
```

**Implementation in `AudioCaptureService`:**
1. Create a copy of the current `SCStreamConfiguration`
2. Set `microphoneCaptureDeviceID` to the new device ID
3. Call `stream.updateConfiguration()` on the live `SCStream` instance
4. Reply with nil on success, or the error on failure

**Client wrapper in `AudioCaptureClient`:**
```swift
func updateMicrophone(deviceId: String) async throws
```

Uses the same `withCheckedThrowingContinuation` pattern as existing `start`/`stop`/`status` methods.

**No additional state:** The XPC service does not need to track the current mic device. It applies the configuration update and the stream handles the rest. AudioOutputHandler detects the format change from the next CMSampleBuffer.

### 3. UI — Menu Item + Mic Switch Panel

**MenuView changes:** When `appState.isRecording == true`, add a "Change Microphone..." menu item below "Stop Recording". Clicking it opens the mic switch panel.

**New files:**

- **`TranscriberApp/Services/MicSwitchWindowController.swift`** — manages the floating `NSPanel`. Same pattern as `SessionNameWindowController`:
  - `NSPanel` (not `NSWindow`) with `hidesOnDeactivate = false`
  - Utility window style: `[.titled, .closable, .utilityWindow]`
  - No `.hudWindow` (gotcha #14)
  - Glass background via `GlassBackgroundModifier` if on macOS 26+
  - Positioned near menu bar

- **`TranscriberApp/Views/MicSwitchDialog.swift`** — SwiftUI content view:
  - Embeds `MicrophonePicker` (reuses existing component with level meter)
  - Pre-selects the currently active mic device (from `configManager.config.lastMicrophoneDeviceId`)
  - "Switch" button:
    1. Calls `captureClient.updateMicrophone(deviceId: selectedDeviceId)`
    2. On success: updates `configManager.lastMicrophoneDeviceId`, dismisses panel
    3. On error: shows inline error text below the button
  - "Cancel" button: dismisses without action

**What is NOT in scope:**
- Auto-detection of newly connected audio devices (future enhancement)
- Changes to `AppState` — recording phase stays `.recording(since:)`, no new state
- Changes to `SessionNameDialog` — initial mic selection flow is untouched
- Automatic prompt when devices connect/disconnect

## Data Flow (end to end)

```
User clicks "Change Microphone..." in menu bar
  -> MicSwitchWindowController opens NSPanel with MicSwitchDialog
  -> User selects new mic from MicrophonePicker, clicks "Switch"
  -> MenuView calls captureClient.updateMicrophone(deviceId:)
  -> AudioCaptureClient sends XPC message to AudioCaptureService
  -> AudioCaptureService calls stream.updateConfiguration() with new microphoneCaptureDeviceID
  -> ScreenCaptureKit starts delivering frames from new mic device
  -> AudioOutputHandler receives CMSampleBuffer with different ASBD
  -> Format change detected -> new AVAudioConverter created (newFormat -> 48kHz mono Int16)
  -> Subsequent frames converted and written to same mic WAV file seamlessly
  -> ConfigManager updated with new lastMicrophoneDeviceId
```

## Error Handling

- **`updateConfiguration()` fails:** Surface the error in `MicSwitchDialog` as inline text. Recording continues on the original mic — no state corruption.
- **XPC connection lost:** Handled by existing `remoteObjectProxyWithErrorHandler` pattern. The error propagates to the dialog.
- **New mic disconnected immediately after switch:** ScreenCaptureKit will stop delivering `.microphone` frames. The system audio stream continues. User can switch again via the menu.
- **AVAudioConverter creation fails:** Log the error. Fall back to writing raw unconverted samples (same as current behavior) with a warning log. This should be extremely rare since AVAudioConverter supports all standard PCM formats.

## Testing

### Unit Tests (SwiftTests/TranscriberTests/)

- **AudioOutputHandler normalization:** Test that Float32 48kHz stereo input and Int16 16kHz mono input both produce 48kHz mono Int16 output.
- **Format change detection:** Feed buffers with different formats, verify converter is rebuilt and output format stays consistent.
- **WavFileWriter:** Verify finalized WAV header always shows 48kHz mono when driven by the normalization layer.

### Manual Testing (scripts/test-checklist.md)

- Start recording on built-in mic, switch to USB headset mid-recording, verify transcription captures both segments.
- Start on USB webcam (48kHz stereo), switch to built-in mic (48kHz mono), verify no audio corruption.
- Switch to a device that is then unplugged — verify recording continues (system audio) and user can switch again.
- Verify the "Change Microphone..." menu item only appears during active recording.
- Verify level meter in MicSwitchDialog shows live levels for the newly selected (but not yet switched) device.

## Files Modified

| File | Change |
|------|--------|
| `AudioCaptureHelper/XPC/AudioOutputHandler.swift` | Add AVAudioConverter normalization for mic audio |
| `AudioCaptureHelper/XPC/AudioCaptureService.swift` | Add `updateMicrophone()` implementation |
| `AudioCaptureProtocol/AudioCaptureProtocol.swift` | Add `updateMicrophone(deviceId:reply:)` to protocol |
| `TranscriberApp/Services/AudioCaptureClient.swift` | Add `updateMicrophone(deviceId:)` async wrapper |
| `TranscriberApp/Views/MenuView.swift` | Add "Change Microphone..." item during recording |
| `TranscriberApp/Views/MicSwitchDialog.swift` | **New** — mic switch SwiftUI view |
| `TranscriberApp/Services/MicSwitchWindowController.swift` | **New** — NSPanel controller |
| `Package.swift` | Add new files to TranscriberApp target (if needed) |
| `scripts/test-checklist.md` | Add mic switch test cases |

## Open Questions (resolved during design)

- **Will `updateConfiguration()` work for `microphoneCaptureDeviceID`?** — Apple docs don't explicitly exclude it. Must verify empirically. If it doesn't work, fallback is stop+restart the stream (with a brief gap in system audio too). This would be discovered immediately during implementation.
- **What output format?** — 48kHz mono Int16. Matches Whisper's preferred input and is a common lowest-common-denominator.
- **Auto-detect new devices?** — Deferred to a follow-up. Manual switch is the MVP.
