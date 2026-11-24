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
           │  │    (mic_echo_cancel on: the mic is cleaned
           │  │     against the system WAV first, see Stage 3a)
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

### Stage 3a — Mic Echo Cancellation (optional, #342)

**What it does:** With `mic_echo_cancel` = `"on"` (config.json only; default `"off"`), `ChunkProcessor.cancelMicEcho` runs alongside the system-audio ASR pass, after the system WAV is known and before the mic pass. It cancels the speaker echo in the chunk's mic WAV with the system WAV as the far-end reference: LocalVQE v1.4-AEC, upstream's adaptive filter in C++ plus a Core ML residual mask, then `NearEndGuard`, which gives the raw mic back in any 100 ms frame where the far end is silent and the cleaned mic is 20 dB or more quieter than the raw one (a word the canceller removed is silent loss; echo left behind is only visible). Only ASR and diarization of the local stream read the cleaned copy, a scratch WAV deleted afterwards. The raw mic stays the archive and the speaker-sample source, and `EchoDeduplicator` (Stage 7) still runs and flags what is left.

**The echo delay is estimated over the whole chunk first (#361).** Upstream's filter estimates the loudspeaker-to-mic delay online and locks it for good 3.5 s in; on a call's opening it can lock on the wrong value and the whole chunk keeps its echo (gotcha 101). `cancelEcho` therefore runs in three passes over the files: decode both to 16 kHz scratch WAVs while `LocalVQEEchoCanceller.DelayEstimate` runs upstream's whole-signal estimate (`daf_prime_delay`, about 2.7 s for a 30-minute chunk) a block at a time; filter at that frozen delay; apply the guard. A shift over 500 ms (8000 samples) is never taken: the filter then runs at 0, whose 1.024 s window still holds any real speaker delay. Re-detect's in-memory path estimates the same way.

**A cancellation that removed nothing is recorded, not passed off as a success (#361).** `EchoReduction` measures two things per chunk over 100 ms frames: the *lift*, how far the raw mic rises above its own floor (its 10th percentile while the far end is silent, below -55 dBFS) while the far end talks (reference at or above -40 dBFS) — 27-32 dB on loudspeakers, about 0 dB with headphones — and the *reduction*, the median of raw minus cleaned over the far-end frames where the mic is at or above -50 dBFS — about 45 dB when it works, 0 dB when it fails. With a lift of 15 dB or more and a reduction under 10 dB the chunk gets `echo_cancel_ineffective` (`detail`: both figures and the delay), and the completion notice says "echo not removed". Each needs 30 s of the far end talking (and the lift 30 s of it silent); less is not judged. Both are medians: a user talking over the far end for more than half of its speech would read as an echo not removed.

**Failure is never a missing local transcript.** If the cancel throws, or the build has no model, the raw mic is used and the chunk gets `echo_cancel_failed` (informational, not content-affecting). Frames the guard restored are counted in `echo_cancel_reverted` (`count` = frames, `track` = `local`).

**Record:** per chunk, a `mic_echo_cancel` entry in `session.json` (`engine`, `model_sha256`, `frames_reverted`, `seconds`, and since #361 `delay_samples`, `erle_db`, `far_end_lift_db`, each absent when unknown); in the transcript, `metadata.mic_echo_cancel` = `{chunks, chunks_failed, chunks_ineffective, seconds, frames_reverted, engine, model_sha256, per_chunk}`, absent when it never ran. `per_chunk` (#365) lists each cancelled chunk's place and measure (`chunk`, `start` on the transcript's timeline, `seconds`, `far_end_lift_db`, `erle_db`), so a re-detect's echo check knows where the mic heard the far end.

**Re-detect:** `TranscriptRediarizer` on the mic channel of a transcript that has `metadata.mic_echo_cancel` cancels each archive's mic side again, with its system side as reference, before diarizing. With the whole-chunk delay estimate this re-cancels a chunk recorded before #361 whose echo was left in; the re-detect records no new `mic_echo_cancel` figures.

**Key code path:**
- `TranscriberCore/MicEchoCanceller.swift`, `LocalVQEEchoCanceller.swift`, `NearEndGuard.swift`
- `TranscriberCore/ChunkProcessor.swift` — `cancelMicEcho(chunkIndex:micURL:systemURL:)`; `TranscriptionRunner.micEchoCancelDictionary` for the CLI/finalize metadata
- Model: `ThirdParty/LocalVQE-CoreML` (0.7 MB, Apache-2.0), bundled by `package_app.sh`, every file checked against `MANIFEST.json` (SHA-256) at load. No download.
- Log: `mic echo cancelled (… s of audio in … s, delay N samples, X dB removed of an echo Y dB above the mic's floor, … frames given back to the raw mic)`; `mic echo cancellation removed next to nothing (…)` on an ineffective chunk

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

**Input:** WAV file URL, read a block at a time to 16 kHz by `VadSpeechMap.samples16k` (never `VadManager.process(URL)`, which decodes the whole file at its own rate first: gotcha 98). Output: `[SpeechRegion](start, end, probability)` or `nil` if model not cached (graceful degradation).

**Key code path:**
- `TranscriberCore/VadSpeechMap.swift` — `analyze(audioPath:)` → `samples16k` → `mgr.process(samples)` → chunk duration from `VadManager.chunkSize / VadManager.sampleRate`

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

**Minority absorption, after the echo check (#65, #249).** Before labels are assigned, `StreamLabeling.withDiarization` absorbs a cluster holding under `diarization_min_speaker_share` (5%) of the stream's speech into the dominant cluster, when one holds at least half (`DiarizationCleanup`). On the mic stream the raw clusters are first judged for echo: when absorption would take any cluster, the mic's segments are labelled with the diarizer's raw clusters and `EchoDeduplicator` (Stage 7's rule, thresholds and other channel: the system stream's lines, transcribed just before) judges them. A cluster it calls echo is never absorbed and never absorbs another; when it holds the most speech no person on the channel is dominant and nothing is absorbed. It still counts in the total, so it never makes absorption take a cluster it would leave alone without it. With no cluster to absorb, or no echo cluster, the result is what it was before. These verdicts are not kept: Stage 7 judges the final clusters, the spared echo cluster among them, and that is the record. Their log lines start "Pre-absorption check (not the record): " so they do not read as the record's. Before #249 a bleed cluster under 5% (the user switched to headphones a minute into the chunk: 47 s of a 21-minute chunk) was folded into the user and never judged as a cluster. The system stream has no other channel to be judged against and is absorbed as before; a stated speaker count (re-detect) turns absorption off altogether.

One consequence: a mic stream whose echo cluster is now kept has two clusters, so the merge step's fold of `Unknown` lines into a channel's single speaker (`SpeakerAssignment.resolveUnknownsWithinSource`, which needs the diarizer to have found exactly one) no longer applies to it. Those lines stay `Local Unknown` rather than going to the user: some of them may be the other side.

### Stage 7 — Echo Deduplication

**What it does:** Flags local (mic) segments that are mic bleed of the remote side — i.e., the local microphone picked up audio playing through the speakers — and judges each local cluster (speaker label) as echo or kept. A flagged segment is kept in the JSON (`echo: true`) and hidden from TXT, SRT, the summary prompt and the rename samples; nothing is deleted. See Section 4 for a full deep dive.

**Input:** `[LabeledSegment]` (combined local+remote), local speaker embeddings, remote speaker embeddings (evidence only), the chunk's far-end lift (`ProcessedChunk.farEndLift`, #374: measured from the raw mic's levels on every dual-stream chunk beside the system stream's ASR, per 120 s window every 30 s, with cancellation on or off; the canceller's whole-chunk measure only when the levels cannot be read; about 2 s per 30-minute chunk in a debug build) and `echo_local_lead_margin_seconds` (#252). Output: `EchoDeduplicator.DeduplicationResult(segments, flaggedCount, clusters)` — every input segment, echoes flagged, and one `ClusterVerdict` per local cluster. The chunk keeps the verdicts (`ProcessedChunk.echoClusters`) and records an `echo_flagged` issue with the segment count and, when a cluster was judged echo, an `echo_cluster` issue with the cluster count. It runs once per chunk (and once over the whole file on the single-file path); finalize does not run it again.

**Key code path:**
- `TranscriberCore/EchoDeduplicator.swift` — `deduplicate(segments:localSpeakerDatabase:remoteSpeakerDatabase:...)`
- `TranscriberCore/FarEndLift.swift` — `FarEndLift.measure(micURL:systemURL:)`: both WAVs at 16 kHz a 4 s block at a time, RMS per 100 ms frame, `EchoReduction.farEndLift` (#374)

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
- `build` — `debug` or `release`: which kind of build captured the recording, from the helper's `captureStart` (#271, #295), so a clean recording, which keeps no `.diag.jsonl`, says it too. Both, comma-joined, when the record's starts disagree; only the starts the record holds (a crashed helper's undrained start is not among them); left out when none carried it.
- `events_dropped` — how many diagnostic-ring events were evicted before the stamp was built: the ring's own admission that it does not hold the whole session. Always written (0 when none).
- `local_coverage` / `remote_coverage` — per-track coverage summed over every helper session (`TrackAccounting.asMetadataDictionary`): `status` (`healthy` | `idle` | `neverDelivered` | `degraded` | `compromised`), `expected_seconds`, `delivered_seconds`, `padded_seconds`, `longest_gap_seconds`, `gap_count`, `rebuilds`, and when measured `exact_zero_seconds`, `exact_zero_unproven_seconds`, `heartbeat_callbacks` (with `*_is_lower_bound: true` when a measured and an unmeasured helper session were summed), plus `content_anomaly_count`. `exact_zero_unproven_seconds` (tap sessions only, #333) is the part of `exact_zero_seconds` nobody can vouch for: the zeros before the session's first non-zero audio, and every zero run during which a denied, undetermined or unverifiable permission answer (or a rebuild made with one) withdrew the proof, counted from the run's first frame until non-zero audio returns. The rest is silence on a tap that had delivered real audio, with its grant never in question during it; a call app renders that as exact zeros whenever the other side is quiet. It shares `exact_zero_seconds_is_lower_bound`, a crashed helper's stand-in carries it too, and it is absent on SCK, on the mic and in records made before it existed; the status never reads it. The verdict does (#333): the summary header and banner judge the remote side's silence on it when it is there, and on `exact_zero_seconds` when it is not (an older record keeps its wording). At least 15 s and 10 % of the delivered seconds of unproven zeros reads "uncertain" (or the denial's lines when the denial was confirmed), on a `healthy` or `degraded` side too; a line that is a verdict on silence states the number it was judged on, and the "; N s of it was digital silence" clause of a partly captured or compromised side states the total, then ", M s of which could not be confirmed" (a side lost to a confirmed denial part-way: "N s of D s was digital silence, M s of it after the permission was lost"). For a `healthy` or `degraded` side that rule is one function, `TrackAccounting.uncertainSilenceSeconds`, read by the summary and by the completion notice alike: the notice then reads "Transcription Complete — remote audio uncertain" with "remote audio: N s of silence could not be confirmed" ("at least N s" when `exact_zero_seconds_is_lower_bound` is set) (below a side not or partly captured, above the brief glitch and the anomaly count). A `healthy` side that was all silence keeps its neutral line and a plain notice. After a confirmed denial the zeros are unproven again, so those lines state them as well. Whether the whole side was silence ("only digital silence was received", "not captured" after a denial) and the `idle` rule still read the total. The remote side also carries `rate_drift` when the tap drifted (#308): one entry per `rateDrift`, with `healed`, `detected_offset_seconds` (from the first `captureStart`), `offset_seconds` (the earliest onset: where the wrong-rate window starts), `healed_after_seconds` (detection → the first frames of the rebuild made to remediate it: the first `restartInPlace` "rate drift remediation" carrying `attempt` after the drift and before the next one), and `affected_seconds` with `affected_seconds_is_upper_bound: true`; a drift whose onset the helper did not measure says `onset: "unknown"` and claims no window. A drift no rebuild healed ends at the capture stop (#333): `healed: false`, `ended_by: "stop"`, `stopped_after_seconds` (detection → the helper's own `captureStop`), and `affected_seconds` from the onset to the stop — the user stopped before the rebuild's first frames, or the remediation budget was spent. Only when the record shows it: the stop is the helper's own (never a crashed helper's stand-in), no later drift comes before it, and no `captureStart` lies between. A drift with nothing to end it claims no window. A window that ended (healed, or at the stop) also carries `after_last_speech`, answered when the transcript is assembled (`TranscriptAssembler.answeringAfterLastSpeech`): `true` when the window starts more than the margin after the end of the remote side's last transcript segment (every segment, a flagged one included), `false` when it does not; the windows after the last speech leave the bound's sum while they total no more than the 15 s bound themselves, so the side's `status` can be lifted from `compromised` to `degraded` there (never further). The margin is 1 s plus the first-frame latency: a drift's offset is wall-clock from the first `captureStart`, but a segment's time counts from the recording's sample 0, the first buffer of either track, so every transcript time reads early by (earliest `firstFrames` − `captureStart`). Absent when it was not judged: the record is not one helper session (more than one `captureStart`, more than one tallied helper, a recovery or a capture gap), it holds no `firstFrames`, or the remote side has no segment, or one with no usable time. `session.json`'s provenance keeps what this needs in three optional keys, `capture_starts`, `helper_sessions` and `first_frames_after_start_seconds`; they are not written to the transcript. `degraded` means every content anomaly on the side is such a drift, healed or ended by the stop, and their `affected_seconds` sum to no more than `RateDriftWindow.healedBoundSeconds` (15 s), with no coverage deficit; the anomaly still counts in `content_anomaly_count` and `quality_anomaly_count`, and the completion notice says "brief capture glitch" / "remote audio briefly affected" instead of "capture compromised". A `degraded` side whose every window ended (healed, or `ended_by: "stop"`) with `after_last_speech: true` is recorded, not announced (`RateDriftWindow.unannounced`, #333): the drift touched nothing anybody said. The status, the windows and both counts stay as written; the summary has no header line and no banner for it, and the completion notice neither names the side nor counts those drifts (it reads `quality_anomaly_count` minus them). The summary line of a side with a stop-ended window says "before the recording stopped", never "before Parley recovered". Each helper session is tallied on its own: a crashed helper's last status pull stands in for the `captureStop` it never wrote, and that helper's real stop, whenever it arrives (a later finalize included), replaces the stand-in, never adds to it (#229). `coverage_incomplete: true` marks every value of a side as a lower bound (the summary then says "at least"): a stop whose seal timed out, a crashed helper's stand-in (its last status pull can trail what it captured, #295; its real stop, when it arrives, takes the mark away with it), or a record built while the recording folder did not answer (built from this process's events alone, so both sides carry the mark). The status is computed once from the coverage and that side's content anomalies, and recomputed (fail closed, never defaulted to healthy) when a stored status is missing or unreadable.
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
- `metadata.echo_clusters` — why each local cluster was or was not judged to be echo, numbers and labels only, never text: `[{track, chunk?, label, segments, matched_segments, seconds, matched_seconds, words, matched_words, share, verdict, embedding_similarity?, matched_remote, median_lag_seconds?, lag_pairs?, reason?}]`. One entry per (chunk, local cluster); `chunk` is absent when the dedup ran over the whole file (the single-file / CLI path). `label` and the keys of `matched_remote` (`{remote label: seconds}`) are in the transcript's global speaker namespace — the labels its segments carry at finalize; a later rename does not rewrite them (the card resolves them through `speaker_names` and the remote lines, #270), and a re-detect of the remote channel remaps or drops the `matched_remote` keys it renumbered. Only unflagged local segments are counted. `share` = `matched_seconds / seconds`; `verdict` is `"echo"` or `"kept"`; `embedding_similarity` is the cluster's best voice similarity to any remote speaker, evidence only, absent when there is no embedding. `median_lag_seconds` (#252) is the median over the matched near-identical lines (not containment or joined-window matches) of local start minus the start of the remote line each copies (positive: the local side trails, as an echo does), over `lag_pairs` lines, both absent without a matched line; `reason` is `"local_leads"` when that median puts the local side ahead by more than `echo_local_lead_margin_seconds` (the cluster and its lines are then kept), absent otherwise. Verdicts written before #252 have none of the three. Written for every dual-stream transcript (`[]` when there was no local speech); absent when no mic stream was captured. A re-detect of the mic channel replaces the `local` entries with its own — see "Re-detect" below.
- `processing_issues` codes `echo_flagged` (`count` = segments) and `echo_cluster` (`count` = local clusters judged echo in that chunk), both informational.

**Mic echo cancellation** (#342, Stage 3a):
- `metadata.mic_echo_cancel` — `{chunks, chunks_failed, chunks_ineffective, seconds, frames_reverted, engine, model_sha256, per_chunk}`: chunks cancelled, chunks that fell back to the raw mic, chunks cancelled that removed next to nothing (#361, also counted in `chunks`), seconds of mic audio cleaned, frames `NearEndGuard` restored; `per_chunk` (#365): per cancelled chunk `{chunk, start, seconds, far_end_lift_db, erle_db}` (`start` in seconds on the transcript's timeline; each dB value absent when too little far-end speech was there to measure). Absent when `mic_echo_cancel` was off or never ran; `per_chunk` is absent from transcripts written before #365. Since #374 echo dedup and re-detect read the lift from `metadata.acoustic_coupling` (below); `mic_echo_cancel.per_chunk` is still written, and read only when `acoustic_coupling` is absent (a transcript of the #365 build).

**Far-end lift** (#374, Stage 7):
- `metadata.acoustic_coupling` — `{per_chunk, uncoupled_below_db}`: per measured dual-stream chunk `{chunk, start, seconds, far_end_lift_db?, windows}` (`start` in seconds on the transcript's timeline; `far_end_lift_db` the whole chunk's, evidence only; `windows` = `[{start, seconds, far_end_lift_db?}]`, 120 s every 30 s, the last ending at the chunk's end, starts on the transcript's timeline: what rule (a) judges by; each `far_end_lift_db` absent when too little far-end speech was there to measure), written with `mic_echo_cancel` on or off; `uncoupled_below_db` is the line rule (a) judged by (15). Absent when nothing was measured (no chunk had a mic and a far end with frames). In `session.json` each chunk keeps `far_end_lift` = `{seconds, far_end_lift_db?, windows}` (windows on the chunk's timeline); a chunk written before #374 falls back to its `mic_echo_cancel` record, judged whole; an entry without `windows` is judged whole. A transcript with neither key is unmeasured: rule (a) holds nothing back, as before #365, never as "headphones".
- `processing_issues` codes `echo_cancel_failed` (`track` = `local`, `detail` = why), `echo_cancel_ineffective` (`detail` = reduction, lift and delay, #361) and `echo_cancel_reverted` (`count` = frames), all informational: none counts in `processing_issue_count`. The first two make the completion notice say "echo not removed".

**Re-detect** (the rename dialog's per-channel speaker count; Section 4, "Re-detect at a stated speaker count"):
- `metadata.speaker_count_local` / `metadata.speaker_count_remote` — how many PEOPLE the channel ended up with: its labels that are neither `Unknown` nor an echo cluster, counted over unflagged lines. Can be 0 (a mic channel that holds only the other side's voice). Absent on a transcript that was never re-detected.
- `metadata.rediarized_channels` — the channels a re-detect has rewritten (`"local"` / `"remote"`), each once, in the order they were first re-detected. Absent on a transcript that never was. A channel listed here no longer carries the labels the pipeline wrote. A rename reads it (#245): a flagged segment is never given to a person by a re-detect — on a listed channel every flagged segment carries the channel's unattributed label, or (an `echo` line of the mic channel) its echo cluster's label (#277, #296), and a channel re-detected by an older build can still hold an earlier diarization's label, which may now be somebody else's — and the rename leaves it alone; on a channel that was never re-detected it is renamed like any other segment, so the JSON never shows two labels for one person. A channel with a `speaker_count_<channel>` counts as listed (builds before this key stamped only the count), a flagged segment with no `source` is renamed only when no channel was re-detected, and a `rediarized_channels` that is not a list of strings protects every flagged segment.
- `metadata.echo_clusters`, after a re-detect of the mic channel: the track's entries are that pass's. No `chunk` (it runs over the whole channel); one entry per RAW cluster the diarizer returned, under the label its lines now carry, so clusters the stated count merged share a label (an echo cluster is never merged, so an `"echo"` entry's label is its own); the unattributed lines are judged as a group and appear as `Local Unknown`, or under the stated speaker's label when a count of 1 folded them in. Lines already flagged `echo` are counted as well as the unflagged ones. No `embedding_similarity`: the transcript holds no embedding for the other channel.
- `processing_issues`, after a re-detect of the mic channel: the track's `echo_flagged` / `echo_cluster` entries are replaced by one of each for the whole channel (no `chunk`), when there is something to report. A transcript with no `processing_issues` key (the CLI path) gets none.
- `metadata.mic_echo_cancel` is left as the pipeline wrote it: a re-detect of the mic channel cancels the archive's mic again (from the AAC, so close to, not identical with, the first pass) but records nothing new.
- `metadata.echo_segments_flagged` follows the segments: it is the number carrying `echo: true` after the rewrite.
- `metadata.echo_matched_remote_current` — `true` once the keys of `echo_clusters[].matched_remote` are known to be the remote labels the lines carry (#270): stamped when a remote re-detect remaps them and when a mic re-detect writes the record again. A transcript whose remote channel was re-detected (`rediarized_channels` holds `"remote"`, or an older build's `speaker_count_remote`) without it was re-detected by a build that left the keys as they were: they are labels of a clustering that no longer exists, so the card quotes none of them and a later remote re-detect drops them.
- `metadata.speaker_names_previous` — the names a re-detect cleared from the channel, kept so a mistaken one is recoverable. The rename dialog puts back in its fields the names the speech carries (#359, "Names after a re-detect" below); they reach `speaker_names` only when the user saves.

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
- Pre-flight and healing in the record (#314, #317): `clamshellPreflight` (`.info`) holds what the lid-closed microphone pre-flight read and decided — `lid`, `device` (UID or `default`), `transport` (`builtIn`, `bluetooth`, `usb`, `virtual`, `aggregate`, `continuity`, `other`, `unknown`), `builtIn`, `verdict` (`warn`/`none`) and `reason` (`start`; `micSwitch`/`micFollow` when the mic changes while the lid-closed banner shows — a `none` verdict then takes that banner down; every start clears a banner left from before). Being `.info`, it reaches `.diag.jsonl` only in a session with an anomaly; the unified log keeps a `notice` line either way. `tapRecoveryRung` carries `trigger`: what ordered the rung (`stalled`, `neverDelivered`, `listenerStopped`, `rebuildFailed`, `serviceRestarted`, `permissionGrant`, `permissionInsurance`, or the ladder's own `heartbeatMissed` / `slowRetry`). `permissionInsurance` runs at most once per episode, after 12 s of exact zeros with the permission authorized, and only on a tap that has delivered no real audio to prove its grant: zeros from the first frame (#220's shape, which a remote that has not spoken yet shares). Once the tap has delivered non-zero audio, a 12 s silence still gets the permission check and never a rebuild (#333).
- Renaming a recording (#357): the rename dialog's "Recording name" renames every file above, the transcript and its formats, the archives and WAVs, the summary, the `.json.bak` and the `.<id>.finalized` marker, from `HHMMSS-<old>` to `HHMMSS-<new>` (`SessionRenamer`). The references follow: `audio_files`, `audio_paths` and `audio_removed.files`, the summary's `Source transcript` line, and the marker's `session_id` / `transcript`. The contents of `.diag.jsonl` and `.json.bak` are left as written. It is refused with nothing changed while the session is in flight (recording, finishing, its chunks or its summary still running), while either name has session state in the folder, or when a target name is taken. If a step fails, everything is rolled back.
- Renaming while it records (#358): a name typed in the menu (its pencil row, for the whole recording) or on the meeting island (its Rename…, during the ~20 s it shows the recording after a one-click start before fading for good) while the recording runs (or a calendar title that arrived after a one-click start) is kept in memory as the coordinator's pending name; the capture keeps writing under the start's name. The Stop applies it with the same `SessionRenamer`, at the end of its finish: after the transcript is written and the stopping recovery file is deleted, and before the completion notice and the rename dialog are given the transcript. It first waits, bounded by the folder-read deadline (5 s), for two queued steps that still name the files by their old names: the storage quota pass (it protects the session's archives by name) and the live log's delete. The rename itself is bounded by the folder-write deadline (30 s) and abandonable: one that had not started by then never runs. Whenever the name is not applied (a wait or the recovery file's delete did not answer, the rename was refused or failed, or it never started) the files keep their name and the name is handed once to the rename dialog, whose field starts from it, so its Save applies it. A rename under way when its bound ran out is waited for one more bound, for its own answer; still running after that, it runs on and the transcript is shown wherever it is then. A recording finished by a salvage instead (a Stop that failed, `finalizeAbandonedSession`, or a later recovery) is never renamed there: a salvage runs under the recovery gate. Its pending name goes to the rename dialog the same way. The name is not in the recovery sentinel, so a crash keeps the start's name (`RecordingSessionName.swift` says why).
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

The words are compared after `EchoTextNormalizer` puts both sides in one form (#363): the two channels' recognisers write the same speech differently ("one ninety five" on the mic, "195" on the system side), and word overlap fell to 40–67% on echo lines. See "Word normalisation" below.

A segment already flagged `filtered` or `duplicate` is neither a candidate nor evidence.

**Step 2 — cluster verdict.** The unflagged local segments are grouped by speaker label (one group per diarized local cluster). `share = matched seconds / total seconds`. The cluster is **echo** when `share >= 0.5` and it holds at least 30 s; otherwise it is **kept**.

**Step 3 — flag.**

- In an echo cluster, every matched segment is flagged `echo`, whatever its length. Its unmatched segments stay unflagged under the cluster's label: there is no per-segment voice evidence to move them anywhere.
- In a kept cluster, a matched segment is flagged only when it has 3 words or more. This is what keeps "Yes." said on both sides at the same moment from being flagged, and still catches bleed that diarization folded into the user's own cluster.
- And only when it can be an echo copy (#365). On a headphone call the user repeated, a fraction of a second later, a short phrase the far end had just said ("Not possible to wait." / "No, not possible to wait."); both lines matched and were hidden. A matched segment in a kept cluster is now held back (matched, counted, not flagged) when:
  - **(a) no coupling was measured** where it was said: the chunk's `far_end_lift_db` is below 15 dB (`AcousticCoupling.uncoupledBelowLiftDB`, the canceller's own line for "the mic heard the far end", `EchoReduction.audibleEchoLiftDB`). Since #374 the lift is measured on every dual-stream chunk from the raw mic's levels (`FarEndLift`), with echo cancellation on or off, **per window** of 120 s every 30 s: one median for a 30-minute chunk that began on laptop speakers and went on in headphones read about 2 dB and held back the bleed lines of its first minutes under the user's name (found in review; `aChunkThatChangesOutputIsJudgedPerWindow`). A line is held back when at least one window over it is measured and every measured one is below 15 dB; a window that heard the far end keeps the per-line rule. A window with too little far-end speech (under 30 s of it talking or 30 s silent) is no evidence either way, since with the far end silent there is nothing to echo: on a real headphone call 22 of 68 windows were measured, and counting the unmeasured ones against a line hid the user's own repetition (r2, fixed). Over windows all unmeasured the line is unknown. The chunk's own lift is not required as well: in a chunk mostly on loudspeakers it would stop holding back the user's repetitions in its headphone part. With windows 4× their hop, any moment before or after a single change of output sits in a window at least three quarters on its own side. Measured: about 0–3 dB on headphones, 27–32 dB on loudspeakers; the band between (a quiet loudspeaker in a noisy room, 7–15 dB) is unmeasured, and a lift there holds the line back. No measure (no far end with frames, a failed read, a transcript written before #374 without cancellation) is unknown and holds nothing back. Over a whole transcript (re-detect, single-file path) each chunk's windows apply to their own spans; a line across a chunk boundary is held back only when no measured side heard the far end.
  - **(b) it is not shaped like an echo copy**, whatever the coupling. It is compared with the far end's speech it can hold: every remote segment that overlaps it in time (flagged ones too: they are still the far end's sound), plus the words it shares with its edges: its first words found in remote lines that ended within 0.8 s before it (`maximumEchoDelaySeconds` + `echoTimingToleranceSeconds`: an echo line often carries the tail of the remote line before, as the two recognisers cut lines differently), and its last words found in remote lines that start within 0.3 s after it. A neighbouring line's other words do not count: they were never in the mic's line. It is held back when it has more words than that (a repetition adds "No, …" or "…, thanks"); when, carrying no neighbour's words, it starts more than 0.3 s before the overlapping speech (an echo never precedes its source); or when it has as many words as all of the overlapping speech and starts more than 0.5 s + 0.3 s after it (`maximumEchoDelaySeconds`, the canceller's 500 ms bound: a full repetition starts once the far end has said it). Words are counted both ways (plain and normalised) and the reading that fits better decides.

  Neither changes a match, a share or a cluster's verdict, and neither applies in an echo cluster. The log line per verdict counts the lines held back for each reason.

**Who is late (#252).** Time and text are symmetric: when the far end returns the user's voice (a room system or speakerphone without echo cancellation), the remote channel holds the copy and the user's own lines match it, and over half a cluster the whole cluster was judged echo. The original precedes its copy. Per local cluster, the median over its matched near-identical lines (word overlap with one remote line above `echo_text_threshold`, as the issue's 80 timed pairs were; an excerpt matched by containment or a line matched against several joined is placed by where the recognisers cut it, and is not timed) of (local start − start of that remote line), judged per chunk (re-detect and the single-file path pass the chunk starts: `acoustic_coupling.per_chunk`, else the chunk archives' `chunk_offsets`). The local side leads in a chunk only on strong evidence, because a line's placement is only good to 0.3 s and about one pair in eight is placed more than 0.2 s off: at least 5 timed pairs (`minimumLagPairs`), at least a third of the cluster's matched lines there timed (`minimumTimedShare`), at least two thirds of the pairs each leading by more than `echo_local_lead_margin_seconds` (0.1 s, `minimumLeadingShare`), and their median too. Then the cluster is never echo, whatever its share, and its timed lines in that chunk are not flagged (listed in `heldBack`, so a re-detect folds them like the user's own), except a line whose own lag trails by more than the margin; that line and the untimed matches are judged by the per-line rules, since a bleed line held back would read as the user's words; the verdict records `reason: "local_leads"`. A bleed cluster with two early pairs among 3–5, or 6 timed pairs among 60 matches, is not overturned (pinned). Data from one direction only: #242's bleed trailed by a median +0.08 s (IQR 0.00–0.08); a round trip is expected at 0.15 s or more (0.4–0.6 s once on AirPods, where 3 of the user's lines were hidden). The margin needs a real mirror-case recording to confirm. The check before minority absorption (#249) and re-detect apply the same rule.

The cluster numbers (0.5, 30 s, 3 words; 5 pairs, 1/3 timed, 2/3 leading for who is late) and the per-line ones (15 dB, 0.3 s, 0.5 s) are constants, not config keys; the lead margin is `echo_local_lead_margin_seconds`.

**The voice similarity is evidence, not a gate.** Until #242 a third gate required the local cluster's speaker embedding to score above 0.8 against a remote speaker. That gate was all-or-nothing per cluster: on a real speaker-mode call the bleed cluster scored 0.68 (speaker playback into a far-field mic changes a voice), so none of its 146 segments were flagged, although 91% of its duration matched concurrent remote speech; the user's own cluster never exceeded 5% on the same measure. Bleed that minority absorption folds into the user's cluster carries the user's embedding and fails any such gate by construction. The similarity is now computed, written to `metadata.echo_clusters[].embedding_similarity` and logged, and decides nothing. `echo_embedding_threshold` is accepted and ignored.

**What is recorded.** One verdict per (chunk, local cluster) in `metadata.echo_clusters` (see "Echo" under the transcript metadata above), an `echo_cluster` processing issue for each chunk with an echo cluster, and one `.info` log line per verdict with public numbers only (the label is `.private`).

**Known limits.**
- The dedup runs per chunk, before cross-chunk reconciliation: a cluster is judged within its chunk, and there is no second pass at finalize.
- Minority absorption runs before it, but on the mic stream only after the raw clusters were judged for echo (#249, Stage 6): a bleed cluster under 5% of a chunk is no longer absorbed into the user's cluster, provided it holds the 30 s a cluster needs to be judged. A shorter one is still absorbed; only the per-segment rule (3 words or more) sees it.
- The text gates and the 3-word rule count whitespace-separated words, so they do little for a language written without spaces.
- (b) cannot tell a repetition whose first or last word the far end also says in the line just before or after it (that word counts as carried): only (a) holds such a line back, and only where the lift reads below 15 dB (headphones). A full copy is held back when it starts more than 0.8 s after its source, so on an output slower than that (AirPlay, about 2 s) an echo copy of a whole line is held back too.
- (a)'s 15 dB line was measured on headphones and loudspeakers only; the 7–15 dB band is unmeasured (#374). A transcript written before #374 with cancellation off has no measure, so (a) does nothing there even on a re-detect.
- Who is late (#252) is judged per cluster and chunk: where it holds, a timed line whose own lag is within the margin is not flagged, so in a chunk that mixes real bleed with returned user speech such a bleed line stays shown under the cluster's label. Strong evidence is required first (above); untimed matches and lines that clearly trail are still judged by the per-line rules. Two channels offset by a constant capture latency of more than about 0.18 s would read bleed as the original (its echo lines then stay visible).
- Word normalisation handles English numbers only (below).

### Word normalisation (#363)

`EchoTextNormalizer.words` is applied to both sides before every word comparison (Jaccard, containment, the joined window, the 3-word rule and the word counts of the per-line rule (b)). Every score is the higher of the plain reading (as before #363) and the normalised one, so normalisation only ever adds matches: "one two three four" against "one, two, three, four" still scores 1.0. The 3-word rule takes the fewer of the two counts, so "Twenty twenty six." is one word against "2026".

- **Case and punctuation** do not count, as before; accents are kept ("schön" is not "schon").
- **Digit groups**: "7,500" and "7.500" are 7500 (a separator followed by exactly three digits); any other separator between digits is a decimal point ("7,5" = "7.5").
- **English number words** become digits. A run of them, unbroken by punctuation other than a hyphen, is one number: with scale words it is evaluated ("seven thousand five hundred" = 7500, "one hundred and five" = 105, "a hundred" = 100); without, it is read in pairs or digit by digit ("one ninety five" = 195, "twenty twenty six" = 2026, "twenty oh five" = 2005, "one two three" = 123). "and", "oh" and "a" count only beside number words.
- **Apostrophes** of every form split a word, as before ("don’t" and "don't" agree). English contractions are deliberately not normalised further. Both ways were tried on the replay below: expanding them ("she's" → "she is") added common words that made short lines of the user's look "contained" in long remote lines; joining a contraction and its long form into one token (`she_is`) also joined "who is" / "who are" and the like, which pushed true echo lines under the threshold and made a line like "I'm at the office" match "you're at the office". Both channels go through the same recogniser, which writes a contraction the same way on both.

Limits: numbers in English only. The other languages' number words are left as they are, so their comparisons are unchanged; where an English number word is also one of theirs (French "six", Polish or Czech "ten") it maps the same way on both sides. Ordinals, decimals read aloud ("seven point five"), times ("one fifteen" against "1:15"), currencies ("five dollars" against "$5"), percentages ("fifty percent" against "50%") and contractions ("it's" against "it is") are not handled. Two numbers said without a pause ("one, ninety five" without the comma) read as one; the other side's digits then decide whether they match.

### Re-detect at a stated speaker count

The rename dialog lets the user state how many people were on a channel and re-detect it (`TranscriptRediarizer.rediarize`). It diarizes the channel's audio again, relabels the transcript's segments and never re-runs ASR: the number of segments and every text stay what they were.

A stated count is about people. With the far side on loudspeakers the diarizer finds its voice as a cluster of its own on the mic channel, and "one speaker on this side" used to merge that cluster into the user: on a real call about 2,400 of the other participant's words took the user's name (#243). So on the mic channel the echo check runs **before** the count is enforced, and the diarizer is given room for the echo voice (#265):

0. The mic channel is diarized for **one voice more than the people stated**. Asked for the people alone, the diarizer blends the echo voice into one of them (measured on a real recording: at 1, 186 of the other side's words stayed under the user's name; at 2, none), and nothing is left for the check to keep apart. Steps 1–2 run on that wider pass. When the check finds an echo voice there — a cluster of the diarizer's own judged echo; unattributed speech judged echo as a group does not count — that pass is the one used. When it finds none, the channel is diarized again at the stated count and steps 1–2 run on that pass, exactly as before #265: a clean channel pays a second diarizer pass, never a different result. The wider pass's extra cluster is then a fragment of somebody, and merging it by resemblance is not what the clusterer does at the stated count. If the wider pass fails (anything but a cancel), the stated count's pass runs as if it had found nothing. The remote channel is diarized once, at the stated count. The two mic passes share the "Detecting speakers" progress (the first fills it to half, the second to the end; when the wider pass is kept, the phase ends full).
1. The channel's segments are labelled with the diarizer's RAW clusters. With no word timings at re-detect this is one segment in, one out.
2. `EchoDeduplicator.deduplicate` judges those clusters against the other channel's unflagged segments — the same rule as at transcription (above), with the configured `echo_temporal_threshold` / `echo_text_threshold` (the rename dialog passes them), and with the per-line safeguards fed the chunks' far-end lift from `metadata.acoustic_coupling.per_chunk` (#374), else `metadata.mic_echo_cancel.per_chunk` (#365); unmeasured for a transcript with neither. The configured `echo_local_lead_margin_seconds` (#252) applies too.
3. `SpeakerCountEnforcer.enforce(_:to:keeping:)` enforces the count on the other clusters. A cluster judged echo is never merged away, never merged into and not counted.
4. The segments are labelled with the result:
   - a line of an echo cluster carries that cluster's own label; its matched lines are flagged `echo`, its unmatched lines are not. Nothing of it is given to the stated speaker, and at a count of 1 unattributed speech is never folded into it;
   - in any other cluster a matched line of 3 words or more is flagged `echo` and takes the channel's unattributed label (`Local Unknown`). It is never relabelled to a stated speaker, and it does not keep the label it had before the re-detect either (#277): after a repair that label is the user's, and the words are the other side's. A 1–2-word match is an ordinary line.
5. The metadata is rewritten as listed under "Re-detect" in the transcript metadata above; `Outcome` reports `speakerCount` (people), `segmentsRelabeled` (unflagged lines labelled), `echoClusters`, `echoFlagged` and `labelOverlap` (the speech each old label shares with each new one, #359).

What follows from that:

- **It never refuses.** Asking for 1 on a channel with the user and an echo voice gives one person and one echo cluster; a mic channel that is nothing but echo gives 0 people.
- **The count is people, so "1" is the answer on a speaker-mode call (#265).** Unattributed lines fold into the one person at a stated count of 1 whether or not an echo voice was kept apart (before, keeping the echo voice apart meant saying 2, and at 2 nothing folds). An unattributed group judged echo is still not folded, and with an echo voice kept apart neither is an unattributed line that repeats the other side at that moment (`DeduplicationResult.matchedLocal`): under 3 words ("Right.") the per-line rule does not flag it, and it is not the user's either, so it stays `Local Unknown`. A match the per-line rules of #365 hold back as the user's own (`DeduplicationResult.heldBack`: no coupling, or not shaped like an echo copy, judged whatever its length; and every match of a cluster that leads the remote, #252) is not spared and folds like any unattributed line. Without an echo voice such a line folds as before.
- **What the wider pass costs.** A second diarizer pass on a channel with no echo voice (about 10 s per pass for 17 minutes of audio in a debug build); never a different result there. Each forced count has its own diarizer manager, and `FluidAudioDiarizer` keeps one, released before another loads (`ForcedManagerSlots`), so a clean re-detect loads both of its managers every time. Measured in a release build on an M5 Pro (GPU, 2026-11-17): a load from the local cache takes about 135 ms (200–546 ms the first in a process); a manager kept idle after a 600 s pass holds about 0.9 GB, and keeping the wider pass's manager beside the stated count's raised the peak footprint from about 0.97 to 1.39 GB and what stays held while the dialog is open from about 0.47 to 1.36 GB. So the managers are reloaded, not kept (about 0.3 s per clean re-detect), and the peak is one manager, below the earlier slot's, which released the old manager only after the new one loaded. The M1 Air is still unmeasured. Measured with the stock FluidAudio config (2026-11-17):
  - *A clean one-person channel is not split.* Asked for 2, it stayed one cluster on 9 of 9 channels: 5 synthetic voices (`say`, 93–112 s each, the other side on the system channel) and the 4 AMI ES2004a speakers each cut out into a channel of their own (76–333 s). The labels came out identical to a re-detect asked for 1 only, 5 of 5. Had it split, the pass would have been discarded (no echo voice).
  - *Why the wider pass is not simply enforced down to N.* On audio holding more voices `maxSpeakers` is a target: the 4-person AMI mix gives exactly 1, 2, 3 clusters at 1, 2, 3, and 2, 3, 4 at one more (4 at 5). `SpeakerCountEnforcer` merging 3 down to 2 agrees with a direct 2 on 74.5% of the speech, 4 down to 3 on 89.7%. So without an echo voice the stated count's own pass is used.
  - *Speaker bleed.* A synthetic mic with the user and the far side's voice mixed in at -6, -12 and -18 dB (5 voice pairs each): asked for 1, the diarizer returned one blended cluster 15 of 15 times; asked for 2 (and unforced, with the same split) it separated the echo voice 14 of 15 times (54/46 to 87/13 of the speech; the one miss, at -18 dB, still found the bleed as unattributed speech judged echo). Re-detect at 1 now: 1 person, every bleed line flagged and none left under the user, none of the user's lines marked as echo, 15 of 15 (the echo voice a cluster of its own in 14). Before: in 9 of 15 the single blended cluster was itself judged echo, so the user counted as nobody and their own lines sat under the echo voice's label. Every synthetic bleed line has 3 words or more, so the per-line rule flagged all of them before #265 too; the real call's 186 words left under the user were in lines the per-line rule could not flag (under 3 words, or not matched).
  - *Why one more, not unforced.* On this fixture unforced split exactly as "one more" did. It gives no room guarantee, though: on the 2026-09-02 speakerphone call unforced found 1 voice for 2 people (DiarizerSpeakerCountTests), so a stated 2 with an echo voice could get neither. One more is the least room that holds the stated people and one echo voice.
- **Lines already flagged `echo` count as evidence.** The pipeline flags an echo cluster's matched lines when it transcribes; judged on the unmatched rest alone, that cluster would look like a person and be merged. They keep their flag (a re-detect never removes one) and take the cluster's new label, since speaker numbers are positional and the old one may now be somebody else's. An already-flagged line that falls in no echo cluster this time takes the unattributed label for the same reason (#277), whether or not the check still finds its match. A line flagged `filtered` or `duplicate` is neither evidence nor relabelled by a cluster: it keeps its flag and takes the unattributed label (#296).
- **Every flagged line on the re-detected channel is unattributed (#296).** `filtered`, `duplicate`, `echo` or no usable time, on either channel, whether or not the echo check ran: it keeps its flag and takes the channel's unattributed label (`Local Unknown` / `Remote Unknown`). The one exception is an `echo` line the check puts in an echo cluster, which carries that cluster's label. The other channel's lines are untouched.
- **It repairs a transcript that was merged this way.** Re-detecting it again finds the echo voice in the raw clusters and takes it back out.
- **Speech the diarizer gave no turn to is judged as a group** (`Local Unknown`). When that group is echo, a count of 1 does not fold its unmatched lines into the user.
- **One blended cluster** (the diarizer honoured the count): there is nothing to keep out; only the per-segment rule applies, and the lines it flags are unattributed.
- **The unattributed label is nobody.** A line flagged outside an echo cluster adds no person to `speaker_count_<track>`, no entry to `echo_clusters`, no row to the rename dialog and no participant to the summary; a rename does not reach it.
- **The other channel is not checked.** The deduplicator judges mic clusters against system audio and has no answer to the reverse, so re-detecting the remote channel does what it always did, except that its flagged lines take `Remote Unknown` (#296). One consequence: the keys of `echo_clusters[].matched_remote` are the remote labels at the time of the check, and the re-detect renumbers the remote speakers, so it follows them (#270): see "After a re-detect of the other channel".
- **If the raw labelling is ever not one-to-one** the check is skipped (logged as an error) and the re-detect is the unguarded one: a relabel must never lose or misplace words.
- **A dialog's second Re-detect of a channel only clusters (#341).** FluidAudio splits a diarization into `prepare()` (segmentation and speaker embeddings, the model work) and `cluster()` at a count. The rename dialog holds a `SpeakerAnalysisCache`; with it, `rediarize` makes the channel's analysis once (`FluidAudioDiarizer.prepare`, on the manager the first pass loads anyway) and every pass clusters it: #265's wider pass and the stated count's, and every later Re-detect of the same channel of the same audio at another count, with no decode either. The clusters are exactly a full pass's (the AMI golden test: segments, times, labels, quality scores and speaker embeddings at 2–5 from one analysis made under 5, at 3–4 from one made under 2, and on the Neural Engine at 3–4 from one made under 4). The key is the channel, each audio file (path, size, modification date, by stat), the decode's timeline inputs (`chunk_durations`, `chunk_offsets`, capture gaps), the echo canceller, and the diarizer's prepare settings (segmentation, embedding, compute units; not clustering). It holds ONE analysis: a miss (the other channel, a renamed session, audio the storage limit removed) releases the held one before decoding the new, so a long call's audio and embeddings are never in memory twice. The analysis holds the channel's decoded audio (16 kHz mono Float, about 220 MB an hour; clustering re-reads short spans of it — the decode's own buffer, not a copy, sized from the chunks' lengths so no unused capacity is kept) plus the embeddings and segmentation scores (measured: 120 MB more for 52.5 minutes, 1,657 embeddings; about 0.36 GB an hour in all); it goes when the dialog closes (`close`, and a re-detect still finishing after the close cannot store one), when a recording starts (`RecordingCoordinator` calls `SpeakerAnalysisCache.releaseAll` on the transition into a recording, a relaunch's resume included, so an open dialog's analysis never sits under the recording's chunk processing) and on memory pressure (a `DispatchSource` memory-pressure source, warning or critical). After a release the dialog stays usable: its next Re-detect misses and runs a full pass, and a re-detect already running when the release came does not keep its analysis. A decode where the echo canceller failed on a chunk and fell back to the raw mic is used for that re-detect and not kept, so a transient failure does not stick. The store comes after a cancellation check: a cancelled re-detect keeps nothing. In memory only, so a FluidAudio update never meets an analysis its predecessor made. A two-file transcript (CLI, pre-0.6) is not kept: the diarizer streams it from disk, and keeping it would hold its whole audio. A failed analysis in the wider pass is that pass failing: the stated count's pass analyses again. Progress: `.detectingSpeakers` carries the analysis' chunk fraction, then `.regroupingSpeakers` ("Regrouping voices…", no fraction) for each clustering; a reused analysis shows only the latter. The diarizer reports after every segmentation chunk, so the dialog takes them through `RedetectProgressThrottle` (phase changes and a fraction's start and end always, otherwise ten a second) before the hop to the main actor. Measured on a 52.5-minute chunked recording (AMI ES2004a three times, stereo AAC chunks; the mic channel at 3, then at 4; release build on an M5 Pro under heavy load from other jobs, load average 18–32, 2026-11-24): before, 41.6 s and 45.4 s (each a decode and two full passes); after, 23.4 s (a decode, one analysis, two clusterings) and 1.9 s. One clustering of that analysis takes about 1 s.

### Names after a re-detect (#359)

Speaker numbers are positional, so a name cannot follow its label across a re-detect (#202). It follows its speech instead: the lines before and after are the same lines, and `SpeakerNameCarryOver` (TranscriberCore) maps them. The dialog only gathers the inputs and shows the result.

- **What votes.** The channel's unflagged lines with a usable time, under a label that is somebody's: never a flagged line (`echo`, `filtered`, `duplicate`, no usable time) and never the unattributed label. On the new side an echo cluster's lines are left out altogether, so no name can land on it. `Outcome.labelOverlap` holds the seconds each old label shares with each new one, by time (a split line counts in parts), plus each label's own total.
- **Which names.** What the channel's name fields hold when the re-detect ends, saved or typed and not yet saved; a field that is empty or holds a pipeline label (`Remote Speaker 2`, `Remote Unknown`) is no name. A label no row shows (too few lines) that is not a pipeline label is a saved name. One name typed on two rows is one person: their speech is pooled. A name typed on an echo row is never carried, nor offered. Whether a row is an echo voice is `EchoNotice.Findings.voice(forRow:)` with its track the re-detected channel (a remote speaker sharing a local echo row's name is not one), which follows the renames in `speaker_names`, decided in Core (`plan(_:fields:echo:channel:previous:)`), not in the view.
- **Kept.** A new speaker keeps a name when more than half of its speech had that name, more than half of that name's speech went to it, AND no other new speaker took a quarter or more of that name's speech. Raising the count usually means one label was really two people, so the larger half of a split (60/40, or a 55/45 cross-mix of two names) is a guess, and neither half keeps the name; a 90/10 split keeps it. A name is kept on at most one new speaker and a new speaker keeps at most one name. Two names merged into one speaker: the one with more speech is kept (it holds more than half), the other offered.
- **Offered, never filled in.** A name not kept is offered as a one-click suggestion on every new speaker that took at least a quarter of its speech, and always on the one that took the most.
- **Said.** Before: the confirmation names the side and its names, states the rule (which name lands where is only known after) and says the re-detect removes the names from the transcript until Save. After: a kept name's card says so while its field holds that name, a suggestion is a button under the name field, and the channel's row lists the names kept, those only suggested and those neither, ending "Save to write them to the transcript." The other channel's fields, typed and unsaved included, are left as they were.
- **The transcript.** Unchanged by this: the re-detect still clears the channel's `speaker_names` into `speaker_names_previous`; the fields reach the transcript on Save. So Cancel, Escape or closing the window asks first (`discardConfirmation`) while any field on a channel re-detected in this dialog holds a name, whether kept, taken from a suggestion, edited or typed (`unsavedNames`), and lists those names.
- **A second re-detect** of the same channel reports the first one's suggestions no field took as not kept again (their speech is under labels that no longer exist, so they cannot be offered). A failed or cancelled re-detect leaves the previous result, suggestions included, on screen.
- **A reload that fails** after a successful re-detect: the transcript has new labels the rows on screen do not show. No name is carried, the channel's fields go back to their labels (never matched to the new labels by position, #202), and Save and Re-detect wait for "Reload Speakers". The error says the names typed on that side were not carried over.

### What the user is told (#244)

A second voice on the mic side used to be listed as "Local Speaker 2" with nothing to explain it. Three places now say what the echo check recorded. All three read the transcript's metadata (`echo_clusters`, `echo_segments_flagged`, `speaker_count_<track>`, `speaker_names`) and recompute nothing; the copy and the counts are built by `EchoNotice` (TranscriberCore), the views only show them.

- **Speaker card** (rename dialog) of a label with at least one `"echo"` verdict: "Looks like the other side's voice through your loudspeakers: N of M lines (P% of its speaking time) match <remote label(s)> at the same time and are marked as echo. The other K lines stay under this label." The numbers are the label's `echo_clusters` entries summed (one per chunk); P is `matched_seconds / seconds`, the measure the verdict is taken on. A label whose entries are all `"kept"` gets no notice.
- **Re-detect row**: before, "Set the number of people on this side. Re-detect looks for the echo voice on its own and keeps it apart when it finds it; its matched lines stay marked as echo." (#265: the count is people and re-detect leaves room for the echo voice itself, so the hint no longer asks the user to count around it; "looks for", since a diarizer that blends the voices even then leaves nothing to keep apart.) After, the outcome: "1 speaker found · 1 echo voice kept separate · N lines marked as echo · R lines relabeled" (without echo it reads as before: "2 speakers found · 84 lines relabeled"). The stepper pre-fills the number of PEOPLE on the channel: its rows that are not an echo voice, never below `speaker_count_<track>`, never below 1.
- **Completion notice** of a recording with an echo voice: the title is "Transcription Complete — echo marked" (last in the title's precedence: every problem is said first), and the body adds "it looks like part of the other side's voice came through your microphone, and N lines are marked as echo (headphones avoid this)", N being `echo_segments_flagged`. Lines flagged in a cluster that was kept (the 3-word rule) do not make a notice.

What follows from reading only the metadata:

- **The record holds labels.** `echo_clusters` keeps the labels the check saw ("Remote Speaker 1"), which a rename does not rewrite. The echo voice's own row is still found after a rename, through `speaker_names` (followed as a chain, since each rename is keyed by the label current at the time); the other side's speakers are quoted as they are called now only where that can be told (below).
- **"Looks like", not "is".** The check sees lines on this side that repeat the other side's words at the same moment. The mirror case (this side's voice coming back on the other side's track) gives the same numbers.
- **A label can be echo in one chunk and too short to judge in the next.** All its entries are summed; in the chunk where it was kept a matched line of one or two words is not flagged, so N can exceed the lines actually marked by those few.
- **After a re-detect of the other channel** (#270) the remote labels in `matched_remote` are remapped, or dropped. `TranscriptRediarizer.remappingMatchedRemote` takes each key (resolved to the label its lines carried by `TranscriptRenamer.currentLabel`, below, before the channel's names are cleared) to the new label that carries its speech, by the rule a name is kept with (`SpeakerNameCarryOver`, `labelOverlap`): more than half of the old label's speech went to one new label and no other new label took a quarter or more of it. Any other key is dropped, never guessed: a stale label would name a remote speaker who is somebody else now, and a dropped one reads "the other side". Keys landing on one new label add up. Only `matched_remote` changes (and the `echo_matched_remote_current` stamp), and only on a remote re-detect; the entries are taken one at a time, so a malformed one is left as it was and the rest are still remapped. Every key of a record an older build re-detected is dropped. The re-detect clears with the channel's labels the names a later rename keyed in turn (`Remote Speaker 1 → Sam`, then `Sam → Tom`: both go to `speaker_names_previous`), unless the other channel's labels lead there too.
- **The card names the other side as it is called now** (#270), when that can be told for sure. `speaker_names` is flat and unordered (each Save merges `{label current then: new name}`), so the end of a rename chain is not always the current name: RS1 named "Sam", then one Save correcting RS1 to "Tom" and naming RS2 "Sam" leaves `{RS1: Sam, Sam: Tom, RS2: Sam}`, where the chain from RS2 ends at "Tom". `TranscriptRenamer.currentLabel` answers only when one group of lines leads through the chain (no other origin — a key nothing renames into, or a pipeline label — reaches a label on it that was renamed on) and exactly one label on the chain is on the remote lines now; a label never renamed is itself. A rename there and back (`Sam → Tom → Sam`) is one group, and the lines say "Sam". Anything else is left out of the card, and with nothing left it says "the other side". Two labels given one name are one speaker, their seconds adding up. A rename does not rewrite `echo_clusters`.

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

The echo benchmark in `docs/benchmarks/` (2026-04-06) measured the earlier algorithm, before the cluster verdict (#242). It cannot be re-run: the `--legacy-dedup` flag it used is gone, its recordings' audio has since been removed by the storage limit, and their transcripts were written when echo lines were deleted, not flagged. Its numbers do not describe the current behaviour.

#363 and #365 were measured instead by replaying the deduplicator over the owner's finished dual-stream transcripts (110 of them, local only; nothing of them is in the repository), once over each whole transcript as re-detect runs it, before and after the change; see `docs/benchmarks/2026-11-17-echo-line-matching.md`.

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

# Run tests: serially (--no-parallel is load-bearing, see AGENTS.md) in a throwaway home (#313).
# `just test` runs this with the fixture guard and a canary; `bash scripts/swift-test.sh <Suite>` runs one suite.
bash scripts/swift-test.sh
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
  --echo-cancel             Cancel speaker echo in the mic before transcribing it (needs --split or two inputs; as mic_echo_cancel "on")
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
