# Architecture

## Overview

The app has three layers:

1. **SwiftUI app** (`TranscriberApp/`) — native macOS menu bar app using `MenuBarExtra`. Manages UI, settings, and orchestrates recording and transcription.

2. **XPC audio capture service** (`AudioCaptureHelper/XPC/`) — uses ScreenCaptureKit to capture two separate audio streams: system audio (`.audio`) and microphone (`.microphone`). Writes two WAV files:
   - `<base>.wav` — system/remote audio
   - `<base>_mic.wav` — local microphone (at device native rate)

3. **Python transcription** (`transcribe.py`) — launched as a subprocess by the Swift app. Accepts dual `-i` flags, transcribes each stream independently, tags segments as `Local Speaker X` / `Remote Speaker X`, and merges them chronologically.

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI App (MenuBarExtra)                             │
│    ├── AudioCaptureClient ──XPC──┐                      │
│    │                             v                      │
│    │               AudioCaptureService (XPC)            │
│    │                 ├── SCStream (.audio)  → base.wav  │
│    │                 └── SCStream (.mic)    → base_mic… │
│    │                                                     │
│    └── TranscriptionRunner                               │
│          └── Process: python transcribe.py               │
│                ├── Whisper (base.wav)    → Remote 1, 2… │
│                ├── Whisper (base_mic…)   → Local 1, 2…  │
│                └── merge chronologically → transcript   │
└─────────────────────────────────────────────────────────┘
```

## Key Technical Decisions

**1. macOS 15.0+ minimum**
`captureMicrophone` and `SCStreamOutputType.microphone` were added in macOS 15.0 (Sequoia). `Package.swift` uses `.macOS("15.0")` string syntax because the `.v15` enum requires swift-tools-version 6.0.

**2. Two separate files, no mixing**
ScreenCaptureKit delivers `.audio` (system) and `.microphone` (mic) as separate streams at different sample rates. There is no Apple API to get a pre-mixed stream (confirmed via SDK headers through macOS 26). Keeping them separate gives Whisper cleaner audio and enables automatic Local vs Remote speaker attribution.

**3. XPC service for audio capture**
Audio capture runs in a separate XPC service process (`audio-capture-helper-xpc`). This provides process isolation and scopes the TCC permission grant to the app bundle. XPC services only function when embedded inside a `.app` bundle — the bare binary cannot reach the service.

**4. Native sample rates, no resampling**
The mic sample rate varies by audio device (48kHz with speakers, 24kHz with some headphones). The Swift code auto-detects the rate from the first `CMSampleBuffer`'s format description and writes it to the WAV header on `finalize()`. Whisper handles any sample rate natively.

**5. No virtual audio devices needed**
Unlike BlackHole/Loopback solutions, ScreenCaptureKit captures system audio natively with a single macOS permission. `.screen` output type must be registered even for audio-only capture — this is a ScreenCaptureKit requirement.

## Source Layout

```
TranscriberApp/                  SwiftUI app target
  TranscriberApp.swift           @main entry, MenuBarExtra + Settings scenes
  Models/AppState.swift          Observable state machine: idle → recording → transcribing
  Models/Config.swift            Codable config mirroring config.json (snake_case keys)
  Services/ConfigManager.swift   Reads/writes ~/.audio-transcribe/config.json
  Services/AudioCaptureClient.swift  XPC connection to capture service
  Services/TranscriptionRunner.swift Launches transcribe.py via Process
  Views/MenuView.swift           Menu bar dropdown
  Views/SettingsView.swift       Settings Form
  Views/RenameDialog.swift       Speaker rename sheet

AudioCaptureHelper/XPC/          XPC service target
  AudioCaptureService.swift      Implements AudioCaptureProtocol via ScreenCaptureKit
  AudioOutputHandler.swift       Routes system/mic streams to WavFileWriters
  WavFileWriter.swift            WAV file writing with deferred sample rate
  main.swift                     NSXPCListener entry point

AudioCaptureProtocol/            Shared protocol target
  AudioCaptureProtocol.swift     @objc XPC protocol + service name constant

transcribe.py                    Python transcription CLI
rename_speakers.py               Interactive speaker renaming CLI
service/config_manager.py        JSON config (shared format with Swift ConfigManager)
service/logger.py                Logging setup
```

## TCC Permissions

Permission is granted to the **app bundle** (`CFBundleIdentifier: com.audio-transcribe.app`). When running as a `.app` bundle the grant is tied to the bundle ID. When running the bare binary from Terminal, macOS ties the grant to Terminal.app — which means it won't carry over to the installed app.

If you change `CFBundleIdentifier` in `packaging/Info.plist`, macOS treats it as a new app and you must re-grant permissions.
