# Crash Recovery Design

**Date:** 2026-04-03
**Status:** Approved

## Problem

If the UI process crashes during recording, the XPC audio capture service continues recording indefinitely (orphaned). On relaunch the app starts fresh with no knowledge of the prior session. There is no auto-relaunch mechanism. Recording state (AppState) is purely in-memory.

This is unacceptable for a discrete recording tool — recording must survive any crash silently.

## Goals

1. Recording survives UI crashes with zero data loss and no user intervention
2. Recording survives XPC crashes with minimal data loss (~300-800ms gap) and automatic restart
3. App auto-relaunches unless user explicitly quits
4. Partial audio from crash scenarios is preserved and transcribable

## Non-Goals

- Crash analytics or reporting
- Redundant audio capture (dual XPC services)
- Memory-mapped WAV files (future optimization)

## Design

### Sentinel File

A JSON file at `~/.audio-transcribe/recording.json` acts as the crash-recovery signal.

**Written** atomically on `startRecording()`. **Deleted** on clean `stopRecording()`. Presence on launch means a crash occurred during recording.

```json
{
  "started_at": "2026-04-03T14:34:00Z",
  "session_name": "Weekly Sync",
  "system_audio_path": "/Users/x/.audio-transcribe/sessions/2026-04-03-weekly-sync/system.wav",
  "mic_audio_path": "/Users/x/.audio-transcribe/sessions/2026-04-03-weekly-sync/mic.wav",
  "display_id": 1,
  "app_bundle_filter": "us.zoom.xos",
  "mic_device_uid": "BuiltInMicrophoneDevice",
  "system_sample_rate": 48000,
  "mic_sample_rate": 48000
}
```

**Implementation:** New `TranscriberCore/RecordingSentinel.swift` — Codable struct with `write()`, `read()`, `delete()` static methods. Uses `JSONEncoder` with atomic write to a temporary file then rename (POSIX `rename()` is atomic on APFS).

### LaunchAgent

A plist at `~/Library/LaunchAgents/com.audio-transcribe.app.plist` with `KeepAlive: true` ensures macOS restarts the app within ~1-2 seconds of a crash.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.audio-transcribe.app</string>
    <key>BundlePath</key>
    <string>/Applications/Transcriber.app</string>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
```

**Install/uninstall:** Managed by the app itself. On first launch (or from Settings), copy the plist and `launchctl load`. On explicit quit (Cmd+Q / menu quit), `launchctl unload` before terminating so macOS does not restart. On next manual launch, re-load. The `BundlePath` is resolved at install time from `Bundle.main.bundlePath`, so it works for both `/Applications/Transcriber.app` and dev builds.

**Key behavior:** `KeepAlive: true` only restarts if the process exits unexpectedly. When the user quits via the app menu, the app unloads the agent first, so no restart occurs.

### XPC Connection-Drop Handler (Service Side)

**Problem:** When the UI process dies, the XPC service has no `invalidationHandler` and keeps recording forever.

**Fix:** In `AudioCaptureService`, when accepting a new connection via `NSXPCListener`, set an `invalidationHandler` on the `NSXPCConnection`. When it fires (client died):

1. Call `stopCapture()` to end the SCStream
2. Call `finalizeAll()` on the AudioOutputHandler to flush and finalize WAV headers
3. Log the event
4. Exit the service process (it will be re-spawned on next XPC connection)

This ensures orphaned recordings are properly closed with valid WAV headers.

### Recovery Flows

#### Flow A: UI Crash, XPC Alive

1. LaunchAgent restarts app (~1-2s)
2. Early in `TranscriberApp.init` or `.onAppear`, check for sentinel file
3. Sentinel exists → attempt XPC connection ping (call new `isCapturing(reply:)` method on `AudioCaptureProtocol`)
4. XPC responds → recording is still active
5. Silently set `AppState.phase = .recording(since: sentinel.startedAt)`
6. Re-attach UI: update elapsed timer from sentinel timestamp, restore session name
7. No notification, no alert — user sees menu bar icon reappear as if nothing happened

#### Flow B: Both Crashed

1. LaunchAgent restarts app (~1-2s)
2. Sentinel exists → attempt XPC ping → no response (service is dead)
3. Check if audio files at sentinel paths have content (file size > 44 bytes / WAV header)
4. If files have content:
   a. Immediately start a **new** recording (same session directory, segment 2 files)
   b. Send macOS notification: "Recording was briefly interrupted. Some audio may have been lost."
   c. Set warning state on menu bar icon (clears when user opens menu)
   d. Mark partial files for later stitching
5. If files are empty: delete sentinel, start fresh

#### Flow C: XPC Crash, UI Alive

1. `AudioCaptureClient`'s `invalidationHandler` fires instantly when XPC service dies
2. UI immediately:
   a. Creates new XPC connection
   b. Calls `startCapture()` with cached config (from sentinel or in-memory)
   c. New WAV files are created as segment 2 in the same session directory
3. Gap: ~300-800ms (XPC spawn + SCStream setup, skipping `SCShareableContent` enumeration by using cached display/app IDs from sentinel)
4. Send macOS notification: "Recording briefly interrupted. Resuming."
5. AppState remains `.recording` throughout — no state transition visible to user

### Transcript Stitching

When a session has multiple audio segments (from XPC restart):

1. Session directory contains: `system.wav`, `mic.wav` (segment 1) and `system-2.wav`, `mic-2.wav` (segment 2), etc.
2. `TranscriptionRunner` detects multiple segments by glob pattern
3. Each segment pair is transcribed independently
4. Results are concatenated in order with a gap marker in the transcript JSON:
   ```json
   {
     "type": "gap",
     "duration_estimate_ms": 800,
     "reason": "recording_interrupted"
   }
   ```
5. Diarization runs per-segment. Speaker ID reconciliation across segments is a stretch goal — initial implementation uses independent speaker IDs per segment

### Optimizations (Already Implemented or Planned)

| Optimization | Status | Impact |
|---|---|---|
| WAV flush every 0.5s | Done | Crash loses max 0.5s of buffered audio |
| Cache capture config in sentinel | This spec | Skip SCShareableContent enumeration (~100-500ms saved) |
| Fast-path recovery startup | This spec | Check sentinel before UI setup (~200ms saved) |

## Files to Create

| File | Purpose |
|---|---|
| `TranscriberCore/RecordingSentinel.swift` | Codable sentinel read/write/delete |
| `packaging/com.audio-transcribe.app.plist` | LaunchAgent plist |

## Files to Modify

| File | Change |
|---|---|
| `AudioCaptureHelper/XPC/AudioCaptureService.swift` | Add connection `invalidationHandler` to stop capture + finalize on client death |
| `AudioCaptureHelper/XPC/main.swift` | Pass connection lifecycle to service |
| `TranscriberApp/Services/AudioCaptureClient.swift` | XPC crash detection → immediate restart (Flow C) |
| `TranscriberApp/TranscriberApp.swift` | Recovery check on launch (Flows A/B), LaunchAgent install/unload on quit |
| `TranscriberApp/Services/TranscriptionRunner.swift` | Multi-segment detection and transcript stitching |
| `TranscriberCore/AppState.swift` | Sentinel write on `.recording` entry, delete on `.idle` entry |
| `AudioCaptureProtocol/AudioCaptureProtocol.swift` | Add `isCapturing(reply:)` method for recovery ping |

## Testing Strategy

**Unit tests (TranscriberTests):**
- `RecordingSentinel`: write/read/delete round-trip, atomic write, missing file returns nil
- `AppState` + sentinel integration: verify sentinel written on recording start, deleted on stop
- Multi-segment file naming: verify segment numbering logic

**Manual tests (test-checklist.md):**
- Kill UI process during recording (`kill -9 <pid>`), verify XPC finalizes WAV, app relaunches, re-attaches
- Kill XPC service during recording, verify UI restarts capture within ~1s, notification appears
- Kill both, verify app relaunches, starts new recording, notification appears
- Quit app normally (Cmd+Q), verify it does NOT restart
- Transcribe a multi-segment recording, verify stitched output

## Edge Cases

- **Sentinel exists but no audio files:** App crashed before recording actually started. Delete sentinel, start fresh.
- **Multiple rapid crashes:** LaunchAgent has built-in throttling (won't restart more than ~10 times in 10 seconds). If the app is crash-looping, macOS stops restarting it. This is correct — a crash loop means a real bug, not a transient failure.
- **User quits during recovery:** If the user hits Cmd+Q while the app is in recovery mode, honor the quit — unload LaunchAgent, stop any recording, finalize files.
- **Stale sentinel from previous boot:** Compare sentinel `started_at` with system boot time. If sentinel predates last boot, the XPC service is definitely dead — skip ping, go straight to file recovery.
