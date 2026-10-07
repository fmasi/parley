# Architecture

An overview of how Parley is built. It says what each part is and where it lives, and points to
the documents that hold the detail:

- [docs/pipeline.md](docs/pipeline.md): the recording-to-summary pipeline stage by stage, the
  transcript's metadata, the files beside a recording, debugging, packaging, the CLI.
- [docs/parameters.md](docs/parameters.md): every config key and its default.
- [docs/gotchas.md](docs/gotchas.md): platform traps (Core Audio, ScreenCaptureKit, XPC, TCC,
  launchd), each with the reason behind the code that avoids it.
- [docs/superpowers/specs/2026-09-24-capture-reliability-design.md](docs/superpowers/specs/2026-09-24-capture-reliability-design.md):
  the design of the capture-reliability machinery. The `§` numbers in code comments refer to it.
- [docs/mic-capture-design.md](docs/mic-capture-design.md): why the microphone is captured the way it is.
- [CLAUDE.md](CLAUDE.md): the file map, one line per source file.

## The promise

Parley records a meeting as two separate streams, the microphone (**local**) and the system
audio (**remote**), and transcribes and diarizes them on the Mac. For each side, at every moment
of a recording, one of three things is true: it is being captured, Parley is healing it by
itself, or the user has been told and keeps being told. Afterwards the record says how much of
each side was captured. Most of the design below follows from that sentence (spec §1).

## Four targets

`Package.swift` defines them; the test target links `TranscriberCore` and `VerifyEdSignatureCore` only.

| Target | Directory | What it is |
|---|---|---|
| `TranscriberApp` | `TranscriberApp/` | The menu-bar app (`MenuBarExtra` + `Settings`): windows, notifications, the XPC client, the CLI entry. Thin: it presents and forwards. |
| `AudioCaptureHelperXPC` | `AudioCaptureHelper/XPC/` | The capture helper, an XPC service in its own process. It owns the audio devices and writes the WAV files. |
| `AudioCaptureProtocol` | `AudioCaptureProtocol/` | The `@objc` protocol both sides of the XPC connection share. |
| `TranscriberCore` | `TranscriberCore/` | Everything with a decision in it: the recording coordinator, the capture-health state machines, the transcription pipeline, the transcript's record. Unit-tested with fakes. |

Two more targets, `VerifyEdSignatureCore` and `VerifyEdSignature`, are a release tool (they check
a published update's EdDSA signature for `scripts/verify-release-feed.sh`) and are not part of the app.

The rule that shapes the layout: the app and the helper have no unit tests, so anything with a
branch in it lives in `TranscriberCore` as a pure type, and the app and helper feed it timestamps
and apply its answers (AGENTS.md, "Testable seams").

```
 helper process (AudioCaptureHelperXPC)             app process (TranscriberApp + TranscriberCore)
┌──────────────────────────────────────────┐      ┌───────────────────────────────────────────────┐
│ SystemTapSession   (system audio)        │      │ AudioCaptureClient                            │
│ MicCaptureSession  (microphone)          │ XPC  │   deadlines, crash detection, SessionEvidence │
│        │ one serial audio queue          │◀────▶│ RecordingCoordinator (Core)                   │
│        ▼                                 │      │   start / stop / crash restart / relaunch     │
│ AudioOutputHandler → WavFileWriter ×2    │      │   AppState.alarms → alarm window, menu rows   │
│   <chunk>.wav   <chunk>_mic.wav          │      │   recovery file (RecordingSentinel)           │
│                                          │      │ TranscriptionRunner (Core)                    │
│ LivenessWatchdogDriver (1 Hz, own queue) │      │   ChunkRotator → ChunkProcessor per chunk     │
│ TapHealer, MicHealPolicy,                │      │   finalize → <session>.json, .txt/.srt        │
│ TapPermissionGuard, alarm registry       │      │ MeetingSummarizer (optional, after rename)    │
└──────────────────────────────────────────┘      └───────────────────────────────────────────────┘
```

## Capture

**Two streams, two files, never mixed.** The helper writes `<chunk>.wav` (system audio) and
`<chunk>_mic.wav` (microphone) for every chunk. Keeping the sides apart is what lets a transcript
say `Local` or `Remote` for every line, and what the echo check compares.

**System audio comes from a Core Audio process tap** (`SystemTapSession.swift`): a global output
tap read through a private aggregate device. It hears everything the Mac plays, including
Continuity and VoIP calls that ScreenCaptureKit does not deliver. It is the default
(`Config.default`, `system_audio_source: core_audio_tap`). ScreenCaptureKit is still in the helper
as the legacy source (`sck`): it is selectable in Settings, it is what a `config.json` written
before the key existed decodes to, and nothing switches to it on its own. Its removal is #221.

**The microphone is an `AVCaptureSession`** of its own (`MicCaptureSession.swift`), so a mic route
change cannot stop system audio. With no microphone pinned it follows the system default input; a
pinned microphone that disappears falls back to the default and is re-pinned when it returns
(`MicTargeting`).

**One audio queue, one timeline.** Both sources deliver on the helper's single serial audio queue,
which also runs writer swaps and finalization. The tap and the microphone are each converted to
48 kHz mono Int16 (`AudioConverter`), and both tracks are pinned to a shared timeline anchor: `AudioOutputHandler` pads silence where
a source starts late or leaves a gap, and counts every padded frame so the record can say how much
of a track was made up rather than captured. `WavFileWriter` rewrites the header and syncs to disk
every 0.5 s, which bounds what a power cut can take.

**Chunks.** `ChunkRotator` (Core, in the app) asks the helper to rotate on a timer
(`chunk_duration_minutes`, default 30, minimum 10). The helper swaps both writers on the audio
queue and hands back the finished pair, which goes to the pipeline while recording continues.

## The helper's lifecycle

The helper holds one capture at a time. `CaptureLifecycle` (Core, pure) is the claim on it:

- A start reserves the session under a token before it opens anything; a second start is refused.
- A stop or a dropped connection during a start aborts that start, which tears down what it built.
- A start that hangs in the OS is abandoned at its own deadline (20 s).
- A dropped connection stops only the capture that connection owns; an explicit stop always acts.
- A stop waits a bounded time for the mic and the tap (3 s) and always ends idle, so the next
  Record is never refused.
- A rotation during a start or a stop is refused with a reply the app does not mistake for a dead
  capture (`CaptureReplies`).

The app side bounds every helper call on awake time (`Deadline.swift`; `AudioCaptureClient`: start
15 s, stop 20 s, rotate 10 s, the rest 3 to 10 s). A call that does not answer is never waited for
indefinitely: the coordinator says so and takes the salvage path.

## Capture reliability

All of this runs in the helper, decided by pure types in Core. Thresholds and the reasoning are in
the spec (§4 to §6) and `docs/parameters.md`.

- **Heartbeats.** Each source stamps a heartbeat as the first statement of its audio callback. A
  heartbeat means "the OS called us", not "there was sound".
- **Liveness watchdog.** `LivenessWatchdogDriver` ticks at 1 Hz on its own queue, because a
  callback that stopped cannot notice its own silence. It feeds one `TrackLivenessMonitor` per
  track, which reports a track that never delivered or that stalled. The microphone is always
  expected to deliver. The tap is expected only while another process is playing audio
  (`OutputActivityProbe`), so a quiet Mac is not an alarm.
- **Healing.** A silent tap goes up `TapRecoveryLadder`, run by `TapHealer`: rebuild the aggregate
  device, then build a new tap, with backoff and a budget, then a slow retry. A silent microphone
  is reopened once; a second silence reopens it and raises the alarm (`MicHealPolicy`).
- **Permission.** A tap without the System Audio Recording permission delivers exact zeros and
  keeps doing so after the permission is granted. `TapPermissionGuard` re-checks while a problem
  lasts, rebuilds the tap on a grant, and reports "restored" only when real audio arrives.
- **Content and writes.** A run of exact digital zero on the mic (`ExactZeroRunMonitor`), a track
  whose callback runs but writes nothing (`WriteProgressMonitor`), too much padding
  (`PadRatioMonitor`), a device delivering slower than it claims (`RateDriftMonitor`) and a failed
  write are each detected and reported.
- **Sleep.** The helper pauses its monitors across sleep (`SleepPauseClock`), from the app's
  message and from its own IOKit observer, so a sleeping Mac is not an alarm and a wake re-arms
  everything. The coordinator records the sleep as a gap in the record.
- **Callback timing.** Every tap and mic callback is timed per stage (`IOCycleStats`); see
  pipeline.md, Stage 1.

## Alarms

An alarm is **state**, not an event: it stays until its condition clears (spec §6).

- The helper owns a `CaptureAlarmRegistry` and sends its state as a `CaptureStatusSnapshot`: pushed
  when it changes, and pulled by the app every 5 s while recording. Every snapshot names the helper
  session that produced it (`HelperSessionId`, ordered), so a late message from a helper that was
  replaced cannot displace its replacement's.
- The app keeps its own registry in `AppState.alarms`: the helper's alarms as last reported, plus
  the app's own (the helper stopped answering, disk low, a rotation failed, `session.json` could
  not be written, crash protection is off, a recording stopped or resumed with a gap).
- An alarm inherited from a helper that crashed is kept as stale until the new helper disproves it
  with evidence about the same thing: first frames, real (non-zero) audio, or a successful write.
- `RecordingCoordinator.presentAlarms` decides when to present: at once when new, then again every
  2 minutes while recording, backing off while idle. `CaptureAlarmWindowController` (app) shows a
  floating window that does not take focus and posts one notification per alarm kind. A missing
  permission goes to `PermissionRepairWindowController` first, which names the permission and
  offers the fix.
- An alarm never stops or blocks a recording.

## The recording coordinator

`RecordingCoordinator` (`TranscriberCore/RecordingCoordinator.swift`, plus its `+Lifecycle` and
`RecordingFolder` extensions) owns a recording from Record to transcript. It is a plain
`@MainActor` object tested against a fake capture client (`RecordingCaptureClient`); the app
injects the UI effects as closures (notifications, the rename dialog, the alarm and repair
windows). `MenuView` only presents.

- **Start**: checks the recording folder (reachable, writable, enough free space for two chunks)
  off the main actor, writes the recovery file, starts the helper, sets up the chunk pipeline. The
  whole start runs under one 30 s deadline.
- **Stop**: stops the rotation, marks the recovery file as stopping, stops the helper, processes
  the last chunk, waits for the chunks still in the pipeline, builds the record, writes the
  transcript, and only then deletes the recovery file and the live diagnostics log.
- **Every read of a recording folder** goes through `FolderReads`: off the main actor, bounded, one
  queue per volume. A network share that stops answering is said to be not answering, and the
  session is kept for when it does; it is never reported as "no audio".
- **Quit, logout, shutdown**: `TerminationPolicy` and `AppTerminationDelegate`. Parley's own Quit
  stops the recording first (at most 30 s). A logout or an outside quit gets a tight bound (5 s):
  the helper is stopped so it seals its files, and the next launch finishes the transcript.

## Crash recovery

- **The recovery file** (`RecordingSentinel`, `recording.json` in
  `~/Library/Application Support/Parley/`) is written at start and deleted once the transcript
  exists. It records where the session is, the boot it was recorded in, and when the recording was
  last known alive (refreshed every 60 s and at every rotation). Sessions that could not be
  finished are kept in a pending list beside it. All of its I/O runs on one serial queue off the
  main actor (`SentinelIO`).
- **The helper dies while the app runs.** The app tells a crash from a harmless connection blip
  (`XPCInterruptionPolicy`, `CrashReportScanner`). On a crash, or when two status pulls in a row
  answer "not capturing", the coordinator restarts the capture into the next chunk, processes the
  chunk the dead helper left, and records the gap. A restart counts as recovered only after its
  first frames arrive. After more than two crashes in a row (a streak; a crash more than 10
  minutes after the last one starts a new streak, `XPCRetryPolicy`) it gives up, salvages what
  was recorded and says the recording failed.
- **The app dies.** A LaunchAgent (`KeepAlive` with `SuccessfulExit: false`) relaunches it;
  `SingleInstanceGuard` (a file lock) keeps a second copy from running. At launch
  `RelaunchDecision` (pure) reads the recovery file and picks one of: re-attach to a helper that is
  still capturing; resume the same session when it was alive less than 180 s ago, recording the
  gap; salvage it and say the recording stopped; salvage a session from an earlier boot; or wait,
  when its folder is not reachable. A session the user had already stopped is never resumed.
- **Salvage** rebuilds the session from `session.json` and the chunk files still on disk
  (`ChunkedSessionRecovery`, `CrashRecoveryPlanner`) and produces the transcript a clean stop
  would have. `RecoveryMessages` words every outcome from what the salvage actually did.
- **Crash protection is itself checked.** At every launch `LaunchAgentManager.verifyAndRepair`
  compares launchd's view with the running process (`LaunchAgentHealth`). A Parley started from
  Finder or by an update is not the process launchd would relaunch, so it hands over to launchd's
  own copy when idle; when that cannot be done, a `crashProtectionOff` alarm says so.

## The pipeline

`TranscriptionRunner` (`TranscriberCore/TranscriptionRunner.swift`) creates the engine, owns the
chunk pipeline and writes the transcript. Stage by stage: [docs/pipeline.md](docs/pipeline.md).

- **Per chunk**, in the background while recording continues (`ChunkProcessor`): transcribe each
  stream, diarize each stream, run voice-activity detection, assign speakers, run the echo check,
  archive the two WAVs into one stereo `.m4a` (left = mic, right = system), append the chunk to
  `session.json`. The WAVs are deleted only after `session.json` holds the chunk.
- **At stop** (`TranscriptionRunner.finalize`): match speakers across chunks by voice
  (`SpeakerReconciler`), merge the chunks onto one timeline (`TranscriptMerger`), concatenate the
  chunk archives into one `.m4a` (`AudioConcatenator`, `merge_chunked_audio`), assemble and write
  `<session>.json` (`TranscriptAssembler`) and, unless `output_format` is `json`, the readable
  `.txt` or `.srt` made from it (`TranscriptWriter`).
- **Engines.** Two, behind the `TranscriptionEngine` protocol, chosen by `EngineID` in the config:
  FluidAudio (Parakeet on CoreML, the default) and Apple SpeechAnalyzer (macOS 26+, labelled "not
  yet usable" in Settings until #223). Diarization is FluidAudio's offline diarizer
  (`FluidAudioDiarizer`). Models are downloaded at Setup or on Settings Save, never while
  recording or transcribing.
- **Single-file path.** `TranscriptionRunner.run()` transcribes whole files without the chunk
  pipeline. The CLI uses it, and so does the stop path for a recording that has no chunked
  session on disk.
- **Storage.** `StorageManager` keeps the `.m4a` archives within `audio_archive_limit_hours`,
  across every day folder of the recording directory, by deleting the oldest (#224). It deletes
  nothing else: transcripts and WAVs are never touched; a transcript whose audio went gets an
  `audio_removed` mark, and the completion notice says so.
- **Summary** (optional). After the rename dialog, `MeetingSummarizer` sends the transcript to the
  endpoint the user configured and writes `<session>-summary.md`.

## The record: flag, never delete

The transcript JSON is the record, and the pipeline does not delete what the engine heard.

- A segment the pipeline doubts is **kept and flagged**: `echo` (the other side's voice picked up
  by the microphone), `filtered` (failed the voice-activity and quality gate), `duplicate` (an
  abutting repeat), `time_unknown`. Flagged segments stay in the JSON and are hidden from the
  `.txt`, the `.srt`, the summary prompt and the rename samples. The one thing dropped is a
  zero-duration segment, which carries no audio, and it is counted (`zero_length_dropped`).
- **Echo** is judged per local speaker cluster, on time and text (`EchoDeduplicator`). The numbers
  behind every verdict are written to `metadata.echo_clusters`. Re-detecting a channel at a
  stated speaker count (`TranscriptRediarizer`) runs the echo check before the count is enforced,
  so an echo voice is never merged into a person. `EchoNotice` builds what the user is told.
- **Processing problems** (a chunk whose transcription or diarization failed, a missing stream, a
  failed archive) are written to `metadata.processing_issues`, and the completion notice counts
  them (`CaptureQualityNotice`).
- **A re-detect or a rename changes the transcript only** (the JSON, and the `.txt` or `.srt` made
  from it). Neither rewrites the audio.
- **Disclosure.** Meeting content leaves the Mac only through the summary endpoint, and the
  transcript says whether it did and to which host (`SummaryDisclosure`). The other network calls
  carry no meeting content: model downloads, the update check (Sparkle) and an opt-in check for
  newer models.

## From evidence to the record

How the record comes to say what was captured (spec §7, §8.11; the keys are listed in pipeline.md,
"Capture provenance and metadata").

1. The helper records capture events into a bounded ring and reports per-track coverage: seconds
   expected, delivered, exact-zero and padded, gaps and rebuilds (`TrackAccounting`, `GapTracker`).
2. The app drains the ring over XPC and adds its own events (interruptions, retries, relaunches,
   gaps). `SessionEvidence` holds them for the session in progress.
3. Every event that is not routine is also appended, as it happens, to
   `<session>.diag.live.jsonl` beside the recording, and every status pull rewrites
   `<session>.diag.coverage.json`. A crash therefore loses neither: the coverage file stands in
   for the stop event a crashed helper never wrote.
4. At finalize the ring, the live log and the coverage are merged into the record. From it come
   `metadata.capture_provenance` and `metadata.capture` in the transcript: a status per side
   (`healthy`, `idle`, `neverDelivered`, `compromised`) with the seconds behind it, and the gaps.
5. **The diagnostics log.** If the session had at least one event of severity `anomaly`, the merged
   events are written to `<session>.diag.jsonl`. A clean recording keeps no diagnostics file: its facts are the
   provenance in the transcript, and its routine events (the `captureStart` event with its
   `build` key among them) are not written to disk.
6. The live log and the coverage file are deleted once the transcript exists. They are kept when
   the `.diag.jsonl` could not be written.
7. The completion notice is worded from the same record (`CaptureQualityNotice`): a side that was
   not captured, or only partly, is said in the notification's title.

## Permissions

`CaptureReadiness` (pure) says which permissions a capture source needs: Microphone always, System
Audio Recording for the tap, Screen Recording for ScreenCaptureKit. `PermissionManager` tracks
them. The app checks Microphone, Screen Recording, Calendar and Notifications itself and asks the
helper for System Audio Recording, because the system caches that answer per process and the
long-running app would keep its launch-time answer. After onboarding a missing permission opens
the repair window, not the Setup screen (a missing model still opens Setup). The System Audio Recording check uses a private system
interface; that and the other choices that would not pass App Store review are listed in
[docs/app-store-blockers.md](docs/app-store-blockers.md).

The app's bundle identifier is `eu.fmasi.parley` (`packaging/Info.plist`), and the helper's is
`eu.fmasi.parley.capture-helper`. `scripts/dev.py --reset-tcc` resets the Microphone, Screen Recording,
Calendar and Documents-folder grants recorded for the app's identifier; it does not reset System
Audio Recording.
