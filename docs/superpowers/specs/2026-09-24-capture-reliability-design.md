# Capture reliability overhaul — design spec

**Date:** 2026-09-24
**Status:** v3 (2026-09-25) — v2 amended the spec after the preflight conflict scan at §4.2, §5, §6.1,
§6.2, §7.2, §7.3, §8.3, §8.8, §8.10, §10 and §11 (each amendment is marked "v2" with the scan item that
showed the spec was wrong or incomplete). v3 brings the text in line with the merged code where review
rulings changed the design (C2–C11, F2, R, L): §4.1, §4.2, §5, §6.1, §6.2, §6.3, §7.1, §7.2, §7.4, §8.2,
§8.3, §8.4, §8.7, §8.11 and §8.12, each marked "v3" with the ruling. Implementation plan (v2) at
`docs/superpowers/plans/2026-09-24-capture-reliability.md`
**Branch:** `fix/capture-reliability`, stacked on `fix/permission-readiness` (PR #222, not merged)
**Closes / advances:** #220 (root cause + the class around it), #192/#193/#194/#195/#196 follow-ups,
#183, #147 (default flagged), #135 residuals. Does NOT touch #221 (SCK retirement).
**Inputs:** the brief (`00-brief.md`), the three validated audits (`10-validated-capture.md`,
`11-validated-post-capture.md`, `12-validated-lifecycle.md`). Only CONFIRMED / PARTLY TRUE
findings are planned on. Refuted claims are listed in §12 so nobody re-plans them.

---

## 1. The promise

Parley is an airgapped, courtroom-grade canonical record of a meeting. For each side of a
recording — **local** (the microphone) and **remote** (system audio through the Core Audio tap) —
exactly one of these is true at every moment:

1. it is being captured;
2. Parley is healing it by itself, within seconds;
3. the user has been told, loudly and persistently, and keeps being told until it is fixed or the
   recording stops.

Afterwards the saved record states truthfully how much of each side was captured, and when.
**Never "neither audio nor an alarm."**

### Principles (binding, from the brief)

- One capture method: the Core Audio tap. SCK stays untouched until #221; nothing here proposes
  SCK as a fix.
- One full overhaul, phased for review, not a quick first release.
- Detection watches the **plumbing, not the conversation**: flowing with sound = healthy; flowing
  but quiet = never an alarm on its own; not flowing when it should = broken → heal → alarm.
- Mic: a real mic has a noise floor, so a sustained run of exact digital zero means broken.
- Grey zone (remote flowing but exact zeros): investigate quietly; alarm only when a fault is
  confirmed, or with honest "can't confirm" wording. How often call apps render exact zeros for a
  muted remote is unknown → device measurement (§10, M-A).
- Mid-call alarm UX (PR #222): floating window that does not steal focus + notification + sticky
  menu-bar state; re-alarm periodically; "Later" snoozes the window, never the sticky state.
  Recording is never blocked or stopped by an alarm.
- Private SPI is acceptable; every App Store-incompatible choice goes in
  `docs/app-store-blockers.md`.
- Performance: MacBook Air M1 16 GB; zero idle wakeups when not recording; cheap polling while
  recording is fine.
- Process: red-first TDD (CI enforces), code council before CI, device test with measurements,
  the checklist's Regression section preserved.

---

## 2. In plain language (for the owner)

**What was wrong.** Four separate things, each of which could lose a whole meeting silently:

1. *The tap could stop and nothing would notice.* On 2026-09-24 the remote side of a 46-minute
   call was never captured. The tap's aggregate device was started, macOS paused it ~6 s later
   during a config change on the speaker device (triggered by the helper's own mic opening on
   AirPods), and it never resumed. Every detector Parley had was driven from inside the audio
   callback, so when callbacks stopped, detection stopped with them. The watchdog that does run on
   its own timer refuses to judge a track that has "not started yet" — and a track that never
   delivers looks exactly like one that has not started yet. The provenance said `anomaly_count 0`
   and `dual_stream: true`.
2. *Alarms were one-shot and overwritable.* On 2026-09-23 the watchdog fired once ("stopped
   delivering 3s ago") and stayed silent for 51 minutes. Every live warning goes into one
   dismissible banner slot that the next benign notice overwrites. Only the #220 permission alarm
   is sticky, and only a *permission* problem opens the window and sends a notification.
3. *Crash protection was off and would not have worked anyway.* The LaunchAgent that relaunches
   Parley after a crash has been unloaded since this morning's Quit (the plist survived, launchd
   forgot it), and nothing checks. Worse: the helper idle-exits ten minutes after the app goes
   quiet, the client misreads that as a crash, latches "crash already handled", and from then on a
   real helper crash mid-meeting runs no recovery at all. Every recording started more than ten
   minutes after launch has been running without crash detection.
4. *The record lied by omission.* A chunk whose ASR threw produced an empty chunk and a
   "Transcription Complete". A mic that delivered nothing for a chunk made the archiver refuse,
   the concatenator re-encode, and the only lossless copy get deleted with the remote voice
   duplicated into the local channel. Repeated short answers ("Yes." … "Yes.", minutes apart) were
   deleted as duplicates. `dual_stream: true` on 33 of 125 transcripts that have no remote audio.
   The summary of the 09-24 call reads "Frederic met to prepare…".

**What changes.**

- Every track gets a **heartbeat** stamped at the very top of its audio callback, and an
  off-callback monitor that judges "expected but silent" from the moment capture (or a rebuild,
  or wake) arms it — so a track that never starts is caught in 5 s, and one that stops in 3 s.
- "Expected" for the remote side is decided by asking Core Audio which **other processes are
  running output**, not whether the default output device is busy. Muted Meet in a browser keeps
  its output running → the tap keeps delivering zeros → healthy. An app that stops its output →
  nothing expected → no alarm. Per-app output devices (Zoom on speakers while AirPods are default)
  are visible by construction.
- When the tap is expected and silent, a **healing ladder** rebuilds the aggregate, then the whole
  tap, with backoff and a budget, and keeps a slow retry going afterwards. Aggregate listeners
  (`goin`, `stpd`, `diff`) and the coreaudiod-restart notification (`srst`) accelerate it.
- Alarms become **state, not events**: per track, owned by the helper, pulled by the app on every
  connection and every 5 s, pushed for latency, cleared only when the condition clears. Raised =
  floating window + sound + notification + red row; re-notified every 2 min; the row cannot be
  dismissed; the window can be snoozed for 3 min. They survive a helper restart and an app relaunch.
- The **record tells the truth**: per-track coverage (expected / delivered / exact-zero / gaps /
  rebuilds) in provenance and in `metadata.capture`; a `remote` track that was never expected is
  `idle`, one that fell short is `compromised`; `dual_stream` comes from capture; every chunk
  carries `processing_issues`; the summary header says "Remote audio: not captured".
- **Lifecycle**: crash detection armed per recording, LaunchAgent verified and repaired at every
  launch (with a visible "crash protection is off" row when it cannot be), honest relaunch
  ("Parley crashed at 16:02:10 and resumed at 16:02:14 — 4 s not recorded" / "Recording STOPPED at
  16:02:10"), retries capped on confirmed frames not on `start()` returning, no stop/crash races,
  disk checked before start and at every rotation, deadlines on every helper call, sleep/wake
  observed and recorded.

**What you will experience.**

- A real fault (Incident A or B) produces, within about 10 s: a floating window over the call that
  does not steal focus, a sound, a notification, and a red row in the menu. Every 2 minutes it
  reminds you until it is fixed or you stop. If Parley fixed it itself, the row clears and a quiet
  banner says so — only after real frames arrived.
- A muted remote on Meet or Zoom for ten minutes produces nothing. Same for presenting, for
  listening in silence, for recording before the call connects.
- After Stop, the transcript's completion notice says either "Transcription Complete" or names
  what was compromised; the JSON header states per side how many seconds were expected and
  captured; the summary says so too.
- If Parley crashes mid-call it relaunches within seconds, resumes the same recording, and tells
  you how many seconds were lost. If it cannot resume, it says the recording STOPPED, loudly.

---

## 3. Architecture overview

```
helper (AudioCaptureHelperXPC)                        app (TranscriberApp)
┌───────────────────────────────────────────┐        ┌──────────────────────────────────────┐
│ SystemTapSession ──heartbeat──┐            │        │ AudioCaptureClient                   │
│   listeners: goin/stpd/diff   │            │ XPC    │   XPCInterruptionPolicy (armed per   │
│   srst on system object       ▼            │ push + │   capture generation)                │
│ MicCaptureSession ──heartbeat─┤            │ pull   │   deadlines on every call            │
│                               ▼            │◀──────▶│                                      │
│ LivenessWatchdogDriver (1 Hz, own queue)   │        │ RecordingCoordinator (Core)          │
│   OutputActivityProbe (other pids' output) │        │   AppState.activeAlarms              │
│   TrackLivenessMonitor ×2 (pure)           │        │   AlarmPresenter (window, sound,     │
│   CaptureAlarmRegistry (pure, helper-owned)│        │     notification, re-alarm)          │
│   TapRecoveryLadder (pure) → tap.heal()    │        │   RelaunchDecision, LaunchAgentHealth │
│   TrackAccounting (pure) → coverage events │        │   LiveDiagnosticsLog (append-as-go)  │
└───────────────────────────────────────────┘        └──────────────────────────────────────┘
                     │  captureStop / chunkCoverage / alarms / firstFrames
                     ▼
        provenance + metadata.capture + processing_issues + summary header
```

Every decision lives in a pure, unit-tested type in `TranscriberCore` (the `TapPermissionGuard` /
`CaptureReadiness` pattern). Helper and app code are thin shells that feed timestamps and apply
actions. The app target and the helper target have no unit tests, so anything with a branch in it
must not live there.

---

## 4. Per-track health model

### 4.1 Signals

| Signal | Mic | Remote (tap) | Where stamped |
|---|---|---|---|
| **heartbeat** | `captureOutput` entry | `handleTapBuffers` entry, before any guard | monotonic ns, `OSAllocatedUnfairLock<UInt64>` |
| **delivery** | `appendAlignedMic` (existing `micBufferArrival`) | `appendSystemSamples` (existing `systemBufferArrival`) | after the writer accepted the frames |
| **content** | `ExactZeroRunMonitor` 12 s (existing) | `TapPermissionGuard.samples` 12 s (existing) | on real samples only |
| **expected** | always while capturing, except during a mic rebuild generation | `OutputActivityProbe`: any process with `pid != getpid()` and `kAudioProcessPropertyIsRunningOutput == 1` | 1 Hz poll on the watchdog tick, no listener (*v3, C3 round 1*: the gate debounce counts ticks; an accelerator reads the probe once for its own check but never feeds the debounce); fails OPEN |
| **generation** | bumped on every `buildAndStart` | bumped on every `buildAggregateAndStart` | tells the monitor "judge from here" |

Heartbeat is distinct from delivery on purpose (gotcha #63): heartbeat means "the OS is calling
us", delivery means "we are writing". Liveness verdicts use the heartbeat; coverage uses delivery.

### 4.2 `TrackLivenessMonitor` (pure; replaces `LivenessGapDetector`)

Inputs per tick: `now`, `lastHeartbeat` (0 = never), `gateOpen`, plus the arm time set by
`arm(at:)` on start/rebuild/wake. Verdicts, each reported once per episode:

- `.healthy`
- `.neverDelivered(seconds)` — armed, gate open, no heartbeat within `firstFrameThreshold`
  (mic 5 s from arm; tap 5 s from `max(arm, gateOpenSince)`).
- `.stalled(seconds)` — delivered in this generation, then no heartbeat for `stallThreshold` (3 s)
  of gate-open time.
- `.firstFrames` — first heartbeat of a generation (once); drives the honest "Resumed".
- `.cleared(.heartbeat | .gateClosed)` — the open episode ended: a heartbeat arrived, or the track
  is no longer expected; clears the track's `NotDelivering` alarm.

Both clocks count only time during which the gate was open: the never-delivered clock starts at
max(arm, gate open), the stall clock at max(last heartbeat, gate open). Each gate-open period that
lasts at least the threshold over a silent track is one episode, reported once; the gate closing
ends the open episode (`.cleared(.gateClosed)`). *(v2, scan C5: v1 said "a flap can re-report an old
gap once", which allowed a spurious `.stalled(<idle seconds>)` on the first tick after a call app
resumed its output under `tap_auto_start = true`.)* An accelerator (§5) may open an episode early;
the monitor then does not report the same stall again. This closes hole H1
(`guard lastArrivalNanos != 0`), L2, and retires `PadRatioMonitor.finish()` / `trackNeverDelivered`
(L-N2: dead in production, tested with impossible input).

*(v3, C3 round 1 ruling, owner rule "never silent".)* v2 said "a 1 Hz flap never reaches a threshold
and reports nothing", which let a dead tap behind a flapping gate stay silent. The gate is now
DEBOUNCED: it counts as closed only after `TrackLivenessMonitor.gateCloseTicks` (2) consecutive closed
ticks. A one-tick dropout neither clears an open episode nor restarts a clock, so a dead tap behind a
1 Hz flap is reported ONCE per episode, never once per flap, and never left silent; a genuine close
clears one tick later than before. `arm` or `pause` over an open episode ends it without a verdict,
and the monitor then owes a `.cleared(.gateClosed)` on the next closed tick, so the alarm it carried
cannot outlive the call. An accelerator opens an episode on the heartbeat it judged
(`openEpisodeExternally(stamp:)`), so only a NEWER heartbeat ends it. The accelerator is refused
before the generation's `.firstFrames`, because the never-delivered path owns the track until then.
Because the debounce counts ticks, the gate is sampled at exactly 1 Hz: the watchdog calls `check`
on every tick whether or not a monitor is armed, and nothing else feeds the gate to a monitor
(`LivenessWatchdogDriver`, `OutputActivityProbe`). An accelerator reads the probe once for its own
"is the track expected" check, but that reading never reaches the debounce.

### 4.3 The gate and the owner scenarios

`OutputActivity.othersRunningOutput(states, ownPid)` is the only "expected to produce" rule for
the tap. Probe facts (run-afplay.txt, run-own-aggregate.txt): `piro` reads 1 for a process
rendering exact zeros and drops to 0 the instant it exits; the helper's own aggregate reports
`piro=1 outDevs=[84]`, so excluding our pid is mandatory; a process on a non-default device is
visible (hole H3b closed by construction).

### 4.4 Rate and coverage bands

Rate drift stays with `RateDriftMonitor` at **0.95–1.05** (the audit's [0.9, 1.1] band is refuted:
a 44.1/48 kHz mismatch is 0.919). Coverage (§7) uses the existing both-conditions shape: deficit
≥ 15 s AND ≥ 10 % of expected.

---

## 5. Healing ladder (remote track)

`TapRecoveryLadder` (pure) turns a trigger into a sequence of rungs with backoff and a budget:

| Trigger | Source |
|---|---|
| `.stalled` / `.neverDelivered` on the remote track while gate open | `TrackLivenessMonitor` |
| `'goin'` → 0 or `'stpd'` on the aggregate, `'diff'`/`'agrp'` | accelerators: a heartbeat check 1 s after the event (`LivenessWatchdogDriver.accelerate`) reports a stall early if nothing arrived; never a blind rebuild |
| `'srst'` on the system object | jump to the top rung (new tap + aggregate + re-register listeners): the old IDs are dead |
| a rebuild throws | next rung after backoff (replaces the permanent `onUnavailable` at `SystemTapSession.swift:655-659`) |
| anchor removed, rate drift | existing paths, unchanged, but their rebuilds report into the same ladder budget |
| wake from sleep | re-arm + heartbeat check (§8.8) |

Rungs, per episode: (1) aggregate rebuild on the same tap (`teardownIO` + `buildAggregateAndStart`,
what `rebuildForOutputChange` does today), (2) new tap + new aggregate. The first attempt runs
immediately, later ones after 0.25 / 0.5 / 1 s; up to 2 of each rung (4 attempts) within a 15 s
fast window. After each rung the healer must see a heartbeat within 3 s while the gate is open
(measured on device, M-J), else the next rung. Budget exhausted → alarm `.remoteNotDelivering`
(sticky) and a slow retry (one tap rebuild) every 60 s while the gate stays open; a later
heartbeat clears the alarm through `.cleared(.heartbeat)`.

A rung runs on `configQueue`; a watchdog on the liveness queue records `.recoveryStuck` and
raises `.remoteRecoveryFailed` if a rung has not returned in 5 s (`AudioDeviceStop` on a paused
context is unverified, M-C). Rate-drift remediation keeps its own budget (`ClockAnchorPolicy`).

*(v2, scan A66/C9/C10.)* Every rung the ladder orders carries a token that the tap echoes with its
result; a rebuild the ladder did not order (output-device change, rate drift, the permission
grant/insurance path) reports with token 0 and counts against the episode's budget without
completing a rung, so an output-change rebuild finishing mid-rung is never mistaken for the rung's
result. When the gate closes, the episode ends and an exhausted ladder is un-exhausted: a still-dead
tap gets a fresh fast episode (rungs, then alarm within ~15 s) when the gate reopens, instead of
waiting for the next 60 s slow retry.

*(v3, C4 round 1 rulings; H review rounds 1–2.)* The ladder as merged (`TapRecoveryLadder`, driven by
`TapHealer`, both in `TranscriberCore`; the healer runs on its own serial queue) differs from the two
paragraphs above in five ways:

- **The heartbeat deadline is tokened.** A rung that returns success yields
  `.awaitHeartbeat(seconds: 3, token:)`, and the miss is `heartbeatDeadlineMissed(token:now:)`. A deadline
  left over from a replaced rung can never cut a newer rung's window short.
- **A heartbeat ends the SILENCE, not the episode.** `heartbeatObserved(now:)` (the monitor's
  `.firstFrames` or `.cleared(.heartbeat)`) cancels what is in flight or awaited and clears
  `remoteNotDelivering`. The budget is refunded only after `sustainedHealthSeconds` (30 s) of continuous
  health. A stall sooner continues the same episode up the ladder, with its budget as it stands and a
  fresh 15 s fast window. This stops an endless heal–blip loop that never alarms.
- **Heal first, then alarm.** An intermediate failed rung raises nothing. The ladder's give-up raises
  `remoteNotDelivering`, and also `remoteRecoveryFailed` when a rebuild threw since the tap last
  delivered. A rung that has not returned within `TapHealer.stuckSeconds` (5 s) raises
  `remoteRecoveryFailed`. Any successful rebuild clears it.
- **The dead state is REMEMBERED across a gate close.** v2 said a still-dead tap gets a fresh fast
  episode when the gate reopens. Instead, a gate close over an episode the tap had not healed from
  arms a "last chance": the reopen gets one immediate tap rung, and if that fails the ladder gives up
  (re-alarm in ~3–4 s) instead of starting a new four-rung episode per gate blip. A gate that closes
  again before that rung's verdict counts as its failure. An episode that had healed keeps its
  budget through a gate blip until the heal has held for 30 s.
- **Wake never rebuilds blind.** `.wake` makes the ladder forget its episode and returns `.none`; the
  re-armed liveness monitor is the heartbeat check. Sleep suspends the healer (`cancelAll()`). A
  liveness verdict that arrives while it is suspended proves the machine is awake, so it acts as an
  implicit wake. A coreaudiod restart or a permission grant that arrives while asleep is kept and
  runs at the wake. Stop ends the session (`endSession()`), and nothing but the next
  `startSession(tap:)` revives the healer.

`TapAutoStart`: becomes a `SystemTapSession` init parameter backed by config key `tap_auto_start`
(diagnostic knob, default `true`). The default flips to `false` only if measurement M-B passes
(§10). With `false` the IOProc runs continuously, "no callbacks" is unambiguous, the autostart
re-arm stall source disappears, and permission-denied zeros are visible from t=0.

`TapPermissionGuard` keeps only permission logic: the exact-zero grey zone still triggers its
quiet check and one insurance rebuild per episode (through the ladder, so it counts against the
budget), but liveness gaps no longer route through `deliveryGap`; they go to the ladder.

---

## 6. Alarm contract

### 6.1 State, not events

`CaptureAlarmRegistry` (pure, `TranscriberCore`) holds `[AlarmKind: ActiveAlarm]` where
`ActiveAlarm = {kind, track, raisedAt, lastNotifiedAt, message, episode}`. The helper owns
capture alarms; the app owns lifecycle alarms. Both kinds land in `AppState.activeAlarms`.

| Kind | Owner | Raised when | Cleared when |
|---|---|---|---|
| `micNotDelivering` | helper | `.neverDelivered`/`.stalled` on mic after `MicCaptureSession.attemptRecover()` did not restore a heartbeat within 5 s, or the recover loop reported its restart budget exhausted (`onUnavailable`; v2, scan C11). *v3:* per `MicHealPolicy`, the first silence verdict of an episode heals and a repeat heals and alarms; a reopen with no newer heartbeat within 8 s alarms; the track is called but writes nothing for 5 s (`WriteProgressMonitor`) | `.firstFrames` / `.cleared(.heartbeat)`, or write progress for a write-bound alarm *(v3: was "`.recovered`", which does not exist)* |
| `micDigitalSilence` | helper | `ExactZeroRunMonitor` 12 s (existing) | first non-zero mic sample |
| `micFollowFailed` *(v3, H2 round 2)* | helper, acknowledgeable | switching to a new microphone failed while the previous one still records | a later successful follow, the end of the recording, or the user's acknowledgement |
| `remoteNotDelivering` | helper | ladder gave up (§5); SCK: a silence verdict at once (no ladder); *v3:* the track is called but writes nothing for 5 s | `.firstFrames` / `.cleared(.heartbeat)` (the healer's recovery), the gate closing (no longer expected), or write progress for a write-bound alarm *(v3: was "`.recovered`")* |
| `remoteRecoveryFailed` | helper | *v3:* a rung stuck for 5 s, or a give-up after a rebuild threw (never an intermediate failed rung); SCK: the stream restart budget exhausted | any successful rebuild, or first frames |
| `remotePermissionDenied` | helper | `TapPermissionGuard.reportDenied(.denied/.notDetermined)` (existing) | real audio (existing `reportRestored`) |
| `remoteCantConfirm` | helper | `TapPermissionGuard.reportDenied(nil)` (existing) | real audio |
| `diskWriteFailure` | helper | `WavFileWriter.onWriteFailure` | next successful write on that writer |
| `diskLow` | app | free space < 1 chunk before a rotation | free space ≥ 2 chunks |
| `rotationFailed` | app | `rotateChunk` threw | next successful rotation |
| `sessionWriteFailed` | app | `session.json` could not be written after a chunk | next successful write |
| `helperUnresponsive` | app | 3 consecutive `captureStatus` polls time out | a poll answers |
| `crashProtectionOff` | app | `LaunchAgentHealth` ≠ healthy after repair. *v3:* never for `loadedButNotThisProcess` while a hand-over is possible (§8.2). Raised when the hand-over is impossible or failed, when the single-instance lock is unavailable, or when open windows have deferred it for 15 min | verified healthy |
| `recordingResumedWithGap` | app | relaunch/restart resumed the session | user acknowledges |
| `recordingStopped` | app | relaunch could not resume | user acknowledges |
| `recordingFolderUnavailable` | app | sentinel folder unreachable at relaunch, or rotation dir missing | folder reachable |
| `unknownHelperAlarm` *(v3, F2 ruling)* | app | a helper snapshot carries an alarm kind this build cannot decode (a newer helper) | a snapshot that no longer carries one |
| `audioAfterTranscript` *(v3, L review 219)* | app, acknowledgeable | audio of a finished recording, recorded after its transcript was written, is kept beside it untranscribed | user acknowledges |
| `possibleAudioAfterTranscript` *(v3, L review 268)* | app, acknowledgeable | chunks the helper may have recorded after a Stop's transcript, which the Stop could not check (the folder did not answer) | user acknowledges |
| `pendingListUnreadable` *(v3, L review 249)* | app, acknowledgeable | a list of unfinished recordings could not be read (set aside or left in place) | user acknowledges |

*(v3.)* Acknowledgeable kinds are past events: `recordingResumedWithGap`, `recordingStopped`,
`micFollowFailed`, `audioAfterTranscript`, `possibleAudioAfterTranscript`, `pendingListUnreadable`.
Each is presented once, with no re-notify, and keeps its row until acknowledged. A kind that outlives
the recording (`AlarmKind.outlivesRecording`) is `crashProtectionOff`, `recordingFolderUnavailable`, or
any acknowledgeable kind except `micFollowFailed`. Everything else is cleared when the recording ends.

### 6.2 Transport

- `AudioCaptureProtocol.captureStatus(reply: (Data?) -> Void)` returns a JSON
  `CaptureStatusSnapshot {helperSessionId, isCapturing, alarms, tracks: [TrackHealthSnapshot]}`.
  `status(reply:)` is kept unchanged for older callers.
- The app **pulls** it on every `connect()`, every 5 s while recording (3 s deadline), and after
  every restart/relaunch. The helper also **pushes** `captureAlarmsChanged(snapshot:)` and
  `captureDidDeliverFirstFrames(track:)` on the reverse channel (`@objc optional`, like
  `captureQualityAnomaly`).
- Pull is what makes the state survive: a Flow-A re-attach restores it on connect; a helper
  restart starts an empty helper registry, but the app keeps its set until first frames clear it
  (`RecordingCoordinator.swift:661 clearRemoteAudioProblem()` is deleted).
- *(v2, scan C6/C7.)* The snapshot carries `helperSessionId`. When it changes, the app marks the
  previous helper's alarms **stale** (still shown, still sticky) and drops them only on
  `captureDidDeliverFirstFrames(track:)` for that track (track-less helper kinds go with either
  track's first frames). A same-helper snapshot replaces helper-owned kinds but preserves the
  2-minute notify clock of a kind that is still active in the same episode, so the 5 s poll never
  re-notifies.
- *(v3, F2 rounds 1–2 rulings; supersedes the v2 bullet above where they differ.)* As merged:
  - **The snapshot.** `CaptureStatusSnapshot` is
    `{helperSessionId, sequence, isCapturing, alarms, tracks, coverage?}`. `coverage` is a status
    pull's cumulative per-track coverage for the helper session, in `captureStop`'s detail keys (L11).
    It is nil in a push, when not capturing, and from an older helper.
  - **Ordered helper ids.** `helperSessionId` is ORDERED: `"<CLOCK_MONOTONIC ms at process start>-<registryResets>"`
    (`HelperSessionId`). The counter increments on every registry reset. A strictly newer id makes
    it the current helper and turns the previous helper's helper-owned alarms stale. An older id is a
    late message and is ignored. A same-helper snapshot whose `sequence` is not newer than the last
    one applied (a pull reply overtaken by a push) is ignored. The helper takes the sequence, the id
    and the alarms in ONE critical section.
  - **Evidence-specific clears.** A stale alarm clears only on evidence about the thing it claims,
    which the helper sends on the reverse channel (`@objc optional`, each carrying the sender's
    `helperSessionId`, so evidence from a new helper that arrives before its first snapshot is never
    lost):
    - `captureDidDeliverFirstFrames(track:helperSessionId:)` clears the delivery kinds
      (`micNotDelivering`, `micFollowFailed`, `remoteNotDelivering`, `remoteRecoveryFailed`) on that
      track.
    - `captureDidDeliverRealAudio(track:helperSessionId:)` (the first non-zero sample) clears the
      content kinds (`micDigitalSilence`, `remotePermissionDenied`, `remoteCantConfirm`) on that
      track. A denied tap delivers frames on time, all of them zero, so first frames cannot disprove
      a content alarm.
    - `captureDidWriteSuccessfully(helperSessionId:)` clears `diskWriteFailure`.
  - **Strict decode.** An alarm kind this build does not know is skipped and reported
    (`unknownAlarmKinds`, which raises `unknownHelperAlarm`). Any other malformed element fails the
    whole decode: a failed poll, never an all-clear.
  - **Notify clock.** The notify clock is per KIND and is never reset by a poll (§6.3).

### 6.3 Presentation (`AlarmPresenter`, app target, thin)

On raise: floating `NSPanel` (`.floating`, `hidesOnDeactivate = false`, no `NSApp.activate`)
listing active alarms with the one action each has; `.timeSensitive` notification with sound;
sticky red menu rows (one per alarm, not dismissible); menu-bar icon. Every 2 min while any alarm
is active: re-notify; reopen the window if "Later" was pressed ≥ 3 min ago
(`CaptureReadiness.repairSnooze`). `AlarmRealarmPolicy` (pure) decides both. The permission alarm
keeps its existing repair window; the rest share the new panel. Benign notices keep the transient
`interruptionWarning` slot and can never touch an alarm. `.critical` interruption level is not
used (gotcha #51).

*(v3, F2 ruling; L2/L4 rulings.)* "On raise: … notification" is governed by a **per-KIND notify floor**
(`AlarmRealarmPolicy.notifyInterval`, 120 s). A kind notifies at once only if it has not notified
within 2 min. That clock is carried across episodes and clears, so a flapping condition cannot notify
faster than every 2 min. The menu rows update immediately whatever the floor. Acknowledgeable kinds
(§6.1) are exempt: each notifies once, at once, and never re-notifies. While NOT recording, a live
alarm backs off: it is presented at once, then after 2 min, 10 min, and at most hourly after that
(`idleRenotifyInterval`). A new permission kind goes to its repair window first. If that window
declines to present, the alarm window presents it. If it has not answered within a 3 s cap, the
alarm's own notification goes out. There is no separate `AlarmPresenter`
type: `RecordingCoordinator.presentAlarms` (Core) decides when, `AlarmRealarmPolicy.presentation`
decides what, and `CaptureAlarmWindowController` / `CaptureAlarmView` (app) show it. Each kind has one
stable notification identifier, so a re-notify replaces that kind's banner and never stacks another.

---

## 7. Honest record and provenance

### 7.1 `TrackAccounting` (pure) → per-track coverage

Counters per track (session-scoped, kept outside the evicting ring): `expectedSeconds`
(mic: capture time; tap: gate-open time), `heartbeatCallbacks`, `deliveredSeconds` (frames written
excluding pad, as Double), `exactZeroSeconds`, `paddedSeconds`, `longestGapSeconds`, `gapCount`,
`rebuilds`, `neverDelivered`. Status:

- `idle` — tap only: `expectedSeconds < 1` and `deliveredSeconds == 0` (nothing ever played);
- `neverDelivered` — expected ≥ 5 s and delivered == 0;
- `compromised` — deficit ≥ 15 s and ≥ 10 % of expected, or any content-compromising anomaly on
  that track (`rateDrift`, `exactZeroMic`, `systemAudioPermissionDenied`, `converterFailure`,
  `writeFailure`, `sustainedFormatDrop`);
- `healthy` otherwise.

*(v3, C6 round 1 ruling; E1/R rulings.)* `neverDelivered` is `expectedSeconds ≥ 1` and
`deliveredSeconds == 0`, on BOTH tracks, not "expected ≥ 5 s". The 5 s debounce belongs to the live
alarm, not to the after-the-fact record. The check runs BEFORE the content-anomaly rule, so a side
that captured nothing is never merely `compromised`. Order in `TrackAccounting.status`:
1. tap `idle` (expected < 1 s and nothing delivered);
2. `neverDelivered`;
3. `compromised` on a content anomaly;
4. tap `idle` again when expected < 1 s and everything delivered was measured exact zero (C-M12);
5. the deficit rule;
6. `healthy`.

There is no `neverDelivered` counter: it is a status. `heartbeatCallbacks` and `exactZeroSeconds` are
nil when unmeasured (SCK), never a claimed 0, and a sum across measured and unmeasured helper
sessions is flagged `*_is_lower_bound`. `longestGapSeconds` is the real gap (`GapTracker`: from the last
heartbeat or the arm until frames return, one still open included), never the ~3 s it took to detect
it.

Emitted as a `trackCoverage` event at every rotation (with the chunk index) and inside
`captureStop` (session totals). `CaptureProvenance` gains `local_coverage` / `remote_coverage`
dictionaries; `system_delivered_seconds` / `system_exact_zero_seconds` stay for compatibility.
`AudioOutputHandler.swift:162-167` (skip the system check when the tap wrote 0 frames) becomes
"skip only when the tap's expected seconds < 1" (Q4.5).

### 7.2 Transcript metadata

- `metadata.dual_stream` = `chunks.contains(where: \.isDualStream)` — the capture-time flag the
  writer persisted, never re-derived from segments (`TranscriptionRunner.swift:397`).
- `metadata.capture = {local: coverage, remote: coverage, gaps: [{start, end, seconds, reason}]}`.
- `metadata.processing_issues = [{chunk, code, track?, count?}]` and `processing_issue_count`,
  from `ProcessedChunk.issues` (codes: `asr_failed`, `diarization_failed`, `vad_unavailable`,
  `stream_empty`, `archive_failed`, `session_write_failed`, `duplicates_flagged` *(v3: was
  `duplicates_dropped`)*, `segments_filtered`, `clusters_absorbed`, `echo_flagged`; the complete v3
  list is below).
- *(v2, scan C13.)* `stream_empty` is informational — an idle side is not a processing problem
  (§9). `processing_issue_count` counts content-affecting issues only (`asr_failed`,
  `diarization_failed`, `archive_failed`, `session_write_failed`) and `processing_problem_chunks`
  the distinct chunks that have one; the completion notice uses the latter.
- *(v3, R0/R2/R3 and R round 3–8 rulings; the code list is `ChunkIssue.Code` in `ChunkSession.swift`.)*
  `duplicates_dropped` is gone: repeats are kept and flagged (`duplicates_flagged`, §7.4). An issue
  is `{chunk?, code, track?, count?, detail?}`; `chunk` is absent for a session-level issue (e.g. a
  failed write after a capture gap). The complete list of codes:

  | Code | Kind | Meaning |
  |---|---|---|
  | `asr_failed` | content-affecting | speech recognition threw for the chunk's track |
  | `diarization_failed` | content-affecting | diarization threw |
  | `vad_failed` | content-affecting | VAD threw at runtime |
  | `stream_missing` | content-affecting | the stream's WAV does not exist at all |
  | `archive_failed` | content-affecting | the archive encode failed |
  | `session_write_failed` | content-affecting | `session.json` could not be written |
  | `chunk_index_collision` | content-affecting | a chunk arrived under an index already held by a different file; it was processed under a fresh index (`count` = the index it collided with), never skipped |
  | `seed_mismatch` | content-affecting | a resume was offered another session's `session.json`; refused, the session started fresh |
  | `vad_unavailable` | informational | the VAD model is not cached: the gate ran without a speech map |
  | `stream_empty` | informational | the stream's WAV is a header only (an idle side) |
  | `duplicates_flagged` | informational | abutting repeats kept, flagged `duplicate` |
  | `zero_length_dropped` | informational | zero-duration segments (no audio behind them) dropped |
  | `segments_filtered` | informational | segments that failed the VAD/quality gate, kept and flagged `filtered` |
  | `clusters_absorbed` | informational | minority diarization clusters absorbed into the dominant speaker |
  | `echo_flagged` | informational | local segments flagged `echo` (mic bleed) |
  | `duplicate_source_other_index` | informational | a file already processed under one index arrived again under another and was skipped (`count` = the incoming index); nothing lost |
  | `seed_engine_changed` | informational | a resumed session's seed was transcribed with another engine |
  | `session_file_displaced` | informational | the day folder's `session.json` held another session and was moved aside (`session-<id>.json`) |
  | `transcribed_from_archive` | informational | the chunk's WAVs were gone and its words came from its `.m4a` |
  | `mic_stream_absent` | informational | the chunk had no microphone stream; processed remote-only |
  | `merge_skipped_implausible_timing` | informational | chunk start times were implausible for one timeline (a gap over 12 h, a non-real start, one before the first chunk): not merged, each chunk's own audio is listed |
  | `merge_skipped_folder_not_answering` | informational | a merge step on the recording folder did not answer within its bound: not merged, `detail` names the step |
  | `quota_exceeded_by_current_session` | informational | the storage quota could not be met without deleting this session's own audio, which is never done |
  | `audio_lengths_unknown` | informational | the listed audio's lengths could not be read within their bound; `chunk_durations` left out |

  `processing_issue_count` and `processing_problem_chunks` count the content-affecting codes only
  (`ChunkIssue.Code.contentAffecting`). A content-affecting issue with no `chunk` counts as one more
  problem chunk, so the notice is never silent about it. A code written by a newer build decodes as
  itself and is not counted.
- `metadata.diarization` = diarizer present and no chunk has `diarization_failed`.
- `metadata.merged_audio = {passthrough: Bool, gaps_inserted_seconds}` when concatenated.

### 7.3 Completion notice and summary

`CaptureQualityNotice.completionTitle(anomalyCount:problemChunkCount:segmentCount:)` picks exactly
one of "Transcription Complete", "— capture anomalies", "— N chunks had processing problems",
"— no speech was transcribed", with precedence no speech > capture anomalies > processing
problems; the body names every non-zero count *(v2, scan C14: v1 left the combination undefined)*.
`MeetingSummarizer.parseTranscript` reads `metadata.capture`; `SummaryPromptBuilder`
adds a header line ("Remote audio: not captured (0 s delivered of 2736 s expected)") and a rule
("state it in the Summary section when a side was not captured").

### 7.4 Post-capture data loss (P2–P14)

- **Archiver/concatenator (P4):** mirror branch `mic.length == 0 && sys.length > 0 →
  archiveSystemOnly` (delete the empty mic header only after success). `AudioConcatenator` refuses
  mixed `.wav`/`.m4a` sources (`AudioConcatenatorError.mixedSources`; the locator already copes
  with separate files), never deletes a non-`.m4a` source, honours `preserveSourceWAV`, verifies
  output duration ≈ Σ sources (+ inserted gaps) before deleting, inserts silence for inter-chunk
  gaps > 1 s using `chunk.startTime` (P9), and reports `usedPassthrough` into metadata.
- **Text dedup (P2):** `SpeakerAssignment.deduplicate` drops a repeat only when it abuts the
  previous segment (`start ≤ prev.end + 0.25 s`). The call moves out of the engines
  (`FluidAudioEngine.swift:123`, `SpeechAnalyzerEngine.swift:141`) into both `transcribeStream`s
  so the count lands in `issues`. *(v3, R3 ruling, consistent with P10/P11 below.)* The abutting
  repeat is not deleted: it is kept, flagged `duplicate: true`, labelled like the segment it repeats,
  and hidden from TXT/SRT/summary/rename samples (`duplicates_flagged`). Zero-duration segments are
  dropped and counted (`zero_length_dropped`).
- **Chunk issues (P3):** every swallowed failure in `ChunkProcessor.transcribeStream` becomes an
  issue. An ASR-failed chunk's WAVs are kept alongside its `.m4a` (re-transcribable).
- **Salvage (P6):** `salvageAbandonedSession` returns `SalvageOutcome`; the alert says
  "transcribed up to HH:MM" only when a transcript was written, else "chunks kept on disk, not
  transcribed". Flow B chunked goes through `presentCompletedTranscription` and raises
  `recordingStopped`.
- **Re-detect (P5):** refuse when a listed chunk is missing; pad `.skip` chunks with silence of
  their `chunk_durations` length (refuse if unknown); `speechMap: nil` (already gated once);
  write a backup before overwrite; show the `Outcome` in the dialog. *(v3, R6 ruling.)* The backup
  is `<transcript>.json.bak` (`TranscriptRediarizer.backupURL`), written only before the FIRST
  re-detect and never replaced, so it always holds the original transcript.
- **Minority absorption (P7):** count into `clusters_absorbed`; rename-dialog hint.
- **Session id (P12):** `SessionState.read(directory:sessionId:)` returns nil on mismatch.
- **Quota (P13):** enforcement moves out of the archive `catch`; the day-folder scope is NOT
  changed (owner decision, §11).
- **Summary truncation (P14):** providers return `truncated`; a banner is prepended to the `.md`.
- **Filters keep text (P10, P11, deferrable):** VAD/quality gate marks `filtered: true` (speaker
  `Unknown`) and echo dedup marks `echo: true` instead of deleting; JSON keeps them, TXT/SRT and
  the summary prompt hide them, `TranscriptRenamer` skips them when collecting samples.

---

## 8. Lifecycle hardening

1. **Crash-detection latch (L-N1).** `XPCInterruptionPolicy` (pure): `start()` bumps
   `captureGeneration` and sets `expectingCapture`; `stop()` clears it. Interruption /
   invalidation while not expecting → record `.helperIdleExit` (info) and return: no ping, no
   latch, no throwaway helper spawn (L-N3). While expecting: classify once per generation.
2. **LaunchAgent (L11).** `LaunchAgentHealth` (pure) judges `{plistExists, programPath,
   executablePath, launchctlPrintStatus}` → `.healthy | .missing | .stalePath | .notLoaded` →
   action. At every launch: `launchctl print gui/<uid>/eu.fmasi.parley`, rewrite +
   `bootstrap gui/<uid>` when missing or stale, check exit status, raise `crashProtectionOff` when
   it still fails. Quit removes the plist **before** `bootout` (today's orphaned-plist ordering).
   The single-instance guard still absorbs the bootstrap-time duplicate (gotcha #54).
   *(v3, C2 rounds 1–5 and L3 rulings.)* The states gain `loadedButNotThisProcess`: the job is loaded
   and points at this binary, but its `pid` is not this process's. That is the NORMAL state after
   a Finder or Sparkle launch, and right after the first install (bootstrap starts the job as its own
   process). A crash of this process would not be relaunched. Its action is `handOverToJob`:
   - **The hand-over.** Persist `lastHandOverAt` in `UserDefaults`, then run
     `launchctl kickstart -k gui/<uid>/eu.fmasi.parley`. If this process is still idle after that,
     it flushes the live logs (bounded), releases the single-instance lock and exits 0 at once.
   - **launchd's copy waits.** launchd's copy is recognised by `XPC_SERVICE_NAME == eu.fmasi.parley`
     in its environment. It WAITS up to 10 s for the lock (`SingleInstancePolicy.lockWaitTimeout`)
     instead of yielding, and exits 0 if the wait times out (never non-zero, which KeepAlive would
     respawn). Every other duplicate still yields at once.
   - **The gate.** `LaunchAgentHealth.crashProtectionAction` decides whether to hand over, and when:
     - never while busy (a recording, a start in flight, transcription, post-recording work, or a
       panel still preparing), which defers it to the transition to idle;
     - never by the launchd job itself;
     - never without the single-instance lock;
     - a 30 s `handOverCooldown` between attempts;
     - at most `maxHandOverAttempts` (3) failed kickstarts per process;
     - a visible Parley window defers it, for at most `windowDeferralLimit` (15 min), after which
       the row says why.

     CLI mode exits before any of this runs.
   - **When the row shows.** `crashProtectionOff` is raised only when the hand-over is impossible or
     failed, the lock is unavailable, or repair failed. It is not raised for the normal
     `loadedButNotThisProcess` state.
   - **Verbs.** Every `bootstrap` is preceded by `launchctl enable` (a job disabled by `unload -w`
     cannot be bootstrapped until it is enabled). The job whose `pid` is this process is never booted
     out: a pid match takes a quiet plist rewrite with no launchctl verb. Every destructive or
     restarting verb requires the single-instance lock. Quit uninstalls only while holding the lock
     (`shouldUninstallOnQuit`). `launchctl` runs through the injectable `LaunchctlRunning` seam.
3. **Honest relaunch (L1).** The helper keeps `stopAndFinalize` on disconnect: sealed WAV headers
   are the only guarantee we have. The "helper keeps capturing 120 s" idea is unsafe until
   measurement M-L1 shows the helper survives the app's pid domain. `RelaunchDecision` (pure):
   sentinel present + helper dead → if `now − sentinel.lastAliveAt < 180 s` (refreshed every 60 s
   and at every rotation) → **resume** into the same session (`CrashRecoveryPlanner.planRestart`),
   rebuild the chunk pipeline seeded from `session.json`, salvage completed chunks in the
   background, record `launchRecovery` + `captureGap`, alarm `recordingResumedWithGap` ("Parley
   crashed at HH:MM:SS and resumed at HH:MM:SS — X s not recorded"); else → salvage + alarm
   `recordingStopped`, `recovered = true`, gap recorded. A sentinel marked `stopping` (Stop sets it
   before asking the helper, §8.8) is salvaged, never resumed: a crash during finalize must not
   restart a recording the user stopped *(v2, scan A163/C16)*. The coordinator is constructed in
   `TranscriberApp.init` and injected into `MenuView`, and `recoverIfNeeded` becomes
   `RecordingCoordinator.recoverAtLaunch()` in Core (testable). This also settles the `@State`
   lifetime doubt.
   *(v3, C7 and C9 rulings; L follow-up 37; L review 236.)* The rules as merged in
   `RelaunchDecision.decide`:
   - **Crash time.** The relaunch alert's times come from the LAST-ALIVE time, never `startedAt`
     while anything better exists (`RecordingCoordinator.crashTime`). That is the newest orphan chunk
     WAV's modification time when one exists (the helper sealed it on disconnect), even over a newer
     `lastAliveAt`, which vouches for the app, not the capture. Else `lastAliveAt`, which can be up to
     60 s early. Else `startedAt`. Never later than now.
   - **Stopping.** `wasStopping` is checked BEFORE `helperCapturing` (a stop-in-flight race never
     resumes or re-attaches; the coordinator stops the helper itself, bounded, before the salvage).
     It does not beat an unreachable folder: that still waits (`.waitForFolder`), even mid-stop. A
     Stop whose mark never landed also counts as `stopping`: `stopRequestedAt`, kept apart from the
     sentinel, no earlier than `lastAliveAt`.
   - **The window.** It is strictly `age < 180 s` (`RelaunchDecision.resumeWindow`); the boundary
     salvages. A negative age (the wall clock stepped back after `lastAliveAt` was written) is as
     untrustworthy as no liveness, and salvages.
4. **First-frame probe and honest "Resumed" (L2).** Helper arms both monitors at start / restart /
   rebuild / wake and calls `captureDidDeliverFirstFrames(track:)` *(v3, F2: now
   `(track:helperSessionId:)`, §6.2)*. The app says "Recording
   Resumed" only on it; "Restarted, waiting for audio…" meanwhile; a miss raises the track's
   `NotDelivering` alarm.
5. **Retry cap (L9).** `xpcRetryCount` resets only after 60 s of confirmed frames following a
   restart (`RecordingCoordinator.confirmRecoveryHealthy()`), never on `start()` returning.
   `RecordingCoordinatorTests.swift:795` enshrines the bug and changes red-first. The launch-time
   handlers (`TranscriberApp.setupCrashHandler`) are deleted; the coordinator owns them.
6. **Stop vs crash (L6), double start (L7), post-start failure (L8).** `handleXPCCrash` bails when
   `stopInFlight`; the stop error path re-ingests the orphan (`ChunkProcessor.processChunk`
   ignores an index already present or in flight); every await in `handleXPCCrash` re-checks the
   phase; the failure message distinguishes "written up to HH:MM; the last N s could not be
   recovered" from "nothing could be written". `startInFlight` mirrors `stopInFlight` and disables
   the Record control. Any failure after a successful `start()` runs a bounded `stop()` before
   reporting; the mic marker is released only after the helper confirms.
7. **Disk (L10).** `DiskSpaceCheck` (pure): bytes for one chunk = `chunkMinutes × 60 × 2 × 96 000`;
   refuse to start below 2 chunks + 200 MB; `diskLow` alarm below 1 chunk at a rotation. Rotation
   failure, `session.json` write failure and a `"No capture in progress"` rotate reply become
   alarms/provenance events (the last one is a dead capture → crash path). The "preserved" wording
   is replaced by what is actually on disk. *(v3, C8 ruling.)* `DiskSpaceCheck.freeBytes` reads
   `volumeAvailableCapacityForImportantUsage`, which reads 0 on non-APFS volumes (exFAT, HFS+). A 0
   there falls back to the plain `volumeAvailableCapacity`, so a non-APFS drive is never "full".
8. **Deadlines (L13).** Every `AudioCaptureClient` call gets a `ResumeOnce` deadline (start 15 s,
   stop 20 s, rotate 10 s, mic 10 s, drain 3 s, status 3 s); Stop marks the sentinel `stopping`
   before it asks the helper, and the sentinel is deleted only after `finalize` returns (or salvage
   completes) *(v2, scan A163)*. Closes #194/#195.
9. **Stale sentinel (L3).** `RecordingSentinel.bootSessionUUID` (`kern.bootsessionuuid`, immune to
   sleep and clock changes) replaces the `systemUptime` comparison (7.2 h of sleep excluded on
   this Mac). Stale → salvage + notify, never delete first; unreachable folder → leave it, alarm.
10. **Sleep/wake/logout/quit (L12).** `SystemEventObserver` (app) forwards
    `NSWorkspace.willSleep/didWake/willPowerOff` to the coordinator and, over XPC,
    `systemPowerEvent(kind:)` to the helper. Logout, shutdown and restart all arrive as
    `willPowerOff`; `sessionDidResignActive` is fast user switching — the recording continues and
    nothing is done *(v2, scan C18: v1 named an undefined `sessionResigned` handler)*. Sleep/wake intervals go into `metadata.capture.gaps`;
    wake forces a chunk rotation and re-arms both monitors (the tap heals via the ladder, the mic via
    `attemptRecover()`). `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` while recording (lid
    close is the user's call: recorded, not fought). Quit while recording confirms, then bounded
    stop; logout/shutdown does a bounded stop.
11. **Evidence survives restarts (L4, L14).** `AudioCaptureClient.start(sessionId:)` clears the
    app ring only when the session id changes; the helper ring is drained (bounded) before an
    in-place restart; `LiveDiagnosticsLog` appends every anomaly to `<session>.diag.live.jsonl` as
    it happens and finalize merges it (deduplicated) into `<session>.diag.jsonl`; `retryCount`,
    `launchRecovery`, and `eventsDropped` are counters outside the ring and land in provenance.
    *(v3, C11 ruling; L11 rulings.)* The live log encodes dates at millisecond precision (JSON's
    built-in ISO-8601 drops sub-seconds, so a disk round-trip never matched its ring twin). It is
    deduplicated on a key built from the ms-rounded timestamp, origin, kind and detail
    (`CaptureEvent.dedupKey`). It keeps every non-`info` event plus the coverage-carrying kinds
    (`captureStop`, `trackCoverage`) whatever their severity, so a crash never loses the pre-crash
    coverage. Beside it, `<session>.diag.coverage.json` keeps each helper session's latest pulled
    coverage, which stands in for a `captureStop` a crashed helper never wrote. The live log is
    deleted only once the session's transcript exists.
12. **Clocks (L15).** Chunk `startTime` comes from `MonotonicWallClock` (wall-clock at session start
    + `ContinuousClock` elapsed); wall clock is for display only. *(v3, C10 ruling.)* A
    `ContinuousClock` instant cannot be persisted, so on a resume the clock is re-anchored at the
    current time. The chunk pipeline builds its `ChunkRotator` with `startTime: Date()`, never the
    seeded `meetingStart`.
13. **Helper wedge.** Three missed `captureStatus` polls raise `helperUnresponsive` (the
    `pkill -STOP` checklist case).

---

## 9. False-positive analysis (owner scenarios)

| Scenario | Gate | Heartbeat | Content | Result |
|---|---|---|---|---|
| Headphones, remote muted on Meet (browser) / Zoom (app), minutes — app keeps output IO | `piro=1` for the app → open | tap keeps calling (zeros / comfort noise) | exact zeros → grey zone: permission check (authorized), at most one insurance rebuild per episode, no `awaitingAudio` → **no alarm** | none; M-A/M-G verify the rebuild's dead window |
| Same, but the app stops its output IO when muted | `piro=0` → closed | none expected | n/a | **no alarm** (nothing expected) |
| Headphones vs speakers, per-app device (Zoom on speakers, AirPods default) | process-level, route-independent | same | same | identical; M-F confirms |
| Local silent for a long stretch (muted in the call app, listening) | mic always expected | mic callbacks continue | room noise ≠ exact zero | **no alarm** |
| Lid closed on the built-in mic | expected | callbacks continue | exact zeros ≥ 12 s | **alarm** (`micDigitalSilence`, correct; #193) |
| Presenting / screen-share, one side talking | unchanged by screen share | flowing | quiet side flowing-but-quiet | **no alarm** |
| Recording started before joining (gotcha #66) | closed until a writer appears | none expected | n/a | **no alarm**; tap first-frame probe arms only when the gate opens |
| Bluetooth route change / anchor rebuild | open | generation bumped; judged from the new arm | n/a | no stall verdict during the rebuild; heartbeat required 3 s after |
| Chunk rotation | unchanged | writer swap does not touch heartbeats | n/a | none |
| System sleep | closes; monitors paused on `willSleep` | re-armed on wake | n/a | gap recorded, no alarm unless wake leaves the tap silent while a writer runs |
| App relaunch / helper restart | pulled snapshot | first frames clear | n/a | no false "restored", no lost alarm |
| USB mic with a hardware mute that renders digital zero | expected | flowing | exact zeros | alarm — accepted: it IS not recording; wording names the mic |

Residual risk accepted: a tap that keeps its IOProc running while a paused app stays registered
as "running output" (a suspended app) would be judged healthy-and-quiet; that is the correct
reading of the plumbing. The bonus signal (mic hears the remote voice while the remote track is
empty) is out of scope for this overhaul.

---

## 10. Open questions only a device test can settle

Each has a protocol and a stated degradation if the answer is "wrong". Protocols are the
checklist entries in the plan (Stream X). *(v2, scan A34.)* The never-delivered path is exercised
end to end on device with the diagnostic config key `debug_drop_tap_frames`, which makes the helper
drop every tap buffer before the heartbeat — Incident B on demand; a denied permission is a
different, separate item (the tap delivers exact zeros; no ladder rung runs).

- **M-A Muted-remote exact-zero census (Meet/Chrome, Meet/Safari, Zoom app, Teams, FaceTime,
  iPhone relay × AirPods, wired).** Start recording, join, remote mutes for 5 min, unmutes, speaks.
  Log at 1 Hz: the call app's `piro` and `outDevs`, tap callbacks/s, exact-zero fraction and RMS
  per second, any guard action and its dead window. Pass: frames flow throughout, no alarm.
  *Wrong way:* an app that stops its output IO while muted AND whose unmute produces a first-audio
  edge slower than 5 s → raise the tap first-frame threshold to the measured p99 + 2 s. If ANY app
  renders exact zeros for a muted remote, the `remoteExactZeroSoftAlarmSeconds` knob stays `nil`
  (off) for good; if NONE does across the matrix, it may ship at 300 s as a "can't confirm".
- **M-B TapAutoStart true vs false.** Recording with nothing playing: callbacks/s before first
  playback (expect 0 vs ~94); play 30 s, stop, idle 120 s: do callbacks continue under `true`
  once writers leave? `powermetrics --samplers cpu_power,tasks` 10 min each on the M1 Air;
  `pmset -g assertions` during and after (no coreaudiod assertion when idle); listen for relay or
  amp noise from the speaker engine; HDMI anchor with the display asleep. Pass for `false`:
  continuous callbacks, ≤ 1 % CPU delta, no audible artefact. *Wrong way:* default stays `true`
  and the gate carries the never-delivered decision alone (already required).
- **M-C Incident-B reproduction and the ladder.** Mic = AirPods (HFP), anchor = built-in speaker,
  a browser playing to the AirPods. Register `goin/stpd/gone/diff` on the aggregate, stream
  `log stream --process audio-capture-helper-xpc` for `PauseIO/ResumeIO`. Wait through the ADM
  adaptation (~5 s after mic start). If the IOProc stalls apply in order: (1) `AudioDeviceStop` +
  `Start` on the same IOProc, (2) destroy/recreate the IOProc, (3) aggregate rebuild (same tap),
  (4) new tap. Record which rung restores callbacks, how long each took, and whether
  `AudioDeviceStop` returned promptly. Control: wired mic. *Wrong way:* if only (4) clears it,
  rung (1) is removed from the ladder; if `Stop` blocks, the stuck-rung watchdog is the alarm and
  the rung runs on a throwaway queue so `configQueue` is not wedged.
- **M-D coreaudiod restart.** Test recording only: `sudo killall coreaudiod`; does `srst` fire,
  which listeners survive, what `AudioObjectGetPropertyData(aggregateID, …)` returns, does the
  device-list listener fire, and the gap until the ladder restores capture. Also the mic
  `AVCaptureSession` after restart. *Wrong way:* if `srst` does not reach the helper, the
  heartbeat + `kAudioHardwareBadObjectError` on the aggregate read is the trigger (already in the
  ladder).
- **M-E `stpd` and `goin` on a real tap aggregate** during M-C: does `stpd` fire; what does `goin`
  read while the proxy is stuck paused. *Wrong way:* they stay accelerators; the heartbeat decides.
- **M-F Per-app output device.** Zoom set to "Speakers" while the default output is AirPods:
  the process gate opens and `outDevs` shows the speaker while the device-level gate stays closed.
- **M-G Insurance rebuild during a muted stretch.** Under both autostart settings: does the
  rebuilt aggregate start while the only writer is silent; frames-resumed latency. *Wrong way:*
  under `true` with a dead window > 3 s, the insurance rebuild is disabled while the gate is open
  and callbacks are flowing (the permission check alone remains).
- **M-H Sleep/wake and HDMI display sleep** with the LG as anchor: does the IOProc stall while the
  device stays listed; does `gone`/`goin` change; is the gap recorded; do frames resume after wake.
- **M-J First-frame latency baseline** after `start()` and after each rung under both autostart
  settings → sets the 5 s / 3 s thresholds (p99 + margin).
- **M-L1 App SIGKILL vs helper survival.** Throwaway bundle (the #220 spike layout): SIGKILL the
  app while the helper records; `launchctl print pid/<helper>` before and after; does the helper
  survive, for how long, are the WAV headers sealed. *Wrong way (survives):* a bounded grace with a
  helper-side 120 s finalize timer becomes a follow-up on top of the primary resume path — never
  a replacement for it.
- **M-L2 LaunchAgent.** `launchctl print gui/<uid>/eu.fmasi.parley` after a normal launch, after
  Quit, after a forced crash (`kill -SEGV`); the relaunch must happen within 5 s and the row must
  never show on a healthy machine.
- **M-L3 First-sample helper crash** (gotcha #52 `CRASH_TEST` file): the app must stop after the
  cap (2 restarts inside 10 min) with the honest salvage alert, never loop.
- **M-L4 Sleep 2 min mid-call:** frames resume, interval recorded, no "Resumed" before frames.
- **M-L5 Fill the disk mid-recording** (`mkfile` on the recordings volume): alarm within one
  rotation; the end message names what is on disk.

---

## 11. Product defaults — owner decisions (2026-09-24)

Decided by the owner after v1; each is a task in the plan (Stream D), with red-first tests.

1. **`Config.default.systemAudioSource` flips to `.coreAudioTap` for new installs** (plan D1;
   `Config.swift:189`). SCK has no content check (H2) and loses Continuity/iPhone calls; the
   health model still applies to SCK's arrival stamp (a stalled SCK is caught and alarmed the same
   way). Existing configs are untouched — including a `config.json` that has no
   `system_audio_source` key: its decode fallback stays `.screenCaptureKit`, because that install
   was written by an SCK-era build and has behaved as SCK. SCK stays selectable, relabelled
   "legacy, until #221"; #221 drops it once the tap is proven.
2. **`EngineID.default = .fluidAudio`** (plan D2; `EngineID.swift:28`). The live chunk path calls
   `transcribe(language: nil)`, which throws `languageRequired` on every chunk under Apple Speech,
   and the error is swallowed (P1). Apple Speech stays listed and is **labelled** "Apple Speech —
   not yet usable (#223)" — labelled, never hidden, so no picker can preselect an engine that is
   not in its list *(v2, scan B P2.9/C3: v1 said "hide it from the Setup preselection")*. The
   engine preflight (a synthetic 1 s WAV at Setup Continue and Settings Save, refuse on throw)
   ships. The real fix is issue #223 (high priority, out of scope here).
3. **Storage quota scope (P13)** is out of scope: issue #224. The quota is scoped to the day folder
   and has never deleted anything across days (1.72 GB on disk vs a 1.44 GB quota); fixing the
   scope would start deleting the oldest archives. Not changed here. The quota call still moves out
   of the archive `catch` (plan R5).

---

## 12. Traceability

Finding IDs: C-* from `10-validated-capture.md` (B = Incident B, H = holes, Q = questions,
I = invariants), P* from `11-validated-post-capture.md`, L* from `12-validated-lifecycle.md`
(L-N1..N3 = its §2 new findings).

| Finding | Verdict | Spec | Plan task |
|---|---|---|---|
| C-B1–B6, C-A1, C-Q1, C-Q3a (tap stalls silently; watchdog fires once) | CONFIRMED | §4.2, §5 | P0.3, P1.2, P1.3 |
| C-B4/Q2a (EAGAIN is HAL-internal, never seen) | PARTLY TRUE | §5 (heartbeat decides) | P0.3 |
| C-B7/B8 (system WAV empty, provenance clean, `dual_stream: true`) | CONFIRMED | §7.1, §7.2 | P2.1 |
| C-Q1a–g (listeners: goin/gone/diff/agrp/nsrt/stpd/srst) | CONFIRMED | §5 | P1.2, P1.5 |
| C-Q2b (retry in `rebuildForOutputChange`) | PARTLY TRUE | §5 | P1.1, P1.2 |
| C-Q3b (TapAutoStart edge) | CONFIRMED / stuck-state unverified | §5, M-B | P1.4 |
| C-Q3c (coreaudiod restart) | CONFIRMED by header | §5, M-D | P1.5 |
| C-Q3d–f (sleep, hog, HDMI) | UNVERIFIABLE | §8.10, M-H | P3.5, P4 |
| C-Q4.1 (process-level gate, exclude own pid) | CONFIRMED | §4.3 | P0.3 |
| C-Q4.2 (listeners) | CONFIRMED | §5 | P1.2 |
| C-Q4.3 (ladder) | CONFIRMED direction | §5 | P1.1–P1.3 |
| C-Q4.4 (alarm separate from permission) | CONFIRMED | §5, §6 | P0.4, P1.3 |
| C-Q4.5 (finalize skip; frames/callbacks/rebuilds) | CONFIRMED | §7.1 | P2.1 |
| C-Q4.6 (TapAutoStart=false) | needs device test | §5, M-B | P1.4 |
| C-H1 (never delivers → nothing fires) | CONFIRMED | §4.2 | P0.3 |
| C-H2 (SCK no content check) | CONFIRMED | §11.1 (owner: default flipped) | D1 |
| C-H3 (deliver-then-stop, one banner, one rebuild) | CONFIRMED | §5, §6 | P0.4, P1.3 |
| C-H3b (default-output gate) | CONFIRMED | §4.3 | P0.3 |
| C-H4 (mic/SCK never delivers; mic on notDetermined) | CONFIRMED | §8.4 | P0.3 |
| C-H5 (zeros with authorized → one rebuild) | CONFIRMED | §5 (ladder, slow retry) | P1.3 |
| C-H6 (rate/format/converter → diag only) | CONFIRMED/PARTLY | §7.1 status, §6 | P2.1, P0.4 |
| C-H7 (crash provenance: ring cleared, re-report) | CONFIRMED | §8.11 | P3.6 |
| C-H8 (empty remote invisible; dual_stream) | CONFIRMED | §7.2 | P2.1, P2.2 |
| C-H9 (sticky alarms not loud) | CONFIRMED | §6.3 | P0.4 |
| C-H10 (false coverage test) | CONFIRMED | §4.2 | P0.3 |
| C-I1 (gate fail-open; band) | feasible; band REFUTED → 0.95–1.05 | §4.3, §4.4 | P0.3 |
| C-I2 (60 s exact-zero alarm) | PARTLY TRUE, conflicts with brief | §9, M-A | P1.3 (knob off) |
| C-I3–I5 | CONFIRMED premises | §6, §7, §8.11 | P0.4, P2.1, P3.6 |
| C-K (excessivePadding can't go live) | PARTLY TRUE | §5 (autostart false) | P1.4 |
| P1 (SpeechAnalyzer default) | CONFIRMED | §11.2 | D2 (preflight + label + default flip; owner 2026-09-24; real fix #223) |
| P2 (dedup without time) | CONFIRMED | §7.4 | P2.4 |
| P3 (chunk failures swallowed) | CONFIRMED | §7.2, §7.4 | P2.2 |
| P4 (archiver/concatenator) | CONFIRMED + probe | §7.4 | P2.3 |
| P5 (re-detect) | CONFIRMED | §7.4 | P2.6 |
| P6 (salvage / Flow B) | CONFIRMED | §7.4, §8.3 | P2.5, P3.1 |
| P7 (absorption) | CONFIRMED | §7.4 | P2.7 |
| P8 (dual_stream, summary) | CONFIRMED | §7.2, §7.3 | P2.1 |
| P9 (concatenator ignores startTime) | CONFIRMED, not observed | §7.4 | P2.3 |
| P10, P11 (VAD/echo delete) | CONFIRMED | §7.4 | P2.8 (deferrable) |
| P12 (session id) | CONFIRMED | §7.4 | P2.7 |
| P13 (quota in catch) | PARTLY TRUE | §7.4, §11.3 | P2.7 |
| P14 (truncation) | CONFIRMED | §7.4 | P2.7 |
| P15 (archiver spin) | REFUTED | — | — |
| L1 (app crash ends recording silently) | CONFIRMED | §8.3 | P3.1 |
| L2 (never-delivered; "Resumed" unverified) | CONFIRMED | §4.2, §8.4 | P0.3, P0.4 |
| L3 (stale sentinel) | CONFIRMED | §8.9 | P3.1 |
| L4 (rings wiped) | CONFIRMED | §8.11 | P3.6 |
| L5 (one slot; no notification) | CONFIRMED | §6 | P0.4 |
| L6 (stop vs crash) | CONFIRMED | §8.6 | P3.2 |
| L7 (double start) | CONFIRMED | §8.6 | P3.2 |
| L8 (post-start failure) | CONFIRMED | §8.6 | P3.2 |
| L9 (retry cap) | CONFIRMED | §8.5 | P0.5 |
| L10 (disk) | CONFIRMED | §8.7 | P3.3 |
| L11 (LaunchAgent OFF) | CONFIRMED | §8.2 | P0.2 |
| L12 (sleep/wake; give-up) | CONFIRMED / PARTLY | §8.10, §5 | P3.5, P1.2 |
| L13 (deadlines) | CONFIRMED | §8.8 | P3.4 |
| L14 (ring eviction) | CONFIRMED | §8.11 | P3.6 |
| L15 (wall clock) | CONFIRMED | §8.12 | P3.6 |
| L-N1 (crash-detection latch) | CONFIRMED (new) | §8.1 | P0.1 |
| L-N2 (`trackNeverDelivered` unreachable) | CONFIRMED (new) | §4.2 | P0.3 |
| L-N3 (throwaway helper on idle-exit) | CONFIRMED (new) | §8.1 | P0.1 |
| "09-10 10:50 never delivered" | REFUTED (it is #193) | — | — |
| "WebKit voice processing caused B2" | REFUTED (helper's own HFP mic IO) | M-C control run | P4 |
| "helper keeps capturing 120 s" | UNSAFE until M-L1 | §8.3 | P4 |

---

## 13. Non-goals

- Switching back to, fixing, or retiring ScreenCaptureKit (#221). SCK inherits the arrival-stamp
  liveness and alarms for free; nothing SCK-specific is built.
- Content-based detection (loudness, VAD) as an alarm trigger. Quiet is never broken.
- The bonus cross-track signal (mic hears the remote while the remote track is empty).
- A standalone LaunchAgent helper that survives app death (changes the tap's TCC attribution,
  gotcha #70a) — only if M-L1 forces it, as its own spec.
- Echo cancellation (#35), meeting sensing (#118), streaming.
- Changing the quota scope (#224) or the CLI `run()` path's `dual_stream` semantics.
- App Store compatibility. New App Store-relevant choices here: none — `kAudioHardwarePropertyProcessObjectList`
  / `kAudioProcessPropertyIsRunningOutput` are public (AudioHardware.h, shipped with the tap API);
  `kern.bootsessionuuid` is a public sysctl; `launchctl bootstrap` is the LaunchAgent already
  registered in `docs/app-store-blockers.md`.

---

## 14. Versioning

The overhaul changes what transcripts say (`dual_stream`, `processing_issues`, coverage), the
alarm surface, and the recovery behaviour → **MINOR** (v0.10.0 line, or the next MINOR after
v0.9.0 is tagged), with release notes that lead with "your transcripts now state per side how much
was captured; re-check recordings that reported `dual_stream: true` with no remote segments".
