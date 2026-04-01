# Architecture

## Overview

The app has three layers:

1. **SwiftUI app** (`TranscriberApp/`) — native macOS menu bar app using `MenuBarExtra`. Manages UI, settings, and orchestrates recording and transcription.

2. **XPC audio capture service** (`AudioCaptureHelper/XPC/`) — uses ScreenCaptureKit to capture two separate audio streams: system audio (`.audio`) and microphone (`.microphone`). Writes two WAV files:
   - `<base>.wav` — system/remote audio
   - `<base>_mic.wav` — local microphone (at device native rate)

3. **Swift transcription pipeline** (`TranscriberCore/`) — runs entirely in-process. WhisperKit (Core ML) transcribes each audio stream independently. SpeakerKit performs speaker diarization. Segments are tagged `Local Speaker X` / `Remote Speaker X` and merged chronologically.

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
│          ├── WhisperKit (base.wav)    → Remote 1, 2…        │
│          ├── WhisperKit (base_mic…)   → Local 1, 2…         │
│          ├── SpeakerKit (diarization per stream)            │
│          └── merge chronologically   → transcript           │
└─────────────────────────────────────────────────────────────┘
```

## Key Technical Decisions

**1. macOS 15.0+ minimum**
`captureMicrophone` and `SCStreamOutputType.microphone` were added in macOS 15.0 (Sequoia). `Package.swift` uses `.macOS("15.0")` string syntax because the `.v15` enum requires swift-tools-version 6.0.

**2. Two separate files, no mixing**
ScreenCaptureKit delivers `.audio` (system) and `.microphone` (mic) as separate streams at different sample rates. There is no Apple API to get a pre-mixed stream (confirmed via SDK headers through macOS 26). Keeping them separate gives WhisperKit cleaner audio and enables automatic Local vs Remote speaker attribution.

**3. XPC service for audio capture**
Audio capture runs in a separate XPC service process (`audio-capture-helper-xpc`). This provides process isolation and scopes the TCC permission grant to the app bundle. XPC services only function when embedded inside a `.app` bundle — the bare binary cannot reach the service.

**4. Native sample rates, no resampling**
The mic sample rate varies by audio device (48kHz with speakers, 24kHz with some headphones). The Swift code auto-detects the rate from the first `CMSampleBuffer`'s format description and writes it to the WAV header on `finalize()`. WhisperKit handles any sample rate natively.

**5. No virtual audio devices needed**
Unlike BlackHole/Loopback solutions, ScreenCaptureKit captures system audio natively with a single macOS permission. `.screen` output type must be registered even for audio-only capture — this is a ScreenCaptureKit requirement.

**6. Fully Swift-native, no Python runtime**
WhisperKit runs Whisper models compiled to Core ML, executing on the Neural Engine / GPU via the Core ML framework. SpeakerKit performs speaker diarization natively in Swift. There is no embedded Python runtime or subprocess execution.

## Source Layout

```
TranscriberApp/                  SwiftUI app target
  TranscriberApp.swift           @main entry, MenuBarExtra + Settings scenes
  Services/AudioCaptureClient.swift  XPC connection to capture service
  Services/TranscriptionRunner.swift Drives WhisperKit + SpeakerKit pipeline
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
  Config.swift                   Codable config (snake_case JSON keys)
  ConfigManager.swift            Reads/writes ~/.audio-transcribe/config.json
  WavFileWriter.swift            WAV file writing with deferred sample rate
  AudioDeviceEnumerator.swift    Lists input devices via AVCaptureDevice
  InputLevelMonitor.swift        Real-time audio level meter
  FilenameUtils.swift            sanitizeFilename helper
  PermissionManager.swift        Observable permission status tracker
  Log.swift                      os.Logger extension (6 category loggers)
```

## TCC Permissions

Permission is granted to the **app bundle** (`CFBundleIdentifier: com.audio-transcribe.app`). When running as a `.app` bundle the grant is tied to the bundle ID. When running the bare binary from Terminal, macOS ties the grant to Terminal.app — which means it won't carry over to the installed app.

If you change `CFBundleIdentifier` in `packaging/Info.plist`, macOS treats it as a new app and you must re-grant permissions.
