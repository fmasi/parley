# Transcriber — End-to-End Pipeline

## 1. Overview

Transcriber is a macOS menu bar app (macOS 15+, Apple Silicon) that records meetings by capturing two separate audio streams — microphone and system audio (Zoom, Teams, Meet) — in an XPC service. System audio comes from a Core Audio output process tap by default (`system_audio_source: core_audio_tap`, which also captures Continuity/VoIP calls ScreenCaptureKit misses), or from ScreenCaptureKit (`sck`, legacy until #221). During recording, audio is written in time-bounded chunks (`chunk_duration_minutes`, default 30) that are processed in parallel: ASR transcription, speaker diarization, VAD quality filtering, and echo deduplication. At the end of recording each chunk's results are merged into a single time-sorted transcript with globally consistent speaker identities, an AAC stereo archive is written (L=mic, R=system), and an optional LLM summary is fired in the background. The raw audio archive is the canonical evidence store — it is never modified after writing.

---

## 2. Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  RECORDING (continuous)                                         │
│                                                                 │
│  Capture (XPC) — two independent sources:                       │
│    system audio: Core Audio tap (default) or ScreenCaptureKit   │
│                  (system_audio_source=sck, legacy)              │
│      → WavFileWriter → <session>-N.wav                          │
│    mic: MicCaptureSession (AVCaptureSession, #96)               │
│      → AudioConverter → WavFileWriter → <session>-N_mic.wav     │
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
           │  AudioConcatenator.concatenate()  (one .m4a, when merge_chunked_audio)
           │  TranscriptAssembler.assemble() + write JSON
           │  then, after the rename dialog:
           │  MeetingSummarizer.summarizeIfConfigured()  (in the background)
           └─────────────────────────────┘
```

---

## 3. Stage Details

### Stage 1 — Audio Capture

**What it does:** the XPC service captures two separate PCM streams — system audio (all app audio, 48 kHz) and microphone — and writes each to a WAV file. There is no Apple API for a pre-mixed stream. System audio is captured by a Core Audio output process tap (`system_audio_source: core_audio_tap`, the default, `SystemTapSession.swift`), which captures Continuity/VoIP call audio ScreenCaptureKit misses, or by ScreenCaptureKit (`sck`, legacy); the mic is captured independently (`MicCaptureSession.swift`). The XPC service (`AudioCaptureHelperXPC` target) is a separate process embedded in the app bundle; all capture happens there.

**Input:** None (live capture). Output: `<baseName>.wav` (system) and `<baseName>_mic.wav` (mic), both written as Int16 WAV. The tap and the mic are each normalized to 48 kHz mono Int16 via `AudioConverter`; the legacy ScreenCaptureKit stream is pinned to 48 kHz mono by its configuration, and its sample format is detected from the first buffer (Float32 input is converted to Int16 by `WavFileWriter`).

**Key code path:**
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` — `startCapture()`, `rotateChunk()`, `startMicSession()`, `startSystemTap()` (tap) / `buildAndStartStream()` (ScreenCaptureKit)
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` — `appendSystemSamples()` (tap), `appendMicSampleBuffer()` (mic), `stream(_:didOutputSampleBuffer:of:)` → `handleSystemAudio()` (ScreenCaptureKit)

Notes:
- System audio, tap: each buffer (float32 at the output device's rate) → `AudioConverter` normalizes to 48 kHz mono Int16.
- System audio, ScreenCaptureKit: format detected from `CMSampleBuffer` on first frame; `Float32` and `Int16` both handled. The stream registers `.audio` and `.screen` (`.screen` must be registered even for audio-only capture), never `.microphone`.
- Mic audio: any native device rate/channel/format → `AudioConverter` normalizes to 48 kHz mono Int16. The device is chosen by its `AVCaptureDevice.uniqueID` (`startCapture(microphoneDeviceId:)`; nil follows the system default input).
- Callback timing (#247): every tap and mic callback is timed per stage by `IOCycleStats` (queue wait, convert, pad, write, sync, check, total), with clock reads and integer arithmetic only. "check" is everything after the samples' write: the frame counters, the pad-ratio monitor and the exact-zero scan over the buffer (mic: `ExactZeroRunMonitor`; tap: `TapPermissionGuard`'s pass in the service). Each cycle is closed by one clock reading taken as the callback's last act, on both tracks, so the total covers all the callback did: the tap's is closed in the service's sample closure, after the guard pass, not when the handler has written. The tap's IOProc is a block on the helper's shared serial audio queue and the HAL waits for it, so the tap's queue wait (the callback's first line minus the HAL's cycle start, `inNow`) counts against the device's IO budget; the mic has no such timestamp and no queue-wait stage. A callback over 11.35 ms (the tap's IO budget) records an `ioOverrun` event with the stage breakdown in ms (at most one per track per 10 s). The ScreenCaptureKit system path is not timed. The numbers are in `captureStop` and in the log (see "Files beside the recording" and Debugging).

### Stage 2 — Chunk Rotation

**What it does:** A `Timer` fires on a configurable interval (`chunk_duration_minutes`, default 30, minimum 10). On each tick, the XPC service atomically swaps the active `WavFileWriter` pair on the audio callback queue (zero-gap guarantee), finalizes the old writers, and returns the old file paths. The caller receives a `FinalizedChunk` value and dispatches background processing.

**Input:** Running capture. Output: `FinalizedChunk(index, systemPath, micPath, startTime)`.

**Key code path:**
- `TranscriberCore/ChunkRotator.swift` — `rotate()` → `captureClient.rotateChunk()`
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
- `TranscriberCore/SpeechAnalyzerEngine.swift` — `transcribe()` (`@available(macOS 26.0, *)`)

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

**What it does:** Flags local (mic) segments that are mic bleed of the remote side — i.e., the local microphone picked up audio playing through the speakers — and judges each local cluster (speaker label) as echo or kept. A flagged segment is kept in the JSON (`echo: true`) and hidden from TXT, SRT, the summary prompt and the rename samples; nothing is deleted. See Section 4 for a full deep dive.

**Input:** `[LabeledSegment]` (combined local+remote), local speaker embeddings, remote speaker embeddings (evidence only). Output: `EchoDeduplicator.DeduplicationResult(segments, flaggedCount, clusters)` — every input segment, echoes flagged, and one `ClusterVerdict` per local cluster. The chunk keeps the verdicts (`ProcessedChunk.echoClusters`) and records an `echo_flagged` issue with the segment count and, when a cluster was judged echo, an `echo_cluster` issue with the cluster count. It runs once per chunk (and once over the whole file on the single-file path); finalize does not run it again.

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

**Input:** `[ProcessedChunk]` (from `session.json`). Output: `<sessionId>.json` with `metadata` and `segments` keys (and, unless `output_format` is `json`, the `.txt` or `.srt` made from it).

**Key code path:**
- `TranscriberCore/SpeakerReconciler.swift` — `reconcile(chunks:isDualStream:threshold:)`: greedy cosine-similarity matching, EMA embedding update (alpha=0.9); each channel is reconciled in its own `Local` / `Remote` namespace
- `TranscriberCore/TranscriptMerger.swift` — `merge(chunks:speakerMapping:meetingStart:)`: converts chunk-relative offsets to elapsed seconds + absolute `Date`
- `TranscriberCore/TranscriptAssembler.swift` — `assemble(segments:audioPaths:...)` → `write(_:to:)`

Notes:
- Reconciler threshold default: 0.65 cosine similarity.
- A chunk speaker that matches no earlier one gets a new global label that continues the numbering (`Speaker N`), never a raw internal id (#113).
- Merger output is `MergeResult(segments: [MergedSegment], meetingStart, chunkCount)`.

#### Capture provenance and metadata

What the record states about how the recording was captured and processed (spec §7). Every key below is written by `TranscriptAssembler.assemble` unless noted; an unmeasured value is left out, never written as 0.

**`metadata.capture_provenance`** (`CaptureProvenance.asMetadataDictionary`, always present for a recording made by the app):
- `engine`, `route_changes`, `retries`, `recovered`, `anomaly_count`, `quality_anomaly_count`, `system_audio_unrecovered`, `system_permission_denied_confirmed`; `system_format`, `mic_format`, `mic_device`, `system_delivered_seconds`, `system_exact_zero_seconds` when known.
- `events_dropped` — how many diagnostic-ring events were evicted before the stamp was built: the ring's own admission that it does not hold the whole session. Always written (0 when none).
- `local_coverage` / `remote_coverage` — per-track coverage summed over every helper session (`TrackAccounting.asMetadataDictionary`): `status` (`healthy` | `idle` | `neverDelivered` | `compromised`), `expected_seconds`, `delivered_seconds`, `padded_seconds`, `longest_gap_seconds`, `gap_count`, `rebuilds`, and when measured `exact_zero_seconds`, `heartbeat_callbacks` (with `*_is_lower_bound: true` when a measured and an unmeasured helper session were summed), plus `content_anomaly_count`. Each helper session is tallied on its own: a crashed helper's last status pull stands in for the `captureStop` it never wrote, and that helper's real stop, whenever it arrives (a later finalize included), replaces the stand-in, never adds to it (#229). `coverage_incomplete: true` marks every value of a side as a lower bound (the summary then says "at least"): a stop whose seal timed out, or a record built while the recording folder did not answer (built from this process's events alone, so both sides carry the mark). The status is computed once from the coverage and that side's content anomalies, and recomputed (fail closed, never defaulted to healthy) when a stored status is missing or unreadable.
- `reconstructed: true` + `reconstructed_note` when the transcript was rebuilt by a recovery run and these facts come from that run.

In `session.json` the same stamp is persisted under `provenance`, with the per-side status in separate `local_status` / `remote_status` keys.

**`metadata.capture`**:
- `local` / `remote` — the same dictionaries as `capture_provenance.local_coverage` / `remote_coverage`. `capture.remote.status` is the authority on whether the remote side was captured; `dual_stream` is only the capture-time flag that a mic stream was recorded next to it.
- `gaps` — `[{start, end, seconds, reason}]`, periods with no capture: `reason` is `"app relaunch"`, `"sleep"` or `"helper restart"` (a capture-helper crash restarted mid-recording: from its last write to the restart). Written even when no coverage was stamped.

**Processing issues** (`ChunkIssue`, the full code list is in spec §7.2):
- `metadata.processing_issues` — `[{chunk?, code, track?, count?, detail?}]`: every chunk's `issues`, plus the session's own (`session.json` `issues`) and those finalize adds (a skipped merge, unreadable audio lengths). Always written for a tracked (app) session, `[]` when clean; absent from the CLI `run()` path, which does not track issues, so absence never reads as "clean".
- `metadata.processing_issue_count` — content-affecting issues only (`asr_failed`, `diarization_failed`, `vad_failed`, `stream_missing`, `archive_failed`, `session_write_failed`, `chunk_index_collision`, `seed_mismatch`).
- `metadata.processing_problem_chunks` — distinct chunks with a content-affecting issue (a session-level one counts as one more). The completion notice uses this.
- `diarization_too_little_speech` (`track` = the stream) — informational: the stream had words, but the diarizer found too little speech in it to attribute them (FluidAudio's `noSpeechDetected`, NSError code 5: no 10 s window has a speaker active for 20 % of it, so no voice embedding exists). Typically a short last chunk where one side said a few words. Its lines are `Unknown` (`Remote Unknown` / `Local Unknown` on a dual-stream recording); it is not `diarization_failed`, adds no problem chunk and leaves `metadata.diarization` true (#302).

**Echo** (Section 4):
- `metadata.echo_segments_flagged` — how many local segments carry `echo: true`; written only when above 0. `metadata.echo_segments_removed` is the same number under the key's old name, still written for one release (nothing is removed).
- `metadata.echo_clusters` — why each local cluster was or was not judged to be echo, numbers and labels only, never text: `[{track, chunk?, label, segments, matched_segments, seconds, matched_seconds, words, matched_words, share, verdict, embedding_similarity?, matched_remote}]`. One entry per (chunk, local cluster); `chunk` is absent when the dedup ran over the whole file (the single-file / CLI path). `label` and the keys of `matched_remote` (`{remote label: seconds}`) are in the transcript's global speaker namespace — the labels its segments carry at finalize; a later rename does not rewrite them. Only unflagged local segments are counted. `share` = `matched_seconds / seconds`; `verdict` is `"echo"` or `"kept"`; `embedding_similarity` is the cluster's best voice similarity to any remote speaker, evidence only, absent when there is no embedding. Written for every dual-stream transcript (`[]` when there was no local speech); absent when no mic stream was captured. A re-detect of the mic channel replaces the `local` entries with its own — see "Re-detect" below.
- `processing_issues` codes `echo_flagged` (`count` = segments) and `echo_cluster` (`count` = local clusters judged echo in that chunk), both informational.

**Re-detect** (the rename dialog's per-channel speaker count; Section 4, "Re-detect at a stated speaker count"):
- `metadata.speaker_count_local` / `metadata.speaker_count_remote` — how many PEOPLE the channel ended up with: its labels that are neither `Unknown` nor an echo cluster, counted over unflagged lines. Can be 0 (a mic channel that holds only the other side's voice). Absent on a transcript that was never re-detected.
- `metadata.rediarized_channels` — the channels a re-detect has rewritten (`"local"` / `"remote"`), each once, in the order they were first re-detected. Absent on a transcript that never was. A channel listed here no longer carries the labels the pipeline wrote. A rename reads it (#245): a flagged segment is never given to a person by a re-detect — on a listed channel every flagged segment carries the channel's unattributed label, or (an `echo` line of the mic channel) its echo cluster's label (#277, #296), and a channel re-detected by an older build can still hold an earlier diarization's label, which may now be somebody else's — and the rename leaves it alone; on a channel that was never re-detected it is renamed like any other segment, so the JSON never shows two labels for one person. A channel with a `speaker_count_<channel>` counts as listed (builds before this key stamped only the count), a flagged segment with no `source` is renamed only when no channel was re-detected, and a `rediarized_channels` that is not a list of strings protects every flagged segment.
- `metadata.echo_clusters`, after a re-detect of the mic channel: the track's entries are that pass's. No `chunk` (it runs over the whole channel); one entry per RAW cluster the diarizer returned, under the label its lines now carry, so clusters the stated count merged share a label (an echo cluster is never merged, so an `"echo"` entry's label is its own); the unattributed lines are judged as a group and appear as `Local Unknown`, or under the stated speaker's label when a count of 1 folded them in. Lines already flagged `echo` are counted as well as the unflagged ones. No `embedding_similarity`: the transcript holds no embedding for the other channel.
- `processing_issues`, after a re-detect of the mic channel: the track's `echo_flagged` / `echo_cluster` entries are replaced by one of each for the whole channel (no `chunk`), when there is something to report. A transcript with no `processing_issues` key (the CLI path) gets none.
- `metadata.echo_segments_flagged` follows the segments: it is the number carrying `echo: true` after the rewrite.
- `metadata.speaker_names_previous` — the names a re-detect cleared from the channel, kept so a mistaken one is recoverable.

**Storage limit** (#224):
- `metadata.audio_removed` — `{at, files, reason}` when the storage limit (`audio_archive_limit_hours`) deleted some of the audio this transcript lists: `at` the ISO 8601 time of the latest removal, `files` the deleted file names (names only, never paths; a later removal adds to the list), `reason` `"storage_limit"`. Nothing else in the transcript changes: `audio_files` / `audio_paths` still list what there was, and the segments are untouched. Absent while all its audio is there.

**Merged audio and timeline**:
- `metadata.merged_audio` — `{passthrough, gaps_inserted_seconds}` when the chunks were concatenated into one `.m4a` (silence is inserted for inter-chunk gaps > 1 s, up to a 12 h bound).
- `metadata.chunk_durations` / `metadata.chunk_offsets` — per `audio_paths` entry: each file's length, and where the transcript placed it on the meeting timeline (what re-detect needs).
- `metadata.transcript_written_at` — when finalize wrote the transcript (ms precision); late audio is judged from it.
- `metadata.diarization` — true only when a diarizer ran and no chunk has `diarization_failed`. A stream with audio but no transcript segments (a listen-only side) has nothing to label and is not diarized, so it never records one. A stream whose few words gave the diarizer too little speech records `diarization_too_little_speech` instead (above), which does not turn this false. The single-file path (`run()`: the CLI, the legacy recovery) skips a stream with no segments the same way and labels a too-little-speech stream `Unknown`; there any other diarizer failure on a stream that does have segments fails the run.

**Segment flags** — kept in the JSON, hidden from TXT/SRT, the summary prompt and the rename samples: `filtered` (failed the VAD/quality gate), `echo` (mic bleed), `duplicate` (abutting repeat), `time_unknown` (a non-finite time, written as `null`). A rename applies to them too, except on a channel a re-detect has rewritten (`rediarized_channels` above).

**Files beside the recording**:
- `<session>.diag.live.jsonl` — every non-`info` capture event plus the coverage-carrying ones (`captureStop`, `trackCoverage`), appended as it happens, with ms-precision dates (`LiveDiagnosticsLog`). The record's build merges it, deduplicated, into the ring, and so into `<session>.diag.jsonl`. It is deleted only once the session's transcript exists.
- `<session>.diag.coverage.json` — the latest per-track coverage of each helper session, rewritten on every status pull; stands in for the `captureStop` a crashed helper never wrote.
- Callback timing in the record (#247): `captureStop` also carries `remote_io_*` (system) and `local_io_*` (mic): `cycles`, `overruns` (callbacks over 11.35 ms), and for each stage that ran `<stage>_n`, `<stage>_p50_ms`, `<stage>_p99_ms`, `<stage>_max_ms`, with `<stage>` one of `queue_wait`, `convert`, `pad`, `write`, `sync`, `check`, `total`. A stage that never ran (or was not measured: the mic's queue wait) is left out. `ioOverrun` events carry `track`, `total_ms` and the stages of that one callback, and `overruns`, the track's count so far. An `ioOverrun` is an anomaly for the record (the session keeps its `.diag.jsonl`) but not a quality anomaly: `quality_anomaly_count` and the per-side status do not move. A session with no anomaly writes no `.diag.jsonl`; its timing is in the unified log.
- Pre-flight and healing in the record (#314, #317): `clamshellPreflight` (`.info`) holds what the lid-closed microphone pre-flight read and decided — `lid`, `device` (UID or `default`), `transport` (`builtIn`, `bluetooth`, `usb`, `virtual`, `aggregate`, `continuity`, `other`, `unknown`), `builtIn`, `verdict` (`warn`/`none`) and `reason` (`start`; `micSwitch`/`micFollow` when the mic changes while the lid-closed banner shows — a `none` verdict then takes that banner down; every start clears a banner left from before). Being `.info`, it reaches `.diag.jsonl` only in a session with an anomaly; the unified log keeps a `notice` line either way. `tapRecoveryRung` carries `trigger`: what ordered the rung (`stalled`, `neverDelivered`, `listenerStopped`, `rebuildFailed`, `serviceRestarted`, `permissionGrant`, `permissionInsurance`, or the ladder's own `heartbeatMissed` / `slowRetry`).
- `session.json` — besides `chunks` (each with its `issues`, its `echo_segments_flagged` count and its `echo_clusters` verdicts with the chunk's own speaker labels, so a crash-recovered finalize still writes `metadata.echo_clusters`) and `provenance`: `gaps` (`CaptureGap`, as above) and `issues` (`SessionIssue` `{chunk?, issue}`: issues that could not be stored on a chunk, such as a failed write after the chunk was appended, or a session-level issue).

### Stage 10 — Summary Generation

**What it does:** Reads the transcript JSON, builds a prompt with speaker-labeled lines (and source labels in dual-stream mode), calls the configured LLM provider, and writes `<sessionName>-summary.md` alongside the transcript. Called via `summarizeIfConfigured()`, in a background task after the rename dialog closes (so the summary has the real speaker names). It never throws: it returns a `SummaryOutcome`, and a failure is posted as a "Summary Failed" notification (#134).

**Participants are people only (#269).** The prompt's `Participants:` line lists the speakers of the visible lines, minus two kinds of label that are not somebody who attended: the unattributed ones (`Unknown`, `Local Unknown`, `Remote Unknown`), whose lines stay in the prompt as they are, and an echo voice (a label `metadata.echo_clusters` records with verdict `echo`, found through `EchoNotice.Findings` so a renamed one is still recognised). An echo voice's flagged lines are already hidden; its visible lines mix both people's words, so they stay in the prompt with the speaker shown as the channel's unattributed label (`Local Unknown`). The transcript file is not changed. A name the user gave to both the echo voice and another speaker stays a participant, lines and all: those lines cannot be told apart. With no echo voice and no unattributed line the prompt is what it was before.

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

### Cluster Verdict Algorithm

The decision uses time and text only, and is made in three steps (`EchoDeduplicator.deduplicate`, #242):

**Step 1 — per-segment match, speaker-independent.** An unflagged local segment MATCHES when an unflagged remote segment, of ANY remote speaker:

- overlaps it in time by more than 50% of the shorter segment's duration (`echo_temporal_threshold`), and
- repeats its words: word-level Jaccard similarity above 0.7 (`echo_text_threshold`), or one of the two fallbacks below.

A segment already flagged `filtered` or `duplicate` is neither a candidate nor evidence.

**Step 2 — cluster verdict.** The unflagged local segments are grouped by speaker label (one group per diarized local cluster). `share = matched seconds / total seconds`. The cluster is **echo** when `share >= 0.5` and it holds at least 30 s; otherwise it is **kept**.

**Step 3 — flag.**

- In an echo cluster, every matched segment is flagged `echo`, whatever its length. Its unmatched segments stay unflagged under the cluster's label: there is no per-segment voice evidence to move them anywhere.
- In a kept cluster, a matched segment is flagged only when it has 3 words or more. This is what keeps "Yes." said on both sides at the same moment from being flagged, and still catches bleed that diarization folded into the user's own cluster.

The three numbers (0.5, 30 s, 3 words) are constants, not config keys.

**The voice similarity is evidence, not a gate.** Until #242 a third gate required the local cluster's speaker embedding to score above 0.8 against a remote speaker. That gate was all-or-nothing per cluster: on a real speaker-mode call the bleed cluster scored 0.68 (speaker playback into a far-field mic changes a voice), so none of its 146 segments were flagged, although 91% of its duration matched concurrent remote speech; the user's own cluster never exceeded 5% on the same measure. Bleed that minority absorption folds into the user's cluster carries the user's embedding and fails any such gate by construction. The similarity is now computed, written to `metadata.echo_clusters[].embedding_similarity` and logged, and decides nothing. `echo_embedding_threshold` is accepted and ignored.

**What is recorded.** One verdict per (chunk, local cluster) in `metadata.echo_clusters` (see "Echo" under the transcript metadata above), an `echo_cluster` processing issue for each chunk with an echo cluster, and one `.info` log line per verdict with public numbers only (the label is `.private`).

**Known limits.**
- The dedup runs per chunk, before cross-chunk reconciliation: a cluster is judged within its chunk, and there is no second pass at finalize.
- Minority absorption runs before it, so a bleed cluster under 5% of a chunk is absorbed into the user's cluster and never judged as a cluster; only the per-segment rule (3 words or more) sees it.
- The text gates and the 3-word rule count whitespace-separated words, so they do little for a language written without spaces.

### Re-detect at a stated speaker count

The rename dialog lets the user state how many people were on a channel and re-detect it (`TranscriptRediarizer.rediarize`). It diarizes the channel's audio again, relabels the transcript's segments and never re-runs ASR: the number of segments and every text stay what they were.

A stated count is about people. With the far side on loudspeakers the diarizer finds its voice as a cluster of its own on the mic channel, and "one speaker on this side" used to merge that cluster into the user: on a real call about 2,400 of the other participant's words took the user's name (#243). So on the mic channel the echo check runs **before** the count is enforced:

1. The channel's segments are labelled with the diarizer's RAW clusters. With no word timings at re-detect this is one segment in, one out.
2. `EchoDeduplicator.deduplicate` judges those clusters against the other channel's unflagged segments — the same rule as at transcription (above), with the default thresholds.
3. `SpeakerCountEnforcer.enforce(_:to:keeping:)` enforces the count on the other clusters. A cluster judged echo is never merged away, never merged into and not counted.
4. The segments are labelled with the result:
   - a line of an echo cluster carries that cluster's own label; its matched lines are flagged `echo`, its unmatched lines are not. Nothing of it is given to the stated speaker, and at a count of 1 unattributed speech is never folded into it;
   - in any other cluster a matched line of 3 words or more is flagged `echo` and takes the channel's unattributed label (`Local Unknown`). It is never relabelled to a stated speaker, and it does not keep the label it had before the re-detect either (#277): after a repair that label is the user's, and the words are the other side's. A 1–2-word match is an ordinary line.
5. The metadata is rewritten as listed under "Re-detect" in the transcript metadata above; `Outcome` reports `speakerCount` (people), `segmentsRelabeled` (unflagged lines labelled), `echoClusters` and `echoFlagged`.

What follows from that:

- **It never refuses.** Asking for 1 on a channel with the user and an echo voice gives one person and one echo cluster; a mic channel that is nothing but echo gives 0 people.
- **Lines already flagged `echo` count as evidence.** The pipeline flags an echo cluster's matched lines when it transcribes; judged on the unmatched rest alone, that cluster would look like a person and be merged. They keep their flag (a re-detect never removes one) and take the cluster's new label, since speaker numbers are positional and the old one may now be somebody else's. An already-flagged line that falls in no echo cluster this time takes the unattributed label for the same reason (#277), whether or not the check still finds its match. A line flagged `filtered` or `duplicate` is neither evidence nor relabelled by a cluster: it keeps its flag and takes the unattributed label (#296).
- **Every flagged line on the re-detected channel is unattributed (#296).** `filtered`, `duplicate`, `echo` or no usable time, on either channel, whether or not the echo check ran: it keeps its flag and takes the channel's unattributed label (`Local Unknown` / `Remote Unknown`). The one exception is an `echo` line the check puts in an echo cluster, which carries that cluster's label. The other channel's lines are untouched.
- **It repairs a transcript that was merged this way.** Re-detecting it again finds the echo voice in the raw clusters and takes it back out.
- **Speech the diarizer gave no turn to is judged as a group** (`Local Unknown`). When that group is echo, a count of 1 does not fold its unmatched lines into the user.
- **One blended cluster** (the diarizer honoured the count): there is nothing to keep out; only the per-segment rule applies, and the lines it flags are unattributed.
- **The unattributed label is nobody.** A line flagged outside an echo cluster adds no person to `speaker_count_<track>`, no entry to `echo_clusters`, no row to the rename dialog and no participant to the summary; a rename does not reach it.
- **The other channel is not checked.** The deduplicator judges mic clusters against system audio and has no answer to the reverse, so re-detecting the remote channel does what it always did, except that its flagged lines take `Remote Unknown` (#296). One consequence: the keys of `echo_clusters[].matched_remote` are the remote labels at the time of the check, and a later re-detect of the remote channel does not rewrite them.
- **If the raw labelling is ever not one-to-one** the check is skipped (logged as an error) and the re-detect is the unguarded one: a relabel must never lose or misplace words.

### What the user is told (#244)

A second voice on the mic side used to be listed as "Local Speaker 2" with nothing to explain it. Three places now say what the echo check recorded. All three read the transcript's metadata (`echo_clusters`, `echo_segments_flagged`, `speaker_count_<track>`, `speaker_names`) and recompute nothing; the copy and the counts are built by `EchoNotice` (TranscriberCore), the views only show them.

- **Speaker card** (rename dialog) of a label with at least one `"echo"` verdict: "Looks like the other side's voice through your loudspeakers: N of M lines (P% of its speaking time) match <remote label(s)> at the same time and are marked as echo. The other K lines stay under this label." The numbers are the label's `echo_clusters` entries summed (one per chunk); P is `matched_seconds / seconds`, the measure the verdict is taken on. A label whose entries are all `"kept"` gets no notice.
- **Re-detect row**: before, "The count is people only, not the echo voice. Re-detect checks for echo again and keeps an echo voice separate; its matched lines stay marked as echo." After, the outcome: "1 speaker found · 1 echo voice kept separate · N lines marked as echo · R lines relabeled" (without echo it reads as before: "2 speakers found · 84 lines relabeled"). The stepper pre-fills the number of PEOPLE on the channel: its rows that are not an echo voice, never below `speaker_count_<track>`, never below 1.
- **Completion notice** of a recording with an echo voice: the title is "Transcription Complete — echo marked" (last in the title's precedence: every problem is said first), and the body adds "it looks like part of the other side's voice came through your microphone, and N lines are marked as echo (headphones avoid this)", N being `echo_segments_flagged`. Lines flagged in a cluster that was kept (the 3-word rule) do not make a notice.

What follows from reading only the metadata:

- **Labels, not names.** The copy names the labels `echo_clusters` holds ("Remote Speaker 1"), which a rename does not rewrite. The echo voice's own row is still found after a rename, through `speaker_names` (followed as a chain, since each rename is keyed by the label current at the time).
- **"Looks like", not "is".** The check sees lines on this side that repeat the other side's words at the same moment. The mirror case (this side's voice coming back on the other side's track) gives the same numbers.
- **A label can be echo in one chunk and too short to judge in the next.** All its entries are summed; in the chunk where it was kept a matched line of one or two words is not flagged, so N can exceed the lines actually marked by those few.
- **After a re-detect of the other channel** the remote labels in `matched_remote` are the ones at the time of the check (see above), and the card names those.

### Windowed Comparison and Containment Fallback

Segment boundaries from independent ASR runs may not align. Two fallbacks handle this:

1. **Containment check:** If Jaccard fails but `textContainment(local, remote) > 0.7` (most words from the short local segment appear in a longer remote segment), the local segment matches. This handles short local excerpts of long remote utterances.

2. **Window concatenation:** If multiple remote segments overlap with the local segment, their texts are concatenated and Jaccard is re-evaluated against the window. This handles one long local segment that covers what the remote side split into several shorter segments — also when those belong to different remote speakers, each of which is then recorded in `matched_remote`.

### LLM Text-Level AEC in Summary Prompt

When `dualStream = true`, the summary prompt receives source labels ("Local" / "Remote") on each transcript line and includes a hint instructing the LLM to treat repeated identical content across streams as echo and to use only the remote stream's version for attribution. This is a text-level fallback for any echoes the cluster verdict and the per-segment rule leave unflagged.

### Courtroom Safety

- The raw WAV files and the AAC archive are **never modified** after writing.
- Echo is flagged, never removed: the segments are kept, flagged `echo: true`, and their text and number never change. `metadata.echo_segments_flagged` counts them (`metadata.echo_segments_removed` is the same count under the old name, for one release), and `metadata.echo_clusters` records the numbers behind each cluster's verdict.
- `metadata.dual_stream` is the capture-time flag (a mic stream was captured next to the remote one). It does not say the remote side delivered audio: `metadata.capture.remote.status` is the authority for that.
- The transcript JSON is the processed record; the `.m4a` is the raw evidence. The two are independent.
- The storage limit (`audio_archive_limit_hours`) deletes `.m4a` archives, never a transcript (#224). The pass after a recording's transcript is written weighs the whole recordings tree — every `yyyy-MM-dd` day folder of the configured recording directory, a day folder that is a symbolic link not followed — and deletes the oldest Parley archive first (`HHmmss[-…].m4a` directly in a day folder; nothing else), never the recording just made nor a session that still has state in its folder (#230), and no more than it needs. It runs after the record is written, on the folder's mutation queue, bounded by its deadline; the completion notice waits for it with the read's bound and adds "Removed the audio of N older recordings to stay within the storage limit; transcripts are kept." A chunk's pass during the recording weighs only its day folder. Every deleted file is recorded in the transcript that listed it (`metadata.audio_removed`); a file no transcript lists, or a transcript that cannot be rewritten, is logged and the deletion stands.
- `AudioArchiverError.verificationFailed` is thrown (and WAVs are preserved) if the output archive is empty, has no audio tracks, or its duration does not match the source's.

### Validation

The echo benchmark in `docs/benchmarks/` (2026-04-06) measured the earlier algorithm, before the cluster verdict (#242). It has not been re-run on the rule described here, so its numbers do not describe the current behaviour.

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

### Background, never blocking the transcript

`MeetingSummarizer.summarizeIfConfigured()` is `async` and never throws: it returns a `SummaryOutcome` (`skipped`, `succeeded`, `failed(reason)`, `cancelled`). The app runs it in a detached task once the rename dialog closes (`MenuView.autoSummarize`), after the transcript is on disk, and posts a "Summary Failed" notification on `failed` (#134).

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

# Via dev.py (builds a release build, installs, launches app + tails log automatically)
python3 scripts/dev.py --debug

# Callback timing (#247): one line per track at each Stop, logged at notice level so `log show` keeps it
/usr/bin/log show --predicate 'subsystem == "eu.fmasi.parley" AND eventMessage CONTAINS "IO cycles"' --last 1h --style compact
```

---

## 7. Packaging

### Package.swift — SPM Workspace

The app's 4 library/executable targets + 1 test target:

| Target | Type | Description |
|---|---|---|
| `TranscriberApp` | Executable | SwiftUI menu bar app (`@main`) |
| `TranscriberCore` | Library | All business logic (engines, pipeline, CLI) |
| `AudioCaptureHelperXPC` | Executable | XPC service for audio capture |
| `AudioCaptureProtocol` | Library | `@objc` XPC protocol + service name constant |
| `TranscriberTests` | Test | Swift Testing, not XCTest. Links `TranscriberCore` and `VerifyEdSignatureCore` only. The current test count is in the [README](../README.md) |

`Package.swift` also defines `VerifyEdSignatureCore` and `VerifyEdSignature`, a release tool that checks the update feed's signature.

Test path: `SwiftTests/TranscriberTests/`.

### Plists

- `packaging/Info.plist` — app bundle metadata: `CFBundleIdentifier: eu.fmasi.parley`, `LSUIElement: true` (menu bar only), TCC usage descriptions (microphone, screen recording, system audio recording, calendar)
- `packaging/AudioCaptureHelper-Info.plist` — XPC service plist: `CFBundleIdentifier: eu.fmasi.parley.capture-helper`, `ServiceType: Application`, and the microphone, screen recording and system audio recording usage descriptions

### Build & Run

```bash
# Build everything
swift build

# Run tests (serially: --no-parallel is load-bearing, see AGENTS.md; `just test` runs this with the fixture guard)
swift test --no-parallel --filter TranscriberTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

### scripts/dev.py

Developer iteration CLI. Key flags:

| Flag | Action |
|---|---|
| (default) | Kill app, build a **release** build, install bundle, launch |
| `--debug-build` | Build the unoptimised debug configuration instead (faster to compile). For the inner loop only: not for real meetings or for timings (gotcha 84) |
| `--debug` | Launch app + tail unified log (subsystem filter). Nothing to do with the build configuration |
| `--reset-tcc` | Reset the app's TCC grants for Microphone, Screen Recording, Calendar and the Documents folder (`tccutil`). System Audio Recording is not in the list |
| `--build` | Build only, into `dist/`: nothing is killed, installed or launched. `just build` runs `--build --debug-build` |
| `--kill --launch` | Relaunch the installed app without building |

`dev.py` prints the configuration it built and installed, and `package_app.sh` prints it next to the
version (`package_app.sh` alone still defaults to debug; `--release` is what `dev.py` and
`scripts/release.sh` pass). The capture helper writes the configuration into each recording's
`captureStart` diagnostic event as `"build"` (`TranscriberCore/BuildConfiguration.swift`, #271).

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
  --output-dir <path>       Output directory, created if missing (default: same as input)
  -f, --format <fmt>        Output format: json (default), txt, srt
  --no-diarize              Skip speaker diarization
  --engine <id>             Engine override: fluid_audio, speech_analyzer
  --split                   Force L/R channel split for stereo AAC (L=mic, R=system)
  --no-split                Force single-stream processing (external recordings)
  --debug                   Stream the unified log to stderr while it runs
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

### `download-models`

Download the diarization and VAD models without a UI (CI uses it, so the ground-truth diarization tests do not skip).

```
Parley download-models
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
