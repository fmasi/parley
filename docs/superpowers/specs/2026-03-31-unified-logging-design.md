# Unified Logging Design

## Summary

Replace ad-hoc print/fputs/silent-failure patterns with Apple's unified logging system (`os.Logger`). All Swift components log through a single subsystem with category-based separation. Python output is forwarded into the unified log by TranscriptionRunner. The `logLevel` config field is removed as dead code. The `--console` flag in dev.py is replaced with `--debug` that tails the unified log.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Logging system | Apple unified logging (`os.Logger`) | Zero-cost `.debug` when unobserved; built-in level filtering; no disk flood in production; `log stream` for live debugging |
| Subsystem | Single: `com.audio-transcribe.app` | Small app; one `log stream` command catches everything |
| Python logging | Forward stdout/stderr into unified log | Python process is short-lived; keeps all logs in one stream |
| Config `logLevel` | Remove | Unified log system handles filtering at read-time; our own filter is redundant |
| `--console` flag | Replace with `--debug` | `--console` breaks TCC permissions; `--debug` launches app normally + tails unified log |
| Instrumentation scope | Pain-point-driven | Instrument areas that caused real debugging sessions, plus known fragile spots |

## Infrastructure

### Logger Extension

A single file in TranscriberCore provides static loggers per category:

```swift
import os

extension Logger {
    private static let subsystem = "com.audio-transcribe.app"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let state = Logger(subsystem: subsystem, category: "state")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let files = Logger(subsystem: subsystem, category: "files")
}
```

The XPC service (AudioCaptureHelperXPC) is a separate process but already links TranscriberCore (see Package.swift). It uses the same Logger extension — no separate copy needed.

### Log Levels

| Level | When to use | System behavior |
|---|---|---|
| `.debug` | Verbose detail: frame counts, buffer sizes, intermediate values | Memory-only. Zero-cost when not observed. Only visible via `log stream --level debug`. |
| `.info` | Milestones and decisions: "recording started", "mic detected as Int16 stereo 48kHz" | Persisted to disk with limited retention. Visible in Console.app and `log show`. |
| `.error` | Failures: XPC connection lost, Python non-zero exit, permission denied, file I/O error | Persisted to disk with long retention. Always visible. |
| `.fault` | Not used | Reserved for system-level corruption we don't expect to encounter. |

### Privacy

Use `os.Logger` privacy annotations for user data:

```swift
// File paths may contain username — redact in production
Logger.files.info("WAV created at \(path, privacy: .private)")

// Device names are not sensitive
Logger.audio.info("Mic selected: \(deviceName, privacy: .public)")

// Numeric values are public by default
Logger.audio.debug("Frame batch: \(sampleCount) samples")
```

Non-numeric interpolations are private by default in release builds. Use `.public` explicitly for values we want visible without `--private-data` flag.

## Instrumentation Plan

### Category: audio (XPC service — AudioCaptureService, AudioOutputHandler)

These address: handler deallocation, format detection surprises, sample rate negotiation, channel count detection, aggregate device filtering, start/stop race condition.

| Location | Level | Message |
|---|---|---|
| AudioCaptureService.startCapture | .info | `"Starting capture — system: \(systemPath), mic: \(micPath), device: \(deviceID)"` |
| AudioCaptureService.startCapture | .info | `"SCStream started, awaiting frames"` |
| AudioCaptureService.stopCapture | .info | `"Stopping capture"` |
| AudioCaptureService.stopCapture | .debug | `"SCStream stopped and removed delegate"` |
| AudioOutputHandler init | .debug | `"AudioOutputHandler initialized, handler retained"` |
| AudioOutputHandler (first system frame) | .info | `"System audio: \(sampleRate)Hz, \(channels)ch, \(formatName)"` |
| AudioOutputHandler (first mic frame) | .info | `"Mic audio: \(sampleRate)Hz, \(channels)ch, \(formatName)"` |
| AudioOutputHandler (frame batch) | .debug | `"System frame: \(sampleCount) samples"` / `"Mic frame: \(sampleCount) samples"` |
| AudioOutputHandler (format branch) | .debug | `"Writing \(formatName) samples to \(streamType)"` |
| AudioCaptureService (device filtering) | .debug | `"Filtered aggregate device: \(uniqueID)"` |
| AudioCaptureService (error) | .error | `"Capture error: \(error)"` |

### Category: transcription (TranscriptionRunner)

These address: Python environment resolution, launch debugging, real-time output, exit code diagnosis.

| Location | Level | Message |
|---|---|---|
| TranscriptionRunner.run (launch) | .info | `"Launching transcription — format: \(format), inputs: \(inputCount)"` |
| TranscriptionRunner.run (env) | .debug | `"Python env — HOME: \(pythonHome), PATH: \(path)"` |
| TranscriptionRunner.run (args) | .debug | `"Python args: \(arguments)"` |
| TranscriptionRunner (stdout line) | .info | `"[python] \(line)"` |
| TranscriptionRunner (stderr line) | .error | `"[python-err] \(line)"` |
| TranscriptionRunner (complete) | .info | `"Transcription complete — exit code: \(code), duration: \(seconds)s"` |
| TranscriptionRunner (failure) | .error | `"Transcription failed — exit code: \(code), stderr: \(lastLines)"` |

### Category: state (AppState, MenuView)

These address: state transition tracking, error message lifecycle, panel visibility debugging, notification delivery.

| Location | Level | Message |
|---|---|---|
| AppState.phase didSet | .info | `"State: \(oldPhase) -> \(newPhase)"` |
| AppState.errorMessage didSet | .info | `"Error set: \(message)"` / `"Error cleared"` |
| MenuView (start recording) | .info | `"Recording started — session: \(name)"` |
| MenuView (stop recording) | .info | `"Recording stopped"` |
| MenuView (dismiss error) | .debug | `"User dismissed error"` |
| MenuView (notification sent) | .debug | `"Notification sent: \(title)"` |
| MenuView (notification failed) | .error | `"Notification failed: \(error)"` |
| WindowController (panel shown) | .debug | `"Panel shown: \(panelType)"` |
| WindowController (panel closed) | .debug | `"Panel closed: \(panelType)"` |

### Category: config (ConfigManager)

These address: silent config corruption, unexpected values.

| Location | Level | Message |
|---|---|---|
| ConfigManager.load (success) | .info | `"Config loaded — format: \(outputFormat), sampleRate: \(rate)"` |
| ConfigManager.load (fallback) | .info | `"Config not found or invalid, using defaults"` |
| ConfigManager.save | .debug | `"Config saved"` |

### Category: permissions (PermissionManager)

These address: permission check failures, grant/deny visibility.

| Location | Level | Message |
|---|---|---|
| PermissionManager.checkAll | .info | `"Permissions — mic: \(mic), screen: \(screen), calendar: \(cal), notifications: \(notif)"` |
| PermissionManager (individual check) | .debug | `"Checked \(permission): \(status)"` |
| SetupView (grant tapped) | .debug | `"User tapped grant: \(permission)"` |

### Category: files (WavFileWriter)

These address: WAV lifecycle tracking, mid-recording crash diagnosis.

| Location | Level | Message |
|---|---|---|
| WavFileWriter.init | .debug | `"WAV writer created: \(path)"` |
| WavFileWriter (first sample) | .info | `"WAV first write — sampleRate: \(rate), channels: \(ch), format: \(fmt)"` |
| WavFileWriter.finalize | .info | `"WAV finalized: \(path), size: \(bytes) bytes"` |
| WavFileWriter (error) | .error | `"WAV write error: \(error)"` |

## TranscriptionRunner: Real-Time Forwarding

Currently TranscriptionRunner reads all stdout/stderr at process termination via `readDataToEndOfFile()`. Change to line-by-line reading so output appears in `log stream` in real-time:

```swift
// Instead of readDataToEndOfFile() at the end:
stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
    for l in line.split(separator: "\n") {
        Logger.transcription.info("[python] \(l, privacy: .public)")
    }
}

stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
    for l in line.split(separator: "\n") {
        Logger.transcription.error("[python-err] \(l, privacy: .public)")
    }
}
```

The readabilityHandler closures also accumulate into a `Data` buffer so that on non-zero exit, the full stderr is still available for the `RunnerError.failed()` message (same as today, just read incrementally instead of at end).

## Dead Code Removal

### Remove `logLevel` from Config

- Remove `logLevel` property from `TranscriberCore/Config.swift`
- Remove `logLevel` from `CodingKeys` enum
- Remove from default initializer
- Update any tests that reference `logLevel`
- Config.json files with `log_level` key will harmlessly ignore it (Codable skips unknown keys when not using `keyDecodingStrategy`)

Note: Codable does NOT skip unknown keys by default — it throws. We need to verify whether Config uses a custom decoder or relies on default. If default, we should keep the field but stop reading it, OR add a custom `init(from:)` that ignores unknown keys. The implementation plan should verify this.

## dev.py: Replace --console with --debug

Remove `--console` flag. Add `--debug` flag that:

1. Builds and installs the app normally (existing behavior)
2. Launches via `open -a AudioTranscribe` (TCC permissions work)
3. Starts `log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug` in the foreground
4. Ctrl+C stops the log stream; app keeps running

```python
if args.debug:
    step("Tailing unified log (Ctrl+C to stop)")
    subprocess.run([
        "log", "stream",
        "--predicate", 'subsystem == "com.audio-transcribe.app"',
        "--level", "debug",
        "--style", "compact",
    ])
```

## Debugging Cheat Sheet

For inclusion in CLAUDE.md or as a comment in the Logger extension:

```bash
# All logs, all levels (debug + info + error)
log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug

# Only errors
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND messageType == error'

# Only audio capture
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND category == "audio"' --level debug

# Only Python output
log stream --predicate 'subsystem == "com.audio-transcribe.app" AND category == "transcription"'

# Historical (last 5 minutes)
log show --predicate 'subsystem == "com.audio-transcribe.app"' --last 5m

# Via dev.py
python scripts/dev.py --debug
```

## What This Does NOT Cover

- **Python-side structured logging**: `transcribe.py` keeps using `print()`. Its output is forwarded into unified log by TranscriptionRunner. If run from CLI, output goes to terminal as usual.
- **Log persistence/export for end users**: No "send logs" feature. If needed later, `log collect` or `log show --archive` can export.
- **Crash reporting**: Out of scope. Unified logging captures up to the crash point but doesn't replace crash reporters.
