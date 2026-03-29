# SwiftUI Native UI Rewrite — Design Spec

**Date:** 2026-03-29
**Branch:** `feature/swiftui-native-ui`
**Status:** Design approved, pending implementation

## Summary

Rewrite all UI code from Python (rumps/PyObjC) to native SwiftUI. The Swift app becomes the host process. Python transcription and the existing audio capture logic stay, but the audio helper migrates from SIGTERM-based subprocess to an XPC service.

## Architecture: Approach B + XPC

SwiftUI app owns the menu bar, settings, dialogs, and notifications. Audio capture runs as an XPC service (existing ScreenCaptureKit code, new entry point). Python transcription runs as a subprocess via `Process`.

```
+-------------------------------+
|  SwiftUI App (host)           |
|  - MenuBarExtra               |
|  - Settings scene             |
|  - Rename dialog              |
|  - State machine              |
|  - TranscriptionRunner        |
+--------+----------+----------+
         |          |
       XPC      subprocess
         |          |
  audio-capture  transcribe.py
  -helper        rename_speakers.py
```

### Why This Architecture

- Apple's recommended pattern for menu bar utilities with system-level workers
- Audio helper stays isolated — crash doesn't take down the UI
- Python subprocess for transcription is proven and avoids embedding a Python runtime
- XPC gives typed bidirectional messaging, lifecycle management, and TCC inheritance

## Project Structure

```
Transcriber/
  TranscriberApp/                  # SwiftUI app target
    TranscriberApp.swift           # @main — MenuBarExtra + Settings scenes
    Views/
      MenuView.swift               # Menu bar dropdown
      SettingsView.swift           # Settings window (Form)
      RenameDialog.swift           # Speaker rename sheet
    Models/
      AppState.swift               # Observable state machine
      Config.swift                 # Codable mirror of config.json
    Services/
      AudioCaptureClient.swift     # XPC client
      TranscriptionRunner.swift    # Launches transcribe.py via Process
      ConfigManager.swift          # Reads/writes ~/.audio-transcribe/config.json

  AudioCaptureHelper/              # XPC service target
    main.swift                     # XPC listener + service delegate
    AudioCaptureService.swift      # Implements XPC protocol
    CaptureSession.swift           # Existing ScreenCaptureKit logic (minimal changes)

  AudioCaptureProtocol/            # Shared target for XPC interface
    AudioCaptureProtocol.swift

  Python/                          # Bundled as-is into Resources
    transcribe.py
    rename_speakers.py
    service/

  Packaging/
    Info.plist
    embed_python.sh                # Embeds relocatable conda env
```

## State Machine

```swift
@Observable
class AppState {
    enum Phase {
        case idle
        case recording(since: Date)
        case transcribing(jobId: UUID, progress: String)
    }

    var phase: Phase = .idle
    var lastTranscriptPath: String?
    var error: AppError?
}
```

SwiftUI views observe `phase` directly. Menu items, icon, and labels react automatically.

### Recording Flow

1. User clicks "Start Recording"
2. `AppState.phase = .recording`
3. `AudioCaptureClient.start(outputDir:)` sends XPC message to helper
4. Helper begins writing `system.wav` and `mic.wav`
5. User clicks "Stop Recording"
6. `AudioCaptureClient.stop()` sends XPC message
7. Helper finalizes WAV headers, replies with file paths
8. `AppState.phase = .transcribing`
9. `TranscriptionRunner.run(systemAudio:, micAudio:)` launches `transcribe.py` via `Process`
10. On completion: `AppState.phase = .idle`, send notification

## XPC Protocol

```swift
@objc protocol AudioCaptureProtocol {
    func startCapture(
        outputDirectory: String,
        baseName: String,
        reply: @escaping (Bool, String?) -> Void
    )

    func stopCapture(
        reply: @escaping (String?, String?, String?) -> Void
        // (systemAudioPath, micAudioPath, errorMessage)
        // Both paths are non-nil on success; errorMessage is non-nil on failure
    )

    func status(
        reply: @escaping (Bool, String?) -> Void
    )
}
```

### Changes to Audio Helper

The ScreenCaptureKit capture logic (`CaptureSession`, WAV writing, mic sample rate auto-detection) stays unchanged. Only the entry point changes:

- **Before:** `main.swift` parses CLI args, installs SIGTERM handler, exits after recording
- **After:** `main.swift` starts `NSXPCListener.service()`, stays alive across recordings

### TCC Permissions

XPC service inherits host app's TCC grants (microphone, screen recording). Python subprocesses also inherit. Same behavior as today.

## SwiftUI Views

### App Entry Point

```swift
@main
struct TranscriberApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Transcriber", image: appState.menuBarIcon) {
            MenuView(appState: appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
```

`LSUIElement = true` — menu bar only, no dock icon.

### MenuView

Maps to current rumps menu items:

| Item | Action |
|------|--------|
| Start/Stop Recording | Toggle based on `appState.phase` |
| Open Recordings Folder | `NSWorkspace.shared.open(url)` |
| Settings... | `SettingsLink()` (with `SettingsAccess` workaround for macOS 26) |
| Rename Speakers... | Sets `appState.showRenameSheet` |
| Quit | `NSApplication.shared.terminate(nil)` |

Menu bar icon changes reactively: mic (idle), red dot (recording), hourglass (transcribing).

### SettingsView

SwiftUI `Form` with `.formStyle(.grouped)`:

- Recording Directory (TextField)
- Output Format (Picker: txt/srt/json)
- Silence Detection toggle + timeout field
- HuggingFace Token (SecureField)
- Launch at Login toggle
- Save button with status feedback

~50 lines replacing ~180 lines of PyObjC. Save/close feedback issues go away — SwiftUI state binding handles it natively.

### RenameDialog

SwiftUI sheet with:
- List of detected speakers with text fields for new names
- Play button per speaker using `AVAudioPlayer`
- Save/Cancel buttons

### Notifications

`UNUserNotificationCenter` replaces `rumps.notification()`.

## Config

Same file: `~/.audio-transcribe/config.json`
Same fields. Swift `Config` struct is `Codable`, mirrors the Python `ServiceConfig` dataclass exactly. Both the SwiftUI app and the Python CLI can read/write it.

## Packaging

### .app Bundle Layout

```
AudioTranscribe.app/
  Contents/
    Info.plist
    MacOS/
      AudioTranscribe
    XPCServices/
      com.audio-transcribe.capture-helper.xpc/
        Contents/
          MacOS/audio-capture-helper
          Info.plist
    Resources/
      Assets.car
      Python/
        transcribe.py
        rename_speakers.py
        service/
      python/
        Python.framework/
        lib/python3.11/site-packages/
```

### Build Workflow

1. `bash embed_python.sh` — embeds relocatable conda env (run once, or when deps change)
2. Open Xcode, Cmd+R — builds SwiftUI app + XPC service, copies Python files, signs, runs

Xcode build phases handle: compiling both targets, bundling the XPC service, copying Python resources, code signing. The `embed_python.sh` script is the only manual step.

## Migration Summary

### Stays Unchanged

- `transcribe.py` — core transcription
- `rename_speakers.py` — speaker renaming
- `service/config_manager.py` — Python CLI config access
- `service/logger.py` — Python-side logging
- `~/.audio-transcribe/config.json` — same file, same fields
- Audio capture ScreenCaptureKit logic — same code, new entry point

### Rewritten in Swift

| Python (deleted) | Swift (new) | Lines |
|---|---|---|
| `service/menu_bar_app.py` (334) | `TranscriberApp.swift` + `MenuView.swift` | ~80 |
| `service/settings_window.py` (181) | `SettingsView.swift` | ~50 |
| `service/rename_dialog.py` (~200) | `RenameDialog.swift` | ~80 |
| `service/audio_capture.py` (110) | `AudioCaptureClient.swift` | ~60 |
| `service/pipeline.py` + `job_queue.py` (~200) | `TranscriptionRunner.swift` | ~80 |
| `service/login_item.py` (50) | 3 lines in SettingsView | ~3 |
| `packaging/launcher.sh` + `build_app.sh` | Xcode project + `embed_python.sh` | — |

### Deleted (no longer needed)

- `service/menu_bar_app.py`
- `service/settings_window.py`
- `service/rename_dialog.py`
- `service/audio_capture.py`
- `service/pipeline.py`
- `service/job_queue.py`
- `service/login_item.py`
- `service/silence_detector.py`
- `packaging/launcher.sh`
- `packaging/build_app.sh`
- `rumps` Python dependency
- `pyobjc` Python dependency

### Net Effect

~1,075 lines of Python UI code replaced by ~350 lines of Swift. Python side shrinks to transcription/diarization logic only.

## Known Issues & Future Work

- **macOS 26 `openSettings` bug:** `SettingsLink()` / `openSettings` broken in MenuBarExtra-only apps. Use `orchetect/SettingsAccess` library as workaround.
- **Liquid Glass:** Standard SwiftUI controls adopt it automatically on macOS 26. Custom views can use `.glassEffect()`.
- **Sample rates and file sizes:** Revisit during XPC implementation — evaluate whether current dual-rate approach is optimal or if downsampling/compression makes sense.
- **Python CLI compatibility:** The CLI (`python transcribe.py -i file.wav`) continues to work independently of the app.
