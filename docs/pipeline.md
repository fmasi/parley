# Transcriber — End-to-End Pipeline

## 1. Overview

Transcriber is a macOS menu bar app (macOS 15+, Apple Silicon) that records meetings by capturing two separate audio streams — microphone and system audio (Zoom, Teams, Meet) — via ScreenCaptureKit running in an XPC service. During recording, audio is written in time-bounded chunks (default: configurable minutes) that are processed in parallel: ASR transcription, speaker diarization, VAD quality filtering, and echo deduplication. At the end of recording each chunk's results are merged into a single time-sorted transcript with globally consistent speaker identities, an AAC stereo archive is written (L=mic, R=system), and an optional LLM summary is fired in the background. The raw audio archive is the canonical evidence store — it is never modified after writing.

---

## 2. Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  RECORDING (continuous)                                         │
│                                                                 │
│  ScreenCaptureKit (XPC)                                         │
│    ├─ system audio → WavFileWriter → chunk-N.wav                │
│    └─ mic audio → AudioConverter → WavFileWriter → chunk-N_mic.wav
│                         │                                       │
│            ChunkRotator (timer-based)                           │
│            ├─ calls rotateChunk() on XPC → swaps writers        │
│            └─ emits FinalizedChunk(index, systemPath, micPath)  │
│                         │                                       │
│            (repeat per chunk interval)                          │
└─────────────────────────────────────────────────────────────────┘
                          │
           ┌──────────────▼──────────────┐
           │   PER-CHUNK PROCESSING      │
           │   (parallel background      │
           │    Task per chunk)          │
           │                             │
           │  ┌──────────────────────┐   │
           │  │ 1. ASR Transcription │   │
           │  │    system WAV → []TranscriptSegment
           │  │    mic WAV    → []TranscriptSegment
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 2. Diarization       │   │
           │  │    system WAV → DiarizationResult (segments + speakerDatabase)
           │  │    mic WAV    → DiarizationResult                │
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 3. VAD Speech Map    │   │
           │  │    system/mic WAV    │   │
           │  │    → [SpeechRegion]  │   │
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 4. Speaker Assignment│   │
           │  │    transcript + diarization + VAD
           │  │    → [LabeledSegment] with source tag
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 5. Echo Dedup        │   │
           │  │    local vs remote   │   │
           │  │    → [LabeledSegment]│   │
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 6. Audio Archival    │   │
           │  │    WAV → stereo AAC  │   │
           │  │    (L=mic, R=system) │   │
           │  └──────────┬───────────┘   │
           │             │               │
           │  ┌──────────▼───────────┐   │
           │  │ 7. Persist to        │   │
           │  │    session.json      │   │
           │  └──────────────────────┘   │
           └─────────────────────────────┘
                          │
           ┌──────────────▼──────────────┐
           │  END OF RECORDING           │
           │                             │
           │  awaitAllProcessed()        │
           │  SpeakerReconciler.reconcile()  (cross-chunk embedding matching)
           │  TranscriptMerger.merge()   (absolute timestamps, global speakers)
           │  TranscriptAssembler.assemble() + write JSON
           │  MeetingSummarizer.summarizeIfConfigured()  (fire-and-forget)
           └─────────────────────────────┘
```

---

## 3. Stage Details

### Stage 1 — Audio Capture

**What it does:** ScreenCaptureKit captures two separate PCM streams — system audio (all app audio, 48 kHz) and microphone — and writes each to a WAV file. There is no Apple API for a pre-mixed stream. The XPC service (`AudioCaptureHelperXPC` target) runs in-process within the app bundle and is the only process that holds Screen Recording permission.

**Input:** None (live capture). Output: `<baseName>.wav` (system, 48 kHz, auto-detected Float32 or Int16) and `<baseName>_mic.wav` (mic, normalized to 48 kHz mono Int16 via `AudioConverter`).

**Key code path:**
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` — `startCapture()`, `rotateChunk()`, `configureAndStart()`
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` — `stream(_:didOutputSampleBuffer:of:)`, `handleSystemAudio()`, `handleMicAudio()`

Notes:
- System audio: format detected from `CMSampleBuffer` on first frame; `Float32` and `Int16` both handled.
- Mic audio: any native device rate/channel/format → `AudioConverter` normalizes to 48 kHz mono Int16.
- `.screen` output type must be registered even for audio-only capture (ScreenCaptureKit requirement).
- `SCStreamConfiguration.microphoneCaptureDeviceID` (macOS 15+) allows per-device mic selection.

### Stage 2 — Chunk Rotation

**What it does:** A `Timer` fires on a configurable interval (default: set in config). On each tick, the XPC service atomically swaps the active `WavFileWriter` pair on the audio callback queue (zero-gap guarantee), finalizes the old writers, and returns the old file paths. The caller receives a `FinalizedChunk` value and dispatches background processing.

**Input:** Running capture. Output: `FinalizedChunk(index, systemPath, micPath, startTime)`.

**Key code path:**
- `TranscriberApp/Services/ChunkRotator.swift` — `rotate()` → `captureClient.rotateChunk()`
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` — `rotateChunk()` → `handler.swapWriters()`
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` — `swapWriters()`

### Stage 3 — ASR Transcription

**What it does:** Both WAV files (system + mic) are transcribed independently using the configured engine. Each produces `[TranscriptSegment]` with chunk-relative timestamps.

**Engines:**

| Engine | Model | Requirement | Download |
|---|---|---|---|
| FluidAudio | Parakeet (CoreML/ANE) | macOS 15+ | ~500 MB (eager at Setup) |
| SpeechAnalyzer | Apple on-device | macOS 26+ | None |

**Input:** WAV file URL, `AudioSourceType` (`.system` / `.microphone`). Output: `[TranscriptSegment]` (start, end, text, language?, confidence?).

**Key code path:**
- `TranscriberCore/FluidAudioEngine.swift` — `transcribe(audioPath:language:audioSource:)` → `mgr.transcribe()` → `groupTokensIntoSegments()` → ITN via `TextNormalizer` → `SpeakerAssignment.deduplicate()`
- `TranscriberCore/SpeechAnalyzerEngine.swift` — `transcribe()` (wrapped in `#if compiler(>=6.2)`)

Notes:
- `ensureLoaded()` is load-only; throws `FluidAudioEngineError.modelNotDownloaded` if cache is absent (never downloads at runtime).
- Model unloads after 60-minute idle timeout to reclaim memory.
- ITN (`TextNormalizer`) converts spoken numbers to written form, e.g., "three hundred" → "300". Uses a native C library via `dlsym`; gracefully no-ops if unavailable.
- Decimal-dot guard: does not split on `.` when next token starts with a digit (e.g., "1.5 million").

### Stage 4 — Diarization

**What it does:** Assigns speaker identities to time regions using offline speaker diarization. Runs on the system audio WAV and (in dual-stream mode) the mic WAV separately. Produces per-chunk speaker embeddings that are used later for cross-chunk reconciliation and echo deduplication.

**Model:** FluidAudio `OfflineDiarizerManager` — pyannote segmentation + WeSpeaker embeddings + VBx clustering (~10 MB, eager at Setup).

**Input:** WAV file URL, optional numSpeakers hint. Output: `DiarizationResult(segments: [DiarizedSegment], speakerDatabase: [String: [Float]])`.

**Key code path:**
- `TranscriberCore/FluidAudioDiarizer.swift` — `diarize(audioPath:numSpeakers:)` → `mgr.process()`

Notes:
- `OfflineDiarizerConfig(embeddingExcludeOverlap: false)` — includes overlap embeddings to avoid collapsing remote speakers into one cluster on mixed Zoom/Teams audio.
- `isDiarizationCached()` checks diarization models only; `isFullyReady()` also checks VAD model.

### Stage 5 — VAD Speech Map

**What it does:** Runs Silero VAD on the audio file to produce a time-indexed speech probability map. Used as a parallel quality signal in speaker assignment. Runs concurrently with diarization (RTFx ~100x, near-zero added latency).

**Model:** Silero VAD (bundled in FluidAudio, ~few MB).

**Input:** WAV file URL. Output: `[SpeechRegion](start, end, probability)` or `nil` if model not cached (graceful degradation).

**Key code path:**
- `TranscriberCore/VadSpeechMap.swift` — `analyze(audioPath:)` → `mgr.process()` → chunk duration from `VadManager.chunkSize / VadManager.sampleRate`

### Stage 6 — Speaker Assignment

**What it does:** Assigns a speaker label to each transcript segment by finding the diarization segment with maximum temporal overlap. Applies a VAD + quality-score filter to suppress hallucinated or low-quality segments.

**Decision matrix (when `speechMap` is provided):**

| VAD speech | Diarizer quality | Action |
|---|---|---|
| High | High | Assign speaker |
| High | Low | Assign "Unknown" |
| Low | High | Assign speaker (trust diarizer) |
| Low | Low | Filter (drop segment) |

**Input:** `[TranscriptSegment]`, `[DiarizedSegment]`, `[SpeechRegion]?`. Output: `[LabeledSegment]` with `source` tag ("local" / "remote").

**Key code path:**
- `TranscriberCore/SpeakerAssignment.swift` — `assign(transcriptSegments:diarizationSegments:speechMap:vadSpeechThreshold:qualityScoreThreshold:)`
- `SpeakerAssignment.tagWithSourcePrefix(_:)` — adds "Local"/"Remote" prefix for dual-stream display

Defaults: `vadSpeechThreshold = 0.5`, `qualityScoreThreshold = 0.3`.

### Stage 7 — Echo Deduplication

**What it does:** Removes local (mic) segments that are mic bleed of the remote speaker — i.e., the local microphone picked up audio playing through the speakers. See Section 4 for a full deep dive.

**Input:** `[LabeledSegment]` (combined local+remote), local speaker embeddings, remote speaker embeddings. Output: `EchoDeduplicator.DeduplicationResult(segments, removedCount)`.

**Key code path:**
- `TranscriberCore/EchoDeduplicator.swift` — `deduplicate(segments:localSpeakerDatabase:remoteSpeakerDatabase:...)`

### Stage 8 — Audio Archival

**What it does:** Combines the two mono WAV files into a stereo AAC `.m4a` archive (L=mic, R=system) via `AVAssetWriter`. Source WAVs are deleted on success. Reads/writes in fixed 65536-frame blocks (~1 MB memory usage, O(block) not O(file)).

**Input:** `systemAudio: URL`, `micAudio: URL`, `bitrateKbps: Int`. Output: `AudioArchiveResult(archivePath: URL)` (.m4a).

**Key code path:**
- `TranscriberCore/AudioArchiver.swift` — `archive(systemAudio:micAudio:outputDirectory:bitrateKbps:)` → `streamEncodeAAC()` → `verify()`

Notes:
- Channel convention: L = mic (local), R = system (remote). `AudioSourceResolver` reads this back for re-transcription.
- Source WAVs are only deleted after verification (non-empty file with at least one audio track).

### Stage 9 — Transcript Assembly

**What it does:** At end of recording, all processed chunks are reconciled cross-chunk (speaker identity), merged into absolute wall-clock timestamps, assembled into a JSON dictionary, and written to disk.

**Input:** `[ProcessedChunk]` (from `session.json`). Output: `<sessionName>-transcript.json` with `metadata` and `segments` keys.

**Key code path:**
- `TranscriberCore/SpeakerReconciler.swift` — `reconcile(chunks:threshold:)`: greedy cosine-similarity matching, EMA embedding update (alpha=0.9), new global IDs as `spk_N`
- `TranscriberCore/TranscriptMerger.swift` — `merge(chunks:speakerMapping:meetingStart:)`: converts chunk-relative offsets to elapsed seconds + absolute `Date`
- `TranscriberCore/TranscriptAssembler.swift` — `assemble(segments:audioPaths:...)` → `write(_:to:)`

Notes:
- Reconciler threshold default: 0.65 cosine similarity.
- Unmatched local speakers in a chunk get new global IDs (`spk_0`, `spk_1`, ...).
- Merger output is `MergeResult(segments: [MergedSegment], meetingStart, chunkCount)`.

### Stage 10 — Summary Generation

**What it does:** Reads the transcript JSON, builds a prompt with speaker-labeled lines (and source labels in dual-stream mode), calls the configured LLM provider, and writes `<sessionName>-summary.md` alongside the transcript. Called via `summarizeIfConfigured()` — logs errors, never throws, fire-and-forget.

**Providers:** `OpenAISummaryProvider` (OpenAI-compatible `/v1/chat/completions`) or `LMStudioSummaryProvider` (LM Studio native `/api/v1/chat` with per-request `context_length` and self-correcting retry on context overflow).

**Input:** Transcript JSON path, `Config`. Output: `-summary.md` file.

**Key code path:**
- `TranscriberCore/MeetingSummarizer.swift` — `summarizeIfConfigured()`, `summarize()`, `createProvider(from:)`
- `TranscriberCore/OpenAISummaryProvider.swift` — `summarize()`, `buildRequest()`
- `TranscriberCore/LMStudioSummaryProvider.swift` — self-correcting retry on context overflow
- `TranscriberCore/TokenRatioCache.swift` — `~/Library/Application Support/Parley/token-ratios.json`

---

## 4. Echo Deduplication Deep Dive

### The Problem

In a video call, the local machine plays remote speaker audio through speakers. The microphone picks this up as bleed, so the local audio stream contains both local speech and echoes of remote speech. Without deduplication, the transcript shows the remote speaker twice — once in the system audio stream and once in the mic stream.

### Triple-Gate Algorithm

A local segment is classified as an echo only when **all three gates pass**:

**Gate 1 — Embedding similarity (checked first for efficiency):**
The local speaker's embedding is compared against every remote speaker embedding via cosine similarity. If the best match is below 0.8, the segment is kept immediately — it's a genuinely different speaker.

**Gate 2 — Temporal overlap:**
The local segment must overlap with at least one remote segment by >50% of the shorter segment's duration.

**Gate 3 — Text similarity:**
The overlapping remote text must match the local text with >70% word-level Jaccard similarity.

Thresholds: `defaultEmbeddingThreshold = 0.8`, `defaultTemporalThreshold = 0.5`, `defaultTextThreshold = 0.7`.

### Windowed Comparison and Containment Fallback

Segment boundaries from independent ASR runs may not align. Two fallbacks handle this:

1. **Containment check:** If Jaccard fails but `textContainment(local, remote) > 0.7` (most words from the short local segment appear in a longer remote segment), the local segment is removed. This handles short local excerpts of long remote utterances.

2. **Window concatenation:** If multiple remote segments overlap with the local segment, their texts are concatenated and Jaccard is re-evaluated against the window. This handles one long local segment that covers what the remote side split into several shorter segments.

### LLM Text-Level AEC in Summary Prompt

When `dualStream = true`, the summary prompt receives source labels ("Local" / "Remote") on each transcript line and includes a hint instructing the LLM to treat repeated identical content across streams as echo and to use only the remote stream's version for attribution. This is a text-level fallback for any echoes that survive the triple-gate filter.

### Courtroom Safety

- The raw WAV files and the AAC archive are **never modified** after writing.
- Echo removals are tracked in `metadata.echo_segments_removed` (integer count) in the transcript JSON.
- The transcript JSON is the processed record; the `.m4a` is the raw evidence. The two are independent.
- `AudioArchiverError.verificationFailed` is thrown (and WAVs are preserved) if the output archive is empty or has no audio tracks.

### Validation

0 false positives across 7 recordings. Benchmark reports are in `docs/benchmarks/`.

---

## 5. Summary Generation

### Provider Protocol Design

`SummaryProvider` is a Swift protocol (`TranscriberCore/SummaryProvider.swift`):

```swift
public protocol SummaryProvider: Sendable {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String
}
```

`MeetingSummarizer.createProvider(from:)` is the factory:
- `summary.provider == .openai` → `OpenAISummaryProvider` (standard OpenAI `/v1/chat/completions`; also works with Claude proxy, Ollama, LM Studio in OpenAI-compat mode)
- `summary.provider == .lmstudio` → `LMStudioSummaryProvider` (LM Studio native `/api/v1/chat` with per-request `context_length`)

### Dual-Stream Prompt

When `metadata.dualStream == true`, each transcript line is prefixed with its source ("Local Speaker 1" / "Remote Speaker 2") and a `dualStreamHint` is appended to the system prompt. The hint instructs the LLM that "Local" speakers are on the local machine and "Remote" speakers joined via video call, and that duplicate lines across streams are acoustic echo — remote attribution should be preferred.

### Token Ratio Calibration Lifecycle

`TokenRatioCache` (`~/Library/Application Support/Parley/token-ratios.json`) maintains a per-model chars-per-token ratio:

1. **Probe (seed):** On first use for a model, a 283-char calibration probe is sent to the LM Studio REST API. The measured ratio is stored as `isSeed: true`.
2. **Real measurement:** When a real transcript is summarized (input >2000 chars), the actual `prompt_tokens` value from the response is used to compute a real ratio, stored as `isSeed: false`. Real measurements always replace seeds.
3. **EMA refinement:** Subsequent real measurements refine via exponential moving average.

The ratio is used by `LMStudioSummaryProvider` to estimate token count and select an appropriate `context_length` for the request, with a self-correcting retry if the context overflows.

### Fire-and-Forget Design

`MeetingSummarizer.summarizeIfConfigured()` is `async` and logs errors via `Logger.transcription.error(...)` — it never throws. It is called from the post-recording flow without `try` and without blocking the transcript write.

---

## 6. Debugging

All Swift components log via `os.Logger` with:
- **Subsystem:** `eu.fmasi.parley`
- **Categories:** `audio`, `transcription`, `state`, `config`, `permissions`, `files`

```bash
# All logs (debug + info + error) — use during development
log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug

# Only errors
log stream --predicate 'subsystem == "eu.fmasi.parley" AND messageType == error'

# Only audio capture (format detection, frame delivery, chunk rotation)
log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "audio"' --level debug

# Only transcription (ASR, diarization, echo dedup, summary)
log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "transcription"' --level debug

# Only file operations (archival, transcript writes, storage quota)
log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "files"' --level debug

# Historical (last 5 minutes)
log show --predicate 'subsystem == "eu.fmasi.parley"' --last 5m

# Save to file (shows in terminal AND writes to file — share for debugging sessions)
log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug --style compact | tee ~/Desktop/transcriber.log

# Dump recent history to file (useful after a crash — no live stream needed)
log show --predicate 'subsystem == "eu.fmasi.parley"' --last 30m --style compact > ~/Desktop/transcriber.log

# Via dev.py (launches app + tails log automatically)
python3 scripts/dev.py --debug
```

---

## 7. Packaging

### Package.swift — SPM Workspace

4 library/executable targets + 1 test target:

| Target | Type | Description |
|---|---|---|
| `TranscriberApp` | Executable | SwiftUI menu bar app (`@main`) |
| `TranscriberCore` | Library | All business logic (engines, pipeline, CLI) |
| `AudioCaptureHelperXPC` | Executable | XPC service for audio capture |
| `AudioCaptureProtocol` | Library | `@objc` XPC protocol + service name constant |
| `TranscriberTests` | Test | 384 tests across 38 suites (Swift Testing, not XCTest) |

Test path: `SwiftTests/TranscriberTests/` (not `Tests/` — APFS case-collision workaround).

### Plists

- `packaging/Info.plist` — app bundle metadata: `CFBundleIdentifier: eu.fmasi.parley`, `LSUIElement: true` (menu bar only), TCC usage descriptions (microphone, screen recording, calendar, notifications)
- `packaging/AudioCaptureHelper-Info.plist` — XPC service plist: `ServiceType: Application`

### Build & Run

```bash
# Build everything
swift build

# Run tests
swift test --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

### scripts/dev.py

Developer iteration CLI. Key flags:

| Flag | Action |
|---|---|
| (default) | Kill app, build, install bundle, launch |
| `--debug` | Launch app + tail unified log (subsystem filter) |
| `--reset-tcc` | Reset TCC permissions (microphone + screen recording) |
| `--no-build` | Skip build step (reuse last binary) |

### scripts/test-checklist.md

Dynamic test checklist printed by `dev.py` on each launch. Updated alongside feature work. Covers all manual verification steps for a full recording + transcription + rename + summary cycle.

---

## 8. CLI Reference

Subcommands are parsed by `TranscriberCore/CLIParser.swift` into a `CLICommand` enum. The app dispatches CLI commands only when known subcommands are present (not just `arguments.count > 1` — LaunchServices can inject extra arguments).

### `transcribe`

Transcribe one or more audio files.

```
Parley transcribe -i <path> [-i <path>...] [options]

Options:
  -i, --input <path>        Input audio file (repeat for multiple files)
  --output-dir <path>       Output directory (default: same as input)
  -f, --format <fmt>        Output format: json (default), txt, srt
  --no-diarize              Skip speaker diarization
  --engine <id>             Engine override: fluidAudio, speechAnalyzer
  --split                   Force L/R channel split for stereo AAC (L=mic, R=system)
  --no-split                Force single-stream processing (external recordings)
  --debug                   Enable verbose debug logging
  --legacy-dedup            Use legacy (non-windowed) echo dedup mode
```

**Stereo channel handling:** When a single `.m4a` file is given without `--split` or `--no-split`, the CLI prompts interactively:

```
Stereo audio detected. How should channels be handled?
  [1] Split L/R channels (app recording: L=mic, R=system)
  [2] Mix to single stream (external recording)
Choice [2]:
```

Default is single-stream (option 2). When stdin is not a terminal (piped/scripted), defaults to single-stream silently. Use `--split` for app recordings or `--no-split` for external files to skip the prompt.

### `rename`

Interactive CLI speaker rename — parses transcript JSON, collects speaker samples, prompts for new names via stdin.

```
Parley rename -i <transcript.json>
```

### `rename-gui`

Opens the speaker rename dialog as a floating NSPanel (same input as `rename` but GUI).

```
Parley rename-gui -i <transcript.json>
```

### `benchmark`

Run engine benchmark suite against test audio files.

```
Parley benchmark [--transcription-only | --diarization-only]
```

### `summarize`

Generate an LLM summary from a transcript JSON file. Options override config values.

```
Parley summarize -i <transcript.json> [options]

Options:
  -i, --input <path>           Transcript JSON file
  --provider <id>              Provider: openai, lmstudio
  --endpoint <url>             API endpoint URL
  --api-key <key>              API key (optional for local servers)
  --model <name>               Model name
  --context-length <n>         Context window size in tokens (LM Studio only)
```
