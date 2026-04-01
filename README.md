# Audio Transcription Tool

On-device meeting transcription with speaker diarization for Apple Silicon Macs. Records both system audio and microphone simultaneously — no virtual audio devices required. Transcribes using WhisperKit (Core ML) and labels who said what with SpeakerKit.

Comes as a native macOS menu bar app. Fully Swift-native — no Python runtime required.

---

## Quick Start

> **Pre-built app coming soon.** Download `AudioTranscribe.app`, drag to `/Applications`, launch, and grant Screen & System Audio Recording permission when prompted.
>
> For now, follow the [Build & Install](#build--install) steps below.

---

## Requirements

- macOS 15.0+ (Sequoia) with Apple Silicon (M1/M2/M3/M4/M5)
- Swift 5.9+ (Xcode Command Line Tools)

Models download automatically on first launch — no manual setup required.

---

## Build & Install

`package_app.sh` builds the Swift targets, assembles the `.app` bundle with the XPC service, and ad-hoc signs everything.

```bash
bash package_app.sh --install
```

This produces `dist/AudioTranscribe.app` and copies it to `/Applications`. Launch it:

```bash
open /Applications/AudioTranscribe.app
```

macOS will prompt for **Screen & System Audio Recording** permission on first launch. Grant it in **System Settings > Privacy & Security**.

| Flag | Description |
|---|---|
| `--release` | Build in release mode (default: debug) |
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
| **Settings** | Configure recordings directory, output format, Launch at Login, permissions |
| **Quit** | Stops the app |

When transcription completes, a notification is sent.

### State machine

```
IDLE → [Start Recording] → RECORDING → [Stop Recording] → TRANSCRIBING → IDLE
```

### Configuration

Config is stored at `~/.audio-transcribe/config.json`:

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

```bash
# Transcribe audio files
.build/debug/AudioTranscribe transcribe -i system.wav [-i mic.wav] [-f srt]

# Rename speakers interactively
.build/debug/AudioTranscribe rename -i transcript.json
```

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
| Models not downloading | Check network connection; models are fetched from Hugging Face Hub on first launch |
| Slow first run | WhisperKit model downloads once and is cached locally |
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
python scripts/dev.py                 # full cycle: kill → build → install → launch
python scripts/dev.py --reset-tcc     # just reset TCC permissions
python scripts/dev.py --kill --launch # relaunch existing install
python scripts/dev.py --build --install  # build + install only
python scripts/dev.py --debug         # build, install, launch with log stream
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
| `--debug` | modifier | Build, install, launch, and tail the unified log stream |

### Running without installing

```bash
swift build
python scripts/dev.py --debug  # build, install, launch with log stream
```

The XPC audio capture service requires a `.app` bundle — the bare binary will show the menu UI but recording will report an XPC connection error. Use `scripts/dev.py` for full end-to-end testing.

### Running tests

```bash
# Swift tests
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

For deeper technical detail — architecture decisions, XPC design, ScreenCaptureKit constraints — see [ARCHITECTURE.md](ARCHITECTURE.md).
