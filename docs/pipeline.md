# Transcriber — End-to-End Pipeline

## 1. Overview

Transcriber is a macOS menu bar app (macOS 15+, Apple Silicon) that records meetings by capturing two separate audio streams — microphone and system audio (Zoom, Teams, Meet) — in an XPC service. System audio comes from a Core Audio output process tap by default (`system_audio_source: core_audio_tap`, which also captures Continuity/VoIP calls ScreenCaptureKit misses), or from ScreenCaptureKit (`sck`, legacy until #221). During recording, audio is written in time-bounded chunks (default: configurable minutes) that are processed in parallel: ASR transcription, speaker diarization, VAD quality filtering, and echo deduplication. At the end of recording each chunk's results are merged into a single time-sorted transcript with globally consistent speaker identities, an AAC stereo archive is written (L=mic, R=system), and an optional LLM summary is fired in the background. The raw audio archive is the canonical evidence store — it is never modified after writing.

---

## 2. Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  RECORDING (continuous)                                         │
│                                                                 │
│  Capture (XPC) — two independent sources:                       │
│    system audio: Core Audio tap (default) or ScreenCaptureKit   │
│                  (system_audio_source=sck, legacy)              │
│      → WavFileWriter → chunk-N.wav                              │
│    mic: MicCaptureSession (AVCaptureSession, #96)               │
│      → AudioConverter → WavFileWriter → chunk-N_mic.wav         │
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

**What it does:** the XPC service captures two separate PCM streams — system audio (all app audio, 48 kHz) and microphone — and writes each to a WAV file. There is no Apple API for a pre-mixed stream. System audio is captured by a Core Audio output process tap (`system_audio_source: core_audio_tap`, the default, `SystemTapSession.swift`), which captures Continuity/VoIP call audio ScreenCaptureKit misses, or by ScreenCaptureKit (`sck`, legacy); the mic is captured independently (`MicCaptureSession.swift`). The XPC service (`AudioCaptureHelperXPC` target) runs in-process within the app bundle and is the only process that holds Screen Recording permission.

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
- `TranscriberCore/FluidAudioEngine.swift` — `transcribe(audioPath:language:audioSource:)` → `mgr.transcribe()` → `groupTokensIntoSegments()` → ITN via `TextNormalizer`
- `SpeakerAssignment.deduplicate()` runs after the engine, in `ChunkProcessor` / `TranscriptionRunner`'s `transcribeStream`, so its counts land in the chunk's `issues`: an abutting repeat (same text, starting ≤ 0.25 s after the previous segment ends) is kept and flagged `duplicate: true` (`duplicates_flagged`); a zero-duration segment is dropped (`zero_length_dropped`)
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
- `OfflineDiarizerConfig(embeddingExcludeOverlap: true)` — **excludes** overlapped speech from speaker embeddings (FluidAudio's default). This previously forced `false`, on the theory that a mixed mono stream is "all overlap" so the mask would discard most embeddings. That reasoning is wrong — the mask marks frames where two *speakers* overlap, not merely remote speech — and the override caused exactly the collapse it was meant to avoid: an embedding computed over a window holding two voices is a blend of both, so every embedding converged and the clusterer saw one speaker. Measured on AMI ES2004a (a 4-speaker reference meeting): `false` → **1 speaker** (639/642 embeddings in one cluster); `true` → **4 speakers**. Overridable via `diarization_exclude_overlap`, but don't.
- `isDiarizationCached()` checks diarization models only; `isFullyReady()` also checks VAD model.

### Stage 5 — VAD Speech Map

**What it does:** Runs Silero VAD on the audio file to produce a time-indexed speech probability map. Used as a parallel quality signal in speaker assignment. Runs concurrently with diarization (RTFx ~100x, near-zero added latency).

**Model:** Silero VAD (bundled in FluidAudio, ~few MB).

**Input:** WAV file URL. Output: `[SpeechRegion](start, end, probability)` or `nil` if model not cached (graceful degradation).

**Key code path:**
- `TranscriberCore/VadSpeechMap.swift` — `analyze(audioPath:)` → `mgr.process()` → chunk duration from `VadManager.chunkSize / VadManager.sampleRate`

### Stage 6 — Speaker Assignment

**What it does:** First re-splits any ASR segment whose word timing straddles a diarization speaker-change boundary (issue #120) — neither ASR engine's own segmentation is diarization-aware, so one segment can otherwise span a real speaker turn. Each resulting piece is single-speaker by construction and carries its word-evidenced speaker forward. Then assigns a speaker label to each transcript segment/piece — trusting that word evidence when present, otherwise by finding the diarization segment with maximum temporal overlap. Applies a VAD + quality-score filter to suppress hallucinated or low-quality segments.

**Decision matrix (when `speechMap` is provided):**

| VAD speech | Diarizer quality | Action |
|---|---|---|
| High | High | Assign speaker |
| High | Low | Assign "Unknown" |
| Low | High | Assign speaker (trust diarizer) |
| Low | Low | Filter: keep the segment, speaker `Unknown`, flagged `filtered: true` |

**Input:** `[TranscriptSegment]`, `[DiarizedSegment]`, `[SpeechRegion]?`. Output: `[LabeledSegment]` with `source` tag ("local" / "remote").

**Key code path:**
- `TranscriberCore/SpeakerAssignment.swift` — `assign(transcriptSegments:diarizationSegments:speechMap:vadSpeechThreshold:qualityScoreThreshold:)`, which calls `splitAcrossSpeakerBoundaries(_:diarizationSegments:)` internally before labeling
- `SpeakerAssignment.tagWithSourcePrefix(_:)` — adds "Local"/"Remote" prefix for dual-stream display

Defaults: `vadSpeechThreshold = 0.5`, `qualityScoreThreshold = 0.3`.

### Stage 7 — Echo Deduplication

**What it does:** Flags local (mic) segments that are mic bleed of the remote speaker — i.e., the local microphone picked up audio playing through the speakers. A flagged segment is kept in the JSON (`echo: true`) and hidden from TXT, SRT, the summary prompt and the rename samples; nothing is deleted. See Section 4 for a full deep dive.

**Input:** `[LabeledSegment]` (combined local+remote), local speaker embeddings, remote speaker embeddings. Output: `EchoDeduplicator.DeduplicationResult(segments, flaggedCount)` — every input segment, echoes flagged; the chunk records an `echo_flagged` issue with the count.

**Key code path:**
- `TranscriberCore/EchoDeduplicator.swift` — `deduplicate(segments:localSpeakerDatabase:remoteSpeakerDatabase:...)`

### Stage 8 — Audio Archival

**What it does:** Combines the two mono WAV files into a stereo AAC `.m4a` archive (L=mic, R=system) via `AVAssetWriter`. Source WAVs are deleted on success. Reads/writes in fixed 65536-frame blocks (~1 MB memory usage, O(block) not O(file)). WAV is a transient crash-resiliency format only — **every** chunk flushes to `.m4a` in the success path, including single-stream (no-mic) and single-chunk recordings (#59).

**Input:** `systemAudio: URL`, `micAudio: URL`, `bitrateKbps: Int`. Output: `AudioArchiveResult(archivePath: URL)` (.m4a).

**Key code path:**
- `TranscriberCore/AudioArchiver.swift` — `archive(systemAudio:micAudio:outputDirectory:bitrateKbps:)` → `streamEncodeAAC()` → `verify()`
- `TranscriberCore/AudioArchiver.swift` — `archiveSystemOnly(systemAudio:outputDirectory:bitrateKbps:)` for single-stream chunks (no mic file): same stereo layout with a silent left/mic channel, so re-ingestion is identical.

Notes:
- Channel convention: L = mic (local), R = system (remote). `AudioSourceResolver` reads this back for re-transcription.
- Source WAVs are only deleted after verification: the encoded duration is compared against the sources (not merely "non-empty with an audio track"). On a genuine archive failure the WAV is kept as a last-resort fallback (never delete a WAV that has no `.m4a` replacement).
- A chunk whose mic WAV is empty but whose system WAV has audio goes through `archiveSystemOnly`; the mirror case (system empty, mic has audio) goes through `archiveMicOnly`, which keeps the mic in the LEFT channel.
- In the chunked path the WAVs are deleted only once `session.json` holds the chunk with its `.m4a`, so a crash in between never loses the chunk. An ASR-failed chunk keeps its WAVs next to the `.m4a` (re-transcribable), and `preserve_source_wav` keeps them for every chunk (diagnostics only; the quota never evicts them).

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

#### Capture provenance and metadata

What the record states about how the recording was captured and processed (spec §7). Every key below is written by `TranscriptAssembler.assemble` unless noted; an unmeasured value is left out, never written as 0.

**`metadata.capture_provenance`** (`CaptureProvenance.asMetadataDictionary`, always present for a recording made by the app):
- `engine`, `route_changes`, `retries`, `recovered`, `anomaly_count`, `quality_anomaly_count`, `system_audio_unrecovered`, `system_permission_denied_confirmed`; `system_format`, `mic_format`, `mic_device`, `system_delivered_seconds`, `system_exact_zero_seconds` when known.
- `events_dropped` — how many diagnostic-ring events were evicted before the stamp was built: the ring's own admission that it does not hold the whole session. Always written (0 when none).
- `local_coverage` / `remote_coverage` — per-track coverage summed over every helper session (`TrackAccounting.asMetadataDictionary`): `status` (`healthy` | `idle` | `neverDelivered` | `compromised`), `expected_seconds`, `delivered_seconds`, `padded_seconds`, `longest_gap_seconds`, `gap_count`, `rebuilds`, and when measured `exact_zero_seconds`, `heartbeat_callbacks` (with `*_is_lower_bound: true` when a measured and an unmeasured helper session were summed), plus `content_anomaly_count`. The status is computed once from the coverage and that side's content anomalies, and recomputed (fail closed, never defaulted to healthy) when a stored status is missing or unreadable.
- `reconstructed: true` + `reconstructed_note` when the transcript was rebuilt by a recovery run and these facts come from that run.

In `session.json` the same stamp is persisted under `provenance`, with the per-side status in separate `local_status` / `remote_status` keys.

**`metadata.capture`**:
- `local` / `remote` — the same dictionaries as `capture_provenance.local_coverage` / `remote_coverage`. `capture.remote.status` is the authority on whether the remote side was captured; `dual_stream` is only the capture-time flag that a mic stream was recorded next to it.
- `gaps` — `[{start, end, seconds, reason}]`, periods with no capture: `reason` is `"app relaunch"` or `"sleep"`. Written even when no coverage was stamped.

**Processing issues** (`ChunkIssue`, the full code list is in spec §7.2):
- `metadata.processing_issues` — `[{chunk?, code, track?, count?, detail?}]`: every chunk's `issues`, plus the session's own (`session.json` `issues`) and those finalize adds (a skipped merge, unreadable audio lengths). Always written for a tracked (app) session, `[]` when clean; absent from the CLI `run()` path, which does not track issues, so absence never reads as "clean".
- `metadata.processing_issue_count` — content-affecting issues only (`asr_failed`, `diarization_failed`, `vad_failed`, `stream_missing`, `archive_failed`, `session_write_failed`, `chunk_index_collision`, `seed_mismatch`).
- `metadata.processing_problem_chunks` — distinct chunks with a content-affecting issue (a session-level one counts as one more). The completion notice uses this.

**Merged audio and timeline**:
- `metadata.merged_audio` — `{passthrough, gaps_inserted_seconds}` when the chunks were concatenated into one `.m4a` (silence is inserted for inter-chunk gaps > 1 s, up to a 12 h bound).
- `metadata.chunk_durations` / `metadata.chunk_offsets` — per `audio_paths` entry: each file's length, and where the transcript placed it on the meeting timeline (what re-detect needs).
- `metadata.transcript_written_at` — when finalize wrote the transcript (ms precision); late audio is judged from it.
- `metadata.diarization` — true only when a diarizer ran and no chunk has `diarization_failed`.

**Segment flags** — kept in the JSON, hidden from TXT/SRT, the summary prompt and the rename samples: `filtered` (failed the VAD/quality gate), `echo` (mic bleed), `duplicate` (abutting repeat), `time_unknown` (a non-finite time, written as `null`).

**Files beside the recording**:
- `<session>.diag.live.jsonl` — every non-`info` capture event plus the coverage-carrying ones (`captureStop`, `trackCoverage`), appended as it happens, with ms-precision dates (`LiveDiagnosticsLog`). The record's build merges it, deduplicated, into the ring, and so into `<session>.diag.jsonl`. It is deleted only once the session's transcript exists.
- `<session>.diag.coverage.json` — the latest per-track coverage of each helper session, rewritten on every status pull; stands in for the `captureStop` a crashed helper never wrote.
- `session.json` — besides `chunks` (each with its `issues`) and `provenance`: `gaps` (`CaptureGap`, as above) and `issues` (`SessionIssue` `{chunk?, issue}`: issues that could not be stored on a chunk, such as a failed write after the chunk was appended, or a session-level issue).

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

1. **Containment check:** If Jaccard fails but `textContainment(local, remote) > 0.7` (most words from the short local segment appear in a longer remote segment), the local segment is flagged as echo. This handles short local excerpts of long remote utterances.

2. **Window concatenation:** If multiple remote segments overlap with the local segment, their texts are concatenated and Jaccard is re-evaluated against the window. This handles one long local segment that covers what the remote side split into several shorter segments.

### LLM Text-Level AEC in Summary Prompt

When `dualStream = true`, the summary prompt receives source labels ("Local" / "Remote") on each transcript line and includes a hint instructing the LLM to treat repeated identical content across streams as echo and to use only the remote stream's version for attribution. This is a text-level fallback for any echoes that survive the triple-gate filter.

### Courtroom Safety

- The raw WAV files and the AAC archive are **never modified** after writing.
- Echo removals are tracked in `metadata.echo_segments_removed` (integer count) in the transcript JSON. The segments are kept, flagged `echo: true`; the count is of flagged segments.
- `metadata.dual_stream` is the capture-time flag (a mic stream was captured next to the remote one). It does not say the remote side delivered audio: `metadata.capture.remote.status` is the authority for that.
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
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug

# Only errors
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley" AND messageType == error'

# Only audio capture (format detection, frame delivery, chunk rotation)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "audio"' --level debug

# Only transcription (ASR, diarization, echo dedup, summary)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "transcription"' --level debug

# Only file operations (archival, transcript writes, storage quota)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "files"' --level debug

# Historical (last 5 minutes)
/usr/bin/log show --predicate 'subsystem == "eu.fmasi.parley"' --last 5m

# Save to file (shows in terminal AND writes to file — share for debugging sessions)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug --style compact | tee ~/Desktop/transcriber.log

# Dump recent history to file (useful after a crash — no live stream needed)
/usr/bin/log show --predicate 'subsystem == "eu.fmasi.parley"' --last 30m --style compact > ~/Desktop/transcriber.log

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
| `TranscriberTests` | Test | 2321 tests across 261 suites (Swift Testing, not XCTest) |

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

## Log privacy conventions

Apple's unified logging treats `privacy: .public` interpolations as visible in Console.app, readable via `log show` by other local users, and persisted in `sysdiagnose` tarballs. For a courtroom-grade, airgapped artifact, log call sites follow these conventions (#53):

- **Speaker names / rename mappings / transcript text → `.private`** — redacted as `<private>` for third-party log readers, still visible in a dev `log stream` with the debug profile. Names become PII once a user renames a speaker.
- **Audio file paths / recording-directory paths / session base names / filenames → `.sensitive`** — stronger redaction; these leak the recording-directory layout and session naming.
- **Operational values → `.public`** — counts, byte sizes, durations, chunk indices, booleans, similarity scores/thresholds, format names, and error *categories* stay public so logs remain debuggable. (`error` objects are kept public; audit any that may embed a path.)

Rule of thumb per interpolation: is the value a *name* (→ `.private`), a *path/filename* (→ `.sensitive`), or a *count/status* (→ `.public`)?
