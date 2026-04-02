# Audio Transcription Tool

On-device meeting transcription for Apple Silicon Macs. Records system audio and microphone simultaneously, transcribes with speaker identification, and outputs clean transcripts -- all running locally on your Mac.

## What's new in v0.4.0

- **Swappable transcription engines** -- choose between FluidAudio (fastest), whisper.cpp, or Apple SpeechAnalyzer in Settings
- **Speaker diarization** -- automatic speaker identification powered by FluidAudio (pyannote + WeSpeaker + VBx clustering)
- **Multilingual transcription** -- handles English, Portuguese, French, and 22 other European languages in a single recording
- **Text normalization (ITN)** -- spoken numbers become written form ("three hundred forty-two" becomes "342")
- **Confidence scores** -- each segment includes engine confidence in the JSON output
- **Smart audio source handling** -- mic and system audio are preprocessed differently for better accuracy
- **Dual-stream speaker labeling** -- Local/Remote speaker tags in dual-stream recordings
- **CLI tools** -- transcribe, rename speakers, and benchmark from the command line
- **184 unit tests** across 16 test suites
- **Fully Swift-native** -- no Python runtime, no virtual audio devices, no cloud APIs

---

## Quick Start

> **Pre-built app coming soon.** For now, follow the [Build & Install](#build--install) steps below.

---

## Requirements

- macOS 15.0+ (Sequoia) with Apple Silicon (M1/M2/M3/M4/M5)
- Swift 5.9+ (Xcode Command Line Tools)

FluidAudio (default engine) downloads its model on first use (~500MB). Apple SpeechAnalyzer requires macOS 26+ but needs no download.

---

## Build & Install

```bash
bash package_app.sh --install
```

This builds the Swift targets, assembles the `.app` bundle with the XPC audio capture service, ad-hoc signs everything, and copies to `/Applications`.

```bash
open /Applications/AudioTranscribe.app
```

macOS will prompt for **Screen & System Audio Recording** permission on first launch.

| Flag | Description |
|---|---|
| `--release` | Build in release mode (default: debug) |
| `--install` | Copy finished app to `/Applications` |

### Uninstalling

```bash
rm -rf /Applications/AudioTranscribe.app
rm -rf ~/.audio-transcribe   # optional -- removes config, models, and recordings
```

---

## Transcription Engines

Three engines, selectable in **Settings > Transcription Engine** or via `config.json`:

| Engine | Speed (17min audio) | Download | Languages | macOS |
|---|---|---|---|---|
| **FluidAudio** (Parakeet) | ~7s (146x real-time) | ~500MB | 25 EU languages | 15.0+ |
| **Apple SpeechAnalyzer** | ~10s (102x real-time) | None | System languages | 26.0+ |
| **whisper.cpp** (large-v3-turbo) | ~41s (25x real-time) | ~1.6GB | 99 languages | 15.0+ |

FluidAudio includes:
- **Inverse Text Normalization** -- "two hundred" becomes "200", dates and numbers formatted correctly
- **Speaker diarization** -- automatic "who said what" with quality scores per segment
- **Confidence scores** -- per-transcription confidence from the ASR model

---

## Menu Bar App

Click the menu bar icon to access:

| Action | Description |
|---|---|
| **Start Recording** | Prompts for session name and mic input, then starts dual-stream capture |
| **Stop Recording** | Stops recording and transcribes automatically |
| **Change Microphone** | Switch mic mid-recording without stopping |
| **Open Recordings Folder** | Opens the recordings directory in Finder |
| **Rename Speakers** | Rename detected speakers in the latest transcript |
| **Settings** | Configure engine, recordings directory, output format, permissions |
| **Quit** | Stops the app |

### Microphone selection

Before recording starts, a dialog lets you pick which microphone to use with a live level meter. Your last-used device is pre-selected. Works with USB webcam mics, external audio interfaces, iPhone Continuity mic, and more.

### Audio capture

Records **both your microphone and system audio** simultaneously:

- **With headphones**: mic captures your voice; system audio captures the remote side
- **With speakers**: both sides are captured by the mic, plus system audio captures remote
- Works with any app (Zoom, Teams, Meet, Slack, FaceTime, Discord)
- No virtual audio devices or kernel extensions needed

### State machine

```
IDLE --> [Start Recording] --> RECORDING --> [Stop Recording] --> TRANSCRIBING --> IDLE
```

---

## Output

Recordings are saved to `~/Documents/Recordings/YYYY-MM-DD/` with system audio, mic audio, JSON transcript, and a formatted output file (SRT or TXT).

### JSON output

```json
{
  "metadata": {
    "audio_files": ["140703.wav", "140703_mic.wav"],
    "language": "multilingual",
    "diarization": true,
    "dual_stream": true
  },
  "segments": [
    {
      "start": 1.6,
      "end": 8.72,
      "speaker": "Speaker 1",
      "text": "On March 15, 2026, we held a meeting with 342 participants.",
      "source": "local",
      "confidence": 0.963
    },
    {
      "start": 49.2,
      "end": 56.08,
      "speaker": "Speaker 2",
      "text": "Le 14 juillet 2026, nous avons organise une conference avec 97 participants.",
      "source": "remote",
      "confidence": 0.941
    }
  ]
}
```

### SRT output

```
1
00:00:01,600 --> 00:00:08,720
Speaker 1: On March 15, 2026, we held a meeting with 342 participants.

2
00:00:49,200 --> 00:00:56,080
Speaker 2: Le 14 juillet 2026, nous avons organise une conference avec 97 participants.
```

### Plain text output

```
[00:00:01] Speaker 1: On March 15, 2026, we held a meeting with 342 participants.
[00:00:49] Speaker 2: Le 14 juillet 2026, nous avons organise une conference avec 97 participants.
```

---

## Configuration

Config is stored at `~/.audio-transcribe/config.json`:

```json
{
  "recording_directory": "~/Documents/Recordings",
  "silence_timeout_minutes": 5,
  "silence_detection_enabled": true,
  "output_format": "srt",
  "engine": "fluid_audio",
  "launch_on_startup": true
}
```

Power users can override the whisper.cpp model path:
```json
{
  "engine": "whisper_cpp",
  "whisper_cpp_model_path": "~/.audio-transcribe/models/ggml-large-v3.bin"
}
```

---

## CLI Usage

```bash
# Transcribe audio files
.build/debug/AudioTranscribe transcribe -i system.wav [-i mic.wav] [-f srt] [--engine fluid_audio] [--no-diarize]

# Rename speakers interactively
.build/debug/AudioTranscribe rename -i transcript.json

# Run benchmark
.build/debug/AudioTranscribe benchmark
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "damaged or incomplete" on launch | Rebuild: `bash package_app.sh` |
| Slow first transcription | FluidAudio/whisper.cpp download models on first use -- cached after that |
| XPC connection failed | Run as `.app` bundle -- XPC services don't work with bare binaries |
| Exit code 2 from capture service | Grant "Screen & System Audio Recording" in System Settings |
| TCC permission not persisting | Run as `.app` bundle so macOS ties the grant to the bundle ID |
| 0-byte WAV files | Rebuild with `bash package_app.sh` |
| Menu bar icon not visible | Hold Cmd and drag other menu bar icons to make space |

---

## Development

### Developer iteration tool

```bash
python scripts/dev.py                    # full cycle: kill, build, install, launch
python scripts/dev.py --debug            # full cycle + tail unified log
python scripts/dev.py --reset-tcc        # reset TCC permissions only
python scripts/dev.py --build --install  # build + install only
```

### Running tests

```bash
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

For architecture details, XPC design, and ScreenCaptureKit constraints, see [ARCHITECTURE.md](ARCHITECTURE.md).
