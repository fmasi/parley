# Tunable Parameters

All parameters are set in `~/.audio-transcribe/config.json` using `snake_case` keys. Parameters not present use defaults.

---

## Recording

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Recording directory | `recording_directory` | `~/Documents/Recordings` | Directory where session WAV files and transcripts are written. |
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

---

## System

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Launch on startup | `launch_on_startup` | `true` | When `true`, installs a KeepAlive LaunchAgent at `~/Library/LaunchAgents/`. Uninstalled automatically on explicit quit. |
| Suppress capture warning | `suppress_capture_warning` | `false` | When `true`, hides the capture interruption warning dialog shown after XPC crash recovery. |
| Chunk processing QoS | `chunk_processing_qos` | `"utility"` | `DispatchQoS` class used for background chunk processing (transcription + diarization). Values: `"userInteractive"`, `"userInitiated"`, `"utility"`, `"background"`. Unknown values fall back to `"utility"`. |

---

## Speaker Reconciliation

Speaker reconciliation is performed by `SpeakerReconciler` in `TranscriberCore/SpeakerReconciler.swift`. The cosine similarity threshold is **hardcoded at 0.65** and is not configurable via `config.json`.

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Cosine similarity threshold | `SpeakerReconciler.reconcile(threshold:)` default | `0.65` | Minimum cosine similarity between per-chunk speaker embeddings required to map a local speaker to an existing global speaker ID. Below this threshold, the speaker is assigned a new global ID (`spk_N`). |
| EMA update alpha | Hardcoded in `SpeakerReconciler` | `0.9` | Exponential moving average weight applied to existing reference embeddings when a match is confirmed. `newRef = 0.9 * oldRef + 0.1 * chunkEmb`. |

---

## Token Ratio Cache

The file `~/.audio-transcribe/token-ratios.json` caches measured chars-per-token ratios for each LLM model used with the summary feature. It is managed automatically by `TokenRatioCache` and does not need manual editing.

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
