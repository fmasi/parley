# Transcriber - Project Instructions

## Environment
- macOS only (requires Apple Silicon for CoreML/ANE acceleration)
- Requires macOS 15.0+ (deployment target). Microphone is captured via AVCaptureSession (#96); system audio via ScreenCaptureKit (default) or the Core Audio tap
- No Python/conda required for the app itself (fully Swift-native)
- Benchmark tool (`tools/engine-benchmark/`) optionally uses Python for mlx-whisper comparison — use conda if running that

## Project Overview
macOS menu bar app for meeting transcription (mic + system audio from Zoom/Teams/Meet).
- **SwiftUI**: native menu bar app (`MenuBarExtra` + `Settings` scene), audio capture via XPC service
- Swappable transcription engines: SpeechAnalyzer (Apple, default) and FluidAudio (Parakeet) — selectable in Settings via `EngineID`

## Architecture

### SwiftUI App (TranscriberApp target)
- `TranscriberApp/TranscriberApp.swift` -- `@main` entry point, MenuBarExtra + Settings scenes
- `TranscriberApp/Services/AudioCaptureClient.swift` -- XPC connection to audio capture service, crash detection via `onServiceCrash` callback, `isCapturing()` ping for recovery
- `TranscriberApp/Services/TranscriptionRunner.swift` -- creates engine from config.engine, runs transcription + optional diarization
- `TranscriberApp/Services/CalendarService.swift` -- EventKit lookup for current meeting title
- `TranscriberApp/Services/ChunkProcessor.swift` -- processes finalized audio chunks in background: transcribe, diarize, VAD, speaker assignment, archive to AAC, persist to session
- `TranscriberApp/Services/ChunkRotator.swift` -- @MainActor timer-based WAV file rotation during recording, emits FinalizedChunk on each rotation
- `TranscriberApp/Services/CLIHandler.swift` -- CLI entry point dispatching parsed commands (transcribe, rename, benchmark) to their handlers
- `TranscriberApp/Services/CLIRename.swift` -- interactive CLI speaker rename: prompts per speaker and plays samples; collection + rename application live in TranscriptRenamer (TranscriberCore)
- `TranscriberApp/Services/MicSwitchWindowController.swift` -- opens mic switch dialog as floating NSPanel during recording
- `TranscriberApp/Services/RenameWindowController.swift` -- opens speaker rename dialog as NSPanel
- `TranscriberApp/Services/SessionNameWindowController.swift` -- opens session naming dialog as NSPanel
- `TranscriberApp/Services/SetupWindowController.swift` -- opens permission setup window as NSWindow at launch
- `TranscriberApp/Services/SystemPermissionChecker.swift` -- real macOS permission API wrapper (AVCaptureDevice, CGPreflight, EventKit, UNUserNotificationCenter)
- `TranscriberApp/Services/UpdaterController.swift` -- hosts `CheckForUpdatesViewModel` + `CheckForUpdatesView`, driving the "Check for Updates..." menu item via `SPUUpdater.canCheckForUpdates` KVO
- `TranscriberApp/Views/MenuView.swift` -- window-style menu bar panel (status header, live timer, record button, action rows)
- `TranscriberApp/Views/DesignSystem.swift` -- shared "Quiet Confidence" components (MenuActionRow, IconTile, StatusDot, AlertBanner, folder-picker helpers); see docs/design/design-system-0.8.x.md
- `TranscriberApp/Views/SettingsView.swift` -- tabbed settings window (General/Audio/Transcription/Summary/Permissions), manual Save semantics; triggers eager model download on Save when engine requires it
- `TranscriberApp/Views/SetupView.swift` -- permission + engine setup window (shown at first launch or when model not cached); gates Continue on permissions AND model download
- `TranscriberApp/Views/RenameDialog.swift` -- speaker rename sheet with sample text and audio playback from source WAV timestamps
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording (includes mic picker)
- `TranscriberApp/Views/MicrophonePicker.swift` -- mic device dropdown + live level meter (used in SessionNameDialog)
- `TranscriberApp/Views/MicSwitchDialog.swift` -- mic device picker for switching microphone mid-recording

### XPC Audio Capture Service (AudioCaptureHelperXPC target)
- `AudioCaptureHelper/XPC/AudioCaptureService.swift` -- implements AudioCaptureProtocol; drives system-audio capture via ScreenCaptureKit (default) or the Core Audio tap, plus mic capture
- `AudioCaptureHelper/XPC/AudioOutputHandler.swift` -- writes system audio (from the SCStream `.audio` output) and mic buffers (fed via `appendMicSampleBuffer()` from `MicCaptureSession`, #96) to WavFileWriters; auto-detects sample format (Float32/Int16) and channel count. Since #96 the SCStream delivers system audio only — `.microphone` is no longer registered.
- `AudioCaptureHelper/XPC/SystemTapSession.swift` -- Core Audio output process tap for system audio (#103), selected by `system_audio_source: core_audio_tap`; captures Continuity/VoIP calls ScreenCaptureKit misses
- `AudioCaptureHelper/XPC/MicCaptureSession.swift` -- microphone capture session feeding the mic WAV stream
- `AudioCaptureHelper/XPC/main.swift` -- NSXPCListener entry point, shared service instance, connection invalidation handler

### Shared Protocol (AudioCaptureProtocol target)
- `AudioCaptureProtocol/AudioCaptureProtocol.swift` -- @objc XPC protocol + service name constant

### Shared Logic (TranscriberCore target)
- `TranscriberCore/AppState.swift` -- Observable state machine: idle -> recording -> transcribing -> idle, `interruptionWarning` for crash recovery UI
- `TranscriberCore/AudioConverter.swift` -- converts arbitrary PCM audio buffers to fixed 48kHz mono Int16 via AVAudioConverter, auto-detects source format changes (e.g. mic switch)
- `TranscriberCore/ChunkSession.swift` -- Codable session state (SessionState) with ProcessedChunk model: segments, speaker embeddings, and atomic JSON persistence
- `TranscriberCore/CLIParser.swift` -- parses CLI arguments into CLICommand enum (transcribe, rename, renameGUI, benchmark, summarize) with typed option structs; SplitMode enum for stereo channel handling (split/noSplit/ask)
- `TranscriberCore/Config.swift` -- Codable config struct (snake_case JSON keys), includes `engine: EngineID` and optional `summary: SummaryConfig`
- `TranscriberCore/ConfigManager.swift` -- reads/writes `~/Library/Application Support/Parley/config.json`
- `TranscriberCore/EngineID.swift` -- engine enum (speechAnalyzer/fluidAudio) + EngineDescriptor metadata
- `TranscriberCore/TranscriptionEngine.swift` -- protocol for swappable transcription engines + AudioSourceType enum
- `TranscriberCore/FluidAudioEngine.swift` -- FluidAudio/Parakeet engine (fastest, 25 EU languages) with ITN text normalization; isModelCached()/preDownloadModel() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/FluidAudioDiarizer.swift` -- FluidAudio offline diarization (pyannote + WeSpeaker + VBx) with quality scores; isDiarizationCached()/preDownloadModels() for eager download; ensureLoaded() is load-only (never downloads)
- `TranscriberCore/SpeechAnalyzerEngine.swift` -- Apple SpeechAnalyzer engine (macOS 26+, no download), guarded with `#if compiler(>=6.2)`
- `TranscriberCore/DiarizationProvider.swift` -- protocol for speaker diarization + DiarizedSegment model
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
- `TranscriberCore/WavFileWriter.swift` -- WAV file writing with deferred sample rate/channel count, Float32->Int16 conversion + direct Int16 passthrough, 0.5s periodic sync
- `TranscriberCore/RecordingSentinel.swift` -- crash recovery sentinel file (JSON at ~/Library/Application Support/Parley/recording.json), atomic write/read/delete
- `TranscriberCore/LaunchAgentManager.swift` -- install/unload macOS LaunchAgent (KeepAlive) for auto-relaunch on crash
- `TranscriberCore/SegmentDiscovery.swift` -- discover multi-segment audio files from crash recovery (base, -2, -3, ...)
- `TranscriberCore/SegmentNaming.swift` -- segment filename computation: strip `-N` suffix, append new segment number
- `TranscriberCore/SpeakerAssignment.swift` -- splits ASR segments at word-level diarization speaker-change boundaries (issue #120), then assigns speaker labels using diarization overlap, with deduplication and VAD-based quality filtering
- `TranscriberCore/StreamLabeling.swift` -- shared per-stream speaker labeling (withDiarization + singleSpeaker) used by both ChunkProcessor and TranscriptionRunner, so the labeling logic lives once
- `TranscriberCore/WordTiming.swift` -- engine-neutral per-word/run timing (start/end/text), populated by both ASR engines and consumed by SpeakerAssignment's boundary-split logic
- `TranscriberCore/SpeakerReconciler.swift` -- cross-chunk speaker matching via greedy cosine similarity on embeddings, maps local per-chunk speaker IDs to global namespace
- `TranscriberCore/TranscriptAssembler.swift` -- assembles labeled segments + metadata into transcript JSON dictionary for file output
- `TranscriberCore/TranscriptMerger.swift` -- merges processed chunks into a single time-sorted transcript with absolute timestamps and cross-chunk speaker remapping
- `TranscriberCore/TranscriptRenamer.swift` -- shared speaker-rename logic (SpeakerSample struct, per-speaker sample collection, rename application that merges into metadata.speaker_names — #162) used by both CLIRename and the GUI rename dialog
- `TranscriberCore/TranscriptWriter.swift` -- formats and writes transcripts in multiple formats (JSON, TXT, SRT) with timestamp formatting
- `TranscriberCore/VadSpeechMap.swift` -- wraps FluidAudio VadManager to produce SpeechRegion map with probabilities for quality filtering
- `TranscriberCore/AudioDeviceEnumerator.swift` -- lists audio input devices via AVCaptureDevice.DiscoverySession, resolves last-used device
- `TranscriberCore/InputLevelMonitor.swift` -- @Observable real-time audio level (0-1) via AVCaptureSession, works with all device types including USB webcams
- `TranscriberCore/FilenameUtils.swift` -- sanitizeFilename (removes /, :, \0)
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol
- `TranscriberCore/PathDisplay.swift` -- prefix-anchored `~` abbreviation of filesystem paths for display (shared by Setup + Settings)
- `TranscriberCore/RecordingTimer.swift` -- pure elapsed-time formatting (mm:ss / h:mm:ss) for the menu bar live timer
- `TranscriberCore/Log.swift` -- os.Logger extension with 6 category loggers (audio, transcription, state, config, permissions, files)
- `TranscriberCore/AudioSourceResolver.swift` -- detects input format (dual WAV or stereo AAC), splits stereo AAC channels (L=local mic, R=remote system) for pipeline re-ingestion
- `TranscriberCore/AudioArchiver.swift` -- converts dual WAV (system+mic) to stereo AAC archive (L=mic, R=system) via AVAssetWriter, deletes source WAVs on success
- `TranscriberCore/StorageManager.swift` -- enforces audio archive storage quota in hours, deletes oldest .m4a files first, never deletes transcripts
- `TranscriberCore/SummaryProvider.swift` -- protocol for LLM summary providers + SummarySegment/SummaryMetadata types
- `TranscriberCore/SummaryPromptBuilder.swift` -- shared prompt + transcript/date/duration formatting (systemMessage + userMessage) used by both summary providers, so the prompt lives once
- `TranscriberCore/OpenAISummaryProvider.swift` -- OpenAI-compatible chat completions provider via /v1/chat/completions (covers OpenAI, Claude proxy, Ollama, LM Studio OpenAI mode)
- `TranscriberCore/LMStudioSummaryProvider.swift` -- LM Studio native REST API v1 provider via /api/v1/chat with per-request context_length, token stats, and self-correcting retry on context overflow
- `TranscriberCore/MeetingSummarizer.swift` -- orchestrator: reads transcript JSON, selects provider from config, calls provider, writes -summary.md; createProvider(from:) factory for both provider types; summarizeIfConfigured returns a SummaryOutcome (skipped/succeeded/failed) so callers can surface failures instead of them being silent (#134)
- `TranscriberCore/TokenRatioCache.swift` -- per-model chars-per-token ratio cache at ~/Library/Application Support/Parley/token-ratios.json; probe calibration on first use, continuous refinement from real transcript stats, seed vs measured distinction, legacy format migration
- `TranscriberCore/EchoDeduplicator.swift` -- triple-confirmed echo dedup: removes local segments that are mic bleed of remote speakers (temporal overlap >50% + word overlap >70% + speaker embedding cosine >0.8)

### Standalone Swift CLI (legacy, still functional)
- `audio_capture_helper/` -- Swift Package Manager project, standalone binary for CLI use
- Produces `bin/audio-capture-helper` via `cd audio_capture_helper && bash build.sh`

## Audio Capture Architecture (critical knowledge)
- Swift captures TWO WAV files: system audio + microphone (separate streams)
- System audio source is selectable via `system_audio_source` (Config): `sck` = ScreenCaptureKit (default), `core_audio_tap` = Core Audio output process tap (#103, a strict superset that also captures Continuity/VoIP calls SCK misses). Mic is captured independently either way.
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
# 741 tests across 78 suites (Config, ConfigManager, EngineID, WavFileWriter, AppState, FilenameUtils, CalendarEventPicker, PermissionManager, AudioDeviceEnumerator, InputLevelMonitor, RecordingSentinel, LaunchAgentManager, DiscoverSegments, SegmentNaming, SpeakerAssignment, SpeakerBoundarySplitTests, SpeakerReconciler, TranscriptMerger, ChunkSession, ChunkRecovery, AudioConverter, VadSpeechMap, ChunkRotator, ChunkProcessor, CLIParser, RecordingTimer, PathDisplay, OpenAISummaryProvider, LMStudioSummaryProvider, MeetingSummarizer, TokenRatioCache, EchoDeduplicator, etc.)
# Uses Swift Testing, not XCTest -- no Xcode installed, only CommandLineTools
# Test path: SwiftTests/TranscriberTests/ (not Tests/ -- case collision with Python tests/ on APFS)
```

### Swift (standalone CLI helper -- legacy)
```bash
cd audio_capture_helper && bash build.sh
# Produces bin/audio-capture-helper
```

## Development Process
**Read [docs/development-process.md](docs/development-process.md) before starting work.** In short:
group related bugs/features into one PR → run a multi-agent **code council over the full diff BEFORE
pushing to CI** (both councils run so far found real bugs inside the code written to fix the previous
bug) → then CI, and monitor it → device-test anything touching capture/audio → **decide the version
deliberately** (PATCH = bug fixes only; MINOR = any new capability, *or* a fix that materially changes
what the transcripts say) → release, and advance that line's `release/vX.Y.x` branch.

## Documentation
- [docs/development-process.md](docs/development-process.md) -- How work gets from idea to release; when to bump MINOR vs PATCH
- [docs/pipeline.md](docs/pipeline.md) -- End-to-end pipeline: recording → transcription → echo dedup → summary
- [docs/parameters.md](docs/parameters.md) -- All tunable parameters with config keys and defaults
- [docs/gotchas.md](docs/gotchas.md) -- 48 platform-specific gotchas
- [docs/mic-capture-design.md](docs/mic-capture-design.md) -- Mic capture API choice (AVCaptureSession + Core Audio HAL) + auto-follow-default direction + when to revisit AVAudioEngine
- [docs/benchmarks/](docs/benchmarks/) -- Dated benchmark reports

## Key Gotchas
See [docs/gotchas.md](docs/gotchas.md) -- 48 platform-specific gotchas (macOS APIs, ScreenCaptureKit, XPC, audio formats, TCC, Liquid Glass, engine quirks). New items are appended there.

## Debugging
See [docs/pipeline.md](docs/pipeline.md#debugging) for full unified logging reference.

```bash
# All logs (debug + info + error)
/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug

# Via dev.py (launches app + tails log)
python3 scripts/dev.py --debug
```

## Packaging
See [docs/pipeline.md](docs/pipeline.md#packaging) for bundle structure, Info.plist, and dev.py details.

## Branches
- `main` -- stable (Python rumps UI)
- `feature/swiftui-native-ui` -- SwiftUI native UI rewrite
- `feature/whisperkit-migration` -- engine abstraction: swappable engines replacing hardcoded WhisperKit (this branch)
