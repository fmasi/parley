# Test Checklist

Build/install this tree first: `python3 scripts/dev.py`
(Resets TCC — re-grant Screen Recording + Microphone on first launch.)

## Meeting sensing (#118 — this branch)

**Nothing in this feature has ever run on hardware.** The on-device spike that was meant to confirm
which Core Audio signals actually fire was never performed, so **section A below _is_ that spike** — it
is the evidence everything else rests on, not a formality. Nine of the thirteen rows in
`MeetingApps.families` carry `TODO(Task 0): verify on device`; the other four (Webex ×2, Discord,
Slack) are inherited from the old shipped set, not confirmed — **treat all thirteen as unverified**.
So "no island appeared" is an expected outcome here rather than a surprise, and the first job is to
find out which of the two possible causes it is (wrong bundle ID, or no wake signal).

**If section A fails wholesale, skip to G and H.** Those two need no call partner, no second machine
and no working bundle IDs — they are the regression checks on code that already worked — so a tester
blocked on the classification table still has something to run while the table is fixed.

**Setup:** notifications OFF in System Settings (the island must not depend on them); Zoom, Teams,
Chrome and Safari signed in and able to join a real call; a calendar event covering "now"; Calendar
access granted; `meeting_sensing` absent from `config.json` (so the default is exercised).

Tail the log throughout:
`/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug`

Bundle IDs and capturing-app lists are logged `privacy: .private` on purpose (airgap), so they render
as `<private>` and the *counts* are public. That is correct behaviour — do not "fix" the privacy level
to make this checklist easier, and do not bother with a private-data logging profile. Read the raw IDs
with the throwaway harness in section A instead: it reads the same Core Audio properties the sensor
does, from outside the app.

### A. Does it fire at all, and for whom (the unrun spike)

**First, build the harness.** This is how the "Bundle IDs reported capturing" column gets filled in —
the app itself will not tell you (see the privacy note above). It reads
`kAudioHardwarePropertyProcessObjectList` + `IsRunningInput` + `BundleID`, exactly what `MeetingSensor`
reads, and prints them once a second. **It needs no TCC prompt and no configuration profile** —
verified during design: 38 process objects enumerated, bundle IDs readable, no permission dialog.
Throwaway: build it, run it, delete it.

```bash
mkdir -p /tmp/parley-sense-spike && cd /tmp/parley-sense-spike   # paste main.swift below
swiftc -O main.swift -o spike -framework CoreAudio && ./spike    # Ctrl-C to stop
```

```swift
// THROWAWAY: which processes are capturing mic input, and under what bundle IDs.
import CoreAudio
import Foundation

func ids() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &list) == noErr else { return [] }
    return list
}
func u32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v) == noErr ? v : 0
}
func bundleID(_ o: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &cf) == noErr else { return "?" }
    return (cf?.takeRetainedValue() as String?) ?? "?"
}
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so `./spike | tee run.txt` shows output live
while true {                      // Ctrl-C to stop; join/leave calls while it runs
    let capturing = ids().filter { u32($0, kAudioProcessPropertyIsRunningInput) == 1 }.map(bundleID).sorted()
    print("\(Date().formatted(date: .omitted, time: .standard))  capturing: \(capturing)")
    Thread.sleep(forTimeInterval: 1)
}
```

Verified as inlined here: builds clean with the command above, enumerates the process list and reads
bundle IDs with no permission dialog. (The `setvbuf` line matters — without it stdout is block-buffered
when redirected, so piping to a file and then Ctrl-C'ing shows an empty file and looks like a failure.)

A few process objects report no bundle ID and print as `?` — measured here: 30 of 34 readable, 4 not.
That is normal, not a fault: the sensor sees the same thing as `""` and deliberately never targets it
(`ListenerReconcile.watchTargets`). Only a `?` where you expected your call app is a finding.

**Record the raw string it prints, not the app you think it is.** Chrome appears as
`com.google.Chrome.helper`, and Safari's mic use surfaces as `com.apple.WebKit.GPU` with no Safari
identity of its own. Run it alongside Parley: the harness gives you the IDs, the app's log
(`Meeting sensor scan: N processes, M capturing […]`) gives you the timing and the count.

Then fill this table in before judging anything below it.

| Scenario | Which wake fired (device `IsRunningSomewhere` / `ProcessObjectList` / per-process) | Call start → island (s) | Bundle IDs reported capturing | Wake on leaving? | Mic still held 60 s after leaving? | Mute/unmute wakes? |
|---|---|---|---|---|---|---|
| Zoom native call | | | | | | |
| Teams native call | | | | | | |
| Meet in Chrome | | | | | | |
| Meet in Safari | | | | | | |
| Chrome dictation / voice search | | | | | n/a | n/a |
| FaceTime (must **not** prompt — record its IDs) | | | | | | |
| Zoom already holding the mic, then Chrome joins | | | | | | |

- [ ] **Reconcile the bundle IDs against the table.** Every ID observed above must be matched by a row
      in `TranscriberCore/MeetingApps.families` (exact, or a `prefix + "."` helper). Correct or add rows
      for anything that differs, and delete a `TODO(Task 0)` marker **only** from a row actually
      observed. Note that Webex, Discord and Slack carry no marker yet are equally unverified — they
      were inherited from the old shipped set, not confirmed.
- [ ] **Helper processes.** Browsers and Zoom/Teams route mic capture through helper processes; confirm
      whether the capturing ID is the app's own or a helper (e.g. `com.google.Chrome.helper`,
      `com.apple.WebKit.GPU`), and that the helper resolves to the right family so one call never shows
      as two apps.
- [ ] **Per-process listeners fire on RELEASE.** While recording, leave the call and watch for a wake.
      **If no wake arrives, the stop offer can never come** — and the agreed fallback (a 10 s one-shot
      re-read, re-armed after each scan, only while `running && !watchedBundleIDs.isEmpty`, never while
      idle, never a repeating timer) is **NOT implemented**: it exists only as a TODO at
      `TranscriberApp/Services/MeetingSensor.swift:191`. This must be decided before merge.
- [ ] **Listener churn does not leak.** Across a long recording with app churn (quit and relaunch
      Chrome/Zoom repeatedly), Parley's RSS and its process-listener count return to roughly where they
      started, and the log shows no storm of
      `Meeting sensor: remove listener on process … → <non-zero status>`.
- [ ] **Watch armed while the app's helpers were idle.** Start recording from an offer at a moment when
      the app's helper processes are *not* capturing, then end the call: the stop offer must still
      arrive after ~30 s. (This is the case that used to swallow the stop prompt; `setWatched` now runs
      a full scan when the watch set becomes non-empty. A stop offer that never comes falsifies it.)

### B. The start offer

- [ ] **Zoom native call → island within ~1 s**, expanded, top-centre. Title **"Record this meeting?"**,
      subtitle **"Zoom is using the microphone"**. On the very first offer this machine has ever shown,
      the subtitle is the disclosure instead: *"Parley noticed Zoom using the mic — it only checks which
      app, on this Mac, and never listens."* Menu-bar icon changes to `mic.badge.plus`; opening the menu
      shows the banner **"Zoom call in progress"** with a Record button.
- [ ] **Teams native, Meet in Chrome, Meet in Safari** → same, each naming the right app.
- [ ] **The disclosure appears exactly once, ever.** Second offer (even after a relaunch) shows the
      ordinary subtitle. Deleting the `meeting_sensing_disclosure_shown` user default brings it back.
- [ ] **Record from the island** → recording starts immediately with **no naming panel**. The session is
      named from the calendar event when one covers now, else **"Zoom call"**. Island disappears, icon
      goes to recording, banner clears.
- [ ] **Calendar name on the FIRST offer of a session** (the cold-EventKit case the 10 s warm-up exists
      for): with an event covering now, the island's subtitle becomes "<Event title> · Zoom" within a
      few seconds and the recording is named after the event — not "Zoom call". This is the whole point
      of warming the calendar at offer time; if the first recording of every session is still "Zoom
      call", the warm-up is not working.
- [ ] **A title found for one meeting never names the next.** End that call, start a different one with
      no calendar event covering it: the offer must not inherit the previous title.
- [ ] **"Name it first…"** (chevron menu) → the naming panel opens, prefilled; recording starts on Start.
- [ ] **"Not now"** → island goes; no re-prompt for this call. Leave and rejoin → prompts again, and
      within 5 minutes of the last expanded offer it appears **compact** rather than expanded.
- [ ] **"Turn off meeting detection…"** → opens Settings (and activates Parley, which is correct for
      this one item only).
- [ ] **Island untouched 20 s → collapses to the compact pill** (red dot, *not* pulsing, + app name);
      click the pill → expands again, and the 20 s countdown restarts.
- [ ] **Hovering holds it open.** Leave the pointer on the pill past 20 s: it stays expanded and
      collapses ~20 s after the pointer leaves. (Depends on `onHover` tracking while Parley is inactive
      — if hover does nothing, the island collapses under the cursor.)
- [ ] **A start offer replaced by a stop offer restarts the countdown** — the new offer must not inherit
      the old one's remaining seconds and vanish a second after appearing.
- [ ] **Browser dictation / Chrome voice search** → at most one prompt, and "Not now" suppresses it.
      (There is deliberately no browser-vs-native distinction in the engine: a browser raises the same
      offer as Zoom. If dictation prompting proves annoying, that is a finding, not a bug.)
- [ ] **The offer moves to the other app rather than vanishing.** With Zoom and Chrome both on the mic
      and a Zoom offer showing, end the Zoom call while Chrome keeps holding the mic: the offer must
      switch to Chrome (title/subtitle/compact label all naming Chrome), not disappear. Nothing else in
      this checklist exercises the takeover branch (`MeetingSenseEngine.swift:184-191`).
- [ ] **FaceTime call → no prompt at all**, and no menu-bar badge.
- [ ] **Parley's own mic use never prompts** — start a recording manually, open the mic picker: no
      offer, ever.

### C. The stop offer

- [ ] **Leave the call while recording → stop island after ~30 s.** Title **"Stop recording?"**,
      subtitle **"Zoom released the microphone · <session name>"**. Stop → the recording ends and
      transcribes normally.
- [ ] **"Keep recording"** → island goes and does not return until the app re-acquires *and* releases
      the mic again.
- [ ] **"Keep recording" does not poison the next meeting.** After keeping, stop the recording manually,
      then start a new call in the same app: a start offer must appear.
- [ ] **Mute for 60 s mid-call → no stop offer.** **Switch mic mid-call → no stop offer.** Both keep the
      app on the mic; a stop offer here would be a false positive.
- [ ] **Re-joining inside the 30 s window cancels the stop offer** rather than firing it late.
- [ ] **A stale stop offer is inert.** Let the stop offer appear, stop the recording from the menu
      instead, then click Stop on the island: nothing happens, and the log says
      `Stop offer answered while not recording — ignoring`.
- [ ] **Record chosen while transcribing** → banner **"Will start when the previous recording finishes
      processing"** (grey/secondary, no button, clock icon — *not* red). When the phase goes idle it
      starts **only if the call is still on**; end the call before then → nothing starts, banner clears
      and the log says `Queued start dropped`.
- [ ] Note while checking the above: during transcription the menu-bar icon is the hourglass, not the
      meeting icon. That is intended — the queued start's only menu-bar surface is the banner.

### D. The island as a window (focus, privacy, placement, accessibility)

These are the highest-risk items: the island is a floating panel over other apps' calls.

- [ ] **Full-screen Zoom** → island draws over it, and **Zoom keeps focus**: typing in Zoom's chat must
      keep working while the island is up.
- [ ] **The chevron menu must not steal focus** (the single highest-risk path). Open the chevron menu
      while Zoom is full-screen and focused: `NSMenu` tracking runs a modal event loop and commonly
      activates its owning app. If Parley comes forward, or Zoom loses focus, **that breaks the feature's
      core promise** — the ruled fallback is an in-panel popover instead of a `Menu`. Also confirm
      clicking **Record** itself does not activate Parley.
- [ ] **Screen share in Zoom → the other side must NOT see the island** (`sharingType = .none`,
      `MeetingIslandController.swift:104`, unverified on macOS 15+). Have the far side confirm, or record
      the share and look. If it *is* visible, file it — the named fallback is compact-only during shares.
- [ ] **Click-through in the transparent margin.** The panel is 488×88 with the visible pill inset
      (24 pt sides/bottom, 8 pt top). Clicking the invisible margin must hit the app underneath, not
      swallow the click.
- [ ] **Second monitor.** With the menu bar on the external display and Parley inactive, the island must
      appear on the display you are calling on. `NSScreen.main` is documented as "the screen with the key
      window" and Parley owns none — if it lands on the built-in display, the fix is to pick the screen
      containing `NSEvent.mouseLocation` in `reposition()`.
- [ ] **Notched vs non-notched.** On a notched MacBook display and on an external one: the pill sits just
      below the menu bar, horizontally centred, not overlapping menu-bar items, and its shadow is not
      clipped at the panel edge.
- [ ] **Pill placement inside the panel.** Expanded and compact share a top edge — the island shrinks in
      place rather than drifting downwards. (This lost its unit test deliberately; it is only checkable
      by eye.)
- [ ] **Reduce Motion on** → no fade in/out and no spring; the island simply appears and changes.
- [ ] **VoiceOver on** → the offer is announced when it appears; swapping a start offer for a stop offer
      announces again; a subtitle changing to the calendar title does **not** re-announce. The compact
      pill reads as a button.
- [ ] **The island survives a Space switch.** With it up, switch to another Space: it is still visible,
      still top-centre and still above the apps there; switch back and it is unchanged and still above
      the call app. Parley must not have activated (the call app keeps focus throughout, and Parley's
      menu-bar panel stays closed). Falsified by: the island left behind on the first Space, sliding out
      of position, or dropping behind another window.
- [ ] **No stray Return starts a recording.** With the island up, press Return with focus in another app
      and in Parley's own windows: nothing starts.

### E. Turning it off (this path has never executed — nothing wrote `meeting_sensing` before Task 10)

Idle:
- [ ] **Default on, first launch** — with no `meeting_sensing` key in config.json, launch. Expect
      `Meeting sensing mode: prompt` then `Meeting sensor started — N input device listener(s)` (N ≥ 1).
- [ ] **The off switch is above the fold.** Settings → General: the "Meeting Detection" section, its
      toggle and its full caption are visible **without scrolling**. The 480 pt tab height was ESTIMATED
      by counting rows, never measured — if it scrolls or clips, raise it.
- [ ] **The caption renders as one clean sentence.** The app list is built at runtime by a formatter
      from `MeetingApps.supportedDisplayNames` — check for stray commas, a missing "and", or truncation
      at the section width.
- [ ] **The caption is true.** It claims: checks which app only, on this Mac, never listens; offers to
      stop when the call ends; looks up the meeting's name with Calendar access. Confirm each against
      what you have just observed, especially that the named apps actually trigger (section A).
- [ ] **Toggle off + Save** → log shows `Meeting sensing mode: off` then `Meeting sensor stopped`, and
      `"meeting_sensing":"off"` appears in config.json.
- [ ] **It really stopped** — start a call: no island, no menu-bar badge, no in-menu banner, and **no
      further `Meeting sensor scan:` lines at all**. Leave the call up a minute: zero periodic wakeups.
- [ ] **Off withdraws a live offer** — turn it back on, Save, start a call so the island is showing, then
      toggle off + Save while it is on screen: island disappears at once, icon reverts, banner clears.
- [ ] **Back on re-arms** — toggle on + Save → `Meeting sensing mode: prompt` +
      `Meeting sensor started`; a call offers again.
- [ ] **Off survives relaunch** — quit and relaunch with it off: `Meeting sensing mode: off` and **no**
      `Meeting sensor started` line.

Mid-recording (the path with per-process listeners armed — what the teardown exists for):
- [ ] **Off during a recording started from an offer** → `Meeting sensing mode: off` +
      `Meeting sensor stopped`, and the **recording continues undisturbed**: timer counting, chunk
      rotation still logging, mic level unaffected.
- [ ] **No stop offer after the mode went off** — with that recording still running, end the call and
      wait past 30 s: no stop offer, ever. Stop manually; transcript is normal.
- [ ] **Off withdraws a live stop offer** — with sensing on: record, end the call, let the stop offer
      appear, then toggle off + Save. The island withdraws immediately and **the recording keeps
      running** (turning the feature off must never stop a recording).
- [ ] **Back on mid-recording** → `Meeting sensor started`; ending the call should still produce a stop
      offer after the debounce. The path is the engine's, not the sensor's: turning the mode off fed an
      empty snapshot which cleared `s.capturing`, so when sensing comes back the call app reads as newly
      `started`, rejoins `s.watched` and a fresh `.watch` is emitted
      (`MeetingSenseEngine.swift:145-160`). Do **not** expect the sensor to have kept the old watch —
      the off path deliberately calls `setWatched([])` before `stop()` so a restart cannot re-arm from
      stale bundle IDs (`MeetingPromptPresenter.swift:154-159`).
- [ ] **No listener leak across off/on cycles** — after several cycles the
      `Meeting sensor started — N input device listener(s)` count returns to the same N, with no
      `listener add failed` errors.

### F. Cost

- [ ] **Idle wake-ups.** Activity Monitor → Parley → "Idle Wake Ups" over 10 minutes, sensing on vs off:
      indistinguishable. No `Meeting sensor scan:` lines while nothing starts or stops audio.
- [ ] **Scan cost WITH A WATCH ARMED** — this is the measurement that matters and the one the ~5 ms
      budget does *not* cover. With no watch, the scan short-circuits on `IsRunningInput`; **with a watch
      armed it reads a bundle ID from every process on the machine, and that is the path that runs for
      the entire duration of a recording.** Record the `scan` signpost interval
      (`subsystem == "eu.fmasi.parley"`, `category == "meeting-sensor"`) in both states, plus the
      first-scan cost (~50 ms one-time HAL client init is expected).
- [ ] **Measure on an M1 Air** if one is available. If not, record the M5 Pro figures and mark the M1
      number explicitly as *extrapolated (×3)*, not measured.
- [ ] **The app never freezes.** If a HAL call wedges there is deliberately no watchdog (gotcha #68
      containment): the menu bar, recording and the mic switcher must all stay responsive, and sensing
      simply goes quiet.

### G. The Task 6 hoist — regressions in code that already worked

**Runnable on its own** — no call, no call partner, no working bundle IDs. If section A fails, run this
section and H while the classification table is being fixed.

Recording ownership moved out of `MenuView` into `RecordingCoordinator` + `RecordingLauncher` on this
branch. None of this is new behaviour; all of it could have broken.

- [ ] **Manual Record from the menu** → naming panel (calendar title prefilled) → records → Stop →
      transcribes → **rename dialog appears** → **auto-summary runs**. The rename/summary closures moved
      with the coordinator, so this whole chain is the check.
- [ ] **Mic label follows a mid-recording switch** — the menu's Microphone row shows the new device after
      switching, and after an idle-time switch.
- [ ] **The mic pick persists across panel opens** — pick a non-default mic, close and reopen the menu
      panel: the label still shows it. (This is the behaviour the hoist exists to fix.)
- [ ] **Settings → Audio → change mic → Save → open the menu:** the mic row shows the newly saved device
      **without relaunching**. Known residual: if you pick a mic in the menu's switcher and *then* save a
      different one in Settings, the in-session pick keeps winning until relaunch — accepted.
- [ ] **CLI builds no UI** — `Parley transcribe -i …` from the terminal still runs with no windows, no
      menu bar item, no crash.
- [ ] **XPC-crash recovery still re-attaches** — kill the helper mid-recording (`pkill -9
      audio-capture-helper-xpc`): the recording recovers as before. The coordinator's lifetime changed,
      so a lifetime regression would hide here.
- [ ] **Start Recording then immediately Cancel** → no recording starts (the pre-existing cancel-wins
      guard, now behind a different owner).
- [ ] **Record from the island while Settings › Audio (mic picker + meter) is open on the same mic** →
      the recording starts and the app does not freeze (gotcha #68 corollary 2). If it hangs, `quickStart`
      must call `InputLevelMonitor.stopAndRelease` on open meters first, exactly as the naming panel does.

### H. Launch and recovery sequencing

- [ ] **Relaunch mid-recording, mid-call** (force-quit, relaunch, Flow A re-attach) → **no start offer**
      (the call is already being recorded); leaving the call still produces the stop offer after 30 s.
- [ ] **Force-quit mid-recording so Flow B recovery runs on relaunch** → while that recovery is still
      transcribing, the menu-bar panel shows the **normal menu**, not "Setup required", and the start
      offer only arrives once recovery completes.
- [ ] **First launch with the Setup window open** → sensing does not begin until Continue is pressed; the
      Setup hero shows the meeting-sensing disclosure line.

---

## Carried from recent releases — device tests still owed

These shipped to `main` but their device passes were never completed, so they are still live checks
rather than history. Prune each one once it has actually been run.

### Mic switcher mid-recording (#192) — added 2026-09-10

- [ ] Start a recording, then open **Change Microphone**. The dialog must appear and stay responsive
      — previously the whole app froze here permanently and had to be force-quit.
- [ ] The exact 2026-09-10 condition: lid closed, recording on the built-in mic, open the switcher,
      pick another mic (e.g. the iPhone) and switch. UI stays responsive throughout, and the level
      meter shows the NEW mic's level.
- [ ] In the picker, flip quickly between two mics a few times — the meter follows the selection
      and never sticks on a previous one.
- [ ] Cancel the switcher while the meter is running: the dialog closes immediately.
- [ ] Regression: the session-name dialog's level meter (before recording) still moves with your voice.
- [ ] After switching mid-recording, stop: the new mic's audio is in the transcript.
- [ ] Open **Settings → Audio** while recording: the mic list and meter appear, and the recording
      keeps going (Settings uses the same picker — it could freeze the same way).
- [ ] Plug in (or connect) a mic, then open the menu: the Microphone row and the switcher list show
      it within a moment of opening.
- [ ] The switcher and the New Recording dialog open within about a second, every time — never a
      beach ball.
- [ ] Mid-recording, the switcher's meter next to the CURRENT mic reads **In use** (it no longer opens
      the mic being recorded); pick another mic and its meter moves.
- [ ] Cancel wins: press **Start Recording** and immediately **Cancel** (or close the panel) —
      no recording starts. Same in the switcher: **Switch** then immediately **Cancel** — the mic
      does not change. (This guard lives in the app target, which has no unit tests.)
- [ ] Switch to a second mic, then open the switcher again: the mic you switched TO now reads
      **In use**, and the one you left shows a live meter.
- [ ] With the lid closed, pick the built-in mic in the switcher: within ~2 s it reads **Not
      responding** (or stays flat), and you can still pick another mic and switch.
      Known gap: SWITCHING TO the not-responding mic itself can leave the dialog on "Switching…" for
      a long time (the app stays responsive) — the helper waits on the same stuck device and the
      call has no deadline yet (#194). Don't switch to a mic that says Not responding.

### Speaker count + minority absorption (#65 / #67) — added 2026-09-03

**Absorption (#65) — should need no interaction at all**
- [ ] Record a 1:1 call where only the other side talks for a stretch. Transcript must show ONE
      remote speaker, not one real speaker plus a fragment. Check the log for
      `DiarizationCleanup: absorbed N minority cluster(s)`.
- [ ] Record a genuine 3-way call. All three must survive — absorption must NOT fire.
      (Guard: absorption only runs when one cluster holds ≥50% of the stream.)

**Speaker count control (#67) — rename dialog**
- [ ] Put a phone call on speakerphone and record it. Expect the local channel to come out as ONE
      speaker (this is the 2026-09-02 failure).
- [ ] Open the rename dialog. A "Wrong number of speakers?" section must appear with a stepper per
      channel, pre-filled with the detected count.
- [ ] Set "This side" to 2, press Re-detect. Spinner shows, then the speaker rows rebuild with two
      local speakers.
- [ ] Play a sample for each new speaker — audio must play and match the label.
- [ ] Name them, Save, reopen the transcript: names stick and segments are attributed to both.
- [ ] Re-detect a channel you had already named. Names for labels that no longer exist must be
      dropped, not re-applied to a different person.
- [ ] Re-detect on a multi-chunk (>30 min) recording: channel audio is concatenated across chunks
      and diarized once, so speaker numbering must stay consistent across the whole recording.
- [ ] Re-detect on a recording whose archive is gone (storage quota evicted it): must show a clear
      "No <channel> audio is available" error, not a spinner that never ends.

### Mic-only recordings (#183) — added 2026-09-03

- [ ] Answer a phone call, put it on speaker, record it. On stop, expect a `.m4a` to appear —
      previously the recording stayed as two WAVs forever.
- [ ] Check the log for `system track is empty — archiving '<name>' as mic-only`.
- [ ] Play the `.m4a`: your voice must be on the LEFT channel, right channel silent. If the voice
      is on the right, the mic has been archived into the remote slot — stop and file it.
- [ ] Open the rename dialog for that recording: the play button must be present and must play.
- [ ] Regression: a normal dual-stream call still archives with L=mic / R=system as before.
- [ ] Regression: a genuine rate mismatch (system 24 kHz vs mic 48 kHz — the 2026-08-04 chipmunk
      shape) must STILL refuse to archive and keep both WAVs.

---

## Standing gates (always — do not trim; these are not per-feature tests)

- [ ] Start recording → stop → transcription completes
- [ ] Multi-chunk recording merges to a single `.m4a`, plays back with no gaps
- [ ] Dual-stream `.m4a` is stereo (L=mic, R=system); source WAVs deleted after archival
- [ ] Rename dialog works; play button plays correct channel per speaker
- [ ] Summary auto-generates (`-summary.md`) when an LLM endpoint is configured
- [ ] App survives quit + relaunch (LaunchAgent) — `LaunchAgentManager.uninstall()` is reachable from both MenuView and SetupRequiredPanel, so exercise Quit from each
- [ ] **Privacy:** during a recording, `log stream --predicate 'subsystem == "eu.fmasi.parley"'` shows names/paths as `<private>`
- [ ] **#86 (SCK default path):** mid-recording output switch (speakers → AirPods) while System Audio Capture is set to Screen Recording → stream restarts in place, remote audio resumes, no "unrecovered" warning in the menu bar panel.
- [ ] **#103 (Core Audio Tap path):** with Settings › Audio › Capture Method set to Core Audio Tap, record a Zoom/Teams/Meet call → remote audio lands on the system channel; stop → no orphaned aggregate device in Audio MIDI Setup. (The tap is user-selectable in Settings, so it is a standing gate, not a one-off acceptance test. Full #103 / #71 acceptance matrices live in those PRs.)

### Rate integrity (#58 — the chipmunk class)
These are the only guard on behaviour no unit test can reach: the HAL's real response to a device
changing under a live capture. A transcript that reads plausibly is NOT evidence — chipmunked audio
transcribes into fluent, wrong text. Verify by ear and by log.
- [ ] **Bluetooth connects mid-recording (the 2026-08-04 case):** start a Core Audio Tap recording on built-in speakers, then connect AirPods mid-call and keep talking (opening the mic on them is what forces A2DP→HFP). Expect: log shows `clocking capture off … reason: bluetoothVolatileRate`; remote audio at correct pitch for the WHOLE recording; if `rateDrift` appears in `.diag.jsonl` it must be paired with a remediation `restartInPlace` and correct audio afterwards.
- [ ] **Bluetooth already connected at start:** with AirPods as the default output, start a tap recording. Same expectations, plus the "System tap rates" log line must show `aggregate(delivered): 48000Hz` — not 24000.
- [ ] **Multi-Output Device:** create one in Audio MIDI Setup (built-in + AirPods), make it the default output, record. Expect a re-anchor with `reason: virtualVolatileClock`; remote pitch correct.
- [ ] **Clock anchor unplugged:** with a USB audio interface as the anchor (Bluetooth default output, no usable built-in), unplug it mid-recording. Expect `reason: clock anchor device removed` and a rebuild — NOT a system track that silently stops growing.
- [ ] **A2DP→HFP on the SCK path:** repeat the first item with Capture Method = Screen Recording. Stream restarts in place; remote pitch correct throughout.
- [ ] **Mid-recording mic switch (functional, not just UI):** switch mics during a recording; both pre- and post-switch mic audio are present, aligned, and at correct pitch.
- [ ] **Stereo mic (#59):** record with a stereo USB interface or webcam mic. Mic audio must be continuous — not choppy/stuttering, which is the signature of the half-buffer truncation.
- [ ] **Pad-ratio backstop fires:** if any recording ends with an `excessivePadding` anomaly in `.diag.jsonl`, the completion notification must read "Transcription Complete — capture anomalies" rather than the plain title.
- [ ] **Pitch spot-check (every audio device test):** play ~30s of the system channel by ear before signing off. Reading the transcript is not a check.
