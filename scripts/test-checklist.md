# Test Checklist — permission readiness (#220, #174)

Build and install this tree: `python3 scripts/dev.py`. The stable signing identity keeps existing
grants; this checklist resets only the permission under test.
Set Settings → Audio → Capture Method → **Core Audio Tap** unless a step says otherwise.
To play "remote" audio, use any video/music, or `afplay` a file.

The acceptance bar for this class of bug (lesson from #217): the alarm must **fire**, it must
**stay** while the problem continues, and it must be **actionable**. A single past-tense
banner doesn't count. **Rule for every mid-call step: after Stop, the right channel of the `.m4a` either
has the remote audio, or the recording raised a persisting alarm. Never neither.**
Check the right channel with `ffmpeg -i <file>.m4a -af "pan=mono|c0=c1,volumedetect" -f null -`
(mean around −91 dB means digital zero), and read `capture_provenance.system_exact_zero_seconds` in the transcript JSON.

## The root cause: Parley can now be prompted
- [ ] **Prompt appears.** `tccutil reset AudioCapture eu.fmasi.parley`, relaunch Parley. Expect the system prompt **"Parley.app" would like to record your system audio** at launch. Allow. No repair window follows.
- [ ] **System Settings lists it.** Parley appears under Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only**, switched on.

## The council's critical case: Allow quickly at Record
- [ ] **Fast Allow, built-in speakers.** With output on the **built-in speakers** (not AirPods, whose route switch triggers a rebuild that would hide the bug), `tccutil reset AudioCapture eu.fmasi.parley`, play audio, press Record, and click **Allow within ~5 s**. After Stop the right channel **has audio** from a few seconds in, and `system_exact_zero_seconds` is small, not the whole recording.

- [ ] **No false "restored".** In the fast-Allow run above, no "being recorded again" banner appears (nothing was ever reported).

## Repair window, before recording
- [ ] **Denied at launch → repair, not lockout.** Switch Parley **off** under "System Audio Recording Only", relaunch. The menu is usable (no "Setup required"), and a floating **Permission Needed** window lists System Audio Recording with **Open Settings**. Open Settings lands on the right pane; switch Parley on → the window **closes by itself** within ~2 s.
- [ ] **Record start with the permission off.** Switch it off, press Record. The recording **starts** (timer running, mic captured), then the repair window opens saying **"Parley isn’t recording everything"** (not "your next recording"), with a notification. The menu shows the sticky red row **"The other side isn’t being recorded"**.
- [ ] **The alarm persists.** Click **Later**. The sticky menu row stays and **can't be dismissed**. Cause an unrelated banner (e.g. switch the mic): the sticky row is still there. After ~3 min the window reopens by itself.
- [ ] **Fix after Later, via System Settings.** With the window dismissed, switch Parley on in System Settings. Within ~5 s the helper rebuilds the tap by itself; once remote audio plays the sticky row clears and the banner says it's being recorded again. After Stop the right channel has audio after the fix.
- [ ] **It comes back next time.** Stop, then start another recording with the permission still off → the window opens again.

## Mid-call (the #220 scenario)
- [ ] **Revocation while audio plays.** Record with remote audio playing; after ~20 s switch Parley off under "System Audio Recording Only". Then **either** the right channel keeps its audio after Stop (macOS keeps feeding a running tap), **or** the repair window + sticky row appear within ~15 s. Check the archive to tell which. Also try revoking **then switching the output device** (forces a rebuild): the alarm must appear.
- [ ] **No focus stealing.** When the window pops mid-call, typing in the meeting app's chat keeps working.
- [ ] **Fix resumes in the same recording.** Switch it back on → the window closes by itself and the banner says remote audio is being recorded again. After Stop, the `.m4a` right channel has audio **before** the revoke and **after** the fix, in one file. `.diag.jsonl` has `systemAudioPermissionDenied` then `systemAudioPermissionRestored`, and provenance has `system_audio_unrecovered: false` and `quality_anomaly_count ≥ 1`.
- [ ] **Unfixed is recorded honestly.** Repeat but don't fix (click **Later**). The banner stays until Stop, and provenance has `system_audio_unrecovered: true`.

## No false alarms
- [ ] **Genuine silence.** Permission on, record 60 s with nothing playing and then a muted call → **no** repair window.
- [ ] **ScreenCaptureKit unaffected.** Switch Capture Method to Screen Recording and Save: Setup/Settings show the **Screen Recording** row, and recording works with no System Audio prompt.
- [ ] **Switching to the tap asks right away.** `tccutil reset AudioCapture eu.fmasi.parley`, then switch Capture Method to Core Audio Tap and **Save** → the system prompt appears immediately, not at the next meeting.

## A stalled helper must not wedge the permission checks
- [ ] **Frozen helper.** Start a recording (so the capture helper is running), then `pkill -STOP -f audio-capture-helper-xpc`. In Settings switch Capture Method and **Save**: the app and menu must stay responsive, and within ~5 s the permission check gives up (each helper call has a 3 s deadline and fails open) instead of hanging. Then `pkill -CONT -f audio-capture-helper-xpc` and confirm the recording carries on. (The same deadline protects the launch check; that path is not race-free to test by hand.)

## Tap recording sanity (this PR)
- [ ] **Normal tap recording.** Permission on, a real call or a video for 2 minutes: transcript has remote segments, and no repair window or new banners appear.

---

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
- [ ] Re-detect on a multi-chunk (>30 min) recording: channel audio is concatenated across chunks
      and diarized once, so speaker numbering must stay consistent across the whole recording.
- [ ] Re-detect on a recording whose archive is gone (storage quota evicted it): must show a clear
      "No <channel> audio is available" error, not a spinner that never ends.

**Known gap:** a mic-only recording (phone on speakerphone, no system audio) still has no `.m4a`
and its transcript does not reference the mic WAV — #183. Re-detect will fail on those until #183
lands. Verify the error message is the readable one.

## Re-detect: binding count + name safety (#201 / #202) — added 2026-09-15

- [ ] **Re-detect is reachable on an ALREADY-NAMED transcript.** Open the rename dialog on a
      recording whose speakers you have already named (the rows read "Jacques", not "Remote
      Speaker 1"). The "Wrong number of speakers?" section must still be there. It used to vanish
      outright, because the channel list was derived from the label prefix — so re-detect was
      unreachable on exactly the transcripts someone had already invested naming effort in.

Both found on an 82-minute one-local/one-remote call. `RenameDialog` is app-target code and cannot
be type-checked without Xcode on this machine, so **every item here is the only check these changes
get** — run them all.
- [ ] **A stated count of 1 is honoured (#201).** On a channel the diarizer split into two (the
      classic case: one remote person plus a 20-30s fragment), set that channel's stepper to **1**
      and press Re-detect. The rows must rebuild with exactly **one** speaker, the stepper must
      settle on 1, and every line of that channel must still be present in the transcript — the
      merge relabels turns, it never drops them. Log line to confirm:
      `SpeakerCountEnforcer: merged N cluster(s) to honour the stated count of 1`.
- [ ] **Count 2 and 3 still behave.** Re-detect the same channel at 2, then 3. Each must produce at
      most the stated number of speakers, and never more.
- [ ] **Re-detect warns before clearing names (#202).** Name at least one speaker on a channel and
      Save. Reopen the rename dialog and press Re-detect on that channel. An alert must appear
      saying the names on that side will be cleared, before any work starts (no spinner first).
- [ ] **Cancel changes nothing.** Dismiss that alert with Cancel: no spinner, no rewrite, the rows
      and names are exactly as they were. Reopen the transcript to confirm it is byte-for-byte
      unchanged in substance — same speakers, same names.
- [ ] **Confirming clears only that channel.** Press Re-detect again and confirm. Afterwards the
      re-detected channel's rows show plain `Local Speaker N` / `Remote Speaker N` labels with empty
      name fields, and **the other channel's names are still there**.
- [ ] **The old names are recoverable.** In the transcript JSON, `metadata.speaker_names_previous`
      contains the cleared name(s); the other channel's entries in `metadata.speaker_names` survive.
- [ ] **Re-nameable afterwards.** Type new names into the rebuilt rows, Save, reopen: the names
      stick and the segments are attributed to them.
- [ ] **A second re-detect keeps the history.** Name the new speakers, re-detect again, confirm:
      `speaker_names_previous` now holds the newer names and has not lost the other channel's.
- [ ] **No warning when there is nothing to lose.** On a channel with no names at all, Re-detect
      must run straight away with no alert.

## Mic-only recordings (#183) — added 2026-09-03

- [ ] Answer a phone call, put it on speaker, record it. On stop, expect a `.m4a` to appear —
      previously the recording stayed as two WAVs forever.
- [ ] Check the log for `system track is empty — archiving '<name>' as mic-only`.
- [ ] Play the `.m4a`: your voice must be on the LEFT channel, right channel silent. If the voice
      is on the right, the mic has been archived into the remote slot — stop and file it.
- [ ] Open the rename dialog for that recording: the play button must be present and must play.
- [ ] Regression: a normal dual-stream call still archives with L=mic / R=system as before.
- [ ] Regression: a genuine rate mismatch (system 24 kHz vs mic 48 kHz — the 2026-08-04 chipmunk
      shape) must STILL refuse to archive and keep both WAVs.

## Mic switcher mid-recording (#192) — added 2026-09-10

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
