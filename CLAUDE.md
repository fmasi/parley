# Transcriber - Project Instructions

## Environment
- macOS only (requires Apple Silicon for CoreML/ANE acceleration)
- Requires macOS 15.0+ for microphone capture via ScreenCaptureKit
- No Python/conda required for the app itself (fully Swift-native)
- Benchmark tool (`tools/engine-benchmark/`) optionally uses Python for mlx-whisper comparison — use conda if running that

## Project Overview
macOS menu bar app for meeting transcription (mic + system audio from Zoom/Teams/Meet).
- **SwiftUI**: native menu bar app (`MenuBarExtra` + `Settings` scene), audio capture via XPC service
- Swappable transcription engines: SpeechAnalyzer (Apple, default) and FluidAudio (Parakeet) — selectable in Settings via `EngineID`

## Architecture

### SwiftUI App (TranscriberApp target)
- `TranscriberApp/TranscriberApp.swift` -- `@main` entry point, MenuBarExtra + Settings scenes
- `TranscriberApp/Services/AudioCaptureClient.swift` -- XPC connection to audio capture service, crash detection via `onServiceCrash` callback, `isCapturing()` ping for recovery
- `TranscriberApp/Services/TranscriptionRunner.swift` -- creates engine from config.engine, runs transcription + optional diarization
- `TranscriberApp/Services/CalendarService.swift` -- EventKit lookup for current meeting title
- `TranscriberApp/Services/RenameWindowController.swift` -- opens speaker rename dialog as NSPanel
- `TranscriberApp/Services/SessionNameWindowController.swift` -- opens session naming dialog as NSPanel
- `TranscriberApp/Services/SetupWindowController.swift` -- opens permission setup window as NSWindow at launch
- `TranscriberApp/Services/SystemPermissionChecker.swift` -- real macOS permission API wrapper (AVCaptureDevice, CGPreflight, EventKit, UNUserNotificationCenter)
- `TranscriberApp/Views/MenuView.swift` -- menu bar dropdown content
- `TranscriberApp/Views/SettingsView.swift` -- settings Form with Permissions section; triggers eager model download on Save when engine requires it
- `TranscriberApp/Views/SetupView.swift` -- permission + engine setup window (shown at first launch or when model not cached); gates Continue on permissions AND model download
- `TranscriberApp/Views/RenameDialog.swift` -- speaker rename sheet with sample text and audio playback from source WAV timestamps
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording (includes mic picker)
- `TranscriberApp/Views/MicrophonePicker.swift` -- mic device dropdown + live level meter (used in SessionNameDialog)

### XPC Audio Capture Service (AudioCaptureHelperXPC target)
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` -- implements AudioCaptureProtocol via ScreenCaptureKit
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` -- SCStreamOutput routing system/mic to WavFileWriters, auto-detects sample format (Float32/Int16) and channel count
- `AudioCaptureHelper/XPC/main.swift` -- NSXPCListener entry point, shared service instance, connection invalidation handler

### Shared Protocol (AudioCaptureProtocol target)
- `AudioCaptureProtocol/AudioCaptureProtocol.swift` -- @objc XPC protocol + service name constant

### Shared Logic (TranscriberCore target)
- `TranscriberCore/AppState.swift` -- Observable state machine: idle → recording → transcribing → idle, `interruptionWarning` for crash recovery UI
- `TranscriberCore/Config.swift` -- Codable config struct (snake_case JSON keys), includes `engine: EngineID`
- `TranscriberCore/ConfigManager.swift` -- reads/writes `~/.audio-transcribe/config.json`
- `TranscriberCore/EngineID.swift` -- engine enum (speechAnalyzer/fluidAudio) + EngineDescriptor metadata
- `TranscriberCore/TranscriptionEngine.swift` -- protocol for swappable transcription engines + AudioSourceType enum
- `TranscriberCore/FluidAudioEngine.swift` -- FluidAudio/Parakeet engine (fastest, 25 EU languages) with ITN text normalization; isModelCached()/preDownloadModel() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/FluidAudioDiarizer.swift` -- FluidAudio offline diarization (pyannote + WeSpeaker + VBx) with quality scores; isDiarizationCached()/preDownloadModels() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/SpeechAnalyzerEngine.swift` -- Apple SpeechAnalyzer engine (macOS 26+, no download), guarded with `#if compiler(>=6.2)`
- `TranscriberCore/DiarizationProvider.swift` -- protocol for speaker diarization + DiarizedSegment model
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
- `TranscriberCore/WavFileWriter.swift` -- WAV file writing with deferred sample rate/channel count, Float32→Int16 conversion + direct Int16 passthrough, 0.5s periodic sync
- `TranscriberCore/RecordingSentinel.swift` -- crash recovery sentinel file (JSON at ~/.audio-transcribe/recording.json), atomic write/read/delete
- `TranscriberCore/LaunchAgentManager.swift` -- install/unload macOS LaunchAgent (KeepAlive) for auto-relaunch on crash
- `TranscriberCore/SegmentDiscovery.swift` -- discover multi-segment audio files from crash recovery (base, -2, -3, ...)
- `TranscriberCore/SegmentNaming.swift` -- segment filename computation: strip `-N` suffix, append new segment number
- `TranscriberCore/AudioDeviceEnumerator.swift` -- lists audio input devices via AVCaptureDevice.DiscoverySession, resolves last-used device
- `TranscriberCore/InputLevelMonitor.swift` -- @Observable real-time audio level (0-1) via AVCaptureSession, works with all device types including USB webcams
- `TranscriberCore/FilenameUtils.swift` -- sanitizeFilename (removes /, :, \0)
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol
- `TranscriberCore/Log.swift` -- os.Logger extension with 6 category loggers (audio, transcription, state, config, permissions, files)
- `TranscriberCore/AudioSourceResolver.swift` -- detects input format (dual WAV or stereo AAC), splits stereo AAC channels (L=local mic, R=remote system) for pipeline re-ingestion
- `TranscriberCore/AudioArchiver.swift` -- converts dual WAV (system+mic) to stereo AAC archive (L=mic, R=system) via AVAssetWriter, deletes source WAVs on success
- `TranscriberCore/StorageManager.swift` -- enforces audio archive storage quota in hours, deletes oldest .m4a files first, never deletes transcripts

### Standalone Swift CLI (legacy, still functional)
- `audio_capture_helper/` -- Swift Package Manager project, standalone binary for CLI use
- Produces `bin/audio-capture-helper` via `cd audio_capture_helper && bash build.sh`

## Audio Capture Architecture (critical knowledge)
- Swift captures TWO WAV files: system audio + microphone (separate streams from ScreenCaptureKit)
- `.audio` output type = system audio only (at 48 kHz, hardcoded)
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
# ~219 tests across ~20 suites (Config, ConfigManager, EngineID, WavFileWriter, AppState, FilenameUtils, CalendarEventPicker, PermissionManager, AudioDeviceEnumerator, InputLevelMonitor, RecordingSentinel, LaunchAgentManager, DiscoverSegments, SegmentNaming, etc.)
# Uses Swift Testing, not XCTest -- no Xcode installed, only CommandLineTools
# Test path: SwiftTests/TranscriberTests/ (not Tests/ -- case collision with Python tests/ on APFS)
```

### Swift (standalone CLI helper -- legacy)
```bash
cd audio_capture_helper && bash build.sh
# Produces bin/audio-capture-helper
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
22. **Engine model downloads (airgap guarantee):** ALL models (ASR ~500MB + diarization ~10MB) are downloaded eagerly during Setup or Settings Save — NEVER at recording/transcription time. `ensureLoaded()` in both `FluidAudioEngine` and `FluidAudioDiarizer` will throw `FluidAudioEngineError.modelNotDownloaded` if cache is missing rather than silently downloading. Use `FluidAudioEngine.isModelCached()` and `FluidAudioDiarizer.isDiarizationCached()` to check cache; `preDownloadModel(progress:)` and `preDownloadModels()` to trigger downloads. SpeechAnalyzer uses the system framework (no download).
23. **SpeechAnalyzerEngine compile guard:** `SpeechAnalyzer`/`SpeechTranscriber` types require the macOS 26 SDK (Swift 6.2+). The entire file is wrapped in `#if compiler(>=6.2)` and references in TranscriptionRunner/tests are similarly guarded. Remove when CI gains a macOS 26 runner.
24. **FluidAudio AudioSource:** Pass `.microphone` or `.system` to `AsrManager.transcribe()` based on stream type — affects audio preprocessing. Map from `AudioSourceType` enum in `TranscriptionEngine` protocol.
25. **FluidAudio ITN:** `TextNormalizer` converts spoken numbers to written form (e.g. "three hundred" → "300"). Uses a native C library via `dlsym` — gracefully no-ops if unavailable (`isNativeAvailable`). Applied per-segment after token grouping.
26. **Decimal-point sentence splitting:** The token grouper must not split on `.` when the next token starts with a digit (e.g. "1.5 million"), or it creates broken segments.
27. **Config default engine:** Must use `.resolvedDefault` (not `.speechAnalyzer`) so fresh installs on macOS 15 get FluidAudio instead of an unavailable engine.
28. **CLI entry detection:** Check for known subcommands (`transcribe`, `rename`, `benchmark`) not just `arguments.count > 1` — LaunchServices can inject extra arguments.
29. **Crash recovery sentinel:** `~/.audio-transcribe/recording.json` is written on recording start, deleted on clean stop. If it exists on launch, a crash happened. Check `RecordingSentinel.read()` and compare `startedAt` with system boot time to detect stale sentinels from a previous boot.
30. **LaunchAgent lifecycle:** `LaunchAgentManager.install()` on first launch, `LaunchAgentManager.uninstall()` before `NSApplication.terminate()` on explicit quit. Forgetting to unload means macOS restarts the app after every quit.
31. **XPC shared service instance:** `main.swift` uses a single `AudioCaptureService()` shared across all connections so a reconnecting client re-attaches to the same live session. Don't create per-connection instances.
32. **Multi-segment file naming:** Crash recovery creates segment files as `base-2.wav`, `base-3.wav`. Use `segmentBaseName()` from `SegmentNaming.swift` to strip/append segment suffixes — don't inline the regex.
33. **WAV periodic sync:** `WavFileWriter` calls `synchronizeFile()` every 0.5s. Without this, a crash could lose up to ~30s of buffered audio. The sync is cheap (~0.05ms on SSD).
34. **Recovery runs before permissions gate:** In `TranscriberApp.init()`, the recovery Task must be launched before the permissions check. Recording must resume even while the permission setup window is shown.
35. **Stereo AAC channel convention:** L=local microphone, R=remote system audio. This is the contract between AudioArchiver (producer) and AudioSourceResolver (consumer). Never swap channels.
36. **System audio capture rate:** Hardcoded to 48 kHz in SCStreamConfiguration. The `sample_rate` config field is deprecated — log a warning if present.
37. **Audio archive quota:** Enforced in hours via static calculation (hours × bitrate → bytes). Only .m4a files count toward quota. Transcripts are never deleted. The just-archived file is always protected from cleanup.
38. **AudioArchiver error safety:** If AAC encoding fails at any step, source WAV files are kept intact. Never delete WAVs before verifying the archive is valid.

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
- `scripts/dev.py` -- developer iteration CLI: kill/build/install/launch/reset-tcc with modular flags (replaced test-fresh.sh)
- `scripts/test-checklist.md` -- dynamic test checklist printed by dev.py on launch

## Branches
- `main` -- stable (Python rumps UI)
- `feature/swiftui-native-ui` -- SwiftUI native UI rewrite
- `feature/whisperkit-migration` -- engine abstraction: swappable engines replacing hardcoded WhisperKit (this branch)
