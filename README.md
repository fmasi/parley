# Audio Transcription Tool

On-device audio transcription with speaker diarization for Apple Silicon Macs.
Uses MLX-optimized Whisper (large-v3) and pyannote.audio for speaker detection.

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4/M5)
- Python 3.10+
- ffmpeg (for speaker renaming tool)

## Setup

### 1. Install system dependencies

```bash
brew install ffmpeg
```

### 2. Create a virtual environment (recommended)

```bash
python3 -m venv venv
source venv/bin/activate
```

### 3. Install Python packages

```bash
pip install mlx-whisper "pyannote.audio>=3.1" torch torchaudio
```

### 4. HuggingFace setup (one-time, required for speaker diarization)

Speaker diarization uses pyannote models which are free but require accepting their terms:

1. Create a free account at [huggingface.co](https://huggingface.co/join)
2. Accept the terms for these two models:
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
4. Set the token in your shell profile:

```bash
echo 'export HF_TOKEN=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' >> ~/.zshrc
source ~/.zshrc
```

After the first run, models are cached locally and work fully offline.

## Usage

### Basic transcription (plain text with timestamps + speakers)

```bash
python transcribe.py -i meeting.mp3
```

### Specify number of speakers and language

```bash
python transcribe.py -i interview.m4a -s 2 -l en
```

### Output as SRT subtitles

```bash
python transcribe.py -i call.wav -f srt
```

### Output as JSON (for LLM processing)

```bash
python transcribe.py -i recording.mp3 -f json -o transcript.json
```

### Fast mode (no speaker detection)

```bash
python transcribe.py -i audio.mp3 --no-diarize
```

### Custom output path

```bash
python transcribe.py -i meeting.mp3 -o /path/to/output.txt
```

## Speaker Renaming

After transcription, you can replace generic labels (Speaker 1, Speaker 2) with real names. This requires a JSON transcript as input.

### Step 1: Transcribe to JSON

```bash
python transcribe.py -i meeting.mp3 -f json
```

### Step 2: Rename speakers interactively

```bash
python rename_speakers.py -i meeting.json -a meeting.mp3
```

The tool will:
1. Play a ~10 second audio sample of each speaker
2. Show you a snippet of what they said
3. Ask you to type their name (or press Enter to keep the generic label, or 'r' to replay)

### Output renamed transcript in different formats

```bash
python rename_speakers.py -i meeting.json -a meeting.mp3 -f srt
python rename_speakers.py -i meeting.json -a meeting.mp3 -f json
```

## CLI Reference

### transcribe.py

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | Path to audio file |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | `txt` | Output format: `txt`, `srt`, `json` |
| `--speakers` | `-s` | auto | Number of speakers |
| `--language` | `-l` | auto | Language code (e.g. `en`, `it`, `es`) |
| `--no-diarize` | | off | Skip speaker detection |
| `--hf-token` | | `$HF_TOKEN` | HuggingFace token |

### rename_speakers.py

| Flag | Short | Default | Description |
|---|---|---|---|
| `--input` | `-i` | required | JSON transcript file |
| `--audio` | `-a` | required | Original audio file |
| `--output` | `-o` | auto | Output file path |
| `--format` | `-f` | `txt` | Output format: `txt`, `srt`, `json` |

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
    "language": "en",
    "num_speakers": 2,
    "diarization": true
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

## Troubleshooting

- **"No module named mlx_whisper"** — activate your venv: `source venv/bin/activate`
- **Diarization token error** — make sure `HF_TOKEN` is set and you accepted both model terms
- **ffmpeg not found** — install with `brew install ffmpeg`
- **Slow first run** — the Whisper model (~1.6GB) downloads on first use, then is cached
