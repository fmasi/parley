# Tunable Parameters

All parameters are set in `~/Library/Application Support/Parley/config.json` using `snake_case` keys. Parameters not present use defaults.

---

## Recording

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Recording directory | `recording_directory` | `~/Documents/Recordings` | Directory where session WAV files and transcripts are written. |
| System audio source | `system_audio_source` | `"sck"` | Which mechanism captures system (remote) audio. `"sck"` = ScreenCaptureKit (default). `"core_audio_tap"` = Core Audio output process tap (#103), a strict superset that also captures Continuity/iPhone and VoIP call audio ScreenCaptureKit misses; prompts for System Audio Recording permission on first use and applies to the next recording. |
| Chunk duration | `chunk_duration_minutes` | `30` | How many minutes of audio per rotating chunk. Enforced minimum of 10 minutes (`validatedChunkDuration`). |
| Silence detection enabled | `silence_detection_enabled` | `true` | When `true`, recording auto-stops after the silence timeout elapses without speech. |
| Silence timeout | `silence_timeout_minutes` | `5` | Minutes of silence before auto-stop (requires `silence_detection_enabled`). |
| Last microphone device ID | `last_microphone_device_id` | `null` | `AVCaptureDevice` unique ID of the microphone last selected in the session dialog. Restored automatically on next launch. |

---

## Engine

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Transcription engine | `engine` | `resolved_default` | Which ASR engine to use. Values: `"speechAnalyzer"` (macOS 26+, no download), `"fluidAudio"` (Parakeet, ~500 MB download, 25 EU languages). Fresh installs resolve to `fluidAudio` on macOS 15 via `.resolvedDefault`. |
| Output format | `output_format` | `"txt"` | Transcript file format. Values: `"txt"`, `"json"`, `"srt"`. |
| VAD speech threshold | `vad_speech_threshold` | `0.5` | Minimum VAD probability (0–1) to classify a frame as speech. Higher values are stricter and discard more uncertain frames. Applies to `VadSpeechMap` quality filtering in speaker assignment. |

---

## Echo Deduplication

> These parameters are config-file-only and have no UI controls.

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Temporal overlap threshold | `echo_temporal_threshold` | `0.5` | Minimum fraction of temporal overlap (0–1) between a local mic segment and a remote segment to consider them candidates for deduplication. Computed as `overlap / shorter_segment`. |
| Text similarity threshold | `echo_text_threshold` | `0.7` | Minimum Jaccard word-level similarity (0–1) between local and remote text to confirm an echo. Also used as the containment threshold (fraction of local words appearing in remote text) as a fallback for short excerpts. |
| Embedding cosine threshold | `echo_embedding_threshold` | `0.8` | Minimum cosine similarity (0–1) between local and remote speaker embeddings to confirm the local speaker is the same person as the remote speaker. This gate runs first; segments with no embedding skip dedup entirely. |

---

## Audio Archive

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Archive bitrate | `archive_bitrate_kbps` | `64` | AAC encoding bitrate in kbps for the stereo archive file (L=mic, R=system). Lower values save space at some quality cost. |
| Archive storage limit | `audio_archive_limit_hours` | `15` | Maximum total hours of `.m4a` archive files to keep in the recording directory. When exceeded, `StorageManager` deletes the oldest files first. Transcripts are never deleted. |
| Merge chunked audio | `merge_chunked_audio` | `true` | When true, concatenates per-chunk `.m4a` files into a single archive at the end of a chunked session. Uses AVFoundation passthrough (lossless) where possible, falls back to AAC re-encode. Set to `false` to keep individual chunk files. |

---

## Summary

All summary fields are nested under the `"summary"` key in config.json. The entire block is optional; omitting it disables summarization.

| Parameter | Config Key (under `summary`) | Default | Description |
|-----------|------------------------------|---------|-------------|
| Enabled | `enabled` | — | `true` to generate a `-summary.md` file after each session. Required field when the `summary` block is present. |
| Provider | `provider` | `"openai"` | LLM backend. Values: `"openai"` (OpenAI-compatible `/v1/chat/completions` — covers OpenAI, Claude proxy, Ollama), `"lmstudio"` (LM Studio native REST `/api/v1/chat` with per-request context_length). |
| Endpoint | `endpoint` | — | Base URL of the API server (e.g. `"http://localhost:1234"` for LM Studio, `"https://api.openai.com"` for OpenAI). Required. |
| API key | `api_key` | — | Bearer token sent in the `Authorization` header. Leave empty for local servers that don't require auth. Required field. |
| Model | `model` | — | Model identifier as expected by the provider (e.g. `"gpt-4o"`, `"llama-3-8b-instruct"`). Required. |
| Context length | `context_length` | `null` | Maximum context window in tokens to advertise to the provider. When `null`, the provider uses its own model default. Primarily relevant for `lmstudio` which passes this per-request. |
| Context overhead percent | `context_overhead_percent` | `10` | Safety margin (%) added to estimated input token count before computing fit. Prevents context overflows from estimation error. |
| Max output tokens | `max_output_tokens` | `2048` | Tokens reserved for the summary response. Subtracted from the usable context window when deciding how much transcript to include. |
| Request timeout | `request_timeout_seconds` | `600` | Seconds a single summary request may take before `URLSession` gives up. **Deliberately far above URLSession's implicit 60 s**: that default governs a *network* call, and this one drives a LOCAL model that routinely needs minutes. Measured on one transcript — cold (model not loaded) 36 s, warm 13 s, the failure that motivated this 60.5 s — so a cold load plus ANE/GPU contention from the ASR that just finished can exceed 60 s on an ordinary meeting. A timeout here surfaces as "The model took too long to respond", not as a file error (#173). |

---

## System

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Launch on startup | `launch_on_startup` | `true` | When `true`, installs a KeepAlive LaunchAgent at `~/Library/LaunchAgents/`. Uninstalled automatically on explicit quit. |
| Suppress capture warning | `suppress_capture_warning` | `false` | When `true`, hides the capture interruption warning dialog shown after XPC crash recovery. |
| Chunk processing QoS | `chunk_processing_qos` | `"utility"` | `DispatchQoS` class used for background chunk processing (transcription + diarization). Values: `"userInteractive"`, `"userInitiated"`, `"utility"`, `"background"`. Unknown values fall back to `"utility"`. |

---

## Diarization

Diarization is performed by `FluidAudioDiarizer` (pyannote segmentation + WeSpeaker embeddings + VBx clustering). All keys below are optional; **the defaults are correct and none of these need to be set.** They exist so a bad recording can be diagnosed without a rebuild.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `diarization_exclude_overlap` | bool | `true` | Exclude overlapped speech when computing speaker embeddings. **Do not set this to `false`.** Including overlap makes each embedding a blend of the voices present, so they all converge and every speaker collapses into one cluster. Measured on AMI ES2004a (4-speaker reference meeting): `false` → **1 speaker**, `true` → **4 speakers**. The app logs a warning if you set it explicitly to `false`. |
| `diarization_clustering_threshold` | float | `0.6` (FluidAudio) | Euclidean distance threshold for unit-normalized embeddings. **Lower** = stricter = more speakers kept apart; **higher** = more merging. |
| `diarization_max_speakers` | int | unset | Upper bound on speakers per stream, passed to VBx. Leave unset unless the true count is known. A value of `0` or `1` will collapse every speaker into one. In practice this behaves as a **target**, not a ceiling: on a file whose unbounded default yields 1 speaker, values of 2/3/4 yield exactly 2/3/4. This is the knob the rename dialog's per-channel speaker count writes to. |
| `diarization_min_speaker_share` | float | `0.05` | Share of a stream's speech below which a diarization cluster is absorbed into the dominant speaker, provided one cluster holds at least 50% of the stream. Removes the fragments the clusterer invents from short utterances. Measured: real fragments came in at **3.5%** and **2.1%** of their stream, a real second speaker at **40%**; embedding similarity cannot separate those cases (cosine 0.4030 vs 0.3987) but duration can. Absorption is skipped entirely when the user states a speaker count via **Re-detect in the rename dialog** — that path forces the count and turns absorption off together. Note this does **not** apply to `diarization_max_speakers`: setting that knob constrains the live recording path's clustering but leaves absorption running, so a cluster under this share is still absorbed even though you named a speaker count. The two are deliberately different — `diarization_max_speakers` is a standing default across every recording, while Re-detect is a statement about one specific recording the user is looking at. Set to `0` to disable. Values above **0.25** are clamped back to the default and logged: past that point the rule absorbs a median participant rather than a fragment, since absorption only runs when some cluster already holds >=50%. |
| `speaker_count_local` / `speaker_count_remote` | int | absent | **Written into the transcript, not read from config.** Records how many speakers a channel actually ended up with after a manual re-detect from the rename dialog (#67) — the count PRODUCED, not the count requested, since the two can differ. Absent on transcripts that were never re-diarized. |

## Debugging

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `preserve_source_wav` | bool | `false` | Keep the uncompressed source WAVs after AAC archiving, so diarization/capture can be analysed on the raw audio. **These are large (~5.5 MB/minute per stream) and `StorageManager`'s quota only evicts `.m4a` archives — it will not reclaim them.** Diagnostic use only; turn it off afterwards. |

---

## Speaker Reconciliation

Speaker reconciliation is performed by `SpeakerReconciler` in `TranscriberCore/SpeakerReconciler.swift`. The cosine similarity threshold is **hardcoded at 0.65** and is not configurable via `config.json`.

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Cosine similarity threshold | `SpeakerReconciler.reconcile(threshold:)` default | `0.65` | Minimum cosine similarity between per-chunk speaker embeddings required to map a local speaker to an existing global speaker ID. Below this threshold, the speaker is assigned a new global ID (`spk_N`). |
| EMA update alpha | Hardcoded in `SpeakerReconciler` | `0.9` | Exponential moving average weight applied to existing reference embeddings when a match is confirmed. `newRef = 0.9 * oldRef + 0.1 * chunkEmb`. |

---

## Token Ratio Cache

The file `~/Library/Application Support/Parley/token-ratios.json` caches measured chars-per-token ratios for each LLM model used with the summary feature. It is managed automatically by `TokenRatioCache` and does not need manual editing.

**File format** — a JSON object keyed by model name:
```json
{
  "llama-3-8b-instruct": { "ratio": 3.72, "isSeed": false },
  "gpt-4o":              { "ratio": 3.15, "isSeed": true  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ratio` | `Double` | Chars-per-token ratio for this model. Used to estimate how much transcript fits in the context window. Default fallback is `3.0` when no entry exists. |
| `isSeed` | `Bool` | `true` when the ratio came from a small calibration probe (rough estimate). `false` when measured from a real transcript (accurate). Subsequent real measurements refine via EMA (`0.3 * new + 0.7 * existing`). |

**Lifecycle:**
1. On first summary request for a model, `TokenRatioCache` sends a small calibration probe to the LM Studio API and stores a seed ratio.
2. After each real summary, the actual token count from the API response refines the ratio (first real measurement replaces seed; subsequent ones blend via EMA).
3. On a context overflow error, `setRatio` force-updates the ratio from the exact token count returned in the error, bypassing EMA.
4. Legacy entries written as plain `[String: Double]` (without `isSeed`) are migrated in-place and treated as seeds on first read.
