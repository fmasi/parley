# Test Checklist — permission readiness (#220, #174)

Build and install this tree: `python3 scripts/dev.py`. The stable signing identity keeps existing
grants; this checklist resets only the permission under test.
Set Settings → Audio → Capture Method → **Core Audio Tap** unless a step says otherwise.
To play "remote" audio, use any video/music, or `afplay` a file.

The acceptance bar for this class of bug (lesson from #217): the alarm must **fire**, it must
**stay** while the problem continues, and it must be **actionable**. A single past-tense
banner doesn't count.

## The root cause: Parley can now be prompted
- [ ] **Prompt appears.** `tccutil reset AudioCapture eu.fmasi.parley`, relaunch Parley. Expect the system prompt **"Parley.app" would like to record your system audio** at launch. Allow. No repair window follows.
- [ ] **System Settings lists it.** Parley appears under Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only**, switched on.

## Repair window, before recording
- [ ] **Denied at launch → repair, not lockout.** Switch Parley **off** under "System Audio Recording Only", relaunch. The menu is usable (no "Setup required"), and a floating **Permission Needed** window lists System Audio Recording with **Open Settings**. Open Settings lands on the right pane; switch Parley on → the window **closes by itself** within ~2 s.
- [ ] **Record start with the permission off.** Switch it off, press Record. The recording **starts** (timer running, mic captured). At the same moment the repair window opens and a notification appears.
- [ ] **It comes back.** Click **Later**, stop, then start another recording → the window opens again.

## Mid-call (the #220 scenario)
- [ ] **Revocation while audio plays.** Record with remote audio playing; after ~20 s switch Parley off under "System Audio Recording Only". If the remote channel goes silent, the repair window + notification + banner appear within ~15 s. (If macOS keeps feeding the running tap after a revoke, nothing fires and nothing is lost. Note which one you saw.)
- [ ] **Fix resumes in the same recording.** Switch it back on → the window closes by itself and the banner says remote audio is being recorded again. After Stop, the `.m4a` right channel has audio **before** the revoke and **after** the fix, in one file. `.diag.jsonl` has `systemAudioPermissionDenied` then `systemAudioPermissionRestored`, and provenance has `system_audio_unrecovered: false` and `quality_anomaly_count ≥ 1`.
- [ ] **Unfixed is recorded honestly.** Repeat but don't fix (click **Later**). The banner stays until Stop, and provenance has `system_audio_unrecovered: true`.

## No false alarms
- [ ] **Genuine silence.** Permission on, record 60 s with nothing playing and then a muted call → **no** repair window.
- [ ] **ScreenCaptureKit unaffected.** Switch Capture Method to Screen Recording and Save: Setup/Settings show the **Screen Recording** row, and recording works with no System Audio prompt.
- [ ] **Switching to the tap asks right away.** `tccutil reset AudioCapture eu.fmasi.parley`, then switch Capture Method to Core Audio Tap and **Save** → the system prompt appears immediately, not at the next meeting.

## Regression
- [ ] **Normal tap recording.** Permission on, a real call or a video for 2 minutes: transcript has remote segments, and no repair window or new banners appear.
