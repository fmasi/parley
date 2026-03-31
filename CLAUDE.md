# Transcriber - Project Instructions

## Environment
- **NEVER install Python packages directly on the host machine** -- always use a conda environment
- macOS only (requires Apple Silicon for mlx-whisper)
- Requires macOS 15.0+ for microphone capture via ScreenCaptureKit

## Project Overview
macOS menu bar app for meeting transcription (mic + system audio from Zoom/Teams/Meet).
- **SwiftUI**: native menu bar app (`MenuBarExtra` + `Settings` scene), audio capture via XPC service
- **Python**: transcription engine (`transcribe.py`), speaker renaming CLI (`rename_speakers.py`)
- Uses mlx-whisper (Apple Silicon optimized) + pyannote.audio for speaker diarization

## Architecture

### SwiftUI App (TranscriberApp target)
- `TranscriberApp/TranscriberApp.swift` -- `@main` entry point, MenuBarExtra + Settings scenes
- `TranscriberApp/Services/AudioCaptureClient.swift` -- XPC connection to audio capture service
- `TranscriberApp/Services/TranscriptionRunner.swift` -- launches transcribe.py via Process
- `TranscriberApp/Services/CalendarService.swift` -- EventKit lookup for current meeting title
- `TranscriberApp/Services/RenameWindowController.swift` -- opens speaker rename dialog as NSPanel
- `TranscriberApp/Services/SessionNameWindowController.swift` -- opens session naming dialog as NSPanel
- `TranscriberApp/Services/SetupWindowController.swift` -- opens permission setup window as NSWindow at launch
- `TranscriberApp/Services/SystemPermissionChecker.swift` -- real macOS permission API wrapper (AVCaptureDevice, CGPreflight, EventKit, UNUserNotificationCenter)
- `TranscriberApp/Views/MenuView.swift` -- menu bar dropdown content
- `TranscriberApp/Views/SettingsView.swift` -- settings Form with Permissions section
- `TranscriberApp/Views/SetupView.swift` -- permission setup window content (shown at first launch)
- `TranscriberApp/Views/RenameDialog.swift` -- speaker rename sheet with sample text and audio playback from source WAV timestamps
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording (includes mic picker)
- `TranscriberApp/Views/MicrophonePicker.swift` -- mic device dropdown + live level meter (used in SessionNameDialog)

### XPC Audio Capture Service (AudioCaptureHelperXPC target)
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` -- implements AudioCaptureProtocol via ScreenCaptureKit
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` -- SCStreamOutput routing system/mic to WavFileWriters, auto-detects sample format (Float32/Int16) and channel count
- `AudioCaptureHelper/XPC/main.swift` -- NSXPCListener entry point

### Shared Protocol (AudioCaptureProtocol target)
- `AudioCaptureProtocol/AudioCaptureProtocol.swift` -- @objc XPC protocol + service name constant

### Shared Logic (TranscriberCore target)
- `TranscriberCore/AppState.swift` -- Observable state machine: idle → recording → transcribing → idle
- `TranscriberCore/Config.swift` -- Codable struct mirroring Python config.json (snake_case JSON keys)
- `TranscriberCore/ConfigManager.swift` -- reads/writes `~/.audio-transcribe/config.json`
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
- `TranscriberCore/WavFileWriter.swift` -- WAV file writing with deferred sample rate/channel count, Float32→Int16 conversion + direct Int16 passthrough
- `TranscriberCore/AudioDeviceEnumerator.swift` -- lists audio input devices via AVCaptureDevice.DiscoverySession, resolves last-used device
- `TranscriberCore/InputLevelMonitor.swift` -- @Observable real-time audio level (0-1) via AVCaptureSession, works with all device types including USB webcams
- `TranscriberCore/FilenameUtils.swift` -- sanitizeFilename (removes /, :, \0)
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol
- `TranscriberCore/Log.swift` -- os.Logger extension with 6 category loggers (audio, transcription, state, config, permissions, files)

### Python CLI (unchanged)
- `transcribe.py` -- CLI tool, mlx-whisper + pyannote diarization, supports dual-stream input (`-i system.wav -i mic.wav`)
- `rename_speakers.py` -- interactive speaker renaming, reads/updates JSON master file
- `service/config_manager.py` -- JSON config (shared format with Swift ConfigManager)
- `service/logger.py` -- logging setup

### Standalone Swift CLI (legacy, still functional)
- `audio_capture_helper/` -- Swift Package Manager project, standalone binary for CLI use
- Produces `bin/audio-capture-helper` via `cd audio_capture_helper && bash build.sh`

## Audio Capture Architecture (critical knowledge)
- Swift captures TWO WAV files: system audio + microphone (separate streams from ScreenCaptureKit)
- `.audio` output type = system audio only (at config sampleRate)
- `.microphone` output type = microphone only (at NATIVE device rate, varies: 16kHz, 24kHz, 48kHz)
- There is NO Apple API to get a pre-mixed stream (verified in SDK headers through macOS 26)
- Handler must be stored to prevent deallocation
- Must use async/await API, not completion-handler callbacks (callbacks don't deliver frames reliably)
- XPC service requires embedding in .app bundle -- bare binary can't reach the service
- Exit code 2 = permission denied

## Build & Test

### Swift (SwiftUI app + XPC service)
```bash
swift build
# Produces .build/debug/AudioTranscribe and .build/debug/audio-capture-helper-xpc

swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
# 102 tests across 9 suites (Config, ConfigManager, WavFileWriter, AppState, FilenameUtils, CalendarEventPicker, PermissionManager, AudioDeviceEnumerator, InputLevelMonitor)
# Uses Swift Testing, not XCTest -- no Xcode installed, only CommandLineTools
# Test path: SwiftTests/TranscriberTests/ (not Tests/ -- case collision with Python tests/ on APFS)
```

### Swift (standalone CLI helper -- legacy)
```bash
cd audio_capture_helper && bash build.sh
# Produces bin/audio-capture-helper
```

### Python
```bash
# Activate conda env first!
python -m pytest tests/ -q
# 79 tests
```

## Key Gotchas
1. `captureMicrophone` requires macOS 15.0+ (not 14.0)
2. PackageDescription `.v15` requires swift-tools-version 6.0; use `.macOS("15.0")` string syntax with 5.9
3. Mic sample rate varies by device -- auto-detect from CMSampleBuffer format description, don't hardcode
4. ScreenCaptureKit requires `.screen` output registration even for audio-only capture
5. TCC permission is granted to the host app -- when running as .app bundle this is the bundle (CFBundleIdentifier: com.audio-transcribe.app); when running from Terminal it's Terminal.app
6. XPC services only work inside .app bundles -- the bare binary will get an XPC connection error
7. UNUserNotificationCenter requires a bundled app -- guarded with `Bundle.main.bundleIdentifier != nil`
8. Use `remoteObjectProxyWithErrorHandler` for XPC calls to prevent continuation leaks
9. MenuBarExtra with `.menu` style cannot present sheets -- use NSPanel via window controllers
10. Calendar access requires `NSCalendarsUsageDescription` in Info.plist and `requestFullAccessToEvents()` at launch
11. Screen Recording has no requestAuthorization API — use `CGPreflightScreenCaptureAccess()` to check (no prompt) and `CGRequestScreenCaptureAccess()` to request (opens System Settings)
12. All required permissions (Mic, Screen Recording) are gated at launch via SetupWindowController — don't add scattered permission requests elsewhere. Optional permissions (Calendar, Notifications) are accessible in Settings.
13. `EKEventStore.authorizationStatus(for:)` may return stale values within a session — don't use `checkAll()` from individual Grant buttons, only update the specific permission that was requested
14. Floating panels must NOT use `.hudWindow` styleMask — it creates a legacy dark HUD appearance that ignores system appearance and Liquid Glass. Use `[.titled, .closable, .utilityWindow]` instead. `SetupWindowController` is a standard `NSWindow` (not a floating panel) and is correct as-is.
15. USB webcam mics (e.g. Logitech C920) may deliver Int16 samples instead of Float32, and stereo instead of mono -- always detect format and channel count from CMSampleBuffer format description, never assume Float32 mono
16. AVAudioEngine cannot handle USB webcam mics -- fails with -10868 (kAudioUnitErr_FormatNotSupported) due to internal audio graph format negotiation. Use AVCaptureSession instead.
17. CADefaultDeviceAggregate is a virtual CoreAudio device -- filter it from device lists (`uniqueID.contains("Aggregate")`) to avoid hangs
18. `SCStreamConfiguration.microphoneCaptureDeviceID` (macOS 15+) overrides the default mic for ScreenCaptureKit capture -- set it to the AVCaptureDevice uniqueID
19. Ad-hoc re-signing invalidates TCC grants -- always reset TCC permissions after a fresh build
20. **macOS 26 Liquid Glass panels (requires macOS 26.0+):** Floating panels use `panel.isOpaque = false` + `panel.backgroundColor = .clear` + `hostingView.layer?.backgroundColor = .clear`. Apply `.glassEffect(in: .rect(...))` as a **view modifier** on the content (not on a background shape — `.glassEffect()` on a shape defaults to capsule/oval). Use `GlassBackgroundModifier` for consistent glass with `.regularMaterial` fallback on macOS 15. Top corners use 0 radius to sit flush against the title bar.
21. **NSPanel `hidesOnDeactivate`:** Defaults to `true` — panels disappear when the menu bar app loses focus. Always set `panel.hidesOnDeactivate = false` on floating panels (SessionName, Rename).
22. **TranscriptionRunner environment:** `process.environment = [...]` replaces ALL env vars. Must include `HOME`, `TMPDIR`, embedded python `bin/` in PATH (for ffmpeg), and `/opt/homebrew/bin`. Must pass `hfToken` from config via `--hf-token` arg. The `-o` flag expects a file path, not a directory.
23. **embed_python.sh rsync excludes:** Use path-anchored excludes (`--exclude='/bin/pip*'`) not bare globs (`--exclude='pip*'`) — bare `pip*` also matches `pipelines/` inside packages like torchaudio.

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

# Save to file (shows in terminal AND writes to file — share for debugging sessions)
log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug --style compact | tee ~/Desktop/transcriber.log

# Dump recent history to file (useful after a crash — no live stream needed)
log show --predicate 'subsystem == "com.audio-transcribe.app"' --last 30m --style compact > ~/Desktop/transcriber.log

# Via dev.py (launches app + tails log)
python scripts/dev.py --debug
```

## Packaging
- `Package.swift` -- SPM workspace with 4 targets + 1 test target (TranscriberApp, TranscriberCore, AudioCaptureHelperXPC, AudioCaptureProtocol, TranscriberTests)
- `packaging/Info.plist` -- app bundle metadata (CFBundleIdentifier, TCC usage descriptions, LSUIElement)
- `packaging/AudioCaptureHelper-Info.plist` -- XPC service plist (ServiceType: Application)
- `packaging/embed_python.sh` -- embeds conda Python + scripts into .app Resources
- `scripts/dev.py` -- developer iteration CLI: kill/build/install/launch/reset-tcc with modular flags (replaced test-fresh.sh)
- `scripts/test-checklist.md` -- dynamic test checklist printed by dev.py on launch

## Branches
- `main` -- stable (Python rumps UI)
- `feature/swiftui-native-ui` -- SwiftUI native UI rewrite (this branch)
