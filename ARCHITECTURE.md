# Architecture

## Overview

The app has three layers:

1. **SwiftUI app** (`TranscriberApp/`) — native macOS menu bar app using `MenuBarExtra`. Manages UI, settings, and orchestrates recording and transcription.

2. **XPC audio capture service** (`AudioCaptureHelper/XPC/`) — uses ScreenCaptureKit to capture two separate audio streams: system audio (`.audio`) and microphone (`.microphone`). Writes two WAV files:
   - `<base>.wav` — system/remote audio
   - `<base>_mic.wav` — local microphone (at device native rate)

3. **Swift transcription pipeline** (`TranscriberCore/`) — runs entirely in-process. Two swappable engines are available: Apple SpeechAnalyzer (default, macOS 26+) and FluidAudio (Parakeet, CoreML/ANE). Engine selection is stored in config and exposed in Settings. Each audio stream is transcribed independently, segments are tagged `Local Speaker X` / `Remote Speaker X` and merged chronologically.

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI App (MenuBarExtra)                                 │
│    ├── AudioCaptureClient ──XPC──┐                          │
│    │                             v                          │
│    │               AudioCaptureService (XPC)                │
│    │                 ├── SCStream (.audio)  → base.wav      │
│    │                 └── SCStream (.mic)    → base_mic.wav  │
│    │                                                         │
│    └── TranscriptionRunner                                   │
│          ├── EngineID (from config) → engine selection       │
│          ├── Engine (base.wav)       → Remote 1, 2…         │
│          ├── Engine (base_mic.wav)   → Local 1, 2…          │
│          └── merge chronologically   → transcript           │
│                                                              │
│    Engines:                                                  │
│      ├── SpeechAnalyzerEngine (Apple, macOS 26+, no download)│
│      └── FluidAudioEngine (Parakeet, CoreML/ANE, ~500MB)    │
└─────────────────────────────────────────────────────────────┘
```

## Key Technical Decisions

**1. macOS 15.0+ minimum**
`captureMicrophone` and `SCStreamOutputType.microphone` were added in macOS 15.0 (Sequoia). `Package.swift` uses `.macOS("15.0")` string syntax because the `.v15` enum requires swift-tools-version 6.0.

**2. Two separate files, no mixing**
ScreenCaptureKit delivers `.audio` (system) and `.microphone` (mic) as separate streams at different sample rates. There is no Apple API to get a pre-mixed stream (confirmed via SDK headers through macOS 26). Keeping them separate gives WhisperKit cleaner audio and enables automatic Local vs Remote speaker attribution.

**3. XPC service for audio capture**
Audio capture runs in a separate XPC service process (`audio-capture-helper-xpc`). This provides process isolation and scopes the TCC permission grant to the app bundle. XPC services only function when embedded inside a `.app` bundle — the bare binary cannot reach the service. The service detects client disconnection via `invalidationHandler` and stops capture + finalizes WAV files to prevent orphaned recordings.

**7. Crash recovery**
Recording survives crashes via three mechanisms: (1) a sentinel file (`~/.audio-transcribe/recording.json`) persists recording state; (2) a LaunchAgent (`KeepAlive: true`) auto-restarts the app; (3) `WavFileWriter` syncs data to disk every 0.5s. On relaunch, the app checks the sentinel and either re-attaches to a live XPC session (Flow A) or starts a new capture segment (Flow B). If the XPC service crashes while the UI is alive, the UI detects it instantly via `invalidationHandler` and restarts capture (Flow C). Multi-segment recordings are stitched at transcription time.

**4. Native sample rates, no resampling**
The mic sample rate varies by audio device (48kHz with speakers, 24kHz with some headphones). The Swift code auto-detects the rate from the first `CMSampleBuffer`'s format description and writes it to the WAV header on `finalize()`. WhisperKit handles any sample rate natively.

**5. No virtual audio devices needed**
Unlike BlackHole/Loopback solutions, ScreenCaptureKit captures system audio natively with a single macOS permission. `.screen` output type must be registered even for audio-only capture — this is a ScreenCaptureKit requirement.

**6. Fully Swift-native, swappable engines**
Both transcription engines are Swift-native with no Python runtime. SpeechAnalyzer uses Apple's system framework (no download). FluidAudio runs the Parakeet model on CoreML/ANE. Engines conform to the `TranscriptionEngine` protocol and are selected via `EngineID` in config.

## Source Layout

```
TranscriberApp/                  SwiftUI app target
  TranscriberApp.swift           @main entry, MenuBarExtra + Settings scenes
  Services/AudioCaptureClient.swift  XPC connection to capture service
  Services/TranscriptionRunner.swift Engine factory + transcription pipeline
  Views/MenuView.swift           Menu bar dropdown
  Views/SettingsView.swift       Settings Form
  Views/RenameDialog.swift       Speaker rename sheet

AudioCaptureHelper/XPC/          XPC service target
  AudioCaptureService.swift      Implements AudioCaptureProtocol via ScreenCaptureKit
  AudioOutputHandler.swift       Routes system/mic streams to WavFileWriters
  main.swift                     NSXPCListener entry point

AudioCaptureProtocol/            Shared protocol target
  AudioCaptureProtocol.swift     @objc XPC protocol + service name constant

TranscriberCore/                 Shared logic target
  AppState.swift                 Observable state machine: idle → recording → transcribing
  Config.swift                   Codable config (snake_case JSON keys, engine selection)
  ConfigManager.swift            Reads/writes ~/.audio-transcribe/config.json
  EngineID.swift                 Engine enum + EngineDescriptor metadata
  TranscriptionEngine.swift      Protocol for swappable transcription engines
  FluidAudioEngine.swift         FluidAudio/Parakeet engine (CoreML/ANE)
  SpeechAnalyzerEngine.swift     Apple SpeechAnalyzer engine (macOS 26+)
  DiarizationProvider.swift      Protocol for speaker diarization
  WavFileWriter.swift            WAV file writing with deferred sample rate + 0.5s sync
  RecordingSentinel.swift        Crash recovery state persistence (JSON sentinel file)
  LaunchAgentManager.swift       Install/unload KeepAlive LaunchAgent for auto-relaunch
  SegmentDiscovery.swift         Discover multi-segment audio files from crash recovery
  SegmentNaming.swift            Segment filename computation (strip/append -N suffix)
  AudioDeviceEnumerator.swift    Lists input devices via AVCaptureDevice
  InputLevelMonitor.swift        Real-time audio level meter
  FilenameUtils.swift            sanitizeFilename helper
  PermissionManager.swift        Observable permission status tracker
  Log.swift                      os.Logger extension (6 category loggers)
```

## TCC Permissions

Permission is granted to the **app bundle** (`CFBundleIdentifier: com.audio-transcribe.app`). When running as a `.app` bundle the grant is tied to the bundle ID. When running the bare binary from Terminal, macOS ties the grant to Terminal.app — which means it won't carry over to the installed app.

If you change `CFBundleIdentifier` in `packaging/Info.plist`, macOS treats it as a new app and you must re-grant permissions.
