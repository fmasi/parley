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
- Python 3.10+ in a conda environment
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
brew install ffmpeg
```

### 2. Create conda environment

```bash
conda create -n transcribe python=3.11 -y
conda activate transcribe
```

> **Important:** Never install packages on the host machine. Always use the conda env.

### 3. Build the audio capture helper

The Swift helper captures both microphone and system audio via ScreenCaptureKit. Requires Xcode Command Line Tools.

```bash
cd audio_capture_helper
bash build.sh
```

This produces `bin/audio-capture-helper` (ad-hoc signed with the screen-capture entitlement).

On first recording macOS will prompt for *"Screen & System Audio Recording"* permission — grant it in System Settings > Privacy & Security.

> **Requires Xcode command-line tools:** `xcode-select --install`

### 4. Install Python packages

For the CLI tools only:

```bash
pip install mlx-whisper "pyannote.audio>=3.1" torch torchaudio soundfile
```

For the menu bar service (includes all CLI dependencies):

```bash
pip install -r requirements-service.txt
```

### 5. HuggingFace setup (required for speaker diarization)

> **Note:** `HF_TOKEN` must be set before running `transcribe.py` or starting the service. Without it, speaker diarization will fail. Pass it via the env var (recommended) or the `--hf-token` flag.

Speaker diarization uses pyannote models which are free but require accepting their terms:

1. Create a free account at [huggingface.co](https://huggingface.co/join)
2. Accept the terms for:
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
4. Add to your shell profile:

```bash
echo 'export HF_TOKEN=your_token_here' >> ~/.zshrc
source ~/.zshrc
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

**1. Build the audio capture helper** (if not done in setup step 3 above):

```bash
cd audio_capture_helper
bash build.sh
```

**2. Create the plist from the template:**

```bash
cp com.audio-transcribe.plist.template com.audio-transcribe.plist
```

**3. Edit `com.audio-transcribe.plist` and replace the three placeholders:**

| Placeholder | Replace with |
|---|---|
| `REPLACE_WITH_REPO_PATH` | Full path to this repo, e.g. `/Users/you/Git/Transcriber` |
| `REPLACE_WITH_USERNAME` | Your macOS username |
| `REPLACE_WITH_HF_TOKEN` | Your HuggingFace token |

**4. Create logs directory:**

```bash
mkdir -p ~/.audio-transcribe/logs
```

**5. Fix rumps notification center (one-time):**

```bash
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "rumps"' \
  /opt/miniconda3/envs/transcribe/bin/Info.plist
```

**6. Install and start:**

```bash
cp com.audio-transcribe.plist ~/Library/LaunchAgents/com.audio-transcribe.plist
launchctl load ~/Library/LaunchAgents/com.audio-transcribe.plist
```

The menu bar icon appears within a few seconds.

### Service Usage

Click the menu bar icon to access:

- **Start Recording** — prompts for a name (pre-filled from current calendar event if available), then starts dual-stream recording (system audio + mic)
- **Stop Recording** — stops recording and queues transcription automatically
- **Settings** — change recordings directory, output format, silence detection
- **View Logs** — opens the log file
- **Quit** — stops the service (launchd restarts it on next login)

When transcription completes, a native dialog prompts you to name each speaker.

### Service Management

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.audio-transcribe.plist

# Start
launchctl load ~/Library/LaunchAgents/com.audio-transcribe.plist

# Uninstall completely
launchctl unload ~/Library/LaunchAgents/com.audio-transcribe.plist
rm ~/Library/LaunchAgents/com.audio-transcribe.plist
```

### Watch live logs

```bash
tail -f ~/.audio-transcribe/logs/stderr.log
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
  "log_level": "info"
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

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for a full log of issues encountered during development and their solutions.

**Quick reference:**

| Symptom | Fix |
|---|---|
| `No module named mlx_whisper` | `conda activate transcribe` |
| `ffmpeg not found` | `brew install ffmpeg` |
| Diarization token error | Set `HF_TOKEN` and accept both model terms on HuggingFace |
| Slow first run | Whisper model (~1.6GB) downloads once then is cached |
| Service not starting | Check `~/.audio-transcribe/logs/stderr.log` |
| Dialog doesn't appear | Look behind other windows; it may be hidden |
| `Failed to setup notification center` | Run the PlistBuddy command in step 5 of service setup |
| Helper exits with code 2 | Grant "Screen & System Audio Recording" in System Settings > Privacy & Security |
| 0-byte WAV files | Rebuild helper (`cd audio_capture_helper && bash build.sh`) — likely a stale binary |
