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

## Regression
- [ ] **Normal tap recording.** Permission on, a real call or a video for 2 minutes: transcript has remote segments, and no repair window or new banners appear.
