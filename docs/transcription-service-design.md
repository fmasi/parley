# Transcription Service Design Spec

**Date:** 2026-03-27
**Project:** audio-transcribe (service extension)
**Status:** Design phase — awaiting skill invocation for detailed design + implementation plan

---

## Overview

Transform the existing `transcribe.py` + `rename_speakers.py` CLI tools into a background macOS service with:
- Menu bar GUI app for recording control
- Automatic transcription pipeline on recording stop
- Interactive speaker renaming with visual prompts
- Configurable recording location
- Silent audio detection with user prompts
- Error logging and notifications

---

## Key Design Decisions

### 1. Recording Trigger
**Option Selected: B - macOS menu bar GUI app**
- Simple visual "Start Record" / "Stop Record" button
- Red indicator during recording
- Future: keyboard shortcut support

### 2. Audio Capture
**Requirements:**
- Capture both microphone AND system audio simultaneously
- Works with speakers and headphones
- Cross-talk from both user and meeting participants

**Technical approach:** (TBD during detailed design)
- Options: ffmpeg + BlackHole, Core Audio APIs, or existing library

### 3. Recording Storage
**Location:** `~/Documents/Recordings/` (user-configurable)
- Organized by date or custom folder structure (TBD)
- Audio files named consistently (e.g., `recording_YYYYMMDD_HHMMSS.m4a`)

### 4. Transcription Pipeline
**Trigger:** Automatic when recording stops
**Flow:**
1. Recording stopped → trigger `transcribe.py` on audio file
2. Transcription runs (expensive operation, cached JSON saved)
3. On completion → immediately prompt user with rename dialog

**Error handling:**
- Log all failures to file
- Show system notification + error dialog if transcription fails
- User can manually retry or skip renaming

### 5. Speaker Renaming
**Trigger:** Automatic popup after transcription completes
**Behavior:**
- Interactive GUI (not CLI) showing:
  - Audio samples of each speaker (auto-played)
  - Prompt to name speaker
  - Save names to JSON metadata
- Output format same as original recording request (e.g., if user wanted `.srt`, rename produces `.srt`)

### 6. Silence Detection
**Feature:** Auto-prompt if silence detected
**Behavior:**
- Monitor audio levels during recording
- If no sound detected for configurable duration (default: 5 minutes)
- Show notification: "No audio detected. Stop recording?"
- User can dismiss and continue or stop

**Purpose:** Prevent accidental long idle recordings

### 7. Logging & Notifications
**Logging:**
- Service logs to `~/Library/Application Support/Parley/logs/` or similar
- Include timestamps, errors, transcription status

**Notifications:**
- Transcription complete → system notification
- Transcription failed → error notification + dialog
- Silence detected → gentle prompt notification
- Recording started/stopped → optional menu bar update

---

## Architecture Overview

### Components (TBD in detailed design)
1. **Menu Bar App** — GUI controller, recording state management
2. **Audio Capture Module** — microphone + system audio mixing
3. **Service Daemon** — background process coordinating transcription pipeline
4. **Transcription Pipeline** — calls existing `transcribe.py`, watches for completion
5. **Rename GUI** — interactive speaker naming dialog
6. **Configuration Manager** — reads/stores user settings
7. **Logger** — file + console logging

### Data Flow
```
Recording → Audio File → transcribe.py (mlx-whisper + pyannote)
         → JSON Master + Format Outputs
         → Rename Prompt (GUI popup)
         → User names speakers
         → Final transcript saved
         → Log entry recorded
```

---

## Configuration

**User-configurable settings:**
- Recording directory (default: `~/Documents/Recordings/`)
- Silence detection timeout (default: 5 min)
- Output format preference (txt/srt/json)
- Auto-start on launch? (yes/no)
- Logging level (debug/info/error)

**Storage location:** `~/Library/Application Support/Parley/config.json` (or similar)

---

## Known Constraints & Unknowns

### Constraints
- macOS only (uses launchd, AppleScript, Core Audio, etc.)
- Requires ffmpeg installed (`brew install ffmpeg`)
- Requires mlx-whisper + pyannote setup (already done)
- BlackHole or equivalent for system audio capture (license/dependency)

### TBD in Detailed Design
- Exact audio mixing library/approach
- GUI framework (PyQt, Tkinter, SwiftUI, or existing menu bar lib)
- Service architecture (launchd daemon vs. local background process)
- File naming and organization scheme
- Silence detection algorithm (threshold, duration, windowing)
- Error recovery strategies
- Multi-recording handling (queue vs. sequential)

---

## Success Criteria

1. ✅ Recording started/stopped from menu bar (no CLI required)
2. ✅ Transcription runs automatically on stop
3. ✅ Speaker renaming works via GUI popup
4. ✅ Audio files organized in configurable location
5. ✅ Silence detection warns user after N minutes
6. ✅ Errors logged AND shown to user
7. ✅ Service survives system sleep/wake
8. ✅ No manual intervention needed after "Stop Recording"

---

## Next Steps

1. Invoke detailed design skill (superpowers:brainstorming or equivalent)
2. Decide on audio capture approach (Core Audio, ffmpeg + BlackHole, etc.)
3. Choose GUI framework
4. Design service daemon architecture
5. Write implementation plan (superpowers:writing-plans)
6. Execute implementation with component testing
