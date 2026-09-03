# Test Checklist

Build/install this tree first: `python3 scripts/dev.py`
(Resets TCC — re-grant Screen Recording + Microphone on first launch.)

## Crash-recovery rehydration (#135 — this branch)
Crashing a long recording used to silently discard the whole session. Recovery now reads
`session.json`, re-ingests the un-archived orphan chunk(s), and finalizes. Use a short chunk
duration (Settings → set chunk minutes low, e.g. 1) so a few-minute recording rotates several chunks.
- [ ] **Single-fault relaunch recovery (the core fix).** Record past ≥2 chunk rotations, then **force-quit Parley** (⌥⌘Esc → Force Quit) so the audio helper dies too. Relaunch. Expect: a **complete transcript** covering *all* chunks including the in-progress one — NOT "No usable audio files", not just the last few minutes. Rename dialog + auto-summary prompt appear (Deliverable C). `session.json` is gone afterward.
- [ ] **Timestamps monotonic (H2).** In the recovered transcript, timestamps increase across chunk boundaries — no two chunks' minute-2 lines interleaved; SRT (if enabled) is monotonic.
- [ ] **Speakers not split/merged wrongly (H3).** With ≥2 speakers across different chunks, the same person keeps one label across chunks and two different people aren't collapsed into one.
- [ ] **Double-fault (app crash → reattach → helper crash).** Record ≥2 chunks; force-quit the app but immediately relaunch WHILE the helper is still capturing (Flow A re-attach — you'll see "Recording…" resume); then kill the helper (`pkill -9 audio-capture-helper-xpc`) to force a restart; keep talking; Stop. Expect: the transcript includes the post-restart audio too (no silently dropped segment). *Note (reviewer edge): the fix keys off the system WAV; a mic-only orphan is a contrived case not covered.*
- [ ] **Normal (no-crash) recording still fine.** A clean record→stop produces the same transcript quality as before (regression check on the relocated pipeline).

---

## Summary-failure visibility (#134 — shipped, kept for reference)
A failed auto-summary used to fail silently, and a misconfigured endpoint reported
the misleading "Summary response contained no content". Both are fixed here.
- [ ] **Broken config surfaces the real error.** In Settings → Summary, enable summaries with a wrong API key (or a model the server doesn't have). Record a short session and finish the rename. A **"Summary Failed"** notification appears whose body is the server's *actual* message (e.g. the auth/model error), **not** "Summary response contained no content".
- [ ] **Working config is silent + writes the file.** Fix the config to a healthy endpoint/model, record again: no failure notification, and a `…-summary.md` lands next to the transcript.
- [ ] **LM Studio native path.** With provider = LM Studio and the target model unloaded/oversized, a failure notification shows the real reason rather than a generic empty-content message.

---

# Test Checklist — v0.8.x UI Revamp (all 8 screens)
_(Stale: belongs to the UI-revamp track, not this branch. Left intact — maintainer to prune.)_

Everything here is a visual/UX pass — the pipeline is untouched. Compare
against docs/design/design-system-0.8.x.md ("Quiet Confidence") when in doubt.

## Menu bar panel (MenuView — from Pass 1, re-check after rebase)
- [ ] Panel opens as a 320pt window-style panel, not a text menu.
- [ ] Idle: green dot, prominent red Start Recording button, hover-highlight on action rows.
- [ ] Recording: pulsing red dot, live mm:ss timer ticking, Stop button.
- [ ] Close and reopen the panel *while recording*: the dot fades in and picks up its pulse (no un-animated jump), and the timer shows the true elapsed time, not a restart from 00:00.
- [ ] Stop recording with the panel open: the dot fades back to solid rather than snapping.
- [ ] Transcribing: spinner in header, record button disabled.
- [ ] Warnings/criticals appear as dismissible banners, not disabled menu items.

## Setup window (SetupView — from Pass 1, re-check after rebase)
- [ ] Opens with app icon + "Welcome to Parley" + privacy line, grouped cards with icon tiles.
- [ ] Continue stays disabled with an explanatory footnote until required permissions + model are ready.
- [ ] Folder Choose… works; denied folder shows orange guidance, not red.

## Settings window (NEW — tabbed)
- [ ] Five tabs render with toolbar-style icons: General / Audio / Transcription / Summary / Permissions.
- [ ] Window resizes sensibly when switching tabs; no clipped content.
- [ ] General: Recording Folder shows a ~-abbreviated path + Choose… panel (no raw TextField).
- [ ] Save bar at the bottom of every tab; ⌘S saves; "Saved" appears ~2s; edits persist to config.json only after Save.
- [ ] Transcription: engine switch to Parakeet when model uncached → "Model will download … when you save"; Save triggers download with progress; failure shows orange (not red).
- [ ] Permissions tab: granted = green check; not-determined = Grant; denied = Open Settings (deep-links Privacy pane).
- [ ] Summary: LM Studio provider reveals the Context section; empty fields show "Model default" prompts.
- [ ] Summary: toggling "Summarize After Transcription" grows/shrinks the window (260 → 460/620pt). Confirm it reads as content revealing itself, not as a glitch.
- [ ] Check for Updates…: the panel closes before Sparkle's dialog appears (it must not linger behind it).

## Rename Speakers dialog (NEW — cards)
- [ ] One card per speaker: label top-left, sample counter + play/next top-right, name field, quoted sample text.
- [ ] Sample text is readable (secondary, not faint quaternary).
- [ ] Play/next buttons are comfortably clickable; playback still channel-correct (local=L, remote=R).

## Session name dialog
- [ ] With a calendar meeting in range: field pre-filled + "Suggested from your calendar" caption; typing your own name swaps the caption to the timestamp hint.
- [ ] Start Recording is the visually primary (filled) button.

## Mic switch dialog (during recording)
- [ ] Switch shows a spinner + "Switching…" while in flight.
- [ ] A failed switch shows an orange warning label, not red.

## Critical alert
- [ ] Sits on the same glass/material as the other dialogs; Dismiss is a prominent filled button; red triangle unchanged.

## Cross-cutting
- [ ] Every "opens further UI" label uses a true ellipsis (…): Settings…, Rename Speakers…, Choose…, Check for Updates…, Switching…
- [ ] Red appears ONLY for: record/stop affordances, recording timer/dot, critical alerts, destructive rows (Quit is not red), meter clipping.
- [ ] Dark mode: run the full pass once in dark mode — cards, glass, and meter must all adapt.
- [ ] Large Text: with System Settings › Accessibility › Display › Larger Text raised, open each Settings tab. Rows grow; the grouped Form should scroll within its fixed tab height, never clip. (Same construction as the pre-revamp 600pt scrolling Form.)
- [ ] VoiceOver: menu panel rows announce their title only, not the SF Symbol name; the status dot is not announced as an unlabelled element.

## Regression (always — do not trim; these are standing gates, not per-feature tests)
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

## Speaker count + minority absorption (#65 / #67) — added 2026-09-03

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

**Known gap:** a mic-only recording (phone on speakerphone, no system audio) still has no `.m4a`
and its transcript does not reference the mic WAV — #183. Re-detect will fail on those until #183
lands. Verify the error message is the readable one.
