# Audio Transcription Tool

On-device audio transcription with speaker diarization for Apple Silicon Macs.
Uses MLX-optimized Whisper (large-v3) and pyannote.audio for speaker detection.
Includes a native macOS SwiftUI menu bar app for automatic recording and transcription.

## Features

- Transcribes audio files via CLI (`transcribe.py`)
- Dual-stream audio capture — system audio and microphone are recorded as separate files for cleaner transcription and automatic Local/Remote speaker attribution
- Speaker diarization — labels who said what
- Interactive speaker renaming with audio playback (`rename_speakers.py`)
- Native SwiftUI menu bar app — records, transcribes, and prompts for speaker names automatically
- Apple Calendar integration — pre-populates recording names from current meeting
- Outputs: plain text, SRT subtitles, JSON (always saved as master copy)
- Fully on-device, free after model download

## Requirements

- macOS 15.0+ (Sequoia) with Apple Silicon (M1/M2/M3/M4/M5)
- Python 3.11 in a conda environment (for transcription engine and CLI)
- Xcode Command Line Tools (`xcode-select --install`)
- ffmpeg (Homebrew)
- HuggingFace account (free, for pyannote models)

## Architecture

The app has three layers:

1. **SwiftUI app** (`TranscriberApp/`) — native macOS menu bar app using `MenuBarExtra`. Manages the UI, settings, and orchestrates recording and transcription.

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
│    │                 ├── SCStream (.audio)  → base.wav   │
│    │                 └── SCStream (.mic)    → base_mic…  │
│    │                                                     │
│    └── TranscriptionRunner                               │
│          └── Process: python transcribe.py               │
│                ├── Whisper (base.wav)    → Remote 1, 2…  │
│                ├── Whisper (base_mic…)   → Local 1, 2…   │
│                └── merge chronologically → transcript    │
└─────────────────────────────────────────────────────────┘
```

### Key technical decisions

1. **macOS 15.0+ minimum** — `captureMicrophone` and `SCStreamOutputType.microphone` were added in macOS 15.0 (Sequoia). The Package.swift uses `.macOS("15.0")` string syntax because the `.v15` enum requires swift-tools-version 6.0.

2. **Two separate files, no mixing** — ScreenCaptureKit delivers `.audio` (system) and `.microphone` (mic) as separate streams at different sample rates. There is no Apple API to get a pre-mixed stream (confirmed via SDK headers through macOS 26). Keeping them separate gives Whisper cleaner audio and enables automatic Local vs Remote speaker attribution.

3. **XPC service for audio capture** — Audio capture runs in a separate XPC service process. This provides process isolation and allows the TCC permission grant to be scoped to the app bundle.

4. **Native sample rates** — The mic sample rate varies by audio device (48kHz with speakers, 24kHz with some headphones). The Swift code auto-detects the rate from the first CMSampleBuffer's format description and writes it to the WAV header on finalize(). No resampling is done — Whisper handles any sample rate.

5. **No virtual audio devices needed** — Unlike BlackHole/Loopback solutions, ScreenCaptureKit captures system audio natively. Only a single macOS permission is required.

## Audio capture

The app captures **both your microphone and system audio** (Zoom, Teams, Google Meet, etc.) simultaneously using ScreenCaptureKit — no virtual audio devices required.

- With **headphones**: your mic captures your voice; system audio captures the remote side
- With **speakers**: both sides are captured by the mic naturally, and system audio also captures the remote side — both paths work
- Works with any app (Zoom, Teams, Meet, Slack, FaceTime, Discord, ...)

### Known constraints

- macOS 15.0+ (Sequoia) required — earlier versions lack `SCStreamOutputType.microphone`
- `.screen` output type must be registered even for audio-only capture (SCStream requirement)
- XPC service only works when embedded in a `.app` bundle
- Exit code 2 from the capture service = permission denied

## macOS permissions

The first time you run the app, macOS will prompt for these permissions:

| Permission | Required for |
|---|---|
| **Screen & System Audio Recording** | Recording both microphone and system audio via ScreenCaptureKit (covers both streams with a single permission) |
| **Calendars** | Pre-populating recording names from the current meeting (optional) |

Permission is granted to the **app bundle** (CFBundleIdentifier: `com.audio-transcribe.app`).

Grant them in **System Settings > Privacy & Security**. If Screen & System Audio Recording is denied the capture service will report a permission error.

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

```bash
pip install -r requirements-transcribe.txt
```

### 4. Build the SwiftUI app

```bash
swift build
```

This produces two binaries in `.build/debug/`:
- `AudioTranscribe` — the SwiftUI menu bar app
- `audio-capture-helper-xpc` — the XPC audio capture service

### 5. HuggingFace setup (required for speaker diarization)

Speaker diarization uses pyannote models which are free but require accepting their terms:

1. Create a free account at [huggingface.co](https://huggingface.co/join)
2. Accept the terms for:
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

For the **menu bar app**: enter your token in **Settings > HuggingFace Token**. It is saved to `~/.audio-transcribe/config.json`.

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

## Menu Bar App

The SwiftUI app runs as a native macOS menu bar agent. It records audio on demand, auto-transcribes when you stop, and prompts for speaker names.

### Running during development

```bash
swift build
.build/debug/AudioTranscribe
```

Note: the XPC audio capture service requires a `.app` bundle to function. Running the bare binary will show the menu bar UI but recording will report an XPC connection error. For full end-to-end testing, build the `.app` bundle.

### Building the .app bundle

```bash
swift build
conda activate transcribe
bash packaging/embed_python.sh
```

This embeds the conda Python environment and scripts into the app bundle's Resources directory.

### App Usage

Click the menu bar icon to access:

- **Start Recording** — starts dual-stream recording (system audio + mic)
- **Stop Recording** — stops recording and starts transcription automatically
- **Open Recordings Folder** — opens the recordings directory in Finder
- **Rename Speakers...** — rename detected speakers in the latest transcript
- **Settings** — change recordings directory, output format, silence detection, HuggingFace token, Launch at Login
- **Quit** — stops the app

When transcription completes, a notification is sent.

### State machine

```
IDLE --[Start Recording]--> RECORDING --[Stop Recording]--> TRANSCRIBING --> IDLE
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

This config file is shared between the SwiftUI app and the Python CLI tools — both read/write the same format with snake_case JSON keys.

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

## Clean Rebuild

### After Swift changes

```bash
swift build
```

### After Python dependency changes

```bash
conda activate transcribe
pip install -r requirements-transcribe.txt
bash packaging/embed_python.sh   # re-embed into .app bundle
```

### Full clean

```bash
swift package clean
swift build
```

### Reset macOS permissions (TCC)

If you change `CFBundleIdentifier` in `packaging/Info.plist`, macOS treats it as a new app and you must re-grant permissions:

1. Go to **System Settings > Privacy & Security > Screen & System Audio Recording**
2. Remove the old entry for AudioTranscribe
3. Launch the new build — macOS will prompt again

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No module named mlx_whisper` | `conda activate transcribe` |
| `ffmpeg not found` | `brew install ffmpeg` |
| Diarization token error | Set HuggingFace token in Settings (or `HF_TOKEN` env var for CLI); accept both model terms on HuggingFace |
| No speakers detected | Set HuggingFace token in Settings — diarization requires it |
| Slow first run | Whisper model (~1.6GB) downloads once then is cached |
| XPC connection failed | Run as `.app` bundle — XPC services don't work with bare binaries |
| Helper exits with code 2 | Grant "Screen & System Audio Recording" in System Settings > Privacy & Security |
| TCC permission not persisting | Run as `.app` bundle so macOS ties the grant to the bundle ID |
| 0-byte WAV files | Rebuild (`swift build`) — likely a stale binary |
| Menu bar icon not visible | On MacBooks with a notch, icons can be pushed off-screen. Hold Cmd and drag other icons to make space, or use [Ice](https://github.com/jordanbaird/Ice) |
