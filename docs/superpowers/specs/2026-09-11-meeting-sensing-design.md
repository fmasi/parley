# Meeting sensing — design spec

**Date:** 2026-09-11
**Status:** Design decided (brainstorming), pending adversarial review + implementation plan
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
- Airgap-safe: only local Core Audio + process metadata. No network, no calendar as a trigger.

## Non-goals

- **Never auto-record, never auto-stop.** Sensing only ever prompts (consent / courtroom-grade
  principle, locked in #118).
- Detecting a meeting from calendar events, window titles, or network traffic.
- Recording a second meeting while the previous one is still transcribing (see Known limitations).

## Decisions (made during brainstorming)

| # | Decision | Why |
|---|---|---|
| D1 | Prompt surface = **time-sensitive notification with a Record action, plus a persistent menu-bar indicator and an in-menu banner** | Forgetting is the #1 problem; a notification alone vanishes in ~5 s, is swallowed by Focus, or is disabled (#150). The indicator/banner persist until the call ends. |
| D2 | Trigger = **per-process attribution**: the specific app capturing input, via Core Audio process objects | "Mic busy + Zoom running" fires falsely when Zoom idles in the background while you dictate, and can't see browser calls at all. |
| D3 | **Browsers count** (Chrome, Safari/WebKit, Arc, Edge, Firefox) as lower-confidence meeting apps | Google Meet / Teams-web / Zoom-web are browser-only for many users. Cost: an occasional prompt for browser dictation, bounded by cooldown. |
| D4 | **Stop prompt included** | Silence detection is a dead config key (`SettingsView.swift:211`) — nothing ends a forgotten recording. |
| D5 | **Event-driven sensing, no polling** | Measured below: a scan is cheap but periodic wakeups are not free on an M1 Air on battery. |
| D6 | **Default ON** (`meeting_sensing = prompt`) | An opt-in "don't forget" feature never reaches the users who forget. |

## Feasibility evidence (throwaway spike, 2026-09-11, M5 Pro, macOS 26)

- `kAudioHardwarePropertyProcessObjectList` returns every Core Audio client process (38 at the
  time) with `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
  `kAudioProcessPropertyIsRunningInput` — **readable from an unprivileged, unsandboxed binary with no
  TCC prompt**.
- `AudioObjectAddPropertyListenerBlock` returns `noErr` for both `kAudioProcessPropertyIsRunningInput`
  (per process) and `kAudioHardwarePropertyProcessObjectList` (system). **Not yet proven to fire** —
  see Task 0.
- Scan cost (list + one `IsRunningInput` read per process): **~51 ms on the first call** (one-time HAL
  client init), **~4.7–5.2 ms steady state** for 38 processes. Budget ×3 for an M1 Air → ~15 ms.
- Bundle IDs are not always the app the user sees: Chrome appears as `com.google.Chrome` **and**
  `com.google.Chrome.helper`; Safari/WebKit media runs in `com.apple.WebKit.GPU` (no Safari identity);
  several daemons report an empty bundle ID.

## Architecture

```
Core Audio HAL ──listeners──▶ MeetingSensor (app layer, own serial queue)
                                 │  coalesced scan → [bundle IDs capturing input]
                                 ▼
                         MeetingSenseEngine (TranscriberCore, pure, value-typed)
                                 │  (state, snapshot, phase, mode, now) → (state', [Action])
                                 ▼
                         MeetingPromptPresenter (app layer, @MainActor)
                            ├─ notifications (UNNotificationCategory + actions)
                            ├─ AppState.detectedMeeting → menu-bar icon + MenuView banner
                            └─ RecordingLauncher → RecordingCoordinator.start/stop
```

### 1. `MeetingSensor` — `TranscriberApp/Services/MeetingSensor.swift` (new)

The only component that touches Core Audio. Everything runs on one private serial `DispatchQueue`
(never main — gotcha #68: HAL calls can block indefinitely; a wedged sensor must wedge only itself).

- **Listeners:** one system listener on `kAudioHardwarePropertyProcessObjectList`; one
  `kAudioProcessPropertyIsRunningInput` listener per process object. On a process-list change the
  listener set is **reconciled** (add for new IDs, remove for vanished IDs) by a pure diff function.
- **Listener = wake signal only.** Any callback schedules a single **coalesced scan** 250 ms later
  (further events inside that window fold into the same scan). The scan reads the process list and
  `IsRunningInput` for each, and — for processes capturing — `BundleID`.
- **Output:** a `CaptureSnapshot` (set of raw bundle IDs currently capturing input) delivered to
  the main actor. The sensor does no classification or policy.
- **Timers:** none, except a **one-shot** recheck the engine may request (the 30 s stop debounce).
  Never a repeating timer.
- **Lifecycle:** started after launch gating passes (not in CLI mode, not before permissions/model
  setup completes); stopped when `meeting_sensing = off`; runs during recording (needed for the
  stop prompt).
- **Fallback (only if Task 0 shows per-process listeners don't fire):** listen to
  `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device (+ `kAudioHardwarePropertyDevices`
  to track device churn, the pattern in `MicCaptureSession`) as the wake signal instead. Same scan,
  same engine. Caveat: during a recording Parley itself holds the device, so this signal cannot see
  the call app releasing the mic — the stop prompt would then need the per-process listener on just
  the watched apps. Decide in Task 0; the rest of the design is unchanged either way.

### 2. `MeetingSenseEngine` — `TranscriberCore/MeetingSenseDecider.swift` (rewrite)

Replaces the stateless `MeetingSenseDecider.decide(signal:…)`. Pure, `Sendable` value types, a
caller-supplied clock — fully unit-testable, no Core Audio / AppKit.

**Classification** — `MeetingApps.classify(bundleID:) -> MeetingApp?`, where
`MeetingApp { id: String; displayName: String; kind: .native | .browser }`:
- Exact + family-prefix matching so helpers map to their parent: `com.google.Chrome.helper` →
  Chrome; `com.microsoft.teams2.*` → Teams; `us.zoom.*` → Zoom.
- `com.apple.WebKit.GPU` → `.browser`, displayName "Safari" (it may also be a WebKit-based app; the
  prompt wording tolerates that).
- Parley's own processes (`eu.fmasi.parley*`, including the capture helper and level meters) are
  **always excluded**.
- Unknown bundle IDs → `nil` → never prompt. Precision over recall for unknowns; the list is
  reviewable data.
- Native list: the existing `MeetingApps.bundleIDs` (Zoom, Teams classic/new, Webex ×2, Discord,
  Slack). FaceTime stays excluded (personal calls; #118 decision). Browsers: Chrome, Safari/WebKit,
  Arc (`company.thebrowser.Browser`), Edge (`com.microsoft.edgemac`), Firefox (`org.mozilla.firefox`).
  Exact helper bundle IDs to be confirmed in Task 0.

**State** — `MeetingSenseState`: the set of meeting apps capturing at the last snapshot (with
since-times), the pending start prompt (app), per-app last-prompt time (cooldown), per-episode
dismissal, and — while recording — the watched set (meeting apps seen capturing during this
recording) plus the pending release time.

**Input** — `step(state, snapshot, phase: .idle | .recording | .transcribing, mode, now) -> (state, [MeetingSenseAction])`.
Also `recheck(state, phase, mode, now)` for the one-shot timer.

**Actions** — `.offerStart(MeetingApp)`, `.withdrawStart`, `.offerStop(MeetingApp)`,
`.withdrawStop`, `.scheduleRecheck(after: TimeInterval)`.

**Rules:**
- `mode == .off` → no actions, and any pending offer is withdrawn.
- **Start:** phase is not `.recording`, a meeting app *transitions* to capturing (absent in the
  previous snapshot), it is outside its 5-min cooldown (`defaultCooldown`, kept), and the user did
  not dismiss this episode → `.offerStart(app)`. An *episode* is one continuous capture span by that
  app; dismissing suppresses it until the app releases and later re-acquires the mic.
- **Withdraw:** the offered app stops capturing before the user answers → `.withdrawStart`.
- **Stop:** phase is `.recording`; the watched set is non-empty; every watched app has stopped
  capturing → record the release time and `.scheduleRecheck(after: 30)`. On recheck, if still
  released for ≥ 30 s continuously → `.offerStop(app)` once. Any watched app re-acquiring cancels
  the pending release (mute/unmute and device switches must not fire it). "Keep Recording" suppresses
  further stop offers until a watched app re-acquires and releases again.
- A recording started manually with no meeting app ever seen capturing has an empty watched set →
  no stop offers.
- Recording ends (phase leaves `.recording`) → watched set cleared, any stop offer withdrawn.

### 3. `MeetingPromptPresenter` — `TranscriberApp/Services/MeetingPromptPresenter.swift` (new)

`@MainActor`. Turns actions into UI; routes the user's answers back.

- **Start offer:**
  - Notification (category `MEETING_START`, `interruptionLevel: .timeSensitive`), title
    "Zoom is using the microphone", body "Record this meeting?" (+ the calendar title when one is
    found). Action **Record** → `RecordingLauncher.quickStart(app:)`. Clicking the body (default
    action) → `RecordingLauncher.promptAndStart()` (the existing naming panel). Dismissing → marks
    the episode dismissed.
  - `AppState.detectedMeeting = DetectedMeeting(app:)` → `menuBarIcon` shows a distinct
    "meeting detected" symbol while idle, and `MenuView` shows a banner "Zoom call in progress" with
    a **Record** button. Persistent until recording starts, the user dismisses it, or the call ends.
- **Stop offer:** notification (category `MEETING_END`), title "Zoom released the microphone",
  body "Stop recording “<session>”?", actions **Stop Recording** → `coordinator.stopRecording()`
  and **Keep Recording**. Plus a banner in the recording view with a **Stop** button.
- **Withdraw:** remove the delivered notification (`removeDeliveredNotifications(withIdentifiers:)`)
  and clear the banner/indicator.
- `NotificationDelegate` gains `userNotificationCenter(_:didReceive:)` routing the action IDs to the
  presenter on the main actor; categories are registered at launch.

### 4. `RecordingLauncher` — `TranscriberApp/Services/RecordingLauncher.swift` (new)

Today `RecordingCoordinator` is `@State` inside `MenuView`, and `promptAndStartRecording` +
`selectedMicId` are private to it — nothing outside the menu can start a recording. Hoist them:

- `TranscriberApp` creates the `RecordingCoordinator` (all its dependencies already live there)
  and a `RecordingLauncher` owning `selectedMicId` (seeded from `config.lastMicrophoneDeviceId`),
  `promptAndStart()` (the current naming-panel flow, moved verbatim) and `quickStart(app:)`.
- `quickStart` name = calendar title if found, else "<App> call"; mic = last-used. It starts
  immediately — every extra click is a place the forgetful user drops off. The rename dialog after
  transcription is unchanged.
- `MenuView` receives the coordinator + launcher instead of constructing them. Behaviour of the
  manual Record button is unchanged.
- **Phase gate:** if the phase is `.transcribing` when Record is chosen, the launcher queues the
  start and fires it the moment the phase becomes `.idle`; the banner says "Will start when the
  previous recording finishes processing". (Known limitation below.)

### 5. Calendar lookup off the main thread (the relevant part of #197)

`CalendarService.currentEventTitle` runs a synchronous `EKEventStore.events(matching:)` over a
12-hour window on main; the Record path now goes through it. Make it `async`, run the EventKit query
off main, cap it at ~1 s (fall back to no title). `CalendarEventPicker` is untouched.

### 6. Config + Settings

- `Config.meetingSensing: MeetingSenseMode` (`off` | `prompt`), CodingKey `meeting_sensing`,
  `decodeIfPresent` → default `.prompt` (back-compat with existing config files).
- Settings → General: Toggle "Offer to record when a meeting starts" (bound to `.prompt`/`.off`),
  caption naming the detected apps in plain words. Changing it starts/stops the sensor immediately.
- `docs/parameters.md` gets the key.

## Performance budget (target: MacBook Air M1, 16 GB)

| Situation | Budget |
|---|---|
| Idle, no audio activity | **0 timers, 0 periodic wakeups from the sensor**, ~0 CPU |
| Per audio event (any app starts/stops IO) | ≤ 1 coalesced scan, ≤ 20 ms on M1 Air (≈5 ms measured on M5 Pro), on the sensor queue |
| Launch | one-time HAL client init (~50 ms measured) on the sensor queue, never main |
| Memory | ~40 listener registrations + small state — negligible |
| Main thread | only receives a finished snapshot; no HAL or EventKit calls on main |

Measured in the device test: Activity Monitor "Idle Wake Ups" for Parley with sensing on vs off
(must be indistinguishable), and `os_signpost` intervals around each scan. If only the M5 Pro is
available, record the numbers and flag that the M1 Air figure is extrapolated.

## Failure modes

| Failure | Behaviour |
|---|---|
| A HAL call blocks forever (gotcha #68) | Only the sensor queue wedges: prompts stop, recording and UI unaffected. Log once. |
| Per-process listeners don't fire | Detected in Task 0 → device-level fallback (§1). |
| Notifications disabled / Focus | Menu-bar indicator + banner still surface the offer; the #150 row already warns. |
| Unknown helper bundle ID | Classified `nil` → no prompt (precision over recall); add it to the list. |
| Browser dictation / voice search | One prompt, then the 5-min cooldown; dismiss suppresses the episode. |
| User mutes / switches device mid-call | Re-acquire within 30 s cancels the pending stop offer. |
| Parley's own meter or helper opens the mic | Excluded by bundle prefix — can never self-trigger. |

## Testing

- **Pure engine, test-first:** start on transition only; no start while recording; cooldown;
  per-episode dismissal; withdraw on early release; stop debounce (30 s, re-acquire cancels,
  exactly-once); Keep Recording suppression; empty watched set → no stop; mode off withdraws;
  `.transcribing` still offers start. Clock is injected.
- **Classification table:** helpers → parent, WebKit.GPU → Safari/browser, Parley excluded,
  unknown → nil, empty bundle ID → nil.
- **Listener reconcile diff:** pure add/remove sets.
- **Config:** round-trip + missing key → `.prompt`.
- **Hoist:** existing `RecordingCoordinatorTests` unchanged and green.
- **Device test** (added to `scripts/test-checklist.md`): Zoom, Teams, Meet in Chrome, Meet in Safari
  → prompt within ~1 s; browser dictation → at most one prompt; FaceTime → none; leave the call →
  stop offer after 30 s; mute 60 s → none; notifications off → banner + icon still appear; Record
  from notification starts with calendar title; idle-wakeups measurement.

## Task 0 (first plan task): on-device listener spike

Before building on the listener mechanism, a throwaway harness on the real machine: register the
listeners, then start/stop a Zoom call, a Meet call in Chrome and in Safari, and browser dictation.
Record (a) whether `IsRunningInput` listeners fire on start and stop, (b) latency, (c) the exact
bundle IDs that report `IsRunningInput = 1` for each. Outcome picks per-process listeners vs the
device-level fallback and fixes the classification table. Throwaway — not merged.

## Known limitations / follow-ups (file as issues)

- **Back-to-back meetings:** `AppState` has one phase, so a new recording cannot start while the
  previous one is transcribing; a queued start loses the head of the next meeting. Follow-up:
  decouple capture start from post-processing.
- The unknown-app list will need tending as Task 0 and users report helper bundle IDs.
- Offering to record calls in apps not on the list (WhatsApp desktop, FaceTime) — revisit with data.

## Open questions for the reviewer

1. Is the engine's state/rule set minimal? Anything that can go without losing a goal?
2. Is 30 s the right stop debounce? Is 250 ms coalescing sufficient for listener storms?
3. Is starting immediately from the notification (no naming panel) the right default?
