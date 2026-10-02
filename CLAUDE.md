@AGENTS.md

<!-- AGENTS.md (imported above) holds the rules every agent follows: how work lands, the `just`
     commands, the repo rules, the nevers. This file holds the project knowledge. -->

# Transcriber - Project Instructions

## Environment
- macOS only (requires Apple Silicon for CoreML/ANE acceleration)
- Requires macOS 15.0+ (deployment target). Microphone is captured via AVCaptureSession (#96); system audio via the Core Audio tap (default for new installs) or ScreenCaptureKit (legacy, until #221)
- No Python/conda required for the app itself (fully Swift-native)
- Benchmark tool (`tools/engine-benchmark/`) optionally uses Python for mlx-whisper comparison — use conda if running that

## Project Overview
macOS menu bar app for meeting transcription (mic + system audio from Zoom/Teams/Meet).
- **SwiftUI**: native menu bar app (`MenuBarExtra` + `Settings` scene), audio capture via XPC service
- Swappable transcription engines: FluidAudio (Parakeet, default) and SpeechAnalyzer (Apple, labelled "not yet usable" until #223) — selectable in Settings via `EngineID`

## Architecture

### SwiftUI App (TranscriberApp target)
- `TranscriberApp/TranscriberApp.swift` -- `@main` entry point, MenuBarExtra + Settings scenes
- `TranscriberApp/Services/AudioCaptureClient.swift` -- XPC connection to audio capture service, crash detection via `onServiceCrash` callback armed per capture generation (`XPCInterruptionPolicy`), `isCapturing()` ping for recovery, a deadline on every helper call (`Deadline.swift`), the helper's alarm snapshots and evidence (first frames, real audio, write succeeded) forwarded to the coordinator; conforms to Core's `RecordingCaptureClient` seam
- `TranscriberApp/Services/CalendarService.swift` -- EventKit lookup for current meeting title
- `TranscriberApp/Services/CLIHandler.swift` -- CLI entry point dispatching parsed commands (transcribe, rename, benchmark) to their handlers
- `TranscriberApp/Services/CLIRename.swift` -- interactive CLI speaker rename: prompts per speaker and plays samples; collection + rename application live in TranscriptRenamer (TranscriberCore)
- `TranscriberApp/Services/MicSwitchWindowController.swift` -- opens mic switch dialog as floating NSPanel during recording
- `TranscriberApp/Services/RenameWindowController.swift` -- opens speaker rename dialog as NSPanel; one off-main parse of the transcript gives the dialog its speaker rows, the saved channel names (#207) and the echo findings (`EchoNotice.Findings`, #244)
- `TranscriberApp/Services/SessionNameWindowController.swift` -- opens session naming dialog as NSPanel
- `TranscriberApp/Services/SetupWindowController.swift` -- opens permission setup window as NSWindow at launch
- `TranscriberApp/Services/SystemPermissionChecker.swift` -- real macOS permission API wrapper (AVCaptureDevice, CGPreflight, EventKit, UNUserNotificationCenter); System Audio Recording is asked of the helper over XPC
- `TranscriberApp/Services/PermissionRepairWindowController.swift` -- checks recording permissions at launch, record start, capture-method change and on helper evidence; opens the floating repair window and rebuilds the tap once fixed (#220)
- `TranscriberApp/Views/PermissionRepairView.swift` -- repair window: lists only what's missing with a one-click fix, polls every 2 s only while open, closes itself when resolved
- `TranscriberApp/Services/AppTerminationDelegate.swift` -- answers `applicationShouldTerminate` via `TerminationPolicy`: a logout/shutdown/restart or an outside quit (Activity Monitor, `osascript`, Sparkle) stops a recording within a tight bound first; every terminate flushes the live diagnostic logs, bounded
- `TranscriberApp/Services/CaptureAlarmWindowController.swift` -- presents capture alarms (§6.3): floating non-activating panel listing every active alarm + one time-sensitive notification per kind (stable identifier); the coordinator decides when (per-kind notify floor), `AlarmRealarmPolicy.presentation` decides what; permission alarms are left to the repair window while it covers them
- `TranscriberApp/Services/SystemEventObserver.swift` -- forwards `NSWorkspace` sleep/wake to the coordinator and notes `willPowerOff` for the termination delegate (fast user switching deliberately ignored); a volume mount or wake retries the sessions a relaunch could not finish
- `TranscriberApp/Views/CaptureAlarmView.swift` -- the alarm window's content: every active alarm with its one action; only past (acknowledgeable) events can be dismissed, "Later" just snoozes the window
- `TranscriberApp/Services/UpdaterController.swift` -- hosts `CheckForUpdatesViewModel` + `CheckForUpdatesView`, driving the "Check for Updates..." menu item via `SPUUpdater.canCheckForUpdates` KVO
- `TranscriberApp/Views/MenuView.swift` -- window-style menu bar panel (status header, live timer, record button, action rows); presentation only — recording lifecycle + crash recovery delegate to Core's `RecordingCoordinator`
- `TranscriberApp/Views/DesignSystem.swift` -- shared "Quiet Confidence" components (MenuActionRow, IconTile, StatusDot, AlertBanner, folder-picker helpers); see docs/design/design-system-0.8.x.md
- `TranscriberApp/Views/SettingsView.swift` -- tabbed settings window (General/Audio/Transcription/Summary/Permissions), manual Save semantics; triggers eager model download on Save when engine requires it
- `TranscriberApp/Views/SetupView.swift` -- permission + engine setup window (shown at first launch or when model not cached); gates Continue on permissions AND model download
- `TranscriberApp/Views/RenameDialog.swift` -- speaker rename sheet with sample text and audio playback from source WAV timestamps; per-channel speaker count + Re-detect; shows `EchoNotice`'s copy on an echo voice's card and under the re-detect row, and pre-fills the count with the people on the channel, not the rows (#244)
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording (includes mic picker)
- `TranscriberApp/Views/MicrophonePicker.swift` -- mic device dropdown + live level meter (used in SessionNameDialog)
- `TranscriberApp/Views/MicSwitchDialog.swift` -- mic device picker for switching microphone mid-recording

### XPC Audio Capture Service (AudioCaptureHelperXPC target)
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` -- implements AudioCaptureProtocol; drives system-audio capture via the Core Audio tap (default) or ScreenCaptureKit (legacy), plus mic capture; owns the helper's alarm registry (`captureStatus` pull + `captureAlarmsChanged` push under an ordered `HelperSessionId`), the capture-session claim (`CaptureLifecycle`), the tap healer, the mic heal policy, write-progress checks and per-track coverage
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` -- writes system audio (from the SCStream `.audio` output) and mic buffers (fed via `appendMicSampleBuffer()` from `MicCaptureSession`, #96) to WavFileWriters; auto-detects sample format (Float32/Int16) and channel count. Since #96 the SCStream delivers system audio only — `.microphone` is no longer registered. Times every tap and mic callback per stage (`IOCycleStats`, #247) and records `ioOverrun`.
- `AudioCaptureHelper/XPC/SystemTapSession.swift` -- Core Audio output process tap for system audio (#103), selected by `system_audio_source: core_audio_tap`; captures Continuity/VoIP calls ScreenCaptureKit misses
- `AudioCaptureHelper/XPC/MicCaptureSession.swift` -- microphone capture session feeding the mic WAV stream
- `AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift` -- off-audio-queue 1 Hz driver for `TrackLivenessMonitor` with the process-level `OutputActivityProbe` gate, fed to the monitors on the tick only (the gate debounce counts ticks): owns its own `DispatchSourceTimer` on a dedicated serial queue, never the real-time audio callback path (#196); aggregate-listener accelerators, the sleep pause (`SleepPauseClock`)
- `AudioCaptureHelper/XPC/OutputActivityProbe.swift` -- reads Core Audio's process objects on each watchdog tick (and once per accelerator check): is any OTHER process running output (`kAudioProcessPropertyIsRunningOutput`, own pid excluded, fails open); rule in `OutputActivity`
- `AudioCaptureHelper/XPC/SystemPowerObserver.swift` -- the helper's own IOKit sleep/wake (will-sleep, powered-on with full-wake vs DarkWake), acknowledged at once on its own queue, so the liveness pause never depends on the app's messages alone
- `AudioCaptureHelper/XPC/main.swift` -- NSXPCListener entry point, shared service instance, connection invalidation handler

### Shared Protocol (AudioCaptureProtocol target)
- `AudioCaptureProtocol/AudioCaptureProtocol.swift` -- @objc XPC protocol + service name constant

### Shared Logic (TranscriberCore target)
- `TranscriberCore/AppState.swift` -- Observable state machine: idle -> recording -> transcribing -> idle, `interruptionWarning` for benign notices, sticky `alarms` (`CaptureAlarmRegistry`: helper snapshots applied, app alarms raised/acknowledged)
- `TranscriberCore/AudioConverter.swift` -- converts arbitrary PCM audio buffers to fixed 48kHz mono Int16 via AVAudioConverter, auto-detects source format changes (e.g. mic switch)
- `TranscriberCore/ChunkProcessor.swift` -- processes finalized audio chunks in background: transcribe, diarize, VAD, speaker assignment, archive to AAC, persist to session
- `TranscriberCore/ChunkRotator.swift` -- @MainActor timer-based WAV file rotation during recording, emits FinalizedChunk on each rotation
- `TranscriberCore/ChunkRotationClient.swift` -- protocol seam: the one capability ChunkRotator needs from the XPC audio client
- `TranscriberCore/ChunkSession.swift` -- Codable session state (SessionState) with ProcessedChunk model: segments, speaker embeddings, processing issues, echo cluster verdicts, and atomic JSON persistence
- `TranscriberCore/RecordingCaptureClient.swift` -- protocol seam (refines ChunkRotationClient) for everything RecordingCoordinator needs from the XPC capture client, plus the AudioPaths stop-result type; lets orchestration be tested with a fake
- `TranscriberCore/RecordingCoordinator.swift` -- recording lifecycle + crash-recovery orchestration (start/stop, XPC-crash retry/restart, abandoned-session salvage), moved out of MenuView (#139 PR-6) so it is unit-testable; app-side UI effects (notifications, rename dialog) are injected closures
- `TranscriberCore/TranscriptionRunner.swift` -- creates engine from config.engine, runs transcription + optional diarization; owns the chunked pipeline (setup/teardown, finalize)
- `TranscriberCore/CLIParser.swift` -- parses CLI arguments into CLICommand enum (transcribe, rename, renameGUI, benchmark, summarize) with typed option structs; SplitMode enum for stereo channel handling (split/noSplit/ask)
- `TranscriberCore/Config.swift` -- Codable config struct (snake_case JSON keys), includes `engine: EngineID` and optional `summary: SummaryConfig`
- `TranscriberCore/ConfigManager.swift` -- reads/writes `~/Library/Application Support/Parley/config.json`; migrates a legacy plaintext `summary.api_key` into the Keychain on every load (#48), idempotent, never clears the JSON field until the Keychain write succeeds
- `TranscriberCore/KeychainStore.swift` -- `KeychainStoring` protocol + `KeychainStore` (SecItem-backed) for string secrets, keyed by (service, account); `SummaryAPIKeyStore` facade holds the one secret this app stores (`Config.summary` has at most one active provider at a time, so a single fixed account is enough) — the summary API key never round-trips through config.json (#48)
- `TranscriberCore/EngineID.swift` -- engine enum (speechAnalyzer/fluidAudio) + EngineDescriptor metadata
- `TranscriberCore/TranscriptionEngine.swift` -- protocol for swappable transcription engines + AudioSourceType enum
- `TranscriberCore/FluidAudioEngine.swift` -- FluidAudio/Parakeet engine (fastest, 25 EU languages) with ITN text normalization; isModelCached()/preDownloadModel() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/FluidAudioDiarizer.swift` -- FluidAudio offline diarization (pyannote + WeSpeaker + VBx) with quality scores; isDiarizationCached()/preDownloadModels() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/SpeechAnalyzerEngine.swift` -- Apple SpeechAnalyzer engine (macOS 26+, no download), guarded with `#if compiler(>=6.2)`
- `TranscriberCore/DiarizationCleanup.swift` -- post-processes a raw `DiarizationResult` before labeling: absorbs clusters holding under `diarization_min_speaker_share` of a stream's speech into the dominant speaker, only when one cluster holds >=50% (#65)
- `TranscriberCore/TranscriptRediarizer.swift` -- re-runs diarization on ONE channel at a user-stated speaker count and rewrites the transcript in place (#67); relabels only, never re-runs ASR. On the mic channel it runs `EchoDeduplicator` on the diarizer's RAW clusters before the count is enforced (#243): a cluster judged echo is kept out of the merge and not counted as a person, its matched lines are flagged `echo`, and the track's `echo_clusters` / echo issues are rewritten; stamps `speaker_count_<track>` (people) and `rediarized_channels`
- `TranscriberCore/SpeakerCountEnforcer.swift` -- makes a user-stated speaker count binding: merges the smallest clusters into their nearest surviving cluster (cosine over the result's embeddings, duration as fallback) until exactly N remain (#201); the diarizer's forced count is a target, not a ceiling. Clusters passed in `keeping` (echo clusters, #243) are never merged away, never merged into and not counted
- `TranscriberCore/DiarizationProvider.swift` -- protocol for speaker diarization + DiarizedSegment model
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
- `TranscriberCore/SessionNameSuggestionPolicy.swift` -- pure decision: whether a late-arriving calendar title should replace the current session-name field value (#197)
- `TranscriberCore/WavFileWriter.swift` -- WAV file writing with deferred sample rate/channel count, Float32->Int16 conversion + direct Int16 passthrough, 0.5s periodic sync (timed for `IOCycleStats`; `debug_skip_wav_sync` leaves out the `fsync` only, #247); throwing `FileHandle` writes are caught and surfaced as a write-failure anomaly instead of crashing the helper (#196)
- `TranscriberCore/ExactZeroRunMonitor.swift` -- pure detector: fires after a sustained run of exact-zero mic samples (hardware-muted mic, e.g. lid closed on the built-in mic) (#193)
- `TranscriberCore/TrackLivenessMonitor.swift` -- pure liveness core: never-delivered / stalled (measured while the debounced gate is open) / first frames per track, from heartbeats stamped at the top of the audio callback (§4.2)
- `TranscriberCore/FrameCountPlausibility.swift` -- session-wide finalize backstop: compares each track's total recorded frames against wall-clock session duration (#196)
- `TranscriberCore/ClamshellMicGuard.swift` -- pre-flight check: warns before capture starts if the lid is closed and the built-in mic is selected (#193)
- `TranscriberCore/RecordingSentinel.swift` -- crash recovery sentinel file (JSON at ~/Library/Application Support/Parley/recording.json), atomic write/read/delete
- `TranscriberCore/LaunchAgentManager.swift` -- macOS LaunchAgent (KeepAlive) for auto-relaunch on crash: `verifyAndRepair(holdsInstanceLock:)` at every launch (judged from `launchctl print`, `enable` before every `bootstrap`, never `bootout` of this process), `handOverToJob` (`kickstart -k`), uninstall removes the plist before `bootout`; every `launchctl` call goes through the injectable `LaunchctlRunning` runner
- `TranscriberCore/SegmentDiscovery.swift` -- discover multi-segment audio files from crash recovery (base, -2, -3, ...)
- `TranscriberCore/SegmentNaming.swift` -- segment filename computation: strip `-N` suffix, append new segment number
- `TranscriberCore/SpeakerAssignment.swift` -- splits ASR segments at word-level diarization speaker-change boundaries (issue #120), then assigns speaker labels using diarization overlap, with deduplication and VAD-based quality filtering
- `TranscriberCore/StreamLabeling.swift` -- shared per-stream speaker labeling (withDiarization + singleSpeaker) used by both ChunkProcessor and TranscriptionRunner, so the labeling logic lives once
- `TranscriberCore/WordTiming.swift` -- engine-neutral per-word/run timing (start/end/text), populated by both ASR engines and consumed by SpeakerAssignment's boundary-split logic
- `TranscriberCore/SpeakerReconciler.swift` -- cross-chunk speaker matching via greedy cosine similarity on embeddings, maps local per-chunk speaker IDs to global namespace
- `TranscriberCore/TranscriptAssembler.swift` -- assembles labeled segments + metadata into transcript JSON dictionary for file output
- `TranscriberCore/TranscriptMerger.swift` -- merges processed chunks into a single time-sorted transcript with absolute timestamps and cross-chunk speaker remapping
- `TranscriberCore/TranscriptRenamer.swift` -- shared speaker-rename logic (SpeakerSample struct, per-speaker sample collection, rename application that merges into metadata.speaker_names — #162; flagged segments are renamed too, except on a channel listed in `metadata.rediarized_channels`, where an echo line of the mic channel carries its echo cluster's label or the unattributed one (#277) and any other flagged segment's label is an earlier diarization's — #245) used by both CLIRename and the GUI rename dialog
- `TranscriberCore/TranscriptWriter.swift` -- formats and writes transcripts in multiple formats (JSON, TXT, SRT) with timestamp formatting
- `TranscriberCore/TranscriptionRunner.swift` -- creates engine from config.engine, runs transcription + optional diarization
- `TranscriberCore/VadSpeechMap.swift` -- wraps FluidAudio VadManager to produce SpeechRegion map with probabilities for quality filtering
- `TranscriberCore/AudioDeviceEnumerator.swift` -- lists audio input devices via AVCaptureDevice.DiscoverySession, resolves last-used device
- `TranscriberCore/InputLevelMonitor.swift` -- @Observable real-time audio level (0-1) via AVCaptureSession, works with all device types including USB webcams; every device call runs on a per-session queue, never the caller's (#192). Also holds two process-wide types: `RecordingMicrophone` (the mic the recording is capturing — kept by RecordingCoordinator and the relaunch re-attach paths; no level meter ever opens it, and the coordinator mirrors it for the menu's mic label) and `PendingStartRegistry` (physical devices with a meter start still in flight — a second start on one waits instead of parking another thread in the same HAL wait). Budget: each picker showing a stuck mic holds one sleeping thread while it waits, so keep at most two pickers open at once (Settings plus one dialog) — a feature that adds a third must revisit this
- `TranscriberCore/AudioDeviceCatalog.swift` -- cached input-device list for views, scanned in the background and coalesced; `refreshed(timeout:)` for a bounded fresh scan (#192) — never call `AudioDeviceEnumerator.availableDevices()` on main
- `TranscriberCore/ResumeOnce.swift` -- resumes a continuation exactly once when work races a deadline
- `TranscriberCore/FilenameUtils.swift` -- sanitizeFilename (removes /, :, \0)
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol — source-aware: the tap needs System Audio Recording, ScreenCaptureKit needs Screen Recording (#220)
- `TranscriberCore/CaptureReadiness.swift` -- pure readiness decisions: required permissions per system-audio source, launch routing (after onboarding a missing permission goes to REPAIR, never the Setup lockout), fix action per status (#174, #220)
- `TranscriberCore/TapPermissionGuard.swift` -- pure state machine keeping the tap honest about its permission: rebuild after a grant, re-check/re-report only while a problem exists, "restored" only on real audio, no rebuild loops; counts exact-zero frames for provenance (#220)
- `TranscriberCore/BootSession.swift` -- `kern.bootsessionuuid` reader: the sentinel's stale-boot check, immune to sleep and wall-clock changes (gotcha #76)
- `TranscriberCore/CaptureAlarm.swift` -- capture-alarm vocabulary and state (§6): `CaptureTrack`, the ordered `HelperSessionId`, `AlarmKind` (owner, track, the evidence that disproves a stale one, acknowledgeable), `CaptureAlarmRegistry` (stale-until-disproved, per-kind notify floor), `CaptureStatusSnapshot` (tolerant of unknown kinds only), `AlarmRealarmPolicy` (2 min notify, idle backoff, presentation)
- `TranscriberCore/CaptureLifecycle.swift` -- the helper's capture-session claim (pure): tokened start reservation, a stop or disconnect aborts a start, 20 s start deadline, per-connection ownership, rotation gate; `AbandonableStep` bounds a rotation's writer swap
- `TranscriberCore/CaptureOptions.swift` -- what the app tells the helper before `startCapture` (`configureCapture`, strict decode): `tap_auto_start`, `remote_exact_zero_soft_alarm_seconds`, `debug_drop_tap_frames`, `debug_skip_wav_sync`
- `TranscriberCore/IOCycleStats.swift` -- per-stage timing of a capture callback (#247): inline fixed-size histograms (queue wait, convert, pad, write, sync, check, total; 4 buckets per octave), exact max and overrun count, a 10 s rate limit for the `ioOverrun` event, the stop summary (`remote_io_*` / `local_io_*`). Fed from the audio queue: no allocation, lock, log or clock inside. A measurement only; the structural fix is #248
- `TranscriberCore/CaptureReplies.swift` -- helper reply strings both sides match exactly: `No capture in progress` on a rotate is a dead capture; refused / cancelled / timed-out replies are not
- `TranscriberCore/CoalescingCheck.swift` -- runs one async check at a time; a caller arriving mid-check queues one merged re-run and waits for it (the permission repair check)
- `TranscriberCore/Deadline.swift` -- `withDeadline` / `boundedReply`: every helper-call deadline (§8.8), on `SuspendingClock` (awake time), reply / error / deadline raced through `ResumeOnce`
- `TranscriberCore/DiskSpaceCheck.swift` -- disk thresholds (§8.7): refuse to start below 2 chunks + 200 MB, `diskLow` below 1 chunk at a rotation; plain-capacity fallback on non-APFS volumes
- `TranscriberCore/EnginePreflight.swift` -- runs the chosen engine on one synthetic second (`SyntheticWAV`) at Setup Continue and Settings Save; refuses an engine that throws (§11.2). `saveStep` decides what a Save does: preflight then commit, or — the engine's model is not downloaded yet, so there is nothing to run — commit and let the Save download it
- `TranscriberCore/FolderReads.swift` -- every blocking read of a recording folder, off the cooperative pool on one serial queue per volume, bounded on awake time; a hung share holds only its own volume's queue
- `TranscriberCore/GapTracker.swift` -- real per-track gap durations for coverage: a silence verdict opens a gap from the last heartbeat, first frames close it; the longest gap, an open one included
- `TranscriberCore/LaunchAgentHealth.swift` -- pure crash-protection judgement (L11): `healthy / missing / stalePath / notLoaded / loadedButNotThisProcess` → action, and `crashProtectionAction` (hand over when idle, 30 s cooldown, 3 attempts, window deferral bounded at 15 min, the honest row otherwise)
- `TranscriberCore/LiveDiagnosticsLog.swift` -- append-as-you-go `<session>.diag.live.jsonl` (ms-precision dates, deduplicated on merge) plus `<session>.diag.coverage.json` (latest coverage per helper session); one write queue per folder, flushed (bounded) on every orderly exit
- `TranscriberCore/MicHealPolicy.swift` -- mic side of heal-then-alarm: the first silence verdict reopens the mic, a repeat reopens and alarms; 8 s reopen deadline; 30 s sustained health ends an episode; a failed follow while the old mic records is `micFollowFailed`
- `TranscriberCore/MonotonicWallClock.swift` -- wall-clock anchor advanced by `ContinuousClock` for chunk start times (§8.12); a resume re-anchors at the current time
- `TranscriberCore/OneAtATimeQueue.swift` -- runs items one at a time, in order (one rename panel at a time when a recovery pass salvages several recordings)
- `TranscriberCore/OutputActivity.swift` -- the tap's "expected" rule (§4.3): is any OTHER process running output; process-level, route-independent, fails open
- `TranscriberCore/RecordingCoordinator+Lifecycle.swift` -- coordinator extension: sleep/wake handling (lost-wake watchdog, idle-sleep activity), the Quit gate and bounded stop, termination / power-off marks
- `TranscriberCore/RecordingFolder.swift` -- coordinator extension: off-main folder scans for re-attach, resume and salvage; folder reachability; the relaunch crash time (newest orphan WAV mtime, else `lastAliveAt`)
- `TranscriberCore/RecoveryMessages.swift` -- `SalvageOutcome` (what a salvage actually did) and every recovery / relaunch / stop-failure message built from it, so no message claims a transcript that does not exist
- `TranscriberCore/RelaunchDecision.swift` -- pure relaunch decision (§8.3): re-attach, resume the same session (< 180 s since last alive), salvage and say STOPPED, salvage a stale boot, or wait for an unreachable folder; `stopping` beats a capturing helper
- `TranscriberCore/RenameReads.swift` -- the rename panel's transcript reads: off-main, bounded (10 s), on a folder reader of its own so a slow parse never blocks a recovery read
- `TranscriberCore/SentinelIO.swift` -- the recovery sentinel's and the pending list's I/O on one serial queue off the main actor; exit marks wait only within a bound
- `TranscriberCore/SessionEvidence.swift` -- the app's capture evidence for the session in progress (§8.11): diagnostic ring, live log and per-helper-session coverage; reset on a new session, kept across an in-session restart or resume; builds the record at finalize
- `TranscriberCore/SingleInstancePolicy.swift` -- pure decision when the single-instance lock is held: proceed, yield, or (launchd's own job during a hand-over) wait up to 10 s for the lock and exit 0 on timeout
- `TranscriberCore/SleepPauseClock.swift` -- the helper's sleep pause: app and IOKit sleep/wake, DarkWake vs full wake, every path ends in a bounded expiry (30 s, 300 s after a DarkWake power-on); mic work that arrives while paused waits for the wake
- `TranscriberCore/SyntheticWAV.swift` -- writes a tiny real WAV (a -20 dBFS tone) for the engine preflight
- `TranscriberCore/TapHealer.swift` -- runs `TapRecoveryLadder`'s actions: rungs with tokens, heartbeat deadline, 5 s stuck watchdog, 60 s slow retry; suspended across sleep and after stop; injectable `HealerScheduler` for tests
- `TranscriberCore/TapRecoveryLadder.swift` -- the tap's pure healing ladder (§5): aggregate rebuild then new tap, backoff 0.25/0.5/1/2 s, 2 attempts per rung in a 15 s fast window, 3 s tokened heartbeat deadline, 30 s sustained health before a refund, dead state remembered across a gate close
- `TranscriberCore/TerminationPolicy.swift` -- pure answer to `applicationShouldTerminate`: Parley's own Quit ends at once (its stop already ran, ≤ 30 s), a power-off or outside quit with work in flight stops within 5 s and leaves the sentinel for the next launch
- `TranscriberCore/TrackAccounting.swift` -- per-track coverage (§7.1): expected / delivered / exact-zero / padded seconds, gaps, rebuilds; status `healthy / idle / neverDelivered / compromised`; `capture_provenance` and `metadata.capture` dictionaries
- `TranscriberCore/WriteProgressMonitor.swift` -- per-track write progress next to the heartbeat: called but nothing written for 5 s raises the track's not-delivering alarm (`DeliveryAlarmGate` decides what may clear it)
- `TranscriberCore/XPCInterruptionPolicy.swift` -- what an XPC interruption/invalidation means, armed per capture generation: an idle-exit is ignored (no ping, no latch), a crash fires at most once per generation (gotcha #74)
- `TranscriberCore/SystemAudioRecordingPermission.swift` -- private TCC SPI wrapper (`dlsym`) for `kTCCServiceAudioCapture`; preflight is cached per process, so live checks go through the helper (gotcha #70, docs/app-store-blockers.md)
- `TranscriberCore/PathDisplay.swift` -- prefix-anchored `~` abbreviation of filesystem paths for display (shared by Setup + Settings)
- `TranscriberCore/RecordingTimer.swift` -- pure elapsed-time formatting (mm:ss / h:mm:ss) for the menu bar live timer
- `TranscriberCore/BuildConfiguration.swift` -- whether this binary is a debug or a release build (`#if DEBUG`), with the stable names `"debug"` / `"release"`; the capture helper stamps it into `captureStart` as `build` (#271)
- `TranscriberCore/Log.swift` -- os.Logger extension with 6 category loggers (audio, transcription, state, config, permissions, files)
- `TranscriberCore/AudioSourceResolver.swift` -- detects input format (dual WAV or stereo AAC), splits stereo AAC channels (L=local mic, R=remote system) for pipeline re-ingestion
- `TranscriberCore/OutputDirectory.swift` -- `ensureExists`: creates a caller-supplied output directory (with intermediates) before Core writes into it, or throws `OutputDirectoryError` naming it (#246); called by `AudioSourceResolver`'s split and by the CLI for `--output-dir`, deliberately not by `TranscriptionRunner.run()` (the app's stop/recovery path must fail visibly if its folder vanished)
- `TranscriberCore/AudioArchiver.swift` -- converts dual WAV (system+mic) to stereo AAC archive (L=mic, R=system) via AVAssetWriter, deletes source WAVs on success
- `TranscriberCore/StorageManager.swift` -- enforces audio archive storage quota in hours, deletes oldest .m4a files first, never deletes transcripts nor the archives of a session that still has a session file in its folder (#230)
- `TranscriberCore/SummaryProvider.swift` -- protocol for LLM summary providers + SummarySegment/SummaryMetadata types
- `TranscriberCore/SummaryDisclosure.swift` -- #138 disclosure stamp: whether a transcript's contents were transmitted off-machine (summary endpoint host only, on-device vs remote); airgapped by default, updated when a summary runs
- `TranscriberCore/SummaryPromptBuilder.swift` -- shared prompt + transcript/date/duration formatting (systemMessage + userMessage) used by both summary providers, so the prompt lives once
- `TranscriberCore/OpenAISummaryProvider.swift` -- OpenAI-compatible chat completions provider via /v1/chat/completions (covers OpenAI, Claude proxy, Ollama, LM Studio OpenAI mode)
- `TranscriberCore/LMStudioSummaryProvider.swift` -- LM Studio native REST API v1 provider via /api/v1/chat with per-request context_length, token stats, and self-correcting retry on context overflow
- `TranscriberCore/MeetingSummarizer.swift` -- orchestrator: reads transcript JSON, selects provider from config, calls provider, writes -summary.md; createProvider(from:) factory for both provider types; summarizeIfConfigured returns a SummaryOutcome (skipped/succeeded/failed) so callers can surface failures instead of them being silent (#134)
- `TranscriberCore/TokenRatioCache.swift` -- per-model chars-per-token ratio cache at ~/Library/Application Support/Parley/token-ratios.json; probe calibration on first use, continuous refinement from real transcript stats, seed vs measured distinction, legacy format migration
- `TranscriberCore/EchoDeduplicator.swift` -- echo dedup by cluster verdict (#242): matches each local segment against every remote speaker on time (>50% overlap) and text (>70% word overlap), judges each local cluster (echo at >=50% of its duration matched over >=30 s), and FLAGS as `echo: true` every matched segment of an echo cluster and, elsewhere, matches of 3+ words; kept in the JSON and hidden from TXT/SRT/summary, never deleted. The speaker-embedding cosine is recorded as evidence only. `ClusterVerdict` (per local cluster: counts, share, verdict, matched remote labels) feeds `ProcessedChunk.echoClusters` and `metadata.echo_clusters`
- `TranscriberCore/EchoNotice.swift` -- what the UI says about echo (#244), from the transcript's metadata only: `Findings` sums `echo_clusters` by label (a label with an `"echo"` verdict is an echo voice), finds its speaker row through `speaker_names`, and counts the PEOPLE on a channel (rows that are not an echo voice, never below `speaker_count_<track>`); pure copy builders for the speaker card, the re-detect row (hint + outcome) and the completion notice (`CaptureQualityNotice` takes `echoLines`). Labels, never names; "looks like", never "is"

## Audio Capture Architecture (critical knowledge)
- Swift captures TWO WAV files: system audio + microphone (separate streams)
- System audio source is selectable via `system_audio_source` (Config): `core_audio_tap` = Core Audio output process tap (#103, default for new installs; a strict superset that also captures Continuity/VoIP calls SCK misses), `sck` = ScreenCaptureKit (legacy, until #221; still the decode fallback for an existing config.json without the key). Mic is captured independently either way.
- SCStream `.audio` output type = system audio only (at 48 kHz, hardcoded). Since #96 the stream registers `.audio` ONLY — `.microphone` is no longer used.
- Mic is captured independently by `MicCaptureSession` (AVCaptureSession, #96) at NATIVE device rate (varies: 16kHz, 24kHz, 48kHz) and fed to `AudioOutputHandler` via `appendMicSampleBuffer()`
- There is NO Apple API to get a pre-mixed stream (verified in SDK headers through macOS 26)
- Handler must be stored to prevent deallocation
- Must use async/await API, not completion-handler callbacks (callbacks don't deliver frames reliably)
- XPC service requires embedding in .app bundle -- bare binary can't reach the service
- Exit code 2 = permission denied

## Build & Test

### Swift (SwiftUI app + XPC service)
```bash
swift build
# Produces .build/debug/Parley and .build/debug/audio-capture-helper-xpc

swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
# 2480 tests across 272 suites (Config, ConfigManager, EngineID, WavFileWriter, AppState, FilenameUtils, CalendarEventPicker, PermissionManager, AudioDeviceEnumerator, InputLevelMonitor, RecordingSentinel, LaunchAgentManager, DiscoverSegments, SegmentNaming, SpeakerAssignment, SpeakerBoundarySplitTests, DiarizationCleanup, DiarizerSpeakerCount, TranscriptRediarizer, SpeakerCountEnforcer, SpeakerReconciler, TranscriptMerger, ChunkSession, ChunkRecovery, AudioConverter, VadSpeechMap, ChunkRotator, ChunkProcessor, CLIParser, RecordingTimer, PathDisplay, OpenAISummaryProvider, LMStudioSummaryProvider, MeetingSummarizer, TokenRatioCache, EchoDeduplicator, EchoNotice, KeychainStore, etc.)
# Uses Swift Testing, not XCTest -- no Xcode installed, only CommandLineTools
# Test path: SwiftTests/TranscriberTests/ (not Tests/ -- case collision with Python tests/ on APFS)
```

## Always identify the RUNNING build before diagnosing a recording
A bug report about a real recording is a report about **the build that produced it**, which is very
often not the branch checked out in your working tree. Establish provenance FIRST — before reading any
code, or you will debug a file the recording never ran:

```bash
/usr/bin/defaults read /Applications/Parley.app/Contents/Info.plist ATGitDescription  # e.g. v0.9.0-beta.1
/usr/bin/stat -f '%Sm' /Applications/Parley.app/Contents/MacOS/Parley                 # build time
git log -1 --format='%h %ci %s' <that-tag>                                            # the actual source
git merge-base --is-ancestor <fix-commit> <that-tag> && echo "fix present" || echo "fix ABSENT"
```

Then read the code **at that commit** (`git show <tag>:path/to/File.swift`), not at `HEAD`. Note that
squash-merged PRs mean a fix commit from a feature branch is *not* an ancestor of `main` even though its
content shipped — check the squash commit, not the original SHA. And when you finish work, verify what
is installed matches what you just built, so the next recording exercises the new code.

Each recording also writes a `.diag.jsonl` beside its audio — a per-session event log (format
detection, device changes, restarts, anomalies). Read it before theorising; it frequently names the
fault outright. Its `captureStart` event says which kind of build recorded it: `"build": "release"` or
`"debug"` (#271). A timing or an allocation count from a debug build is not the shipped app's.

## Documentation
- [docs/development-process.md](docs/development-process.md) -- How work gets from idea to release; when to bump MINOR vs PATCH
- [docs/pipeline.md](docs/pipeline.md) -- End-to-end pipeline: recording → transcription → echo dedup → summary
- [docs/parameters.md](docs/parameters.md) -- All tunable parameters with config keys and defaults
- [docs/gotchas.md](docs/gotchas.md) -- 84 platform-specific gotchas
- [docs/mic-capture-design.md](docs/mic-capture-design.md) -- Mic capture API choice (AVCaptureSession + Core Audio HAL) + auto-follow-default direction + when to revisit AVAudioEngine
- [docs/benchmarks/](docs/benchmarks/) -- Dated benchmark reports
- [docs/app-store-blockers.md](docs/app-store-blockers.md) -- choices that would not survive App Store review (private SPI, global tap, LaunchAgent) — add an entry with any new one

## Key Gotchas
See [docs/gotchas.md](docs/gotchas.md) -- 84 platform-specific gotchas (macOS APIs, ScreenCaptureKit, XPC, audio formats, TCC, Liquid Glass, engine quirks). New items are appended there.

## Debugging
See [docs/pipeline.md](docs/pipeline.md#debugging) for full unified logging reference.

```bash
# All logs (debug + info + error)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug

# Via dev.py (builds a RELEASE build, installs, launches + tails log; `--debug` is about the log, not the build)
python3 scripts/dev.py --debug
# The fast inner loop: an unoptimised debug build. Not for real meetings or for timings (gotcha 84)
python3 scripts/dev.py --debug-build
```

## Packaging
See [docs/pipeline.md](docs/pipeline.md#packaging) for bundle structure, Info.plist, and dev.py details.

## Branches
- `main` -- stable (Python rumps UI)
- `feature/swiftui-native-ui` -- SwiftUI native UI rewrite
- `feature/whisperkit-migration` -- engine abstraction: swappable engines replacing hardcoded WhisperKit (this branch)
