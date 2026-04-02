# ASR Engine Benchmark Tool

Compares transcription speed and accuracy across all ASR engines used by the Transcriber app, plus legacy baselines.

## Results (2026-04-02, Apple M5 Pro)

### Average WER by Language

| Language | FluidAudio | SpeechAnalyzer | WhisperCppKit |
|----------|:-:|:-:|:-:|
| **English** | **0.5%** | 0.6%* | 24.3% |
| **Spanish** | 4.5% | **2.5%** | 23.8% |
| **French** | 5.2% | **5.1%** | 27.1% |
| **Portuguese** | **4.8%** | 6.5% | 22.6% |
| **Japanese** | - | **8.2%** | 142.0% |
| **Korean** | - | **17.0%** | 146.2% |
| **Turkish** | - | - | 89.3% |

*SpeechAnalyzer EN average includes short AMI meeting clips which inflate WER. On LibriSpeech clean speech, SpeechAnalyzer EN = 0.6%.

### Speed (Real-Time Factor, higher = faster)

| Engine | Range | Notes |
|--------|-------|-------|
| **FluidAudio** | 17-145x | Fastest, most consistent |
| **SpeechAnalyzer** | 3-98x | Fast on longer clips |
| **WhisperCppKit** | 1-44x | Slowest |

### Verdict

- **FluidAudio**: Best default for European languages (EN/FR/PT/ES) — lowest WER, fastest
- **SpeechAnalyzer**: Matches FluidAudio on English, best on Spanish, only viable engine for Japanese and Korean
- **WhisperCppKit**: Unreliable — hallucinates on some EU files (97-110% WER), garbage on CJK (142-146%), crashes on Korean. Uses large-v3-turbo GGML via poorly maintained wrapper
- **FluidAudio + SpeechAnalyzer covers all languages** except Turkish

### Language Support

| Language | FluidAudio | SpeechAnalyzer | WhisperCppKit |
|----------|:-:|:-:|:-:|
| EN/ES/FR/PT | Y | Y | Y (unreliable) |
| Japanese | - | Y | garbage |
| Korean | - | Y | garbage (crashes) |
| Turkish | - | no model | garbage |

## Engines

| Engine | Type | Inference | Languages |
|--------|------|-----------|-----------|
| **FluidAudio** (Parakeet v3) | Current default | CoreML/ANE | 25 European |
| **WhisperCppKit** (whisper.cpp) | Current option | Metal GPU | 99 (Whisper large-v3-turbo) |
| **SpeechAnalyzer** (macOS 26) | Current option | Apple on-device | EN, ES, FR, PT, JA, KO + more |
| **WhisperKit** (CoreML) | Legacy | CoreML/ANE | 99 (Whisper) |
| **mlx-whisper** (Python) | Legacy baseline | MLX GPU | 99 (Whisper) |

## Quick Start

```bash
# 1. Download test audio (EN, FR, PT, ES, TR, KO, JA + AMI meeting)
python3 tools/engine-benchmark/download-test-audio.py

# 2. Run full benchmark matrix (all files x compatible engines)
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
| **WER** | Word Error Rate — Levenshtein edit distance at word level vs ground truth |
| **CER** | Character Error Rate — used for CJK languages (Korean, Japanese) |
| **RTF** | Real-time factor — audio duration / processing time (higher = faster) |

WER normalization: lowercase, strip punctuation (keep apostrophes), collapse whitespace.

## Test Audio

The downloader (`download-test-audio.py`) fetches:

| Language | Source | Samples |
|----------|--------|---------|
| English | LibriSpeech (openslr) | 5 + 1 long-form |
| French | MLS (Facebook) | 5 |
| Portuguese | MLS (Facebook) | 5 |
| Spanish | MLS (Facebook) | 5 |
| Korean | Zeroth Korean | 5 |
| Turkish | FLEURS (Google, requires HF_TOKEN) | 5 |
| Japanese | FLEURS (Google, requires HF_TOKEN) | 5 |
| Multi-speaker | AMI Meeting Corpus | 5 |

All audio includes ground-truth transcripts saved to `ground-truth.json`.

For the full dataset reference (LibriSpeech, TED-LIUM, Earnings21, mTEDx, VoxConverse, etc.), see [test-audio-datasets.md](test-audio-datasets.md).

## Architecture Notes

- **SpeechAnalyzer** runs in a subprocess (`SpeechTest`) per file to avoid Apple's 5-concurrent-locale limit on `SpeechTranscriber`
- **WhisperCppKit** skips Korean due to upstream crash (fatal Range error in Swift interface)
- **FluidAudio** skips Turkish (not in Parakeet v3's 25 EU languages, confirmed 100% WER)

## Building

```bash
swift build --package-path tools/engine-benchmark
```

Requires macOS 26.0+ (for SpeechAnalyzer), Swift 6.2+. SPM dependencies: WhisperKit, FluidAudio, WhisperCppKit.
