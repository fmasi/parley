# Audio Transcription Tool

On-device audio transcription with speaker diarization for Apple Silicon Macs.
Uses MLX-optimized Whisper (large-v3) and pyannote.audio for speaker detection.
Includes a persistent macOS menu bar service for automatic recording and transcription.

## Features

- Transcribes audio files via CLI (`transcribe.py`)
- Speaker diarization — labels who said what
- Interactive speaker renaming with audio playback (`rename_speakers.py`)
- macOS menu bar service — records, transcribes, and prompts for speaker names automatically
- Silence detection via Silero VAD — stops recording when no one is speaking
- Apple Calendar integration — pre-populates recording names from current meeting
- Outputs: plain text, SRT subtitles, JSON (always saved as master copy)
- Fully on-device, free after model download

## Requirements

- macOS 12.0+ with Apple Silicon (M1/M2/M3/M4/M5)
- Python 3.10+ in a conda environment
- ffmpeg (Homebrew)
- HuggingFace account (free, for pyannote models)

## Audio capture scope

The service records from your **microphone only**. System audio (e.g., the remote side of a Zoom call via speakers) is not captured — macOS has no Python-accessible API for per-app audio capture without a virtual audio device such as BlackHole. If you use speakers rather than headphones, remote participants' voices will be picked up by the mic naturally.

## macOS permissions

The first time you run the service macOS will prompt for these permissions:

| Permission | Required for |
|---|---|
| **Microphone** | Recording audio |
| **Calendars** | Pre-populating recording names from the current meeting (optional) |
| **Accessibility / Automation** | AppKit dialogs appearing in front of other windows |

Grant them in **System Settings → Privacy & Security**. If you deny Microphone access, recording will silently produce an empty file.

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

### 3. Install Python packages

For the CLI tools only:

```bash
pip install mlx-whisper "pyannote.audio>=3.1" torch torchaudio soundfile
```

For the menu bar service (includes all CLI dependencies):

```bash
pip install -r requirements-service.txt
```

### 4. HuggingFace setup (required for speaker diarization)

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

### CLI Reference — transcribe.py

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | Path to audio file |
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

### CLI Reference — rename_speakers.py

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

**1. Create the plist from the template:**

```bash
cp com.audio-transcribe.plist.template com.audio-transcribe.plist
```

**2. Edit `com.audio-transcribe.plist` and replace the three placeholders:**

| Placeholder | Replace with |
|---|---|
| `REPLACE_WITH_REPO_PATH` | Full path to this repo, e.g. `/Users/you/Git/Transcriber` |
| `REPLACE_WITH_USERNAME` | Your macOS username |
| `REPLACE_WITH_HF_TOKEN` | Your HuggingFace token |

**3. Create logs directory:**

```bash
mkdir -p ~/.audio-transcribe/logs
```

**4. Fix rumps notification center (one-time):**

```bash
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "rumps"' \
  /opt/miniconda3/envs/transcribe/bin/Info.plist
```

**5. Install and start:**

```bash
cp com.audio-transcribe.plist ~/Library/LaunchAgents/com.audio-transcribe.plist
launchctl load ~/Library/LaunchAgents/com.audio-transcribe.plist
```

The menu bar icon appears within a few seconds.

### Service Usage

Click the menu bar icon to access:

- **Start Recording** — prompts for a name (pre-filled from current calendar event if available), then starts mic recording
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
IDLE ──[Start Recording]──► PROMPTING ──[name entered]──► RECORDING
                                                               │
                              IDLE ◄──[error]                  │ Stop / silence timeout
                                │                              ▼
                                └──────────────────────── TRANSCRIBING
                                                               │
                                                 [JSON ready] │
                                                               ▼
                                                         Rename dialog → IDLE
```

### Performance expectations

On Apple Silicon (M2 Pro), transcription runs at roughly real-time speed — a 30-minute recording takes ~30 minutes to transcribe. Speaker diarization adds a further ~30 % overhead. Short recordings (< 5 min) complete in under a minute.

---

## Output Examples

### Plain text (default)

```
[00:00:02] Speaker 1: Good morning, thanks for joining.
[00:00:05] Speaker 2: Thanks for having me.
```

### SRT

```
1
00:00:02,000 --> 00:00:04,500
Speaker 1: Good morning, thanks for joining.

2
00:00:05,100 --> 00:00:06,800
Speaker 2: Thanks for having me.
```

### JSON

```json
{
  "metadata": {
    "audio_file": "meeting.mp3",
    "audio_path": "/full/path/to/meeting.mp3",
    "language": "en",
    "num_speakers": 2,
    "diarization": true,
    "output_format": "txt"
  },
  "segments": [
    {
      "start": 2.0,
      "end": 4.5,
      "speaker": "Speaker 1",
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
| `Failed to setup notification center` | Run the PlistBuddy command in step 4 of service setup |
