# Transcriber - Project Instructions

## Environment
- **NEVER install Python packages directly on the host machine** -- always use a conda environment
- macOS only (requires Apple Silicon for mlx-whisper)
- Requires macOS 15.0+ for microphone capture via ScreenCaptureKit

## Project Overview
macOS menu bar app for meeting transcription (mic + system audio from Zoom/Teams/Meet).
- Python: rumps menu bar UI, pipeline orchestration, transcription
- Swift: audio capture via ScreenCaptureKit (separate binary)
- Uses mlx-whisper (Apple Silicon optimized) + pyannote.audio for speaker diarization

## Architecture

### Entry Points
- `service/menu_bar_app.py` -- rumps-based menu bar app, state machine: IDLE -> RECORDING -> TRANSCRIBING -> IDLE
- `transcribe.py` -- CLI tool, mlx-whisper + pyannote diarization, supports dual-stream input (`-i system.wav -i mic.wav`)
- `rename_speakers.py` -- interactive speaker renaming, reads/updates JSON master file

### Core Modules
- `service/audio_capture.py` -- thin Python subprocess wrapper around the Swift binary
- `service/pipeline.py` + `service/job_queue.py` -- orchestration, runs transcribe.py as subprocess
- `service/config_manager.py` -- JSON config at `~/.audio-transcribe/config.json` (fields: recording_directory, silence_timeout_minutes, silence_detection_enabled, output_format, launch_on_startup, log_level, suppress_capture_warning, hf_token)
- `service/settings_window.py` -- PyObjC native settings window (includes HF Token field + Launch at Login toggle)
- `service/login_item.py` -- SMAppService wrapper for login item registration (no-ops outside .app bundle)

### Swift Audio Capture
- `audio_capture_helper/` -- Swift Package Manager project using ScreenCaptureKit
- Produces `bin/audio-capture-helper` via `cd audio_capture_helper && bash build.sh`

## Audio Capture Architecture (critical knowledge)
- Swift helper writes TWO WAV files: system audio + microphone (separate streams from ScreenCaptureKit)
- `.audio` output type = system audio only (at config sampleRate)
- `.microphone` output type = microphone only (at NATIVE device rate, varies: 24kHz, 48kHz)
- There is NO Apple API to get a pre-mixed stream (verified in SDK headers through macOS 26)
- Handler must be stored as global to prevent deallocation
- Must use async/await API, not completion-handler callbacks (callbacks don't deliver frames reliably)
- SIGTERM triggers clean shutdown: stopCapture -> finalize WAV headers -> exit(0)
- Exit code 2 = permission denied

## Build & Test

### Swift
```bash
cd audio_capture_helper && bash build.sh
# Produces bin/audio-capture-helper
```

### Python
```bash
# Activate conda env first!
python -m pytest tests/ -q
# 126 tests; ignore test_silence_detector.py if torch not installed
```

## Key Gotchas
1. `captureMicrophone` requires macOS 15.0+ (not 14.0)
2. PackageDescription `.v15` requires swift-tools-version 6.0; use `.macOS("15.0")` string syntax with 5.9
3. Mic sample rate varies by device -- auto-detect from CMSampleBuffer format description, don't hardcode
4. ScreenCaptureKit requires `.screen` output registration even for audio-only capture
5. TCC permission is granted to the host app — when running as .app bundle this is the bundle (CFBundleIdentifier: com.audio-transcribe.app); when running from Terminal it's Terminal.app (doesn't persist as a service)
6. The `suppress_capture_warning` config field exists but is not yet wired up in UI

## Packaging
- `packaging/Info.plist` -- bundle metadata (CFBundleIdentifier, TCC usage descriptions, LSUIElement)
- `packaging/launcher.sh` -- sets PYTHONHOME/PYTHONPATH, exec's embedded Python (TCC flows to subprocesses)
- `packaging/build_app.sh` -- assembles .app, embeds relocatable Python, ad-hoc signs, creates DMG

## Branches
- `main` -- stable
- `feature/full-audio-capture` -- .app bundle packaging + HF token UI + login item (PR #2)
- `claude/review-docs-tests-sRRO3` -- docs + test improvements (merged)
