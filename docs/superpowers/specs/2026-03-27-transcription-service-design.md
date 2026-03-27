# Transcription Service Design Spec

**Date:** 2026-03-27
**Project:** audio-transcribe (macOS service extension)
**Status:** Design approved, ready for implementation planning
**Author:** Design brainstorming session with user approval

---

## Executive Summary

Transform the existing CLI transcription tools (`transcribe.py`, `rename_speakers.py`) into a seamless background service on macOS. Users click a menu bar button to record meetings; transcription and speaker renaming happen automatically. No setup beyond granting permissions — the service "just works" like Notion AI.

**Key design decisions:**
- AppKit + PyObjC for native UI (Python-only, no Swift/C code)
- CoreAudio APIs for simultaneous mic + system audio capture (no BlackHole)
- Persistent daemon for back-to-back recording sessions
- Silero VAD for intelligent silence detection (speech-aware, not level-based)
- Calendar event lookup for auto-populating recording names
- All configuration user-accessible via menu bar settings

---

## Architecture

### System Overview

Two coordinated processes:

**1. Menu Bar App (Always Running)**
- AppKit GUI via PyObjC
- Starts at user login via launchd
- Handles all UI: recording control, settings, rename dialogs, notifications
- Manages daemon lifecycle

**2. Background Pipeline (Event-Driven)**
- File system watcher for recording completion
- Orchestrates transcription (calls existing `transcribe.py`)
- Triggers speaker renaming on transcription success
- Error recovery and logging

### Component Breakdown

#### Menu Bar App (AppKit + PyObjC)
**Responsibilities:**
- Menu bar button with recording state indicator (red dot = recording)
- "Start Recording" dialog:
  - Prompts for recording name
  - Calendar lookup (checks Apple Calendar for current event, pre-fills name)
  - User can edit or accept
- "Stop Recording" action
- Settings window:
  - Recording directory (configurable, default: `~/Documents/Recordings`)
  - Silence detection timeout (default: 5 minutes, toggle to enable/disable)
  - Output format preference (txt/srt/json)
  - Launch on startup (toggle)
  - View logs (opens log file)
- Notification dispatcher:
  - "Transcription complete" notification
  - "Transcription failed" error dialog + notification
  - "No audio detected" prompt during silence timeout
- Rename speaker dialog (native macOS popup):
  - Audio samples played via `afplay`
  - Prompts for speaker names
  - Integrated with existing `rename_speakers.py` logic

#### Audio Capture Module (PyObjC + CoreAudio)
**Responsibilities:**
- Access CoreAudio APIs via PyObjC
- Capture microphone input stream
- Capture system audio output stream (mixed in-memory)
- Blend both streams without external virtual devices
- Write M4A file to specified location
- Handle device enumeration (fallback if default device unavailable)

**Key detail:** Uses CoreAudio's Audio Unit (AU) architecture to build a custom audio graph mixing both inputs. Permission: macOS Screen Recording permission grants this access.

#### Pipeline Orchestrator (Subprocess)
**Responsibilities:**
- File system watcher (monitors `~/Documents/Recordings/*` for new `.m4a` files)
- Silence detector:
  - Runs Silero VAD on live audio stream during recording
  - Counts silence as "no human speech detected for N minutes"
  - After timeout, shows notification: "No audio detected. Stop recording?"
  - User can dismiss and continue, or stop
  - Disabled via toggle in settings
- Transcription trigger:
  - When recording stops, launches `transcribe.py` with detected recording
  - Polls for completion (JSON file appears)
  - On success, captures output format from metadata
- Rename trigger:
  - Launches rename speaker dialog via GUI
  - Blocks until user completes naming
  - Updates JSON + output files
- Error handler:
  - Catches transcription failures
  - Shows error notification with option to retry
  - Logs all errors with timestamp + context
  - Allows manual recovery via settings

#### Configuration Manager
**Responsibilities:**
- Read/write `~/.audio-transcribe/config.json`
- Validate settings on load
- Provide defaults if missing
- Hot-reload on settings change (no restart needed)

**Config file structure:**
```json
{
  "recording_directory": "~/Documents/Recordings",
  "silence_timeout_minutes": 5,
  "silence_detection_enabled": true,
  "output_format": "txt",
  "launch_on_startup": true,
  "log_level": "info"
}
```

#### Logger
**Responsibilities:**
- Write to `~/.audio-transcribe/logs/transcribe-service.log`
- Include: timestamp, level (INFO/ERROR/DEBUG), component, message
- Daily rotation, keep 7 days of logs
- Toggle verbosity (info/debug) in settings

---

## Recording & Transcription Flow

### User Flow: Single Recording Session

```
1. User clicks "Start Recording" in menu bar
   ↓
2. Dialog appears: "Recording name?"
   - Calendar lookup checks Apple Calendar
   - If event found: pre-fills with event title
   - User can edit or accept
   ↓
3. Recording starts
   - Menu bar shows red indicator
   - Audio capture: mic + system audio mixed in-memory
   ↓
4. During recording:
   - Silence detector runs (Silero VAD)
   - If no speech for 5 min → notification: "No audio detected. Stop?"
   - User can dismiss and continue
   ↓
5. User clicks "Stop Recording"
   - Audio capture ends
   - File written: ~/Documents/Recordings/2026-03-27/Client_Meeting.m4a
   - Menu bar red dot disappears
   ↓
6. Pipeline detects file completion
   - Runs: transcribe.py -i Client_Meeting.m4a -f {user_format}
   ↓
7. Transcription complete (~1-10 min depending on audio length)
   - Outputs: Client_Meeting.json (master) + Client_Meeting.{txt|srt}
   - Pipeline detects completion
   ↓
8. Rename speaker dialog pops up
   - Shows detected speakers
   - Plays 10-second audio sample of each
   - Prompts "Who is Speaker 1?" etc.
   - User names speakers
   ↓
9. Rename complete
   - JSON + output files updated with real names
   - Success notification shown
   - Log entry recorded
```

### File Organization

**Directory structure:**
```
~/Documents/Recordings/
  2026-03-27/
    143022_Client_Meeting.m4a
    143022_Client_Meeting.json      (master)
    143022_Client_Meeting.txt       (or .srt based on user preference)
  2026-03-28/
    095530_Team_Standup.m4a
    095530_Team_Standup.json
    095530_Team_Standup.txt
```

**Naming:** `HHMMSS_RecordingName.{m4a|json|txt|srt}`
- Timestamp ensures uniqueness
- Preserves user-provided name
- Sortable by time

---

## System Requirements & Setup

### Prerequisites
- macOS 12.0 or later
- Python 3.9+
- ffmpeg (for audio processing): `brew install ffmpeg`
- Installed via pip: mlx-whisper, pyannote.audio, silero-vad, PyObjC

### First-Time Setup
1. User installs: `pip install audio-transcribe` (or clones repo)
2. First launch → macOS system dialog: "Grant Screen Recording permission?"
3. User clicks "Allow" (one-time, system-level permission)
4. Service starts and registers with launchd
5. Ready to record

### Configuration
- User settings accessible via menu bar: Settings icon
- Config stored: `~/.audio-transcribe/config.json`
- Changes apply immediately (no restart needed)
- Defaults provided if config missing

### Launch Management
- Launchd plist: `~/Library/LaunchAgents/com.audio-transcribe.plist`
- Starts automatically at user login (unless disabled in settings)
- User can disable "Launch on Startup" to prevent auto-start

### Logging
- Location: `~/.audio-transcribe/logs/transcribe-service.log`
- Rotation: daily, keep 7 days
- Accessible via Settings → "View Logs"
- Default level: info (toggle to debug if needed)

---

## Error Handling & Recovery

### Transcription Failure
**Scenario:** `transcribe.py` crashes or fails

**Recovery:**
1. Pipeline detects failure (no JSON output after timeout)
2. Shows error notification: "Transcription failed. Retry?"
3. User can:
   - Retry (auto-runs `transcribe.py` again)
   - Skip and manually run later
   - Check logs for details
4. Log entry with full error message

### Audio Capture Failure
**Scenario:** CoreAudio device unavailable or permission denied

**Recovery:**
1. Recording fails to start
2. Shows error: "Cannot access audio devices. Check permissions?"
3. User can:
   - Re-grant Screen Recording permission in System Settings
   - Check if another app is blocking audio
   - View logs for details

### Silence Detector False Positives
**Scenario:** Legitimate silence (thinking, background noise) triggers prompt

**Recovery:**
- User dismisses notification and continues recording
- Can disable silence detection in settings
- Timeout is configurable (default 5 min, can adjust)

### Multi-Recording Edge Cases
**Scenario:** User tries to start a second recording while first is transcribing

**Behavior:**
- Second recording starts normally
- Pipeline queues transcription (sequential, not parallel)
- First transcription completes, then second starts
- Rename prompts appear in order

---

## Testing & Validation

### Unit Tests (Per Component)
- Audio capture: verify mic + system audio both captured
- VAD: verify speech detected, non-speech ignored
- Pipeline: verify file watcher detects completion
- Configuration: verify settings load/save/validate
- Logger: verify log rotation works

### Integration Tests
- Full recording → transcription → rename flow
- Error recovery (transcription failure, retry)
- Multi-recording queueing
- Settings changes apply without restart
- Silence detection prompt dismissal

### User Testing
- Record a meeting, verify transcription quality
- Test rename dialog UX
- Test settings changes (location, timeout, format)
- Test silence detection (legitimate pauses don't trigger)
- Test calendar pre-population

---

## Constraints & Assumptions

### Constraints
- macOS-only (uses launchd, AppKit, CoreAudio, Calendar APIs)
- Requires Screen Recording permission (OS-level, not app permission)
- Requires ffmpeg installed separately
- Requires mlx-whisper + pyannote.audio environment (already setup)

### Assumptions
- Apple Calendar is available (fallback: no pre-population if unavailable)
- User has microphone + speaker audio available
- Typical recording: 5 min - 2 hours (transcription time ~same as audio length)
- Users record back-to-back, so persistent daemon is justified

### Future Enhancements (Out of Scope)
- Google Calendar integration (Apple Calendar only for now)
- Custom VAD models (Silero VAD is sufficient)
- Automatic call-end detection (user manually stops)
- Batch transcription queue management UI
- Cloud transcription (on-device only)

---

## Success Criteria

1. ✅ Menu bar app launches at startup (configurable)
2. ✅ Recording starts/stops with one click
3. ✅ Calendar event auto-populates recording name
4. ✅ Mic + system audio captured simultaneously
5. ✅ No external virtual devices needed (CoreAudio direct)
6. ✅ Transcription auto-triggers on recording stop
7. ✅ Rename speaker dialog pops up automatically
8. ✅ All output files (txt/srt/json) organized by date
9. ✅ Silence detection (VAD-based) prompts after 5 min inactivity
10. ✅ Errors logged AND shown to user with recovery options
11. ✅ Settings configurable via menu bar (no config file editing)
12. ✅ Service survives system sleep/wake
13. ✅ Back-to-back recordings queue transcriptions sequentially
14. ✅ Logs accessible and rotated daily

---

## Implementation Roadmap

### Phase 1: Core Recording
- Audio capture module (CoreAudio + PyObjC)
- Menu bar app (start/stop button, name prompt)
- File organization and naming

### Phase 2: Transcription Pipeline
- File watcher for recording completion
- Pipeline orchestrator (calls existing `transcribe.py`)
- Error handling and retry logic

### Phase 3: Speaker Renaming
- Rename GUI integration
- Automation trigger on transcription complete

### Phase 4: Polish
- Silence detection (Silero VAD)
- Settings UI and configuration manager
- Calendar integration
- Logging and error notifications
- Launchd setup for auto-startup

---

## Deliverables

1. `audio_capture.py` — CoreAudio wrapper via PyObjC
2. `menu_bar_app.py` — AppKit menu bar application
3. `pipeline.py` — Orchestrator for transcription workflow
4. `silence_detector.py` — Silero VAD integration
5. `config_manager.py` — Settings management
6. `logger.py` — File logging with rotation
7. `main.py` — Entry point, launchd integration
8. Unit + integration tests for each component
9. Updated README with installation and usage
10. launchd plist template for auto-startup
