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
- `TranscriberApp/Views/RenameDialog.swift` -- speaker rename sheet
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording

### XPC Audio Capture Service (AudioCaptureHelperXPC target)
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` -- implements AudioCaptureProtocol via ScreenCaptureKit
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` -- SCStreamOutput routing system/mic to WavFileWriters
- `AudioCaptureHelper/XPC/main.swift` -- NSXPCListener entry point

### Shared Protocol (AudioCaptureProtocol target)
- `AudioCaptureProtocol/AudioCaptureProtocol.swift` -- @objc XPC protocol + service name constant

### Shared Logic (TranscriberCore target)
- `TranscriberCore/AppState.swift` -- Observable state machine: idle → recording → transcribing → idle
- `TranscriberCore/Config.swift` -- Codable struct mirroring Python config.json (snake_case JSON keys)
- `TranscriberCore/ConfigManager.swift` -- reads/writes `~/.audio-transcribe/config.json`
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
- `TranscriberCore/WavFileWriter.swift` -- WAV file writing with deferred sample rate, Float32→Int16 conversion
- `TranscriberCore/FilenameUtils.swift` -- sanitizeFilename (removes /, :, \0)
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol

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
- `.microphone` output type = microphone only (at NATIVE device rate, varies: 24kHz, 48kHz)
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

swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/
# 70 tests across 7 suites (Config, ConfigManager, WavFileWriter, AppState, FilenameUtils, CalendarEventPicker, PermissionManager)
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
15. **macOS 26 Liquid Glass panels (requires macOS 26.0+):** Floating panels use `panel.isOpaque = false` + `panel.backgroundColor = .clear` + `hostingView.layer?.backgroundColor = .clear`, and SwiftUI content applies `.glassEffect()` on a `RoundedRectangle` background (with `.regularMaterial` fallback for macOS 15). The `#available(macOS 26.0, *)` guard means no deployment-target bump is required — the glass is a progressive enhancement. To require macOS 26 as the hard minimum, bump `Package.swift` to `.macOS("26.0")`.

## Packaging
- `Package.swift` -- SPM workspace with 4 targets + 1 test target (TranscriberApp, TranscriberCore, AudioCaptureHelperXPC, AudioCaptureProtocol, TranscriberTests)
- `packaging/Info.plist` -- app bundle metadata (CFBundleIdentifier, TCC usage descriptions, LSUIElement)
- `packaging/AudioCaptureHelper-Info.plist` -- XPC service plist (ServiceType: Application)
- `packaging/embed_python.sh` -- embeds conda Python + scripts into .app Resources
- `scripts/test-fresh.sh` -- resets TCC permissions, builds with embedded Python, installs to /Applications, launches app

## Branches
- `main` -- stable (Python rumps UI)
- `feature/swiftui-native-ui` -- SwiftUI native UI rewrite (this branch)
