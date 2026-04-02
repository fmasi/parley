# WhisperKit Migration Design Spec

**Date:** 2026-04-01
**Branch:** `feature/whisperkit-migration` (off main)
**Goal:** Replace Python transcription engine (mlx-whisper + pyannote.audio) with native Swift (WhisperKit + SpeakerKit). Eliminate all Python dependencies.

---

## Motivation

- Eliminate embedded Python/conda (~100-200MB bundle overhead)
- Improve transcription speed (~5-8x with large-v3-turbo vs large-v3)
- Simplify packaging (no embed_python.sh, no ffmpeg)
- Fully native Swift app — single binary for GUI and CLI

## Approach: Incremental Migration (4 phases)

Each phase is independently testable. Benchmark files validate performance and quality at every step. TDD throughout. Generous `os.Logger` logging at every stage.

---

## Dependencies

**Add to Package.swift:**
```swift
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0")
```

WhisperKit includes SpeakerKit. No other new dependencies.

**Remove (Phase 4):**
- `embed_python.sh`
- `transcribe.py`, `rename_speakers.py`, `service/` directory
- conda environment requirement
- ffmpeg bundling

---

## Config Changes

**Config.swift — add:**
- `whisperModel: String` — default `"large-v3-turbo"`
- `modelStoragePath: String` — default `"~/.audio-transcribe/models"`
- `modelUnloadTimeout: Int` — default `60` (minutes). Not exposed in Settings UI.

**Config.swift — remove:**
- `hfToken: String`

---

## New Components

### ModelManager (`TranscriberCore/ModelManager.swift`)

Downloads and caches WhisperKit models.

- Storage: `~/.audio-transcribe/models/`
- Downloads from HuggingFace via WhisperKit's built-in API
- Exposes download progress (for SetupView progress bar)
- Checks cache before downloading
- Handles both Whisper models and SpeakerKit models (~10MB)
- Available models:
  - `large-v3-turbo` — "Fast (recommended)" ~1.6GB
  - `large-v3` — "High Quality" ~3GB
- Logging: download start/end, file sizes, cache hits/misses

### WhisperKitTranscriber (`TranscriberCore/WhisperKitTranscriber.swift`)

Wraps WhisperKit for transcription.

```swift
public struct TranscriptSegment {
    public let start: Double
    public let end: Double
    public let text: String
    public let language: String?
}

public class WhisperKitTranscriber {
    init(modelPath: URL, model: String = "large-v3-turbo") async throws
    func transcribe(audioPath: URL, language: String? = nil) async throws -> [TranscriptSegment]
}
```

**Model lifecycle:**
- Lazy load on first transcription
- 1-hour idle timer after transcription completes
- Unload model (release to nil) when timer fires
- Timer resets on new transcription
- Log model load/unload events

**Logging:** Model load time, audio duration, transcription time, segment count, detected language, confidence scores.

### DiarizationProvider Protocol (`TranscriberCore/DiarizationProvider.swift`)

Abstraction over diarization backends.

```swift
public protocol DiarizationProvider {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment]
}

public struct DiarizedSegment {
    public let start: Double
    public let end: Double
    public let speaker: String  // "SPEAKER_00", "SPEAKER_01", etc.
}
```

**Implementations:**
1. `PyAnnoteDiarizer` — temporary bridge, shells out to a minimal Python script running pyannote only. Used during phases 1-2.
2. `SpeakerKitDiarizer` — uses SpeakerKit Core ML. Default from phase 2 onward.

Both log: entry/exit, audio duration, number of speakers detected, processing time.

### CLIHandler (`TranscriberApp/Services/CLIHandler.swift`)

Handles CLI mode when arguments are detected.

**Subcommands:**
```
AudioTranscribe transcribe -i system.wav [-i mic.wav] [-o output.json] [-f json|srt|txt] [-l en] [--no-diarize] [--model large-v3] [--speakers 3]
AudioTranscribe rename -i transcript.json
AudioTranscribe benchmark [--transcription-only] [--diarization-only]
```

**Entry point detection** in `TranscriberApp.swift`:
```swift
@main struct TranscriberApp: App {
    init() {
        if CommandLine.arguments.count > 1 {
            CLIHandler.run()  // handles args, runs, exits
        }
    }
}
```

**Transcribe:** Same pipeline as GUI — WhisperKitTranscriber + DiarizationProvider. Outputs JSON always, plus format file if `-f srt` or `-f txt`.

**Rename:** Reads JSON, finds speakers, extracts sample timestamps. Plays audio via `afplay` (with seek). Interactive terminal prompts. Writes updated JSON + format file.

**Benchmark:** Runs against files in `~/.audio-transcribe/benchmark/`. Flags to isolate subsystem. Outputs timing comparison.

---

## Modified Components

### TranscriptionRunner (`TranscriberApp/Services/TranscriptionRunner.swift`)

**Current:** Launches `python transcribe.py` via `Process`.

**New:** Calls `WhisperKitTranscriber` + `DiarizationProvider` directly (in-process, no subprocess).

- Dual-stream handling stays here: transcribe system + mic separately, tag with "Remote"/"Local", merge chronologically
- Speaker assignment logic (mapping diarization labels to transcript segments by time overlap) moves from Python to Swift
- Assembles same JSON schema as today (metadata + segments)
- Writes JSON via `JSONEncoder`, then format file via existing `TranscriptWriter.writeFormatFile()`

### SetupView (`TranscriberApp/Views/SetupView.swift`)

New step after permissions: "Download transcription model"
- Shows model name and size
- Progress bar during download
- Skips if already cached

### SettingsView (`TranscriberApp/Views/SettingsView.swift`)

- Remove HuggingFace token field
- Add model picker dropdown (large-v3-turbo / large-v3) with download status
- No UI for `modelUnloadTimeout` (config.json only)

---

## JSON Output Schema (unchanged)

The output JSON format is preserved exactly for compatibility:

```json
{
  "metadata": {
    "audio_files": ["system.wav", "mic.wav"],
    "audio_paths": ["/full/path/system.wav", "/full/path/mic.wav"],
    "output_format": "json",
    "language": "en",
    "num_speakers": 2,
    "diarization": true,
    "dual_stream": true,
    "speaker_names": {}
  },
  "segments": [
    {
      "start": 0.5,
      "end": 2.3,
      "speaker": "Remote Speaker 1",
      "text": "transcript text",
      "source": "remote"
    }
  ]
}
```

---

## Benchmark Harness

**Purpose:** Live regression/comparison tool used throughout development.

**Setup:**
- Developer places recording files in `~/.audio-transcribe/benchmark/` (not committed to git)
- Expected layout: pairs of WAV files (system + mic per recording)
- Path added to `.gitignore`

**Usage:**
- `AudioTranscribe benchmark` — full pipeline (transcription + diarization)
- `AudioTranscribe benchmark --transcription-only` — isolate transcription engine
- `AudioTranscribe benchmark --diarization-only` — isolate diarization

**Output:**
- Wall-clock time per stage
- Segment count, speaker count
- Peak memory (if measurable)
- Results appended to `~/.audio-transcribe/benchmark/results.json` with timestamp for historical comparison

**Baseline:** Record Python pipeline timings before any changes (Phase 0).

---

## Migration Phases

### Phase 0 — Baseline & Setup
- Create branch `feature/whisperkit-migration` off main
- Manually copy benchmark audio to `~/.audio-transcribe/benchmark/`
- Run current Python pipeline, record baseline timings
- Add WhisperKit SPM dependency to Package.swift
- Update Config.swift (add `whisperModel`, `modelStoragePath`, `modelUnloadTimeout`; remove `hfToken`)
- Build `ModelManager` (TDD)
- Build benchmark harness CLI subcommand

### Phase 1 — WhisperKit Transcription
- Build `WhisperKitTranscriber` (TDD)
- Build `DiarizationProvider` protocol
- Build `PyAnnoteDiarizer` (temporary bridge)
- Rewrite `TranscriptionRunner` to use WhisperKit + PyAnnoteDiarizer
- Port speaker assignment logic from Python to Swift (TDD)
- SetupView: add model download step
- SettingsView: add model picker, remove HF token field
- Benchmark: compare transcription speed/quality vs baseline

### Phase 2 — SpeakerKit Diarization
- Build `SpeakerKitDiarizer` implementing `DiarizationProvider` (TDD)
- Swap default diarizer to SpeakerKit
- Benchmark: compare diarization speed/quality vs pyannote baseline
- Keep `PyAnnoteDiarizer` accessible via `--diarizer pyannote` CLI flag

### Phase 3 — CLI Mode & Rename
- Add CLI argument detection in `TranscriberApp.swift`
- Build `CLIHandler` with transcribe/rename/benchmark subcommands
- Swift rename with `afplay` playback (TDD)
- Test CLI end-to-end with benchmark files

### Phase 4 — Kill Python
- Remove `transcribe.py`, `rename_speakers.py`, `service/`
- Remove `embed_python.sh`
- Remove `PyAnnoteDiarizer` (or keep as CLI-only escape hatch — decide at the time based on SpeakerKit confidence)
- Remove conda/ffmpeg from packaging
- Update CLAUDE.md, scripts/test-checklist.md, scripts/dev.py
- Final benchmark: full pipeline comparison vs Phase 0 baseline

---

## Logging Strategy

All new components log via `os.Logger` with subsystem `com.audio-transcribe.app`.

**Categories used:**
- `transcription` — WhisperKitTranscriber operations, model load/unload, timing
- `audio` — file I/O, WAV reading, benchmark file handling
- `state` — model lifecycle transitions (loading → ready → idle → unloaded)
- `config` — model selection, storage path resolution

**Log levels:**
- `.debug` — timing breakdowns, segment counts, confidence scores, progress
- `.info` — model load/unload, transcription start/complete, diarization results
- `.error` — failures, download errors, format mismatches

**Development phase:** Log generously at debug level. Can be reduced before shipping.

---

## Testing Strategy

**TDD throughout.** Tests written before implementation for each new type.

**Unit tests (SwiftTests/TranscriberTests/):**
- `ModelManagerTests` — cache hit/miss, path resolution, config integration
- `WhisperKitTranscriberTests` — segment parsing, language detection, model lifecycle (idle timer)
- `DiarizationProviderTests` — protocol conformance, segment merging
- `SpeakerAssignmentTests` — time overlap matching, midpoint tiebreaker, Remote/Local tagging
- `CLIHandlerTests` — argument parsing, subcommand routing
- `SpeakerRenameTests` — JSON read/write, name substitution, format file regeneration
- `BenchmarkTests` — results serialization, timing capture

**Integration tests:** Manual, using benchmark audio files. Not automated (files not in git).

**Existing tests:** 102 tests across 9 suites remain unchanged. New tests add to the suite.

---

## What's NOT in Scope

- Streaming/real-time transcription (future phase, likely whisper.cpp or custom chunked WhisperKit)
- fastText multilingual post-processing (future improvement)
- Multi-model dispatch per language (discussed, deferred)
- WhisperKit Pro features (paywall)
