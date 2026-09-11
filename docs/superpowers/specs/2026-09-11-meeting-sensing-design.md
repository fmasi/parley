# Meeting sensing — design spec

**Date:** 2026-09-11 (rev 2 — after adversarial review)
**Status:** Design decided; reviewed (Fable, 15 findings, all folded in); pending implementation plan
**Milestone:** v0.10 — Meetings that run themselves
**Closes:** #118
**Branch:** `feature/meeting-sensing-118` (off `main` 9f01c8d). **Do not merge until v0.9.0 is tagged** —
anything on `main` before then ships in v0.9.0.

## Problem

Forgetting to press Record is the number-one failure users have with meeting recorders. A missed
meeting is unrecoverable; everything else Parley does (diarization, summaries, the context layer)
is worth nothing for a meeting that was never captured. Parley today has no idea a meeting started.

The pure decision core landed in v0.7.x (`TranscriberCore/MeetingSenseDecider.swift` + 9 tests) as
intentional dead code. Nothing senses, nothing prompts, there is no config key and no Settings UI.

## Goals

- When a call starts, the user is **asked** to record — through a surface that survives a missed
  banner, Focus, or disabled notifications.
- One click from "call started" to "recording".
- When the call app lets go of the mic during a recording, the user is **asked** to stop.
- **Near-zero cost when idle on a MacBook Air M1 / 16 GB** — the performance target, not the M5 Pro.
- Airgap-safe: only local Core Audio + process metadata; nothing leaves the machine.

## Non-goals

- **Never auto-record, never auto-stop.** Sensing only ever prompts (consent / courtroom-grade
  principle, locked in #118).
- Detecting a meeting from calendar events or window titles.
- Recording a second meeting while the previous one is still transcribing (see Known limitations).

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Prompt surface = **a top-centre floating "island" panel** (Dynamic-Island-like, at the notch), **plus a menu-bar indicator and an in-menu banner** as backup. No system notification. | Forgetting is the #1 problem. A notification vanishes in ~5 s, is held by Focus (no time-sensitive entitlement), or is disabled (#150). The island is Parley's own window: always visible, over full-screen apps, needs no notification permission — and it is what Notion ships (owner's first-hand observation). Dropping notifications also removes categories/action routing — less code. |
| D2 | Trigger = **per-process attribution**: the specific app capturing input, via Core Audio process objects | "Mic busy + Zoom running" fires falsely when Zoom idles in the background while you dictate, and can't see browser calls at all. |
| D3 | **Browsers count** (Chrome, Safari/WebKit, Arc, Edge, Firefox) as lower-confidence meeting apps | Google Meet / Teams-web / Zoom-web are browser-only for many users. Cost: an occasional prompt for browser dictation. |
| D4 | **Stop prompt included** | Silence detection is a dead config key (`SettingsView.swift:211`) — nothing ends a forgotten recording. |
| D5 | **Event-driven sensing, no polling** | Scans are cheap (below) but periodic wakeups are not free on an M1 Air on battery. |
| D6 | **Default ON** (`meeting_sensing = prompt`), **with plain disclosure** | An opt-in "don't forget" feature never reaches the users who forget. Notion shipped the same detection default-on *without* disclosure and drew a public privacy backlash (HN 44594790: "privacy invading", "make it opt-in"). Parley is upfront where the user will see it, one toggle turns it off, and the code is open source (AGPL) — anyone can verify it only reads which app holds the mic. |

## Evidence

**Throwaway spike, 2026-09-11, M5 Pro, macOS 26:**
- `kAudioHardwarePropertyProcessObjectList` returns every Core Audio client process (38 at the
  time) with `kAudioProcessPropertyPID`, `…BundleID`, `…IsRunningInput` — readable from an
  unprivileged, unsandboxed binary with no TCC prompt.
- `AudioObjectAddPropertyListenerBlock` returns `noErr` for `kAudioProcessPropertyIsRunningInput`
  (per process) and `kAudioHardwarePropertyProcessObjectList` (system). Not yet proven to fire.
- Scan cost (list + one `IsRunningInput` read per process): ~51 ms first call (one-time HAL client
  init), **~4.7–5.2 ms steady state** for 38 processes. Budget ×3 for an M1 Air → ~15 ms.
- Bundle IDs are not always the app the user sees: Chrome appears as `com.google.Chrome` **and**
  `com.google.Chrome.helper`; Safari/WebKit media runs in `com.apple.WebKit.GPU`; several daemons
  report an empty bundle ID.

**Header facts (AudioHardware.h:380-393):** a listener block is `Block_copy`'d and its queue retained
"until a matching call to AudioObjectRemovePropertyListenerBlock is made". Nothing documents what
happens when a *Process* object is destroyed — and browsers/Teams spawn and kill helper processes
constantly. So per-process listeners are kept to a small, explicitly-managed set (§1).

**Production precedent (Notion desktop, `mac_utils.node`, inspected locally):** a
`MicrophoneUsageMonitor` with a property listener on the input device + a *debounced*
`getProcessesAccessingMicrophone` lookup matched against running bundle IDs. That is this design's
start path. Notion's prompt copy: "In a meeting? Start AI Meeting Notes", shown as its own floating
panel at the top-centre of the screen, Dynamic-Island style (owner's first-hand observation).

## Architecture

```
Core Audio HAL ──device/system listeners──▶ MeetingSensor (app layer, own serial queue)
                                               │ coalesced scan → CaptureSnapshot
AppState.phase changes ────────────────────────┤
                                               ▼
                                   MeetingSenseEngine (TranscriberCore, pure)
                                   step(state, input, mode, now) → (state', [Action])
                                               ▼
                                   MeetingPromptPresenter (app layer, @MainActor)
                                      ├─ MeetingIslandPanel (top-centre floating panel)
                                      ├─ AppState.detectedMeeting → menu-bar icon + banner
                                      └─ RecordingLauncher → RecordingCoordinator.start/stop
```

### 1. `MeetingSensor` — `TranscriberApp/Services/MeetingSensor.swift` (new)

The only component that touches Core Audio. Everything runs on one private serial `DispatchQueue`,
never main (gotcha #68: HAL calls can block indefinitely — a wedged sensor wedges only itself).

- **Wake signals (baseline, always on):**
  - `kAudioDevicePropertyDeviceIsRunningSomewhere` on **every input device** (not just the default —
    a call can use a non-default mic), plus `kAudioHardwarePropertyDevices` to re-register on device
    churn. This is the pattern already device-proven in `MicCaptureSession.swift:248-249` (gotcha #55).
  - `kAudioHardwarePropertyProcessObjectList` on the system object (one registration) — catches a
    call app connecting to the HAL while another client already holds the device.
- **Per-process listeners (only while recording):** `kAudioProcessPropertyIsRunningInput` on the
  process objects of the **watched set** (≤ a few; §2). Added when recording starts / the watched set
  grows, removed when recording ends. Needed because during a recording Parley's own helper holds the
  device, so the device-level signal cannot see the call app let go. No general reconcile diff.
- **Scan:** any wake schedules one **leading-edge coalesced scan** (fires on the first event, folds
  further events within 250 ms). The scan reads the process list, `IsRunningInput` per process, and
  `BundleID` + `PID` for processes capturing. It reads live state, so listener storms are harmless.
- **Output:** `CaptureSnapshot` — the set of raw bundle IDs currently capturing input — delivered to
  the main actor. No classification or policy in the sensor.
- **Timers:** none, except the **one-shot** stop-debounce timer the engine may request; when it fires
  it triggers an ordinary scan (not a separate engine entry point). Never a repeating timer.
- **Lifecycle:** started only after **both** launch-time crash recovery (`recoverIfNeeded`) and the
  launch gate (`checkAndGate`) have completed — today these are independent unordered Tasks
  (`TranscriberApp.swift:140, 182`); the sensor start is sequenced after both, so a relaunch
  mid-recording never sees an `.idle` phase with a call in progress. Not in CLI mode. Stopped when
  `meeting_sensing = off`.

### 2. `MeetingSenseEngine` — `TranscriberCore/MeetingSenseDecider.swift` (rewrite)

Replaces the stateless `MeetingSenseDecider.decide(signal:…)` and its tests. Pure, `Sendable` value
types, caller-supplied clock — fully unit-testable, no Core Audio / AppKit.

**Classification** — `MeetingApps.classify(bundleID:) -> MeetingApp?`,
`MeetingApp { id; displayName; kind: .native | .browser }`:
- Exact + family-prefix matching so helpers map to their parent (`com.google.Chrome.helper` → Chrome,
  `com.microsoft.teams2.*` → Teams, `us.zoom.*` → Zoom).
- `com.apple.WebKit.GPU` → `.browser`, displayName "Safari".
- Parley's own processes (`eu.fmasi.parley*` — app, capture helper, level meters) are **always
  excluded**.
- Unknown or empty bundle ID → `nil` → never prompt. The list is reviewable data.
- Native: the existing `MeetingApps.bundleIDs` (Zoom, Teams classic/new, Webex ×2, Discord, Slack).
  FaceTime stays excluded (#118). Browsers: Chrome, Safari/WebKit, Arc (`company.thebrowser.Browser`),
  Edge (`com.microsoft.edgemac`), Firefox (`org.mozilla.firefox`). Exact helper IDs fixed in Task 0.

**Input** — one entry point: `step(state, input, mode, now) -> (state, [MeetingSenseAction])` where
`input` is `.snapshot(CaptureSnapshot)` or `.phaseChanged(Phase)` (`.idle | .recording | .transcribing`,
fed by observing `AppState.phase`).

**State** — `MeetingSenseState`:
- `capturing: [MeetingApp: Date]` — meeting apps capturing at the last snapshot (with since-times).
  The initial value is empty, so apps already capturing at first snapshot count as transitions:
  launching Parley mid-call, or turning the setting on mid-call, prompts. Intended (goal 1).
- `pendingStart: MeetingApp?` — at most one start offer at a time; a second app transitioning while
  one is pending folds into it (Zoom + Chrome = one offer).
- `suppressed: Set<MeetingApp>` — the user said "not now" / "keep recording"; cleared per app when
  that app releases the mic. The single suppression mechanism.
- `lastExpanded: [MeetingApp: Date]` — for the expansion-only cooldown.
- `watched: Set<MeetingApp>` + `releasedAt: Date?` — only meaningful while recording.

**Actions** — `.offerStart(MeetingApp, expand: Bool)`, `.withdrawStart`, `.offerStop(MeetingApp)`,
`.withdrawStop`, `.watch(Set<MeetingApp>)` (tells the sensor which per-process listeners to hold),
`.scheduleScan(after: TimeInterval)`.

**Rules:**
- `mode == .off` → no offers; any pending offer is withdrawn.
- **Start:** phase ≠ `.recording`, a meeting app transitions to capturing, not in `suppressed` →
  `.offerStart(app, expand: <outside the app's 5-min expansion cooldown>)`. The **island (compact),
  banner and icon appear on every new episode**; the cooldown gates only the expanded, attention-
  grabbing state (a call that drops and reconnects must not lose the persistent surface, but must
  not re-interrupt either).
- **Withdraw start:** the offered app stops capturing before the user answers → `.withdrawStart`.
- **Phase → `.recording`** (manual Record, prompt Record, or crash re-attach): withdraw any pending
  start; seed `watched` from the meeting apps capturing *now*; emit `.watch(watched)`. A meeting app
  that starts capturing later during the recording joins `watched`.
- **Stop:** phase is `.recording`, `watched` non-empty, every watched app has stopped capturing →
  set `releasedAt = now`, `.scheduleScan(after: 30)`. On any later snapshot: if still all released and
  `now − releasedAt ≥ 30 s` and not suppressed → `.offerStop(app)` once. Any watched app
  re-acquiring clears `releasedAt` (mute/unmute and device switches must not fire it). "Keep
  Recording" adds the apps to `suppressed` until they re-acquire and release again.
- **Phase leaves `.recording`:** clear `watched` / `releasedAt`, `.watch([])`, `.withdrawStop`.
- Recording with an empty `watched` set (started with no meeting app capturing) → no stop offers.

### 3. `MeetingPromptPresenter` — `TranscriberApp/Services/MeetingPromptPresenter.swift` (new)

`@MainActor`. Turns actions into UI; routes answers back. Owns the island panel and
`AppState.detectedMeeting`. **No `UNNotification` usage** — `NotificationDelegate` is unchanged,
and the missing time-sensitive entitlement (only `critical-alerts` in `packaging/*.entitlements`)
stops mattering.

**The island** — `TranscriberApp/Services/MeetingIslandController.swift` +
`TranscriberApp/Views/MeetingIslandView.swift`, following the existing `NSPanel` window-controller
pattern (`SessionNameWindowController`) and the 0.8.x design system.

- **Window:** borderless `NSPanel` with `.nonactivatingPanel` (clicking it never takes focus from
  Zoom), `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary, .ignoresCycle]` (shows over full-screen apps, on every Space), `hidesOnDeactivate =
  false`, `sharingType = .none` (see Failure modes — screen sharing). Created lazily on the first
  offer, closed and released on withdraw — no idle window.
- **Placement:** top-centre of the screen that has the menu bar focus (`NSScreen.main`); on a notched
  display it hugs the notch (`auxiliaryTopLeftArea`/`auxiliaryTopRightArea` give the camera-housing
  gap), otherwise it sits just below the menu bar.
- **Layout (mirrors Notion's, from the owner's screenshot):** white rounded pill; Parley icon left;
  title + one-line subtitle; **one primary button** with a chevron menu for the secondary choices.
  One obvious action beats two equal buttons for the forgetful user.
- **States:** **expanded** (full pill) on a new episode outside the expansion cooldown → after 20 s
  untouched, **compact** (small pill beside the notch: red dot + app name) until answered or the call
  ends; clicking compact re-expands. Within the cooldown the island arrives compact. Spring
  animation; honours Reduce Motion. Posts a VoiceOver announcement on appear (a non-activating panel
  is otherwise silent to VoiceOver).

**Start offer:**
- Title **"Record this meeting?"**, subtitle **"Zoom is using the microphone"** (calendar title
  instead when one is found: "Weekly sync · Zoom").
- Primary button **Record** → `RecordingLauncher.quickStart(app:)`. Chevron menu: **Name it first…**
  → `RecordingLauncher.promptAndStart()` (naming panel), **Not now** → suppress the episode,
  **Turn off meeting detection…** → opens Settings → General.
- **First-ever offer** swaps the subtitle for the disclosure (D6): "Parley noticed Zoom using the mic
  — it only checks which app, on this Mac, and never listens."
- `AppState.detectedMeeting = DetectedMeeting(app:)` → `menuBarIcon` shows a distinct
  "meeting detected" symbol while idle; `MenuView` shows a banner "Zoom call in progress" with
  **Record**. Backup surfaces for anyone who closed the island's attention state without answering.

**Stop offer:** same island. Title **"Stop recording?"**, subtitle "Zoom released the microphone ·
<session>". Primary **Stop** → `coordinator.stopRecording()`; chevron: **Keep recording** → suppress.
Plus a banner with **Stop** in the recording view.

**Withdraw:** animate the island out and release it; clear `detectedMeeting`/banner.

### 4. `RecordingLauncher` + coordinator hoist

Today `RecordingCoordinator` is `@State` inside `MenuView` (`MenuView.swift:45`), and
`promptAndStartRecording` + `selectedMicId` are private to it — nothing outside the menu can start a
recording. (Side effect of today's shape: `MenuBarExtra(…systemImage: appState.menuBarIcon)`
re-evaluates the scene on every icon change and constructs a throwaway coordinator each time; the
hoist removes that.)

- `TranscriberApp` creates the `RecordingCoordinator` (all its dependencies already live there) and
  a `@MainActor @Observable RecordingLauncher` owning `selectedMicId` (observable — `activeMicName`
  reads it), `promptAndStart()` (the current naming-panel flow, moved verbatim) and `quickStart(app:)`.
  Nothing in `TranscriberApp` depends on the coordinator's current lifetime (recovery uses the static
  `setupCrashHandler`; the coordinator claims `onServiceCrash`/`onFatalFailure` only inside
  `startRecording`).
- **Start guard in the coordinator:** `startRecording` gains `guard appState.isIdle, !startInFlight`
  (mirroring the existing `stopInFlight`) and returns whether it started. With three entry points
  (menu, island, banner), two starts could otherwise interleave across `await
  captureClient.start` → two sentinels, two helper starts.
- `quickStart` name = calendar title if found (waits ≤ 1 s — the name is baked into filenames at
  start by `startNaming`), else "<App> call"; mic = last-used (the helper already falls back to the
  default device if it is gone, `MicCaptureSession.swift:157-163`). Starts immediately.
- **Transcribing gate:** if the phase is `.transcribing` when Record is chosen, the launcher queues
  the start; it fires when the phase becomes `.idle` **only if the offered app is still capturing in
  the latest snapshot** (otherwise drop it and clear the banner). Never fired from a re-attach path.
  Banner meanwhile: "Will start when the previous recording finishes processing".
- `MenuView` receives the coordinator + launcher instead of constructing them; the manual Record
  button's behaviour is unchanged.

### 5. Calendar lookup off the main thread (the relevant part of #197)

`CalendarService.currentEventTitle` runs a synchronous `EKEventStore.events(matching:)` over a
12-hour window on main. Make it `async`: run the query off main and race it against a 1 s timeout
(the query can't be cancelled — it finishes in the background and its result is discarded; reuse the
existing resume-once helper). `CalendarEventPicker` is untouched.

### 6. Config + Settings

- `Config.meetingSensing: MeetingSenseMode` (`off` | `prompt`), CodingKey `meeting_sensing`,
  `decodeIfPresent` → default `.prompt`.
- Settings → General: Toggle "Offer to record when a meeting starts" with the disclosure caption
  ("Parley checks which app is using the microphone — on this Mac only; it never listens.").
  Settings are Save-applied (`SettingsView.swift:14-16`), so the sensor reacts to
  `ConfigManager.config.meetingSensing` changing after Save — no special-casing in the view.
- Setup window: one line mentioning the feature and the same disclosure.
- `docs/parameters.md` gets the key.

## Performance budget (target: MacBook Air M1, 16 GB)

| Situation | Budget |
|---|---|
| Idle, no audio activity | **0 timers, 0 periodic wakeups from the sensor**, ~0 CPU |
| Per audio event | ≤ 1 coalesced scan, ≤ 20 ms on M1 Air (≈5 ms measured on M5 Pro), sensor queue |
| Launch | one-time HAL client init (~50 ms measured) on the sensor queue, never main |
| While recording | + ≤ a few per-process listeners; no timers beyond the one-shot debounce |
| Main thread | receives a finished snapshot only; no HAL or EventKit calls on main |

Measured in the device test: Activity Monitor "Idle Wake Ups" for Parley with sensing on vs off
(must be indistinguishable), and `os_signpost` intervals around each scan. If only the M5 Pro is
available, record the numbers and flag the M1 Air figure as extrapolated.

## Failure modes

| Failure | Behaviour |
|---|---|
| A HAL call blocks forever (gotcha #68) | Only the sensor queue wedges: prompts stop; recording and UI unaffected. Logged once. |
| A second app starts capturing while the device is already running (no `IsRunningSomewhere` edge) | The process-list listener still wakes a scan if the app newly connects to the HAL; otherwise missed. Measured in Task 0. |
| Per-process listener doesn't fire / leaks on process death | Only a handful exist, only while recording; Task 0 measures both. Fallback: the one-shot scan also runs when a device-level edge arrives. |
| Focus on / notifications disabled | Irrelevant — the island is Parley's own window, not a notification. |
| Full-screen call app | Island shows over it (`.fullScreenAuxiliary`, all Spaces) without taking focus. |
| User is screen-sharing | The island could appear in the share, showing participants "Record with Parley". `sharingType = .none` should exclude it, but whether ScreenCaptureKit on macOS 15+ still honours that is **unverified** — device test. If it doesn't, the island stays compact (no text) while a share is detected. |
| Unknown helper bundle ID | Classified `nil` → no prompt; add it to the list. |
| Browser dictation / voice search | One expanded island, then compact; expansion cooldown; Not now suppresses the episode. |
| Call app keeps the mic open after leaving (Teams preview, a Meet tab) | No stop offer. Measured in Task 0; not fixable by debounce. |
| Parley's own meter or helper opens the mic | Excluded by bundle prefix — can never self-trigger. |
| Record from the island while a Settings level meter runs on the same mic | Device-test item; if the helper's start hangs behind it, `quickStart` calls `InputLevelMonitor.stopAndRelease` on open meters first (gotcha #68 corollary 2). |

## Testing

- **Pure engine, test-first:** start on transition only; first-snapshot-counts-as-transition; no
  start while recording; one pending offer, second app folds in; expansion cooldown gates `expand`
  but not the island/banner; Not now suppresses until release; withdraw on early release;
  phase→recording withdraws start and seeds `watched`; re-attach (phase→recording with a call in
  progress) seeds `watched`; stop debounce (30 s, re-acquire cancels, exactly-once); Keep Recording;
  empty `watched` → no stop; phase leaves recording → clears + withdraws; mode off withdraws.
- **Classification table:** helpers → parent, WebKit.GPU → Safari/browser, Parley excluded,
  unknown/empty → nil.
- **Coordinator:** concurrent `startRecording` calls → exactly one start; existing
  `RecordingCoordinatorTests` unchanged and green.
- **Config:** round-trip + missing key → `.prompt`.
- **Device test** (`scripts/test-checklist.md`): Zoom, Teams, Meet in Chrome, Meet in Safari → prompt
  within ~1 s; browser dictation → at most one prompt; FaceTime → none; leave the call → stop offer
  after 30 s; mute 60 s → none; Focus on → island still shows; full-screen Zoom → island over it,
  Zoom keeps focus; screen-share in Zoom → island not visible to the other side; second monitor →
  island on the screen with the menu bar focus; notched vs non-notched display placement; Record
  from the island with the Settings mic picker open; relaunch Parley mid-recording mid-call → no
  start offer, stop offer still works after leaving; idle-wakeups measurement.

## Task 0 (first plan task): on-device listener spike — throwaway, not merged

On the real machine, with the device + process-list listeners and per-process listeners registered:
start/stop a Zoom call, a Meet call in Chrome and in Safari, a Teams call, and browser dictation.
Record: (a) which listeners fire on start and on stop, and latency; (b) the exact bundle IDs that
report `IsRunningInput = 1` per app; (c) whether the app **keeps the input open after leaving** the
call (Teams pre-join preview, Chrome after the Meet tab closes); (d) churn/leak: spawn and kill ~100
short-lived audio processes (`afplay`) with per-process listeners registered, watching RSS and the
`Remove…ListenerBlock` OSStatus on dead objects. Outcome fixes the classification table and confirms
or adjusts §1.

## Known limitations / follow-ups (file as issues)

- **Back-to-back meetings:** `AppState` has one phase, so a new recording cannot start while the
  previous one is transcribing; a queued start loses the head of the next meeting. Follow-up:
  decouple capture start from post-processing.
- **Precision upgrade — local network signal:** a browser holding the mic *and* carrying active UDP
  media is almost certainly a call; dictation isn't. Reading a process's own sockets
  (`proc_pidinfo`) is a local read — no airgap impact — and would run only on a mic event. Deferred
  from v1 (extra code, and "monitors your network" reads badly next to Notion's backlash); adopt if
  the device test shows browser false prompts are frequent.
- Apps not on the list (WhatsApp desktop, FaceTime) — revisit with data.
