# Audio Transcription Tool

On-device meeting transcription with speaker diarization for Apple Silicon Macs. Records both system audio and microphone simultaneously — no virtual audio devices required. Transcribes using MLX-optimized Whisper and labels who said what with pyannote.audio.

Comes as a native macOS menu bar app, with a Python CLI available for standalone use.

---

## Quick Start

> **Pre-built app coming soon.** Download `AudioTranscribe.app`, drag to `/Applications`, launch, and grant Screen & System Audio Recording permission when prompted.
>
> For now, follow the [Setup](#setup) and [Build & Install](#build--install) steps below.

---

## Requirements

- macOS 15.0+ (Sequoia) with Apple Silicon (M1/M2/M3/M4/M5)
- [Miniconda](https://docs.anaconda.com/miniconda/) — use Miniconda, not full Anaconda
- Xcode Command Line Tools
- ffmpeg (Homebrew)
- HuggingFace account (free, for pyannote diarization models)

---

## Setup

### 1. Install system dependencies

```bash
xcode-select --install
brew install ffmpeg
```

### 2. Create conda environments

Two environments — one for development and CLI use, one lean environment for embedding into the app bundle:

```bash
# Development (includes pytest and dev tools)
conda create -n transcribe python=3.11 -y
conda activate transcribe
pip install -r requirements-transcribe.txt

# Bundle (runtime only — keeps the embedded app small)
conda create -n transcribe-bundle python=3.11 -y
conda activate transcribe-bundle
pip install -r requirements-bundle.txt
```

> Never install packages directly on the host machine — always use a conda env.

### 3. HuggingFace setup (required for speaker diarization)

Pyannote models are free but require accepting their terms:

1. Create a free account at [huggingface.co](https://huggingface.co/join)
2. Accept terms for [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0) and [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

For the **menu bar app**: enter the token in **Settings > HuggingFace Token** — saved to `~/.audio-transcribe/config.json`.

For **CLI use**: pass via env var or flag:

```bash
export HF_TOKEN=your_token_here   # or --hf-token flag
```

After first run, models are cached locally and work fully offline.

---

## Build & Install

`package_app.sh` builds the Swift targets, assembles the `.app` bundle with the XPC service, and ad-hoc signs everything.

The full build requires the `transcribe-bundle` conda env so that Python can be embedded into the app:

```bash
conda activate transcribe-bundle
bash package_app.sh --embed-python --install
```

This produces `dist/AudioTranscribe.app`, embeds the Python runtime from the active conda env, and copies it to `/Applications`. Launch it:

```bash
open /Applications/AudioTranscribe.app
```

macOS will prompt for **Screen & System Audio Recording** permission on first launch. Grant it in **System Settings > Privacy & Security**.

> **Swift-only build (no Python embed):** If you're only working on Swift code and don't need transcription to work, you can skip the conda env entirely: `bash package_app.sh`

| Flag | Description |
|---|---|
| `--release` | Build in release mode (default: debug) |
| `--embed-python` | Embed the active conda env into the bundle |
| `--install` | Copy finished app to `/Applications` |

### Uninstalling

```bash
rm -rf /Applications/AudioTranscribe.app
rm -rf ~/.audio-transcribe   # optional — removes config and recordings
```

Also remove leftover permissions: **System Settings > Privacy & Security > Screen & System Audio Recording** → find AudioTranscribe → click minus.

---

## Menu Bar App

Click the menu bar icon to access:

| Action | Description |
|---|---|
| **Start Recording** | Prompts for session name and mic input, then starts dual-stream recording (system audio + selected mic) |
| **Stop Recording** | Stops recording and starts transcription automatically |
| **Open Recordings Folder** | Opens the recordings directory in Finder |
| **Rename Speakers…** | Rename detected speakers in the latest transcript |
| **Settings** | Configure recordings directory, output format, HuggingFace token, Launch at Login, permissions |
| **Quit** | Stops the app |

When transcription completes, a notification is sent.

### State machine

```
IDLE → [Start Recording] → RECORDING → [Stop Recording] → TRANSCRIBING → IDLE
```

### Configuration

Config is stored at `~/.audio-transcribe/config.json` and shared between the app and Python CLI:

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

### Microphone selection

Before recording starts, a dialog lets you pick which microphone to use. This is important when conferencing apps (Zoom, Teams, Meet) select a mic internally without changing the macOS system default — e.g. when your laptop lid is closed and a USB webcam mic is active in Zoom but macOS still defaults to the built-in mic.

The dialog shows all available input devices with a live level meter. Your last-used device is pre-selected on subsequent recordings.

### Audio capture

The app records **both your microphone and system audio** simultaneously — no virtual audio devices required:

- **With headphones**: mic captures your voice; system audio captures the remote side
- **With speakers**: both sides are captured by the mic, and system audio also captures the remote side — both paths work
- Works with any app (Zoom, Teams, Meet, Slack, FaceTime, Discord, …)
- Works with USB webcam mics, external audio interfaces, iPhone Continuity mic, etc.

### Performance

On Apple Silicon (M2 Pro), transcription runs at roughly real-time speed — a 30-minute recording takes ~30 minutes. Speaker diarization adds ~30% overhead. Short recordings (< 5 min) complete in under a minute.

---

## CLI Usage

### transcribe.py

```bash
conda activate transcribe

# Single file
python transcribe.py -i meeting.mp3

# Dual-stream (system audio + mic recorded separately)
python transcribe.py -i meeting.wav -i meeting_mic.wav

# Specify speakers and language
python transcribe.py -i interview.m4a -s 2 -l en

# Output as SRT or JSON
python transcribe.py -i call.wav -f srt

# Skip speaker detection (faster)
python transcribe.py -i audio.mp3 --no-diarize
```

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | Audio file path (pass twice for dual-stream) |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | `txt` | Output format: `txt`, `srt`, `json` |
| `--speakers` | `-s` | auto | Number of speakers (omit to auto-detect) |
| `--language` | `-l` | auto | Language code (`en`, `it`, `es`, …) |
| `--no-diarize` | | off | Skip speaker detection |
| `--hf-token` | | `$HF_TOKEN` | HuggingFace token |

### rename_speakers.py

Replace generic labels (SPEAKER_00, SPEAKER_01) with real names after transcription. Plays a ~10s audio sample per speaker and asks for their name. Press Enter to keep the generic label, `r` to replay.

```bash
conda activate transcribe

# Audio path is read from the JSON metadata automatically
python rename_speakers.py -i meeting.json

# Or specify audio explicitly
python rename_speakers.py -i meeting.json -a meeting.mp3
```

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | JSON transcript file |
| `--audio` | `-a` | from JSON | Original audio file |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | from JSON | Output format: `txt`, `srt`, `json` |

---

## Output Formats

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

## Troubleshooting

| Symptom | Fix |
|---|---|
| "damaged or incomplete" on launch | Bundle built with old launcher — run `bash package_app.sh` to rebuild |
| `No module named mlx_whisper` | `conda activate transcribe` |
| `ffmpeg not found` | `brew install ffmpeg` |
| Diarization token error | Set HuggingFace token in Settings (or `HF_TOKEN` env var); accept both model terms on HuggingFace |
| No speakers detected | HuggingFace token missing — diarization requires it |
| Slow first run | Whisper model (~1.6GB) downloads once and is cached |
| XPC connection failed | Run as `.app` bundle — XPC services don't work with bare binaries |
| Exit code 2 from capture service | Grant "Screen & System Audio Recording" in System Settings > Privacy & Security |
| TCC permission not persisting | Run as `.app` bundle so macOS ties the grant to the bundle ID |
| 0-byte WAV files | Rebuild (`bash package_app.sh`) — likely a stale binary |
| Menu bar icon not visible | On MacBooks with a notch, icons can be pushed off-screen. Hold Cmd and drag other icons to make space, or use [Ice](https://github.com/jordanbaird/Ice) |

---

## Development

### Developer iteration tool

`scripts/dev.py` is the primary tool for building, installing, and testing during development:

```bash
python scripts/dev.py                          # full cycle: kill → build → install → launch
python scripts/dev.py --skip-embed             # skip Python embedding (faster Swift-only rebuild)
python scripts/dev.py --reset-tcc              # just reset TCC permissions
python scripts/dev.py --kill --launch          # relaunch existing install
python scripts/dev.py --build --install        # build + install only
```

Default (no flags) runs the full cycle: kill running app → reset TCC permissions → build → install → launch. Passing any step flag (`--kill`, `--build`, `--install`, `--launch`, `--reset-tcc`) switches to explicit mode where only the specified steps run. TCC permissions are always reset when building, since ad-hoc re-signing invalidates prior grants.

A test checklist is printed on launch — update `scripts/test-checklist.md` when adding features.

| Flag | Type | Description |
|---|---|---|
| `--kill` | step | Kill running AudioTranscribe |
| `--build` | step | Build app bundle |
| `--install` | step | Install to /Applications |
| `--launch` | step | Launch via `open` |
| `--reset-tcc` | step | Reset TCC permissions (Mic, Screen Recording, Calendar) |
| `--skip-embed` | modifier | Skip Python embedding (faster rebuild) |

### Running without installing

```bash
swift build
.build/debug/AudioTranscribe
```

The XPC audio capture service requires a `.app` bundle — the bare binary will show the menu UI but recording will report an XPC connection error. Use `scripts/dev.py` for full end-to-end testing.

### Full build with Python

```bash
conda activate transcribe-bundle
python scripts/dev.py
```

### Running tests

```bash
# Swift (83 tests across 9 suites)
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/

# Python (79 tests)
conda activate transcribe
python -m pytest tests/ -q
```

For deeper technical detail — architecture decisions, XPC design, ScreenCaptureKit constraints — see [ARCHITECTURE.md](ARCHITECTURE.md).
