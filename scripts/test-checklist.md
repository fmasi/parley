# Test Checklist — capture reliability overhaul

Spec: `docs/superpowers/specs/2026-09-24-capture-reliability-design.md`. Measurement decisions (what each
number changes, and the default if it is not measured): `docs/superpowers/specs/2026-09-24-capture-reliability-measurements.md`.

**The promise under test:** for each side (your mic = LEFT, the other side = RIGHT), at every moment it is
**captured**, or **healed within seconds**, or **you are told loudly and keep being told**. Never neither.
Every mid-call item ends with the same check: after Stop, the `.m4a` channel has the audio, or an alarm
stayed up, and `metadata.capture.<side>.status` says which.

## Setup (once per session)

1. Build and install the merged tree: `python3 scripts/dev.py`. Settings → Audio → Capture Method →
   **Core Audio Tap** (the default for new installs).
2. Evidence folder and a copy of your config:
   `mkdir -p ~/Desktop/parley-x1 && cp ~/Library/Application\ Support/Parley/config.json ~/Desktop/parley-x1/config.before.json`.
   Put each item's evidence in `~/Desktop/parley-x1/<item>/` (for example `D-03/`).
3. Keep a log capture running in its own Terminal window for the whole session:
   `log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug | tee -a ~/Desktop/parley-x1/stream.log`.
   `log show` does not keep `.info` lines, so this stream is the only record of most log lines quoted below.
4. Paste these helpers into the Terminal you work in:
   ```zsh
   CFG=~/Library/Application\ Support/Parley/config.json
   # the transcript's capture facts
   meta()  { python3 -c 'import json,sys;m=json.load(open(sys.argv[1]))["metadata"];p=m.get("capture_provenance") or {};print(json.dumps({k:m.get(k) for k in ("dual_stream","capture","processing_issue_count","processing_issues","merged_audio","audio_files")},indent=1,ensure_ascii=False));print(json.dumps({k:p.get(k) for k in ("remote_coverage","local_coverage","retries","recovered","quality_anomaly_count","system_audio_unrecovered","reconstructed")},indent=1))' "$1"; }
   # a .diag.jsonl in time order (the file exists only when the session had an anomaly)
   diag()  { python3 -c 'import json,sys;[print(e["timestamp"],e["origin"],e["kind"],json.dumps(e.get("detail",{}))) for e in (json.loads(l) for l in open(sys.argv[1]) if l.strip())]' "$1"; }
   # right channel (the other side) of an .m4a: mean around -91 dB means digital zero
   rch()   { ffmpeg -hide_banner -i "$1" -af "pan=mono|c0=c1,volumedetect" -f null - 2>&1 | grep -E 'mean_volume|max_volume'; }
   # exact-zero runs of 1 s or more: zeros <file> <channel: 0 = left or mono WAV, 1 = right> <start s> <length s>; times are relative to <start>
   zeros() { ffmpeg -hide_banner -ss "$3" -t "$4" -i "$1" -af "pan=mono|c0=c$2,aformat=sample_fmts=flt,silencedetect=noise=-100dB:d=1" -f null - 2>&1 | grep -E 'silence_(start|end)'; }
   dur()   { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
   # set a config key to a JSON value, or remove it with null. Quit Parley first (menu → Quit): Parley reads config.json only at launch.
   cfg()   { python3 -c 'import json,sys;p=sys.argv[3];c=json.load(open(p));k,v=sys.argv[1],json.loads(sys.argv[2]);c.pop(k,None) if v is None else c.update({k:v});json.dump(c,open(p,"w"),indent=2);print(k,"=",json.dumps(c.get(k)))' "$1" "$2" "$CFG"; }
   ```
5. For multi-chunk items, `cfg chunk_duration_minutes 10` (the minimum) makes a 2-chunk recording take ~12 min.
   Restore with `cfg chunk_duration_minutes 30`, or copy `config.before.json` back, at the end.
6. "Remote" audio means a real call where the item says so, otherwise a video or `afplay <file>` (use
   `while true; do afplay <file>; done` to loop). For a muted remote, join the meeting from your iPhone as
   the other participant and mute or unmute it there.
7. How to mark: tick an item only when every PASS condition held. On a failure, write `FAIL:` and one
   line under the item, and keep its evidence folder. "shot" means a screenshot (Cmd-Shift-4, Space,
   click the window) saved into the item's folder.

The transcript is `<recordings>/<date>/<id>.json`, the audio `<id>.m4a`, the event log `<id>.diag.jsonl`.
The alarm rows are: "The other side may not be recorded", "Your microphone isn’t being recorded",
"Recording to disk is in trouble", "The capture helper stopped answering", "Crash protection is off",
"Recording resumed after a crash", "Recording STOPPED", "Recording folder unavailable".

## P0 — live safety

- [ ] **D-01 An idle-exit does not disarm crash detection.**
  - Do: launch Parley and don't record for 12 min. Check `pgrep -fl audio-capture-helper-xpc` prints nothing. Start a recording with audio playing. After 30 s, `pkill -9 -f audio-capture-helper-xpc`. Stop after 1 more minute.
  - PASS: around the 10-min mark the log shows "XPC interrupted while idle — helper idle-exit, ignored", and no helper process is started again until you record. After the kill, the menu shows "Recording restarted — waiting for audio…", and the "Recording Resumed" notification comes only after audio frames arrive (never at the instant of the restart); it says "Some audio may have been lost". After Stop, `diag <id>.diag.jsonl` lists `xpcInterruption`, `retry` and a `captureGap` with reason `helper restart`; `meta` shows `capture.gaps` with `{reason: "helper restart", seconds ≈ the restart's few seconds}` (final review R-I1); and `rch` shows audio after the kill.
  - Capture: the log lines, `diag` output, `rch` output.

- [ ] **D-02a LaunchAgent: Quit removes it.**
  - Do: menu → Quit. Run `launchctl print gui/$(id -u)/eu.fmasi.parley >/dev/null; echo $?` and `ls ~/Library/LaunchAgents/eu.fmasi.parley.plist`.
  - PASS: the exit status is non-zero, and the plist does not exist.

- [ ] **D-02b LaunchAgent: a Finder launch hands over to launchd once.**
  - Do: after D-02a, open Parley from Finder. Watch the menu-bar icon. Then run `launchctl print gui/$(id -u)/eu.fmasi.parley | grep -E 'pid =|program ='`, `pgrep -x Parley`.
  - PASS: within ~2 s the icon disappears and reappears exactly once. `pgrep` prints one pid, and it equals the `pid =` value. The log shows "Handed over to launchd's own job — this process exits now", then "Instance guard: launchd job = true" for the survivor. No "Crash protection is off" row.
  - FAIL, and a release blocker: the survivor logs "launchd job = false" (see X3 M-L2).
  - Capture: the log lines, the `launchctl print` output.

- [ ] **D-02c LaunchAgent: a second launch is absorbed.**
  - Do: with Parley running, open it from Finder again.
  - PASS: no icon blink, still one `pgrep -x Parley` pid, the same as before, and no row.

- [ ] **D-02d LaunchAgent: a moved bundle is repaired silently.**
  - Do: `osascript -e 'quit app "Parley"'` (this keeps the LaunchAgent). `mkdir -p ~/Applications && mv /Applications/Parley.app ~/Applications/`, then open `~/Applications/Parley.app`.
  - PASS: one icon blink. `launchctl print gui/$(id -u)/eu.fmasi.parley | grep program` shows the NEW path, and its `pid =` equals `pgrep -x Parley`. No row.
  - Afterwards: menu → Quit, move the app back to `/Applications`, and open it (another single blink).

- [ ] **D-02e LaunchAgent: no hand-over while busy.**
  - Do: this needs a Parley that is NOT launchd's job, which the 30 s hand-over cooldown gives you. Right after D-02b's blink (within 30 s): `osascript -e 'quit app "Parley"'`, open Parley from Finder, and read the log line "LaunchAgent hand-over cooldown — one re-check in N s". Before N s pass, start a recording. Record 2 min, Stop, let the transcript finish, and close the rename panel.
  - PASS: no icon blink during the recording, the transcription, or while the rename panel is open, and no row. Within a few seconds of closing the last panel: one blink, and `launchctl print`'s `pid =` equals `pgrep -x Parley`.

- [ ] **D-02f LaunchAgent: an open menu defers the hand-over, and closing it resumes it.**
  - Do: repeat D-02b to reset the cooldown clock. Within 30 s: `osascript -e 'quit app "Parley"'`, open Parley from Finder, click the menu-bar icon, and keep the dropdown open past the N s from the cooldown log line.
  - PASS: the dropdown stays open (no blink), and the log shows "Crash-protection hand-over deferred by windows: <class>@<level>". After you close the dropdown, you see one blink within ~2 s, and `pid =` matches again.
  - Capture: the log lines.

- [ ] **D-02g LaunchAgent: a failure is loud.**
  - Do: menu → Quit, `chmod 500 ~/Library/LaunchAgents`, and open Parley. Then `chmod 700 ~/Library/LaunchAgents`, menu → Quit, and open Parley again.
  - PASS: with 500, the row "Crash protection is off" and ONE notification appear at once, not after 2 min. With 700, one blink and no row.
  - Capture: shot of the row.
  - Optional (15 min): on a non-job instance (the D-02e trick), leave Settings open 15 min. PASS: the row reads "Crash protection is waiting for you to close Parley’s windows…".

- [ ] **D-02h Crash protection during a recording (final review A-I2).**
  - Do: make Parley a non-job instance whose hand-over is deferred: launch it from Finder with the Setup/repair window open (or the D-02e cooldown trick), or click Record within a second of launch. Record 5 min with audio, then Stop and let the transcript finish.
  - PASS: when the recording starts, the row "Crash protection is off for this recording — if Parley crashes now it will not relaunch or resume it…" appears with ONE notification, and no further notification for the rest of the call (not every 2 min). After Stop, once Parley is idle (no panel open): the hand-over runs (one icon blink) and the row clears.
  - Capture: shot of the row, the log line "Crash-protection hand-over deferred…" if any.

- [ ] **D-03 A crash relaunches and resumes within 5 s.**
  - Do: check that Parley is launchd's job (D-02b). Record a call or a looping `afplay`, talk for 1 min, then `date +%T; kill -SEGV $(pgrep -x Parley)`. Keep talking for 1 more minute, then Stop.
  - PASS:
    - the log shows "Instance guard: launchd job = true" ≤ 5 s after the kill (note the delay: M-L2);
    - the helper logs "Capture finalized after client disconnect";
    - the menu timer continues from the ORIGINAL start;
    - a floating alert says "Parley crashed at HH:MM:SS and resumed at HH:MM:SS — N s not recorded";
    - the red row "Recording resumed after a crash" stays until you acknowledge it;
    - after Stop, `meta` shows `capture.gaps` with `{reason: "app relaunch", seconds ≈ N}`;
    - the transcript has your speech from BEFORE the crash as well as after (the resume read the session by its id, R5), and `rch` has audio on both sides of the gap.
  - Note which crash time was used: the orphan chunk WAV's mtime (the helper sealed it on disconnect), or, with no orphan WAV, the recovery file's `lastAliveAt`, which can be up to 60 s early. Write down both N and the real gap.
  - Capture: shot of the alert, the log lines, `meta`.

- [ ] **D-04 Never delivered → heal → alarm (Incident B, on demand).**
  - Do: Quit, `cfg debug_drop_tap_frames true`, and open Parley. The helper now drops every tap buffer before its heartbeat. Loop `afplay`, then Record.
  - PASS (the ladder, from `diag` after Stop): within ~10 s, `neverDelivered` (track system); then up to 4 `tapRecoveryRung` (rung `rebuildAggregate`, `rebuildAggregate`, `rebuildTap`, `rebuildTap`) inside ~15 s; then `tapRecoveryGivenUp`.
  - PASS (the alarm): the floating window, a sound, a notification, and the red row "The other side may not be recorded" appear, while typing in another app keeps working. Click **Later**: the row stays. A second notification comes 2 min after the first. The window returns 3 min after Later. A `tapRecoveryRung` with `rebuildTap` runs every 60 s (the slow retry).
  - PASS (the dead-gate memory): stop `afplay` for ≥ 3 s. `livenessRecovered` with reason `gateClosed` appears, and the row goes away (nothing is expected to play). Start `afplay` again: ONE `tapRecoveryRung rebuildTap`, then `tapRecoveryGivenUp` and the row again within ~4 s, not a fresh 4-rung episode. A notification comes only if ≥ 2 min have passed since the last one (the notify floor).
  - PASS (the record): after Stop, `meta` shows `capture.remote.status == "neverDelivered"`. The completion notice reads "Transcription Complete — the other side was not captured" (it reads the per-side verdict, final review R-I2), never the plain "Transcription Complete". `-summary.md` (with an LLM endpoint) opens with a banner saying "Remote audio: not captured (0 s delivered of N s expected)".
  - Cleanup (required): Quit, `cfg debug_drop_tap_frames null`, and open Parley.
  - Note: the knob can't be removed mid-recording, because config is read only at launch. Healing that clears the row is checked in D-10, D-13 and D-16 instead.
  - Note: the Core test rig now drives the Incident-B chain (the helper's HF-4); this device item stays for the HAL half — the real tap, aggregate and IOProc.
  - Capture: `diag`, `meta`, shots of the window and the row.

- [ ] **D-05 A wedged helper is noticed, and does not freeze the app.**
  - Do: Record with audio playing. `pkill -STOP -f audio-capture-helper-xpc`. While it is stopped, open Settings, change Capture Method, and Save. Then `pkill -CONT -f audio-capture-helper-xpc`. Set Capture Method back, and Stop after 1 min.
  - PASS: within ~25 s (3 missed 5-s polls with a 3-s deadline each), the row "The capture helper stopped answering" appears. The menu and Settings stay responsive, and Save finishes within ~5 s. After CONT, the row clears within ~10 s and the timer keeps running. After Stop, the audio after CONT is in the `.m4a`. The frozen stretch is a gap, never an unexplained end.
  - Capture: shot of the row, the log lines.

- D-06 "Muted remote, no alarm (M-A)" is covered by N-01, N-02 and the measurement matrix below.

- [ ] **D-07 Permission denied mid-recording (the #220 path).**
  - Do: `tccutil reset AudioCapture eu.fmasi.parley`, quit and reopen Parley, and click **Don't Allow** on the system prompt. Play audio, then Record.
  - PASS: within ~15 s, the permission repair window ("Parley isn’t recording everything", its own window) and the red row "The other side may not be recorded" appear. The log shows no `tapRecoveryRung`: this is exact zeros from a denial, not never-delivered, so no ladder runs.
  - Do: while still denied, `pkill -9 -f audio-capture-helper-xpc` and wait 30 s.
  - PASS: the row never disappears. The new helper's first frames of zeros must not clear it.
  - Do: grant it in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.
  - PASS: the repair window closes by itself. The row clears only once remote audio plays, at the log line "System tap: real audio is arriving again — remote side restored".
  - PASS (after Stop): `diag` lists `systemAudioPermissionDenied` then `systemAudioPermissionRestored`. `rch` shows audio after the grant. The summary header says "system audio permission was not granted for part of the call".
  - Capture: shots of the window and the row, `diag`, `meta`.

- [ ] **D-08 The notify floor (no spam), except for past events.**
  - Do: record with a mic you can silence digitally. Either use the built-in mic in clamshell mode (external display + keyboard + power; the lid closed gives exact zeros, #193), or a USB mic with a hardware mute. Silence it for 20 s, unsilence it, and silence it again within 2 min of the first notification.
  - PASS: the first silence gives the row "Your microphone isn’t being recorded", a window and ONE notification within ~15 s. Unsilencing clears the row within ~2 s. The second silence brings the row back within ~15 s, but no notification or window until 2 min after the first notification; then exactly one.
  - Do: then `kill -SEGV $(pgrep -x Parley)`.
  - PASS: "Recording resumed after a crash" notifies at once, even seconds after another notification. Acknowledgeable past events are exempt from the floor.

- [ ] **D-09 Alarm panels over a full-screen call, without stealing focus.**
  - Do: put a Zoom, Teams or Meet call in full screen (its own Space), and click into its chat box. Trigger an app alarm: Record, then `pkill -STOP -f audio-capture-helper-xpc` (D-05's row, after ~25 s). Then `pkill -CONT`. Repeat with the repair window (D-07's denial) while the call is full screen.
  - PASS: each panel appears ON the full-screen call's Space, not on another desktop. Characters you type keep landing in the meeting chat while the panel is up. **Later** works with one click.
  - Note (informational): whether Esc dismisses the panel before you click it. A non-activating panel may need a click first.
  - Capture: shot of each panel over the full-screen call.

## Permission (#220 / PR #222 — still current)

- [ ] **P-01 Parley can be prompted, and is listed.**
  - Do: `tccutil reset AudioCapture eu.fmasi.parley`, then quit and reopen Parley.
  - PASS: at launch, the system prompt "“Parley.app” would like to record your system audio" appears. Allow. No repair window follows. System Settings → Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only** lists Parley, switched on.

- [ ] **P-02 A fast Allow at Record loses only the first seconds.**
  - Do: output on the **built-in speakers** (AirPods' route switch forces a rebuild that hides the bug). `tccutil reset AudioCapture eu.fmasi.parley`, play audio, Record, and click **Allow within ~5 s**.
  - PASS: after Stop, the right channel has audio from a few seconds in (`rch`, and listen), and `remote_coverage.exact_zero_seconds` is small, not the whole recording. No "being recorded again" banner appears, because nothing was ever reported.

- [ ] **P-03 Denied at launch: repair, not lockout.**
  - Do: switch Parley **off** under System Audio Recording Only, then quit and reopen it.
  - PASS: the menu is usable (no "Setup required"). A floating **Permission Needed** window lists System Audio Recording with **Open Settings**, which lands on the right pane. Switching Parley on closes the window by itself within ~2 s.

- [ ] **P-04 Recording with the permission off: starts, alarms, persists.**
  - Do: with the permission off, press Record. Then click **Later**, and cause an unrelated banner (switch the mic).
  - PASS: the recording STARTS (timer running, mic captured). The repair window opens saying "Parley isn’t recording everything", with a notification and the red row "The other side may not be recorded". The row can't be dismissed and survives the unrelated banner. The window reopens by itself after ~3 min.
  - Do: Stop, then start another recording with the permission still off.
  - PASS: the window opens again.

- [ ] **P-05 Fixed after Later, in the same recording.**
  - Do: in P-04's second recording, with the window dismissed, switch Parley on in System Settings.
  - PASS: within ~5 s the helper rebuilds the tap by itself. Once remote audio plays, the row clears and a quiet banner says it is being recorded again. After Stop, `rch` has audio after the fix.

- [ ] **P-06 Revoked mid-call.**
  - Do: Record with remote audio playing. After ~20 s, switch Parley off under System Audio Recording Only. Then also switch the output device (this forces a rebuild).
  - PASS: either the right channel keeps its audio (macOS keeps feeding a running tap), or the repair window and the row appear within ~15 s. After the output switch, the alarm MUST be up.
  - Do: switch it back on.
  - PASS: the window closes by itself. One `.m4a` has audio before the revoke and after the fix, and `diag` shows `systemAudioPermissionDenied` then `systemAudioPermissionRestored`.
  - Do: repeat, but leave it off until Stop (click Later).
  - PASS: the row stays until Stop. `meta` shows `capture.remote.status` not `healthy`, and the summary header says the permission "was not granted for part of the call".

- [ ] **P-07 ScreenCaptureKit is unaffected, and switching to the tap asks at once.**
  - Do: set Capture Method to Screen Recording (legacy, until #221) and Save.
  - PASS: Setup and Settings show the **Screen Recording** row, and a recording works with no System Audio prompt.
  - Do: `tccutil reset AudioCapture eu.fmasi.parley`, switch back to Core Audio Tap, and Save.
  - PASS: the system prompt appears immediately, not at the next meeting.

## P1 — tap healing

- [ ] **D-10 Incident B, reproduced for real (M-C).**
  - Do: mic = AirPods (HFP), default output = AirPods, clock anchor = built-in speaker, Safari playing to the AirPods. Record, and wait 15 s past the mic start. In a second Terminal, watch `log stream --process audio-capture-helper-xpc | grep -E 'PauseIO|ResumeIO'`. Try 3 times. Control run: a wired mic.
  - PASS: if callbacks stop (a `PauseIO` with no `ResumeIO`), then `tapRecoveryRung` events come in order and frames are back within 10 s (a system `firstFrames` after the rung), with no alarm left up. If callbacks never stop in 3 tries, write "not reproduced".
  - Record for X3: which `rung` and `token` restored callbacks, how long each rung took, and whether any `recoveryStuck` appeared (a rung that did not return in 5 s means `AudioDeviceStop` blocked).
  - If `recoveryStuck` appears: ALSO Stop, then start a second recording WITHOUT relaunching the helper, and check its remote side is captured — `sweepOrphanedAggregates` on an abandoned stop's aggregate is unverified (final review, helper M6).
  - Capture: `diag`, the PauseIO/ResumeIO lines.

- [ ] **D-11 Aggregate listeners (M-E), during D-10.**
  - PASS: `diag` shows `aggregateIOStopped` with `selector` `goin`, `stpd` or `diff`. Write down which ones fired, and whether each fired before the heartbeat verdict.

- [ ] **D-12 `tap_auto_start` A/B (M-B), on the M1 Air.**
  - Do: for each setting (Quit, `cfg tap_auto_start false` or `cfg tap_auto_start true`, reopen):
    1. Start `sudo powermetrics --samplers cpu_power,tasks -i 10000 -n 60 > ~/Desktop/parley-x1/D-12/<setting>.txt` (10 min).
    2. While it runs, make two recordings:
       - A: 3 min with nothing playing;
       - B: 30 s of playback, then 120 s idle.
    3. Run `pmset -g assertions` before the first recording and after each Stop.
    4. Listen to the speakers for clicks or relay noise.
    5. Repeat B once with the HDMI display (the LG) as the output and the display asleep (`pmset displaysleepnow`).
  - Measure: callbacks per second = `remote_coverage.heartbeat_callbacks ÷` the recording's length in seconds. Expect ~0 in A under `true`, and ~94 under `false`. For B under `true`, it shows whether callbacks continued after the playback stopped. CPU = the average of the 3rd column ("CPU ms/s") for `audio-capture-helper-xpc` and `coreaudiod`.
  - PASS for `false`: continuous callbacks (≥ 90/s in A and B), CPU (helper + coreaudiod) no more than 10 ms/s above `true`, no audible artefact, and no leftover coreaudiod assertion after Stop.
  - Capture: the powermetrics files, the four `meta` outputs, and the assertions before and after.

- [ ] **D-13 A coreaudiod restart (M-D).**
  - Do: test recording only. Loop `afplay`, Record, and after 30 s run `sudo killall coreaudiod`. Stop after 1 min.
  - PASS: `serviceRestarted`, then `tapRecoveryRung rebuildTap`. Remote frames are back ≤ 10 s after the kill (a system `firstFrames`). The mic is back (your voice after the restart is in the left channel). There is no alarm, or an alarm that clears by itself once frames return.
  - Record for X3: whether `srst` reached the helper (`serviceRestarted` present), and the gap until frames returned.

- [ ] **D-14 The insurance rebuild's dead window, during a muted remote (M-G).**
  - Do: this is done inside N-01 and N-02 (a remote muted ≥ 60 s under both `tap_auto_start` settings).
  - PASS: `remote_coverage.rebuilds ≤ 1`. If the log shows "System tap: rebuilding for the System Audio Recording permission (insurance)", the next system `firstFrames` in `diag` comes < 1 s after that rebuild's `tapRecoveryRung`. 1–3 s: note it. > 3 s, or no `firstFrames` at all followed by `neverDelivered` and more rungs: FAIL, and see X3 M-G.

- [ ] **D-15 First-frame latency (M-J).**
  - Do: for each `tap_auto_start` setting, 10 recordings started with audio ALREADY playing. Under `true` the tap waits for audio by design.
  - Measure:
    - start latency = the log time of "System audio (tap): normalized" (the rate prints as <private> in `log stream`; match the prefix, not "48000Hz") minus "Capture started — mic AVCaptureSession + system source …; awaiting frames";
    - rebuild latency = in the `diag` of D-04, D-10, D-13, D-14 and D-16, each `tapRecoveryRung` or `restartInPlace` to the next system `firstFrames`.

    Take the p99 (with 10 samples, the maximum) per setting. X3 sets the 5 s / 3 s thresholds from it.

- [ ] **D-16 An AirPods HFP switch mid-call.**
  - Do: output = AirPods playing a call or video (A2DP), mic = built-in. Record 1 min, then Change Microphone → AirPods (this forces HFP, the Incident-B trigger). Keep playing for 2 min, then Stop.
  - PASS: the remote audio continues, or it heals: a `tapRecoveryRung` then a system `firstFrames` within 10 s. No alarm stays up while audio is flowing. `rch` has audio across the switch (gap ≤ 10 s). The remote pitch is correct by ear (the chipmunk check). Never neither: if audio did not come back, the row "The other side may not be recorded" is up.

- [ ] **D-17 An HDMI display sleep with the LG as the output (M-H).**
  - Do: default output = the LG over HDMI, playing audio. Record 1 min, then `pmset displaysleepnow`, wait 2 min, and wake the display. Record 1 more minute, then Stop.
  - PASS: the right channel has audio after the wake (or it moved to another output and was recorded there). Any stall healed ≤ 10 s after the wake, or an alarm stayed up. There is no silent stretch without an alarm after the display woke.
  - Record for X3: whether the IOProc stalled while the display slept, and whether `goin` or `agrp` fired (the registered listeners are goin, stpd, diff, agrp).

## P2 — honest record

- [ ] **D-20 Coverage on a real call.**
  - Do: a 2-chunk real call.
  - PASS: `meta` shows `capture.remote.status` `healthy`, `expected_seconds ≈ delivered_seconds` on both sides, `processing_issue_count` 0 (informational entries such as `echo_flagged` or `duplicates_flagged` in `processing_issues` are fine), and `dual_stream: true`. The completion notice is "Transcription Complete". There is no alarm at the chunk boundary.

- [ ] **D-21 A mic-empty chunk (opportunistic).**
  - A chunk whose mic delivered nothing while the remote played. Unplugging a USB mic does NOT produce it: Parley follows the next mic (log "Mic input removed — … following to …"). Run this only if it happens naturally, or with a mic that stops delivering while staying selected.
  - PASS: that chunk archives system-only. The merged `.m4a` keeps the remote on the RIGHT, with the LEFT silent for that stretch. No WAV is left behind unless `preserve_source_wav` is on.

- [ ] **D-22 Re-detect keeps the timeline.**
  - Do: make a 2-chunk recording where chunk 1 has remote audio and chunk 2 has NOTHING playing (quit the browser and players; under `tap_auto_start` `true` the system track stays empty → a mic-only chunk, #183). Note 3 segment start times on the remote channel. Open the rename dialog and re-detect the remote channel.
  - PASS: the speaker turns land at the same timestamps as before (±0.5 s), and `<id>.json.bak` exists next to the transcript.

- [ ] **D-23 The summary is honest.**
  - Do: make a stamped COPY of the 09-24 incident transcript, never the original:
    ```zsh
    mkdir -p ~/Desktop/parley-x1/D-23 && python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));j["metadata"].setdefault("capture",{})["remote"]={"status":"neverDelivered","expected_seconds":2736.0,"delivered_seconds":0.0};json.dump(j,open(sys.argv[2],"w"),ensure_ascii=False,indent=1)' ~/Documents/Recordings/2026-09-24/160032-*.json ~/Desktop/parley-x1/D-23/stamped.json
    /Applications/Parley.app/Contents/MacOS/Parley summarize -i ~/Desktop/parley-x1/D-23/stamped.json
    ```
  - PASS: `stamped-summary.md` opens with a banner containing "Remote audio: not captured (0 s delivered of 2736 s expected)", and its Summary section says the other side was not captured. It does not read "Frederic met to prepare…" as if both sides were there.

- [ ] **D-24 The engine preflight.**
  - Do: Settings → Engine → "Apple Speech — not yet usable (#223)" → Save.
  - PASS: "Not saved — this engine cannot transcribe on this Mac: …", and the engine stays FluidAudio after reopening Settings.

- [ ] **D-25 The audio merge: passthrough without a gap, re-encode with one (R4).**
  - Do (a): a 2-chunk recording with no sleep. Do (b): D-33's recording (a 2-min sleep gap).
  - PASS (a): `merged_audio.gaps_inserted_seconds` is 0. `dur <id>.m4a` ≈ the sum of the chunk durations (±1 s). There is no audible gap at the chunk boundary. Write down whether the log said "AudioConcatenator: passthrough export succeeded" (`merged_audio.passthrough: true`) or fell back to the re-encode. Passthrough was never exercised in tests (it fails in the test runner), so this is its first real run.
  - PASS (b): the log says "AudioConcatenator: re-encoding with AAC (silence inserted)". `merged_audio.passthrough` is `false`, and `gaps_inserted_seconds` ≈ the sleep (±2 s). `dur` ≈ the chunks plus the gap. For a segment after the gap, seek the `.m4a` to its `start` in the JSON: you hear those words (within ~1 s).
  - FAIL: passthrough was used for a merge with a gap.

- [ ] **D-26 Same-day sessions stay separate across a crash (R5 / C-I3).**
  - Do: record A (2 min) and Stop. Run `md5 <A>.json`. Record B, talk for 1 min, `kill -SEGV $(pgrep -x Parley)`, let it resume, talk 1 min more, and Stop.
  - PASS: B's transcript has only B's speech (before and after the crash), and none of A's segments. A's `.json` has the same md5 as before.

- [ ] **D-27 exFAT and SMB recording folders (R2 round 3).**
  - Do:
    ```zsh
    hdiutil create -size 2g -fs ExFAT -volname ParleyExFAT ~/Desktop/parley-x1/exfat.dmg && hdiutil attach ~/Desktop/parley-x1/exfat.dmg && mkdir -p /Volumes/ParleyExFAT/Recordings
    ```
    Set the recording folder to `/Volumes/ParleyExFAT/Recordings`. Make two 1-min recordings back to back, then a third with a crash-resume (D-03). Repeat on an SMB share if you have one (a NAS, not this Mac).
  - PASS: all three transcripts are written, with no "Recording to disk is in trouble" row and no session-write error in the log. The second recording's transcript does not contain the first's speech.
  - Afterwards: set the folder back, and `hdiutil detach /Volumes/ParleyExFAT`.

## P3 — lifecycle

- [ ] **D-30 App SIGKILL: the helper seals, and does it survive? (M-L1)**
  - Do: Record with audio. In a second Terminal: `pgrep -fl audio-capture-helper-xpc`, then `kill -9 $(pgrep -x Parley); for i in $(seq 10); do date +%T; pgrep -fl audio-capture-helper-xpc; sleep 1; done`.
  - PASS: the helper logs "Capture finalized after client disconnect" within ~3 s of the kill, and the orphan WAV is sealed (`dur` reads a duration from it before the relaunch picks it up). The relaunch resumes as in D-03.
  - Record for X3: how long the OLD helper pid stayed alive after the kill. If it survived, X3 files the helper-grace follow-up.
  - (The plan's throwaway bundle is only needed if the helper survives and you want to see whether an un-finalized helper keeps capturing.)

- D-31 "LaunchAgent after a crash (M-L2)" is covered by D-02b and D-03. Write D-03's relaunch delay into X3 M-L2.

- [ ] **D-32 The restart cap: no crash loop (M-L3).**
  - Do: Record with audio. `pkill -9 -f audio-capture-helper-xpc`. Wait for "Recording Resumed", then kill it again within 60 s. Wait for "Recording Resumed", then kill it a third time.
  - PASS: two restarts, then the recording ends with "Recording Failed" (or "Recording STOPPED"), and a message naming what was written. There is never a 4th restart, and a transcript of the audio before it exists.
  - Control: 3 kills each ≥ 70 s apart (60 s of confirmed frames resets the count). The recording survives all 3.
  - (The gotcha #52 `CRASH_TEST` first-sample crash needs a temporary DEBUG patch. Skip it unless you build one.)

- [ ] **D-33 Sleep 2 min mid-call (M-L4).**
  - Do: Record with audio. Apple menu → Sleep (or close the lid with no external display). Wake after 2 min, play 1 more minute, and Stop.
  - PASS:
    - log: "System going to sleep while recording" and "System sleep (…): liveness paused", then at the wake "System woke while recording (~120 s asleep)" and ONE "Resuming after sleep (…)" line, with the reason `wake` or `implicit wake: a full-wake power-on` (the log prints the reason text, e.g. "Resuming after sleep (implicit wake: a full-wake power-on): …");
    - no line containing "implicit wake" (any case) within 5 s after "System sleep (IOKit): liveness paused";
    - a new chunk starts at the wake, frames resume, and "Resumed" appears only after frames;
    - `capture.gaps` has a `sleep` entry ≈ 120 s;
    - no alarm.
  - Keep this recording for D-25 (b).

- [ ] **D-34 A full disk (M-L5), on a disk image.**
  - Do:
    ```zsh
    hdiutil create -size 2g -fs APFS -volname ParleyFull ~/Desktop/parley-x1/full.dmg && hdiutil attach ~/Desktop/parley-x1/full.dmg && mkdir -p /Volumes/ParleyFull/Recordings
    ```
    Set the recording folder to it, with `chunk_duration_minutes` 10. Record with audio. After 1 min, `mkfile 1400m /Volumes/ParleyFull/fill`. Keep recording past the next rotation, and until writes fail. Then `rm /Volumes/ParleyFull/fill`, record past one more rotation, and Stop.
  - PASS: the row "Recording to disk is in trouble" (`diskLow`) appears at the first rotation after the fill, then `diskWriteFailure` when writes fail. After the `rm`, `diskLow` clears only at a rotation with ≥ 2 chunks free. After Stop, the end message says what is actually on disk (not "preserved"). Recording never stops silently.
  - Afterwards: set the folder back, then `hdiutil detach /Volumes/ParleyFull`.

- [ ] **D-35 A reboot mid-recording.**
  - Do: Record with audio for 1 min, then `sudo reboot`. Log in again.
  - PASS: Parley starts by itself, the salvage runs, and an alert says "Recording STOPPED at HH:MM:SS — your Mac restarted during the recording. Parley recovered … to <id>.json". The recovery file (`~/Library/Application Support/Parley/recording.json`) is gone only after that. The transcript has the minute before the reboot.

- [ ] **D-36 A crash during finalize.**
  - Do: Stop a 5-min recording, and while "Transcribing…" shows, `kill -SEGV $(pgrep -x Parley)`.
  - PASS: on relaunch, the salvage runs and says "Recording STOPPED at …" with what it recovered. It must NOT start recording again (the recovery file was marked `stopping`).

- [ ] **D-37 Quit while recording.**
  - Do: while recording, menu → Quit. Then Cmd-Q with the Settings window focused.
  - PASS: both show "Stop the recording and quit?". **Cancel** keeps recording. **Stop and Quit** stops first: the transcript appears, and Parley quits within ~30 s. After it, the LaunchAgent plist is gone (D-02a).

- [ ] **D-38 Log out while recording.**
  - Do: Record with audio for 1 min. Apple menu → Log Out → confirm. Log in again.
  - PASS: the logout completes without a "Parley … prevented logout" or "Log out has timed out" dialog. After login, Parley starts by itself and salvages. Its alert describes a quit or logout, never "Parley crashed", and names the transcript, which has the minute before the logout. The recording is not resumed.

- [ ] **D-39 Restart (Apple menu) while recording.**
  - Do: as D-38, with Apple menu → Restart.
  - PASS: as D-38. A graceful restart delivers the quit event, unlike `sudo reboot` in D-35.

- [ ] **D-40 Activity Monitor Quit and `osascript` quit while recording.**
  - Do: Record for 1 min, then Activity Monitor → Parley → Quit (not Force Quit). Reopen Parley. Repeat with `osascript -e 'quit app "Parley"'`.
  - PASS: Parley exits within ~5 s without a dialog, and launchd does not relaunch it (a clean exit). When you reopen it, the salvage alert is worded as a quit, and the transcript has the minute. No resume.

- [ ] **D-41 A Sparkle update relaunch while recording.**
  - Do: `bash scripts/sparkle-dryrun.sh`. It builds this tree as OLD and NEW, and CLOBBERS `/Applications/Parley.app`. Follow its printed steps: open OLD, start a recording, then Check for Updates → Install and Relaunch. Afterwards, `bash scripts/sparkle-dryrun.sh --stop` and reinstall with `python3 scripts/dev.py`.
  - PASS: OLD stops within ~5 s. NEW launches, and salvages with a quit-worded alert and a transcript of the minute. No resume. D-02b's hand-over happens once NEW is idle.

- [ ] **D-42 A logout with a hung helper stop.**
  - Do: Record, `pkill -STOP -f audio-capture-helper-xpc`, and log out.
  - PASS: no "Log out has timed out" dialog; Parley lets go within ~5 s even though the helper can't answer. After login, the salvage runs. It may say the last seconds could not be recovered, but it must not say "no recorded audio" when the first minute is on disk.

- [ ] **D-43 A cancelled logout.**
  - Do (a), cancelled BEFORE Parley's quit event: Record, Apple menu → Log Out → **Cancel** in the confirmation dialog.
  - PASS (a): the recording continues (the timer runs, no alert). More than 60 s later, menu → Quit shows the normal "Stop the recording and quit?" confirmation: it is treated as your own Quit, not a logout.
  - Do (b), cancelled AFTER it: open TextEdit with an unsaved document, Record, Log Out → confirm, then **Cancel** in TextEdit's save dialog.
  - PASS (b): Parley has already stopped and quit. It did not keep a half-stopped recording. Reopen it: the salvage alert is worded as a quit, and the transcript has the audio up to the logout.

- [ ] **D-44 An overnight lid-closed recording vs DarkWake.**
  - Do: on the M1 Air if possible (this also gives X3 M-P2). Use power, Power Nap on, the built-in mic, and no external display. Start `log stream …` into a file (Setup 3), Record, and close the lid for the night (under 12 h). In the morning, open the lid, wait 1 min, Stop, and let it finish. Then:
    ```zsh
    pmset -g log | awk '$4=="Sleep" || $4=="DarkWake" || ($4=="Wake" && $5!="Requests")' > ~/Desktop/parley-x1/D-44/pmset.txt
    grep -i -E 'System sleep|Power-on while paused|Resuming after sleep|implicit wake|going to sleep|woke while recording|No wake arrived|AudioConcatenator' ~/Desktop/parley-x1/stream.log > ~/Desktop/parley-x1/D-44/parley.txt
    ```
  - PASS:
    - no line containing "implicit wake" (any case) within 5 s after any "System sleep (IOKit): liveness paused";
    - at each `DarkWake` line in `pmset.txt`, the helper logs nothing, or "Power-on while paused for sleep (DarkWake) — pause kept", never a "Resuming after sleep (…)";
    - "Implicit wake — the bound expired — resuming liveness" happens at most once, and only after a DarkWake longer than 5 min;
    - every "Resuming after sleep (…)" matches a `Wake` line in `pmset.txt` (a real full wake, including "DarkWake to FullWake"). If one of those came overnight with the lid closed, the transcript and the alarm rows show what happened then; note it;
    - the app's "No wake arrived … waking implicitly" does not fire during the night. If it did, the morning wake still records the rest of the night;
    - `capture.gaps` has `sleep` entries covering lid-close → lid-open (±60 s);
    - no alarm or notification during the night or at the wake;
    - the transcript has the evening and morning speech.
  - Record for X3: the time from "AudioConcatenator: re-encoding with AAC (silence inserted)" to "AudioConcatenator: re-encode succeeded", the gap length, and the Mac (M-P2).

- [ ] **D-45a Recording folder gone: the start is refused.**
  - Setup for D-45:
    ```zsh
    hdiutil create -size 2g -fs APFS -volname ParleyX ~/Desktop/parley-x1/px.dmg && hdiutil attach ~/Desktop/parley-x1/px.dmg && mkdir -p /Volumes/ParleyX/Recordings
    ```
    Set the recording folder to `/Volumes/ParleyX/Recordings`.
  - Do: `hdiutil detach /Volumes/ParleyX`, then press Record.
  - PASS: refused at once with "The recording folder isn’t reachable — is its drive connected?" (the folder's abbreviated path follows in parens). The refusal is visible in the menu, even with notifications off. No capture starts.

- [ ] **D-45b A ghost mount point is still "gone".**
  - Do: with the image detached, `sudo mkdir -p /Volumes/ParleyX/Recordings` (a leftover folder, not a volume). Record. Then `sudo rmdir /Volumes/ParleyX/Recordings /Volumes/ParleyX`.
  - PASS: refused as in D-45a. Nothing is written onto the boot disk under `/Volumes`.

- [ ] **D-45c A dangling symlink, and a read-only volume.**
  - Do: `ln -s /Volumes/ParleyX/Recordings ~/ParleyLink`, set the folder to `~/ParleyLink`, and with the image detached, Record. Then `hdiutil attach -readonly ~/Desktop/parley-x1/px.dmg` and Record again. Clean up with `hdiutil detach /Volumes/ParleyX; rm ~/ParleyLink`.
  - PASS: the symlink case is refused naming the folder, as in D-45a. The read-only case is refused with "Parley can’t write to the recording folder — check its permissions".

- [ ] **D-45d Unplugged mid-recording, a crash, then the drive returns.**
  - Do:
    1. Attach the image read-write, with the folder = `/Volumes/ParleyX/Recordings`. Record with audio for 1 min.
    2. `hdiutil detach -force /Volumes/ParleyX`. Wait 20 s.
    3. `kill -SEGV $(pgrep -x Parley)`. After the relaunch, `sudo mkdir -p /Volumes/ParleyX` (ghost) and wait 30 s.
    4. `sudo rmdir /Volumes/ParleyX` and `hdiutil attach ~/Desktop/parley-x1/px.dmg`.
  - PASS:
    - after the detach, the row "Recording to disk is in trouble" appears, and the timer keeps running;
    - after the relaunch, the row "Recording folder unavailable" appears, and the recovery file stays in `~/Library/Application Support/Parley/`. There is no "no recorded audio" message, including with the ghost folder;
    - within ~10 s of the attach (the mount event, not a poll), the salvage runs: an alert names what was recovered, the row clears, and the transcript has the first minute.
  - Repeat with an exFAT image (`-fs ExFAT`), and with an SMB share ejected in Finder if you have one.
  - Optional: two sessions waiting at once (two images, each detached mid-recording then crashed). On re-attach, PASS: ONE row "2 earlier recordings were recovered: …", and the rename panels open one at a time.

- [ ] **D-46 Switching to a mic that is not responding (#194).**
  - Do: in clamshell mode, record on an external mic. Open Change Microphone. The built-in mic reads **Not responding** within ~2 s. Switch to it anyway.
  - PASS: no endless "Switching…". Within ~10 s, either the switch fails with a message and the old mic keeps recording, or it switches and "Your microphone isn’t being recorded" appears within ~15 s. The app stays responsive throughout (never neither).

## No false alarms — the owner's scenarios (spec §9)

Each runs ≥ 5 min (10 min where stated) and PASSES only with **no** alarm row, window or
notification. The "muted" cells are also M-A census cells: fill the matrix row below from the same recording.

- [ ] **N-01 Meet in a browser, headphones, the remote muted 10 min.** Run it twice: `tap_auto_start` `true` and `false`. This is M-G, and the owner's #1 case. PASS: no alarm, `remote_coverage.rebuilds ≤ 1`, and D-14's dead-window condition.
- [ ] **N-02 The Zoom app, headphones, the remote muted 10 min.** As N-01, under both settings.
- [ ] **N-03 A per-app output device (M-F).** Zoom → Speakers while the default output is AirPods, with the remote talking. PASS: no alarm, the right channel has the Zoom audio, and `remote_coverage.expected_seconds` ≈ the call length (the gate opened for Zoom, even though the default device was idle).
- [ ] **N-04 You stay silent 10 min** (muted in the call app, just listening). PASS: no mic alarm.
- [ ] **N-05 Screen sharing 5 min** with one side talking. PASS: no alarm.
- [ ] **N-06 Recording started 5 min before joining** (gotcha #66). PASS: no alarm while waiting. After joining, the remote is captured.
- [ ] **N-07 AirPods connect mid-call** (a route change). PASS: no alarm row. The pitch is checked in the Regression section's rate-integrity items.
- [ ] **N-08 Stop 5 min after hanging up.** PASS: the completion notice is "Transcription Complete", not "Transcription Complete — capture anomalies" (`CaptureQualityNotice.swift`; the frame check counts only expected time).
- [ ] **N-09 Nothing playing for 60 s,** with the permission on. PASS: no repair window, and `capture.remote.status` is `idle` (the summary says nothing was playing, not a fault).
- [ ] **N-10 True alarms still fire.** Close the lid on the built-in mic in clamshell mode (or use a USB mic's hardware mute) during a recording. PASS: the row "Your microphone isn’t being recorded" appears within ~15 s (12 s of exact-zero samples plus presentation). Its message is the static "The microphone has delivered Ns of pure digital silence — it may be hardware-muted (e.g. the lid is closed on the built-in mic)." — it does NOT name the actual mic device, even for the USB-mute case; that clause is only an example.
- [ ] **N-11 Grant System Audio Recording while nothing is playing** (final review, helper HF-1). Start a recording with no call and nothing playing, with the permission denied (`tccutil reset AudioCapture eu.fmasi.parley`, **Don't Allow**); then grant it in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only. PASS: no new row and no notification while nothing plays. Join the call: the remote is captured. If the tap is dead, ONE tap rung, then `remoteNotDelivering` within ~10 s of audio starting. (D-07 grants with audio playing and cannot see this.)

## Measurement runs (they feed X3; the decisions are in the measurements file)

**M-A census.** For the census, Quit, `cfg preserve_source_wav true`, and reopen. That keeps the system
WAVs; delete them afterwards, since they are not quota-managed. Per cell:
1. The remote talks for 1 min.
2. Note the menu timer when it mutes (Tm).
3. Wait 5 min, or 10 for N-01 and N-02.
4. It unmutes, counts "one, two, three" at once, and you note the timer (Tu).
5. Talk for 1 min, then Stop.

Fill the columns:
- **gate open while muted?**: yes if `remote_coverage.expected_seconds` ≈ the recording length; no if it is ≈ the length minus the muted time;
- **callbacks/s**: `heartbeat_callbacks ÷ expected_seconds`;
- **exact-zero s while muted**: the sum of the `silence_end − silence_start` lines from `zeros <system WAV> 0 <Tm in s> <muted s>`;
- **first audio after unmute**: the first `silence_end` of `zeros <system WAV> 0 <Tu in s> 20`;
- **after unmute**: any `neverDelivered` or `tapRecoveryRung` in `diag` after Tu;
- **rebuilds**, and **alarm?**.

The system WAV is `<id>.wav` or `<id>-N.wav`, not `_mic.wav`. The per-second `piro` and `outDevs`
columns in the plan need a helper debug line that does not exist; the columns above are the substitute
(see X3 M-A). PASS per cell: no alarm, and `rebuilds ≤ 1`.

- [ ] Meet in Chrome — AirPods, wired headphones
- [ ] Meet in Safari — AirPods, wired headphones
- [ ] Zoom app — AirPods, wired headphones
- [ ] Teams — AirPods, wired headphones
- [ ] FaceTime — AirPods, wired headphones
- [ ] iPhone relay (a cellular call answered on the Mac) — AirPods, wired headphones

| App | Route | tap_auto_start | Gate open while muted? | Callbacks/s | Exact-zero s / muted s | First audio after unmute (s) | neverDelivered or rung after unmute? | Rebuilds | Alarm? |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | |

- [ ] **M-P1 The cost of the output probe on the M1 Air.**
  - Do: nothing playing, no call apps open, `tap_auto_start` at its default. Record. After 1 min, `sudo powermetrics --samplers tasks -i 10000 -n 60 > ~/Desktop/parley-x1/M-P1-overhaul.txt` (10 min), then Stop. If the previous release is available, repeat on it → `M-P1-baseline.txt`.
  - Measure: the average "CPU ms/s" (3rd column) of `audio-capture-helper-xpc` and `Parley`: `grep -E '^(audio-capture|Parley)' <file> | awk '{s[$1]+=$3;n[$1]++} END{for(k in s) printf "%s %.1f ms/s\n",k,s[k]/n[k]}'`. Write the numbers into X3 M-P1.

- [ ] **M-P2 A long-gap merge on the M1 Air.** It comes from D-44 run on the M1 Air: the re-encode time and the gap. X3 extrapolates it to the 12 h bound.

- [ ] **M-P3 Zero idle wakeups.**
  - Do: after a recording and its transcript, leave Parley idle 12 min. Then run `pgrep -fl audio-capture-helper-xpc` and `sudo powermetrics --samplers tasks -i 60000 -n 5 | grep -E '^(Parley|audio-capture)'`.
  - PASS: no helper process (it idle-exited). Parley's interrupt wakeups per second are at X3's M-P3 threshold or below.

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
