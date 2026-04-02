# ASR Engine Benchmark Tool

Compares transcription speed and accuracy across all ASR engines used by the Transcriber app, plus legacy baselines.

## Engines

| Engine | Type | Inference | Languages |
|--------|------|-----------|-----------|
| **FluidAudio** (Parakeet v3) | Current default | CoreML/ANE | 25 European |
| **WhisperCppKit** (whisper.cpp) | Current option | Metal GPU | 99 (Whisper) |
| **SpeechAnalyzer** (macOS 26) | Current option | Apple on-device | Broad (system locales) |
| **WhisperKit** (CoreML) | Legacy | CoreML/ANE | 99 (Whisper) |
| **mlx-whisper** (Python) | Legacy baseline | MLX GPU | 99 (Whisper) |

## Quick Start

```bash
# 1. Download test audio (EN, FR, PT, ES, TR, FI, KR, JP + AMI meeting)
python3 tools/engine-benchmark/download-test-audio.py

# 2. Run full benchmark matrix (all files × compatible engines)
bash tools/engine-benchmark/run-benchmark-matrix.sh
```

Reports are saved to `~/.audio-transcribe/benchmark/`.

## Usage

### Single file

```bash
swift run --package-path tools/engine-benchmark EngineBenchmark <audio.wav> \
  [--engines fluid,whisper-cpp,speech] \
  [--ground-truth ground-truth.json]
```

### Batch mode (recommended)

Loads each engine model once, runs all audio files, outputs a comparison matrix:

```bash
swift run --package-path tools/engine-benchmark EngineBenchmark \
  --batch ~/.audio-transcribe/benchmark/test-audio \
  --engines fluid,whisper-cpp,speech
```

Ground truth is auto-loaded from `ground-truth.json` in the batch directory.

### Diarization

Benchmarks FluidAudio's speaker diarization (pyannote + WeSpeaker + VBx):

```bash
swift run --package-path tools/engine-benchmark EngineBenchmark <meeting.wav> --diarize
```

## Metrics

| Metric | Description |
|--------|-------------|
| **Wall clock** | Total time including model load (single-file) or transcription only (batch) |
| **RTF** | Real-time factor — audio duration / processing time (higher = faster) |
| **WER** | Word Error Rate — Levenshtein edit distance at word level vs ground truth |
| **CER** | Character Error Rate — used for CJK languages (Korean, Japanese) |
| **Segments** | Number of transcript segments produced |

WER normalization: lowercase, strip punctuation (keep apostrophes), collapse whitespace.

## Test Audio

The downloader (`download-test-audio.py`) fetches:

| Language | Source | Samples |
|----------|--------|---------|
| English (clean) | LibriVox Gettysburg Address | 1 |
| English (telephony) | Harvard Sentences (8kHz) | 1 |
| French | FLEURS fr_fr | 5 |
| Portuguese | FLEURS pt_br | 5 |
| Spanish | FLEURS es_419 | 5 |
| Turkish | FLEURS tr_tr | 5 |
| Finnish | FLEURS fi_fi | 5 |
| Korean | FLEURS ko_kr | 5 |
| Japanese | FLEURS ja_jp | 5 |
| Multi-speaker | AMI Meeting Corpus | 1 |

All audio includes ground-truth transcripts saved to `ground-truth.json`.

For the full dataset reference (LibriSpeech, TED-LIUM, Earnings21, mTEDx, VoxConverse, etc.), see [test-audio-datasets.md](test-audio-datasets.md).

## Language-Engine Compatibility

FluidAudio (Parakeet v3) only supports European languages. The benchmark tool auto-skips incompatible combos in batch mode:

| Language | FluidAudio | WhisperCppKit | SpeechAnalyzer | WhisperKit | mlx-whisper |
|----------|:---:|:---:|:---:|:---:|:---:|
| EN/FR/PT/ES/TR/FI | Y | Y | Y | Y | Y |
| KR/JP/ZH | - | Y | Y | Y | Y |

## Output

- **Single-file:** Console output + `~/.audio-transcribe/benchmark/engine-benchmark-*.txt`
- **Batch matrix:** `~/.audio-transcribe/benchmark/matrix-*.md` (markdown table with per-file and per-language average WER/RTF)
- **Logs:** `~/.audio-transcribe/benchmark/engine-benchmark-*.log`

## Building

```bash
swift build --package-path tools/engine-benchmark
```

Requires macOS 26.0+ (for SpeechAnalyzer), Swift 6.2+. SPM dependencies: WhisperKit, FluidAudio, WhisperCppKit.
