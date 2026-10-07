# Tunable Parameters

All parameters are set in `~/Library/Application Support/Parley/config.json` using `snake_case` keys. Parameters not present use defaults.

---

## Recording

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Recording directory | `recording_directory` | `~/Documents/Recordings` | Directory where session WAV files and transcripts are written. |
| System audio source | `system_audio_source` | `"core_audio_tap"` | Which mechanism captures system (remote) audio. `"core_audio_tap"` = Core Audio output process tap (#103), the default for new installs: a strict superset that also captures Continuity/iPhone and VoIP call audio ScreenCaptureKit misses; prompts for System Audio Recording permission on first use and applies to the next recording. `"sck"` = ScreenCaptureKit (legacy, until #221). An existing `config.json` without this key keeps decoding as `"sck"`: it was written by an SCK-era build (spec §11.1). |
| Chunk duration | `chunk_duration_minutes` | `30` | How many minutes of audio per rotating chunk. Enforced minimum of 10 minutes (`validatedChunkDuration`). |
| Silence detection enabled | `silence_detection_enabled` | `true` | When `true`, recording auto-stops after the silence timeout elapses without speech. |
| Silence timeout | `silence_timeout_minutes` | `5` | Minutes of silence before auto-stop (requires `silence_detection_enabled`). |
| Last microphone device ID | `last_microphone_device_id` | `null` | `AVCaptureDevice` unique ID of the microphone last selected in the session dialog. Restored automatically on next launch. |

---

## Engine

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Transcription engine | `engine` | `"fluid_audio"` | Which ASR engine to use. Values: `"fluid_audio"` (Parakeet, ~500 MB download, 25 EU languages; the default), `"speech_analyzer"` (Apple, macOS 26+, no download; labelled "not yet usable" because it produces blank transcripts on the live chunk path until #223). A config without the key, or with an unknown value, follows the current default (`.resolvedDefault`). The chosen engine must pass a one-second preflight at Setup Continue and Settings Save (`EnginePreflight`). One exception at Save: an engine whose model is not downloaded yet has nothing to preflight, so it is saved and the Save starts its download (`EnginePreflight.saveStep`). |
| Output format | `output_format` | `"txt"` | Transcript file format. Values: `"txt"`, `"json"`, `"srt"`. |
| VAD speech threshold | `vad_speech_threshold` | `0.5` | Minimum VAD probability (0–1) to classify a frame as speech. Higher values are stricter and discard more uncertain frames. Applies to `VadSpeechMap` quality filtering in speaker assignment. |

---

## Echo Deduplication

> These parameters are config-file-only and have no UI controls.

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Temporal overlap threshold | `echo_temporal_threshold` | `0.5` | A local mic segment and a remote segment are compared only when they overlap in time by more than this fraction (0–1) of the shorter one (`overlap / shorter_segment`). Remote segments of every remote speaker are candidates. |
| Text similarity threshold | `echo_text_threshold` | `0.7` | A local segment MATCHES a remote one when their word-level Jaccard similarity (0–1) is above this. Also the containment threshold (fraction of the local words found in the remote text, for a short excerpt of a long remote segment) and the threshold for the Jaccard against all the overlapping remote segments joined. |
| Embedding cosine threshold (**deprecated, ignored**) | `echo_embedding_threshold` | — | Still read and written back, so an existing config file keeps working; it no longer changes anything (#242). The voice similarity is recorded as evidence (`metadata.echo_clusters[].embedding_similarity`) and decides nothing. The key will be removed in a later release. |

The echo check a re-detect runs from the rename dialog (#243) uses the two defaults above, whatever the config file says: it has no config in hand.

The cluster rule has three constants. They are **not** config keys (`EchoDeduplicator`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `clusterShareThreshold` | `0.5` | A local cluster (one diarized speaker label on the mic side, per chunk) is echo when at least this share of its duration is in matched segments. |
| `clusterMinimumSeconds` | `30` | A cluster with less speech than this is not judged as a cluster. |
| `minimumWordsOutsideEchoCluster` | `3` | Outside an echo cluster, a matched segment is flagged only when it has this many words or more (whitespace-separated words holding a letter or digit). In an echo cluster every matched segment is flagged, whatever its length. |

---

## Audio Archive

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Archive bitrate | `archive_bitrate_kbps` | `64` | AAC encoding bitrate in kbps for the stereo archive file (L=mic, R=system). Lower values save space at some quality cost. |
| Archive storage limit | `audio_archive_limit_hours` | `15` | Maximum total hours of `.m4a` audio to keep in the recording directory, **across all its day folders** (#224; before, each day folder was weighed alone and nothing was ever deleted across days). When exceeded, the pass after each recording deletes the oldest Parley archives first (an `HHmmss[-…].m4a` directly in a `yyyy-MM-dd` folder; any other `.m4a` in the folder counts towards the limit, as Settings shows it, but is never deleted). Transcripts are never deleted: each one whose audio went gets a `metadata.audio_removed` mark, and the completion notice says how many older recordings lost their audio. Neither is the audio of the recording just made, nor of a session that is still being recorded, processed or awaiting recovery (#230): usage can stay over the limit until it finishes. A chunk's own pass during a recording still weighs only its day folder. |
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
| Launch on startup | `launch_on_startup` | `true` | Settings' "Launch at Login" toggle: registers Parley as a login item (`SMAppService`). Separate from crash protection: the KeepAlive LaunchAgent at `~/Library/LaunchAgents/eu.fmasi.parley.plist` is verified and repaired at every launch whatever this says, and removed on Parley's own Quit only by the instance holding the single-instance lock. |
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
| `speaker_count_local` / `speaker_count_remote` | int | absent | **Written into the transcript, not read from config.** Records how many people a channel actually ended up with after a manual re-detect from the rename dialog (#67) — the count PRODUCED, not the count requested, since the two can differ. It counts people: not `Unknown`, and not a cluster the echo check judged to be the other side's voice through the speakers (#243), so it can be lower than the number of labels on the channel, and 0 on a mic channel that holds only echo. Absent on transcripts that were never re-diarized. |
| `rediarized_channels` | [string] | absent | **Written into the transcript, not read from config.** The channels (`"local"` / `"remote"`) a re-detect has rewritten, each once. Absent on transcripts that were never re-diarized. A rename reads it: flagged segments on a listed channel keep their label (the unattributed one, or an echo cluster's — #296), those on the other channels are renamed (#245). |

## Debugging

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `preserve_source_wav` | bool | `false` | Keep the uncompressed source WAVs after AAC archiving, so diarization/capture can be analysed on the raw audio. **These are large (~5.5 MB/minute per stream) and `StorageManager`'s quota only evicts `.m4a` archives — it will not reclaim them.** Diagnostic use only; turn it off afterwards. |
| `tap_auto_start` | bool | `true` | `kAudioAggregateDeviceTapAutoStartKey` for every aggregate the tap builds. `false` keeps the tap IOProc running continuously (zeros when idle), so "no callbacks" is never ambiguous (gotcha #78). The default is decided by measurement M-B (device item D-12). Sent to the helper before each start (`CaptureOptions`) and stamped into `captureStart` provenance. |
| `remote_exact_zero_soft_alarm_seconds` | int | unset (off) | Seconds of exact-zero remote audio after which the helper says "can't confirm" (`remoteCantConfirm`). Stays off unless the M-A census shows no call app renders exact zeros for a muted remote. |
| `debug_drop_tap_frames` | bool | `false` | DIAGNOSTIC: the helper drops every tap buffer before the heartbeat, reproducing Incident B ("expected but never delivered") on demand (device item D-04). **Never leave it on**: the remote side is not recorded while it is set. |
| `debug_skip_wav_sync` | bool | `false` | DIAGNOSTIC (#247): both WAV writers skip their periodic `fsync`; the header is still rewritten every 0.5 s. It exists for one A/B: whether that `fsync` is what stalls the capture callback (device item M-IO). **Never leave it on**: with the `fsync`, a power cut or kernel panic costs at most the last 0.5 s of audio; without it, whatever the OS had not flushed yet. A helper crash costs nothing extra (the data is already with the OS). Sent to the helper before each start (`CaptureOptions`), logged as a warning at start and stamped into `captureStart`. |

---

## Capture Reliability Detectors

The capture-reliability constants below are hardcoded (in `TranscriberCore` unless noted) and are **not configurable via `config.json`**. Design: `docs/superpowers/specs/2026-09-24-capture-reliability-design.md`. The only related `config.json` knobs are the four capture keys in Debugging above (`tap_auto_start`, `remote_exact_zero_soft_alarm_seconds`, `debug_drop_tap_frames`, `debug_skip_wav_sync`).

### Detection

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Exact-zero silence threshold | `ExactZeroRunMonitor.defaultThresholdSeconds` | `12` | Seconds of sustained exact-digital-zero mic samples before `micDigitalSilence` (e.g. lid closed on the built-in mic). |
| First-frame threshold | `TrackLivenessMonitor.init` `firstFrameThresholdSeconds` | `5` | Seconds after the monitor is armed (start, rebuild, wake) with no heartbeat before `.neverDelivered`. For the tap the clock runs only while the gate is open. |
| Stall threshold | `TrackLivenessMonitor.init` `stallThresholdSeconds` | `3` | Seconds without a heartbeat, counted while the gate is open, before `.stalled`. Replaces `LivenessGapDetector.defaultGapThresholdSeconds` (deleted). |
| Gate debounce | `TrackLivenessMonitor.gateCloseTicks` | `2` | Consecutive closed ticks (at 1 Hz) before the tap's "another process is running output" gate counts as closed. A one-tick dropout neither clears an episode nor restarts a clock. |
| Watchdog tick | `LivenessWatchdogDriver` (helper) | `1` s | The liveness check and the gate probe run on this tick. The debounce counts ticks, so only the tick feeds the gate to the monitors. |
| Accelerator check | `LivenessWatchdogDriver.accelerate` (helper) | `1` s | After an aggregate event (`goin`→0, `stpd`, `diff`, `agrp`), a stall is reported if no heartbeat arrived in this time. An accelerator never triggers a blind rebuild. |
| Write-progress stall | `WriteProgressMonitor.stuckSeconds` | `5` | A track whose heartbeat flows but that writes nothing for this long raises its not-delivering alarm ("audio arrives but can't be recorded"). |
| Frame-count tolerance ratio | `FrameCountPlausibility.defaultToleranceRatio` | `0.10` | Allowed fractional deviation between a track's total recorded frames and its expected count from wall-clock elapsed time, at finalize. |
| Frame-count minimum elapsed | `FrameCountPlausibility.defaultMinimumElapsedSeconds` | `30` | Session must have run at least this long before the frame-count-vs-wall-clock check is judged (avoids false positives on very short sessions). |
| Frame-count minimum deficit | `FrameCountPlausibility.defaultMinimumDeficitSeconds` | `15` | Minimum absolute shortfall (seconds of missing audio) before a tolerance-ratio breach is reported, so a technically-out-of-ratio but tiny gap doesn't fire. |

### Callback timing (#247)

A measurement, not a detector: it changes nothing about the recording. Each tap and mic callback is timed per stage (`IOCycleStats`: queue wait, convert, pad, write, sync, check, total), from its start to the last clock reading before it returns.

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Overrun threshold | `IOCycleStats.overrunThresholdNanos` | `11.35` ms | A callback whose total is OVER this is counted as an overrun: the IO budget `coreaudiod` reported for the tap (#247). It was 8 ms until v0.9.1; healthy recordings logged 8.8–11 ms cycles that cost nothing. For the tap the total starts at the HAL's cycle start, so it includes the wait for the helper's audio queue; for the mic it starts at the callback's first line. |
| Overrun event interval | `IOCycleStats.overrunReportIntervalNanos` | `10` s | At most one `ioOverrun` event per track per this long. Every overrun is still counted (`remote_io_overruns` / `local_io_overruns` in `captureStop`). |
| Histogram resolution | `IOCycleStats.bucketCount` | `70` per stage | Four buckets per octave from 8.192 µs to 1.074 s, one below, one above. A percentile is the upper edge of its bucket, never above the exact maximum: at most 25 % over the true value, never under. The maximum and the overrun count are exact. |
| Periodic WAV sync | `WavFileWriter.syncInterval` | `500` ms | How often an append also rewrites the header and `fsync`s, per writer. `debug_skip_wav_sync` leaves out the `fsync` only. |

### Healing

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Rung backoff | `TapRecoveryLadder.backoff` | `[0.25, 0.5, 1, 2]` s | Delay before each ladder run after the first, which runs at once. |
| Fast window | `TapRecoveryLadder.fastWindowSeconds` | `15` | Rungs run within this window of the episode's start; past it the ladder gives up (alarm + slow retry). |
| Heartbeat deadline | `TapRecoveryLadder.heartbeatDeadlineSeconds` | `3` | After a rung succeeds, a heartbeat must arrive within this long (tokened to the rung), else the next rung. |
| Slow retry | `TapRecoveryLadder.slowRetrySeconds` | `60` | After a give-up, one tap rebuild this often while the gate stays open. |
| Rung budget | `TapRecoveryLadder.rungBudget` | `2` | Attempts per rung (aggregate rebuild, then new tap) per episode; rebuilds the ladder did not order count too. |
| Sustained health | `TapRecoveryLadder.sustainedHealthSeconds` (also `MicHealPolicy`) | `30` | A heal must hold this long before the episode ends and its budget is refunded; a stall sooner continues the episode. |
| Stuck rung | `TapHealer.stuckSeconds` | `5` | A rung that has not returned within this long raises `remoteRecoveryFailed`. |
| Mic reopen deadline | `MicHealPolicy.reopenDeadlineSeconds` | `8` | A mic reopen that has delivered no newer heartbeat by then raises `micNotDelivering` (stuck, or reopened but silent). |
| Sleep pause expiry | `SleepPauseClock.expirySeconds` | `30` | Awake seconds after an unclassified power-on (or after the pause, without power notifications) before the liveness pause ends on its own. |
| DarkWake pause expiry | `SleepPauseClock.darkPowerOnExpirySeconds` | `300` | The same bound after a power-on that read DarkWake (Power Nap). |

### Alarms and presentation

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Notify floor | `AlarmRealarmPolicy.notifyInterval` | `120` s | Per KIND, across episodes and clears: a kind notifies at once only if it has not notified within this long. Acknowledgeable kinds notify once and never re-notify. |
| Idle backoff | `AlarmRealarmPolicy.idleRenotifyInterval` | `120` → `600` → `3600` s | While not recording, a live alarm re-notifies after 2 min, then 10 min, then at most hourly. |
| "Later" snooze | `CaptureReadiness.repairSnooze` | `180` s | The alarm window (and the repair window) stays closed this long after "Later", unless a new kind arrives. |
| Repair-notification dedup | `AlarmRealarmPolicy.repairNotificationDedupWindow` | `30` s | The repair window skips its own notification when the alarm's notification for the same problem went out this recently. |
| Status poll | `RecordingCoordinator.statusPollInterval` | `5` s | The app pulls the helper's alarm snapshot this often while recording. 3 unanswered polls in a row raise `helperUnresponsive`. |
| Recovery confirmation | `RecordingCoordinator.recoveryConfirmationSeconds` | `60` | The XPC retry streak resets only after this long of confirmed frames following a restart. |

### Lifecycle

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Helper call deadlines | `AudioCaptureClient` (app), via `Deadline.swift` | start `15`, stop `20`, rotate `10`, mic switch `10`, status / drain / configure / power event / permission `3` s | Awake time (`SuspendingClock`): a Mac that sleeps through a call never times out at wake. |
| Helper start deadline | `CaptureLifecycle.startTimeoutSeconds` | `20` | The helper abandons a start that has not finished (longer than the app's 15 s, so the app gives up first). |
| Helper source stop | `CaptureLifecycle.sourceStopTimeoutSeconds` | `3` | How long a helper Stop waits for mic and tap to stop before abandoning them. |
| Writer-swap bound | `AbandonableStep.rotationTimeoutSeconds` | `3` | A rotation's writer swap on a stalled audio queue is abandoned after this (it never applies late). |
| Resume window | `RelaunchDecision.resumeWindow` | `180` s | A relaunch strictly within this long of the last-alive time resumes the same session; otherwise it salvages and says STOPPED. |
| Alive refresh | `RecordingCoordinator.aliveRefreshInterval` | `60` s | The sentinel's `lastAliveAt` is refreshed this often while recording, and at every rotation. |
| Hand-over cooldown | `LaunchAgentHealth.handOverCooldown` | `30` s | Minimum time between two crash-protection hand-overs; persisted in `UserDefaults`. |
| Hand-over attempts | `LaunchAgentHealth.maxHandOverAttempts` | `3` | Failed kickstarts per process before the row says crash protection is off. |
| Window deferral | `LaunchAgentHealth.windowDeferralLimit` | `15` min | Open Parley windows defer the hand-over at most this long while idle; after that the row says why. |
| Lock wait | `SingleInstancePolicy.lockWaitTimeout` | `10` s | launchd's own copy waits this long for the single-instance lock during a hand-over, then exits 0. |
| Quit stop bound | `TerminationPolicy.userQuitBound` | `30` s | Parley's own Quit (confirmed) stops the recording within this bound before the app ends. |
| Termination stop bound | `TerminationPolicy.terminationBound` | `5` s | A logout, shutdown, restart or outside quit stops a recording within this bound; the next launch salvages. |
| Disk headroom | `DiskSpaceCheck.headroomBytes` | `200 MB` | Start is refused below 2 chunks + this. A chunk is `chunk_duration_minutes × 60 × 2 × 96 000` bytes. `diskLow` is raised below 1 chunk at a rotation and cleared at 2. |
| Folder read bound | `SessionEvidence.folderDeadlineSeconds` | `5` | Bound on the record's reads of a recording folder at finalize. |
| Chunk processing bound | `RecordingCoordinator.chunkProcessingBound` | the audio still being processed, at least `300` s (`chunkProcessingFloor`) | How long a Stop or a salvage waits for the chunks still being transcribed (#226): the time from when the oldest unfinished chunk began recording until now, never under the floor. Past it the session is kept pending ("Parley will finish it when the folder answers"), its chunks go on being processed, and it is finished once they end, or at the next launch. Not a config key. |
| Last-chunk seal wait | `RecordingCoordinator.sealWait` | stable `1` s, looked at every `200` ms, at most `3` s | Before a live chunk is re-ingested after a stop the helper did not answer (or a crash), its files must keep their size this long (#232). When the wait runs out the chunk is processed as it is, and the message says the last chunk could not be checked. Not a config key. |

### Record

| Parameter | Location | Value | Description |
|-----------|----------|-------|-------------|
| Coverage deficit | `TrackAccounting.minimumDeficitSeconds` / `deficitRatio` | `15` s and `0.10` | A side is `compromised` when its deficit (expected − delivered seconds) is at least 15 s AND at least 10 % of expected. |
| Never delivered | `TrackAccounting.status` | expected `≥ 1` s, delivered `0` | On both tracks, checked before the content-anomaly rule. |
| Merge gap fill | `AudioConcatenator.gapThresholdSeconds` | `1` s | A wall-clock gap between chunks longer than this is filled with silence in the merged `.m4a`. |
| Merge bound | `AudioConcatenator.maxInsertedSilenceSeconds` | `12` h | More inserted silence than this (one gap or all together) means the timing is wrong: the merge is skipped (`merge_skipped_implausible_timing`) and each chunk's audio is listed. |

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
