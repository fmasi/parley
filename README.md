# Audio Transcription Tool

On-device audio transcription with speaker diarization for Apple Silicon Macs.
Uses MLX-optimized Whisper (large-v3) and pyannote.audio for speaker detection.
Includes a persistent macOS menu bar service for automatic recording and transcription.

## Features

- Transcribes audio files via CLI (`transcribe.py`)
- Dual-stream audio capture — system audio and microphone are recorded as separate files for cleaner transcription and automatic Local/Remote speaker attribution
- Speaker diarization — labels who said what
- Interactive speaker renaming with audio playback (`rename_speakers.py`)
- macOS menu bar service — records, transcribes, and prompts for speaker names automatically
- Silence detection via Silero VAD — stops recording when no one is speaking
- Apple Calendar integration — pre-populates recording names from current meeting
- Outputs: plain text, SRT subtitles, JSON (always saved as master copy)
- Fully on-device, free after model download

## Requirements

- macOS 15.0+ (Sequoia) with Apple Silicon (M1/M2/M3/M4/M5)
- Python 3.11 in a conda environment (development / CLI)
- **python.org Python 3.11** framework build — required to produce the `.app` bundle (not conda, not Homebrew)
- Xcode Command Line Tools (`xcode-select --install`)
- ffmpeg (Homebrew)
- HuggingFace account (free, for pyannote models)

## Architecture

Audio capture uses a **two-process design**:

1. **Swift helper** (`audio_capture_helper/`) — uses ScreenCaptureKit to capture two separate audio streams: system audio (`.audio`) and microphone (`.microphone`). Writes two WAV files:
   - `<base>.wav` — system/remote audio (sample rate follows config)
   - `<base>_mic.wav` — local microphone (at device native rate, e.g. 48kHz with speakers, 24kHz with some headphones)
2. **Python wrapper** (`audio_capture.py`) — thin subprocess wrapper that launches/stops the Swift helper via SIGTERM.
3. **Transcriber** (`transcribe.py`) — accepts dual `-i` flags, transcribes each stream independently, tags segments as `Local Speaker X` / `Remote Speaker X`, and merges them chronologically.

```
┌─────────────────────────────────────────────────────────┐
│  Python (audio_capture.py)                              │
│    └── subprocess: audio-capture-helper                 │
│          ├── SCStream (.audio)       → base.wav         │
│          └── SCStream (.microphone)  → base_mic.wav     │
│                                                         │
│  Python (transcribe.py -i base.wav -i base_mic.wav)     │
│    ├── Whisper (base.wav)      → Remote Speaker 1, 2…   │
│    ├── Whisper (base_mic.wav)  → Local Speaker 1, 2…    │
│    └── merge chronologically   → final transcript       │
└─────────────────────────────────────────────────────────┘
```

### Key technical decisions

1. **macOS 15.0+ minimum** — `captureMicrophone` and `SCStreamOutputType.microphone` were added in macOS 15.0 (Sequoia), not 14.0 as initially assumed. The Package.swift uses `.macOS("15.0")` string syntax because the `.v15` enum requires swift-tools-version 6.0.

2. **Two separate files, no mixing** — ScreenCaptureKit delivers `.audio` (system) and `.microphone` (mic) as separate streams at different sample rates. There is no Apple API to get a pre-mixed stream (confirmed via SDK headers through macOS 15.4 and macOS 26). Apps like Granola and Muesli also capture two streams. Keeping them separate gives Whisper cleaner audio and enables automatic Local vs Remote speaker attribution.

3. **async/await + global handler** — The original callback-based approach produced 0-byte WAV files because: (a) the AudioOutputHandler was a local variable that got deallocated before frames arrived, and (b) the callback-based SCShareableContent/startCapture API didn't reliably deliver stream output callbacks. Switching to async/await and storing the handler as a global fixed both issues.

4. **Native sample rates** — The mic sample rate varies by audio device (48kHz with speakers, 24kHz with some headphones). The Swift code auto-detects the rate from the first CMSampleBuffer's format description and writes it to the WAV header on finalize(). No resampling is done — Whisper handles any sample rate.

5. **No virtual audio devices needed** — Unlike BlackHole/Loopback solutions, ScreenCaptureKit captures system audio natively. Only a single macOS permission is required.

## Audio capture

The service captures **both your microphone and system audio** (Zoom, Teams, Google Meet, etc.) simultaneously using ScreenCaptureKit — no virtual audio devices required.

- With **headphones**: your mic captures your voice; system audio captures the remote side
- With **speakers**: both sides are captured by the mic naturally, and system audio also captures the remote side — both paths work
- Works with any app (Zoom, Teams, Meet, Slack, FaceTime, Discord, ...)

### Known constraints

- macOS 15.0+ (Sequoia) required — earlier versions lack `SCStreamOutputType.microphone`
- Swift CLI must be ad-hoc signed with `com.apple.security.screen-capture` entitlement
- `.screen` output type must be registered even for audio-only capture (SCStream requirement)
- The helper process must stay alive — Python sends SIGTERM to stop it gracefully
- Exit code 2 from the helper = permission denied

## macOS permissions

The first time you run the service macOS will prompt for these permissions:

| Permission | Required for |
|---|---|
| **Screen & System Audio Recording** | Recording both microphone and system audio via ScreenCaptureKit (covers both streams with a single permission) |
| **Calendars** | Pre-populating recording names from the current meeting (optional) |
| **Accessibility / Automation** | AppKit dialogs appearing in front of other windows |

Permission is granted to the **host app** (Terminal.app or the menu bar app), not to the helper binary itself.

Grant them in **System Settings > Privacy & Security**. If Screen & System Audio Recording is denied the helper exits with code 2 and the service will show a warning.

## Setup

### 1. Install system dependencies

```bash
xcode-select --install   # Xcode Command Line Tools (needed for Swift build)
brew install ffmpeg
```

### 2. Create conda environment

```bash
conda create -n transcribe python=3.11 -y
conda activate transcribe
```

> **Important:** Never install packages on the host machine. Always use the conda env.

### 3. Install Python packages

For the menu bar service and CLI tools:

```bash
pip install -r requirements-service.txt -r requirements-transcribe.txt
```

For CLI tools only (no menu bar service):

```bash
pip install -r requirements-transcribe.txt
```

### 4. Build the Swift audio capture helper

The Swift helper captures both microphone and system audio via ScreenCaptureKit.

```bash
cd audio_capture_helper
bash build.sh
cd ..
```

This produces `bin/audio-capture-helper` (ad-hoc signed with the screen-capture entitlement).

### 5. HuggingFace setup (required for speaker diarization)

Speaker diarization uses pyannote models which are free but require accepting their terms:

1. Create a free account at [huggingface.co](https://huggingface.co/join)
2. Accept the terms for:
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

For the **menu bar service**: enter your token in **Settings → HuggingFace Token**. It is saved to `~/.audio-transcribe/config.json`.

For **CLI usage**: pass via env var or flag:

```bash
export HF_TOKEN=your_token_here   # or pass --hf-token flag
```

After first run, models are cached locally and work fully offline.

---

## CLI Usage

### Basic transcription

```bash
python transcribe.py -i meeting.mp3
```

### Dual-stream transcription (meeting with separate system/mic audio)

```bash
python transcribe.py -i meeting.wav -i meeting_mic.wav
```

This transcribes each stream independently, tags segments as `Local Speaker X` (from mic) and `Remote Speaker X` (from system audio), and merges them chronologically.

### Specify speakers and language

```bash
python transcribe.py -i interview.m4a -s 2 -l en
```

### Output formats

```bash
python transcribe.py -i call.wav -f srt
python transcribe.py -i call.wav -f json
```

### Skip speaker detection (faster)

```bash
python transcribe.py -i audio.mp3 --no-diarize
```

### CLI Reference -- transcribe.py

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | Path to audio file (pass twice for dual-stream) |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | `txt` | Output format: `txt`, `srt`, `json` |
| `--speakers` | `-s` | auto | Number of speakers (omit to auto-detect) |
| `--language` | `-l` | auto | Language code (e.g. `en`, `it`, `es`) |
| `--no-diarize` | | off | Skip speaker detection |
| `--hf-token` | | `$HF_TOKEN` | HuggingFace token |

---

## Speaker Renaming

After transcription, replace generic labels (SPEAKER_00, SPEAKER_01) with real names.

```bash
# Rename interactively — reads audio path from JSON metadata automatically
python rename_speakers.py -i meeting.json

# Or specify audio explicitly
python rename_speakers.py -i meeting.json -a meeting.mp3
```

The tool plays a ~10s audio sample per speaker, shows what they said, and asks for their name.
Press Enter to keep the generic label, `r` to replay the clip.

### CLI Reference -- rename_speakers.py

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | JSON transcript file |
| `--audio` | `-a` | from JSON | Original audio file |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | from JSON | Output format: `txt`, `srt`, `json` |

---

## Menu Bar Service

The service runs persistently in the background as a macOS menu bar agent. It records audio on demand, auto-transcribes when you stop, and prompts for speaker names via native dialogs.

### Service Setup

**Option A: Build the .app bundle (recommended)**

The app runs as a proper macOS `.app` so Screen Recording permission persists across reboots. The build embeds a standalone Python 3.11 — no conda required at runtime.

**Prerequisites (one-time):**

1. Install **python.org Python 3.11** — download the `.pkg` from [python.org/downloads](https://www.python.org/downloads/) and run the installer. This installs to `/Library/Frameworks/Python.framework/Versions/3.11/`. Conda and Homebrew Python will not work here.

   Verify:
   ```bash
   /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 --version
   # Python 3.11.x
   ```

2. Ensure the Swift binary is built (Step 4 above).

**Build:**

```bash
bash packaging/build_app.sh
```

This will:
- Clone `gregneagle/relocatable-python` automatically (no manual install needed)
- Download and embed a standalone Python 3.11 with all dependencies
- Ad-hoc codesign the bundle
- Produce `dist/AudioTranscribe.app` and `dist/AudioTranscribe.dmg`

Takes 5–15 minutes on first run (downloads ~45 MB Python framework + installs ML packages).

**Launch:**

```bash
open dist/AudioTranscribe.app
# or move to /Applications first: cp -r dist/AudioTranscribe.app /Applications/
```

macOS will prompt for *Screen & System Audio Recording* — grant it in **System Settings → Privacy & Security**. The permission is tied to the bundle ID and persists permanently.

> **Menu bar icon not visible?** On MacBooks with a notch, icons can be pushed off-screen. Hold `Cmd` and drag other icons to make space, or use [Ice](https://github.com/jordanbaird/Ice) (free) to manage menu bar overflow.

Enter your HuggingFace token in **Settings → HuggingFace Token**. Optionally enable **Launch at Login** in Settings.

**Option B: Run from source (development)**

```bash
conda activate transcribe
python service/main.py
```

The menu bar icon appears. Note: when running from Terminal, Screen Recording permission is granted to Terminal.app, not to the Python process directly — this works for development but will fail if launched as a background service.

### Service Usage

Click the menu bar icon to access:

- **Start Recording** — prompts for a name (pre-filled from current calendar event if available), then starts dual-stream recording (system audio + mic)
- **Stop Recording** — stops recording and queues transcription automatically
- **Settings** — change recordings directory, output format, silence detection, HuggingFace token, Launch at Login
- **View Logs** — opens the log file
- **Quit** — stops the service

When transcription completes, a native dialog prompts you to name each speaker.

### Service Management

When running as a `.app` bundle, use the **Quit** menu item to stop. Launch at Login is managed from **Settings → Launch at Login**.

### Watch live logs

```bash
tail -f ~/.audio-transcribe/logs/transcribe-service.log
```

### Service configuration

Config is stored at `~/.audio-transcribe/config.json`. Defaults:

```json
{
  "recording_directory": "~/Documents/Recordings",
  "silence_timeout_minutes": 5,
  "silence_detection_enabled": true,
  "output_format": "txt",
  "launch_on_startup": true,
  "log_level": "info",
  "hf_token": ""
}
```

### Menu bar state machine

```
IDLE --[Start Recording]--> PROMPTING --[name entered]--> RECORDING
                                                               |
                              IDLE <--[error]                  | Stop / silence timeout
                                |                              v
                                +------------------------ TRANSCRIBING
                                                               |
                                                 [JSON ready]  |
                                                               v
                                                         Rename dialog --> IDLE
```

### Performance expectations

On Apple Silicon (M2 Pro), transcription runs at roughly real-time speed — a 30-minute recording takes ~30 minutes to transcribe. Speaker diarization adds a further ~30% overhead. Short recordings (< 5 min) complete in under a minute.

---

## Output Examples

### Plain text (default)

```
[00:00:02] Remote Speaker 1: Good morning, thanks for joining.
[00:00:05] Local Speaker 1: Thanks for having me.
```

### SRT

```
1
00:00:02,000 --> 00:00:04,500
Remote Speaker 1: Good morning, thanks for joining.

2
00:00:05,100 --> 00:00:06,800
Local Speaker 1: Thanks for having me.
```

### JSON

```json
{
  "metadata": {
    "audio_file": "meeting.wav",
    "audio_path": "/full/path/to/meeting.wav",
    "mic_file": "meeting_mic.wav",
    "language": "en",
    "num_speakers": 2,
    "diarization": true,
    "output_format": "txt"
  },
  "segments": [
    {
      "start": 2.0,
      "end": 4.5,
      "speaker": "Remote Speaker 1",
      "text": "Good morning, thanks for joining."
    }
  ]
}
```

---

## Diagnosing audio capture issues

If the service records silence or you suspect audio device problems, run the built-in diagnostic:

```bash
conda activate transcribe
python diagnose_audio.py
```

This lists available input devices, records 3 seconds of audio, and reports whether it captured any signal. Useful for confirming that launchd (which runs in a different session) can access the microphone.

---

## Clean Rebuild

Use this when code changes aren't reflected in the running app, or when the build is in a broken state.

### After Python source changes only (no dep changes)

```bash
# Quit the running app first (menu bar → Quit), then:
bash packaging/build_app.sh
open dist/AudioTranscribe.app
```

The build script wipes and recreates `dist/AudioTranscribe.app` on every run.

### After Swift changes

```bash
cd audio_capture_helper && bash build.sh && cd ..
bash packaging/build_app.sh
open dist/AudioTranscribe.app
```

### After requirements*.txt changes

Same as above — the build script recreates the embedded Python env from scratch each run.

### Full clean (something is broken, start fresh)

```bash
# 1. Quit the running app (menu bar → Quit)

# 2. Remove the app and DMG output
rm -rf dist/

# 3. Remove the cached relocatable-python clone (forces re-download)
rm -rf /tmp/relocatable-python

# 4. Rebuild
bash packaging/build_app.sh
open dist/AudioTranscribe.app
```

### Reset the conda dev environment

Only needed if the dev environment is broken (for CLI / `python service/main.py` usage):

```bash
conda deactivate
conda env remove -n transcribe -y
conda create -n transcribe python=3.11 -y
conda activate transcribe
pip install -r requirements-service.txt -r requirements-transcribe.txt
```

### Reset macOS permissions (TCC)

If you change `CFBundleIdentifier` in `packaging/Info.plist`, macOS treats it as a new app and you must re-grant permissions:

1. Go to **System Settings → Privacy & Security → Screen & System Audio Recording**
2. Remove the old entry for AudioTranscribe
3. Launch the new build — macOS will prompt again

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for a full log of issues encountered during development and their solutions.

**Quick reference:**

| Symptom | Fix |
|---|---|
| `No module named mlx_whisper` | `conda activate transcribe` |
| `ffmpeg not found` | `brew install ffmpeg` |
| Diarization token error | Set HuggingFace token in Settings (or `HF_TOKEN` env var for CLI); accept both model terms on HuggingFace |
| No speakers detected | Set HuggingFace token in Settings — diarization requires it |
| Slow first run | Whisper model (~1.6GB) downloads once then is cached |
| Service not starting | Check `~/.audio-transcribe/logs/transcribe-service.log` |
| Dialog doesn't appear | Look behind other windows; it may be hidden |
| Helper exits with code 2 | Grant "Screen & System Audio Recording" in System Settings → Privacy & Security — must be granted to `AudioTranscribe.app`, not Terminal |
| TCC permission not persisting | Run as `.app` bundle (not from Terminal) so macOS ties the grant to the bundle ID |
| 0-byte WAV files | Rebuild helper (`cd audio_capture_helper && bash build.sh`) — likely a stale binary |
| `build_app.sh` fails with 404 downloading Python | Fixed — `--os-version 11` is now set in the script |
| Menu bar icon not visible after launch | App is running but icon is hidden by notch overflow — hold Cmd and drag other icons to make space, or use [Ice](https://github.com/jordanbaird/Ice) |
