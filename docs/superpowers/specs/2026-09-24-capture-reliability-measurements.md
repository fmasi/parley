# Capture reliability overhaul: measurement decisions (X3)

**Date:** 2026-09-25
**Inputs:**
- spec §10 (open questions only a device test can settle) and §11 (defaults);
- plan Task X3;
- the review ledger (`.superpowers/sdd/2026-09-24-capture-reliability/progress.md`);
- the device protocol in `scripts/test-checklist.md` (the D-, N- and M-P items named below).

Each row below is a number the code cannot know until it runs on a real Mac. For each one, this file
gives:
- what to measure;
- which checklist item measures it;
- the decision it drives;
- the threshold that triggers that decision;
- what ships if nobody measures it.

A threshold marked *(proposed)* is not from the spec or a review ruling. It was set here and needs the
owner's OK.

**How to apply a result.** Put the measured numbers in one commit, together with the code change they
justify and the `docs/parameters.md` update. Example message: "p99 first-frame 1.3 s under false →
firstFrame 5 s, stall 3 s kept". Write the M-A census table and the M1 Air numbers into
`docs/benchmarks/2026-09-capture-reliability.md` (new). Never lower a detection threshold on thin
evidence: a lower threshold only adds false alarms, and the owner's first rule is "no false positive
on a muted remote".

## Summary

| ID | Measurement | Checklist | Drives | Threshold | Default if not measured | Release |
|---|---|---|---|---|---|---|
| M-A | Muted-remote exact-zero census | N-01, N-02, matrix | `remote_exact_zero_soft_alarm_seconds`; the tap first-frame threshold | any app with gate open and a ≥ 60 s exact-zero run while muted → knob stays off for good *(run length proposed)* | knob off (`nil`) | owner cells (N-01, N-02) before release; rest follow-up |
| M-B | `tap_auto_start` true vs false | D-12 | default of `tap_auto_start` (2 sites) | `false` wins only if: ≥ 90 callbacks/s continuous, CPU delta ≤ 10 ms/s on the M1 Air, no artefact, no leftover assertion | `true` | before release (couples with M-G) |
| M-C | Incident B and the ladder | D-10 | rung order; rung queue | the rung that restores callbacks; `AudioDeviceStop` > 1 s or any `recoveryStuck` *(1 s proposed)* | ladder as shipped; rungs on `configQueue`; 5 s stuck watchdog alarms | follow-up unless a rung hangs |
| M-D | coreaudiod restart | D-13 | none, or a bug | frames and mic back ≤ 10 s | heartbeat + ladder (already there) | blocker only if neither frames nor an alarm |
| M-E | `goin` / `stpd` / `diff` on a real aggregate | D-11 | none (they stay accelerators) | informational | accelerators | — |
| M-F | Per-app output device | N-03 | whether the process gate is right | no alarm; `expected_seconds` ≈ call length | trust the probe facts | before release |
| M-G | Insurance rebuild during a muted stretch | D-14 in N-01, N-02 | keep or disable the TapPermissionGuard insurance rebuild while callbacks flow | next `firstFrames` < 1 s ok, ≤ 3 s note, > 3 s or none = fail | **open question** (see M-G) | **must measure before release** |
| M-H | Sleep, wake and HDMI display sleep | D-17, D-33 | none, or a bug | frames back ≤ 10 s after wake, or alarm up | as shipped | blocker only if silent |
| M-J | First-frame latency | D-15 | `firstFrameThresholdSeconds` 5, `stallThresholdSeconds` 3, `heartbeatDeadlineSeconds` 3 | new value = max(current, p99 + 2 s) | 5 / 3 / 3 | before any default flip |
| M-K | Gate debounce, sustained health, the one-tick dropout | D-04, D-10, D-12–D-16, M-A | `gateCloseTicks` 2, `sustainedHealthSeconds` 30 | zero spurious stalls or rungs within 5 s of a gate reopen *(proposed)* | 2 / 30 | follow-up issue, never blind tuning |
| M-L1 | App SIGKILL vs helper survival | D-30 | helper-side grace follow-up | old helper pid alive > 1 s after the kill | none (the resume path is primary) | follow-up only |
| M-L2 | LaunchAgent relaunch, and the `isLaunchdJob` signal | D-02b, D-03 | the launchd-job signal | relaunch ≤ 5 s; the survivor logs "launchd job = true" | `XPC_SERVICE_NAME` signal | **blocker if "false"** |
| M-L3 | Restart cap | D-32 | none | never a 4th restart | 2 restarts / 10 min | blocker if it loops |
| M-L4 | Sleep 2 min | D-33 | none | gap ≈ 120 s recorded, "Resumed" after frames | as shipped | pass/fail |
| M-L5 | Disk full | D-34 | none | `diskLow` within one rotation | 2 chunks + 200 MB to start; `diskLow` < 1 chunk | pass/fail |
| M-S1 | DarkWake discriminator (graphics capability bit) | D-44 | `SystemPowerObserver.isFullWake` trust | no wake resumed at a `DarkWake` line; no "implicit wake" ≤ 5 s after sleep | as shipped (300 s dark bound) | **before release** (night false alarms) |
| M-S2 | App lost-wake watchdog vs DarkWake (L) | D-44 | L item 104 | night recorded as sleep gap(s) ±60 s | as shipped by L | before release |
| M-T1 | Termination bound on logout / outside quit (L) | D-38–D-42 | `TerminationPolicy.terminationBound` 5 s | no logout-timeout dialog; minute before logout salvaged | 5 s | pass/fail |
| M-P1 | Output-probe cost on the M1 Air | M-P1 | probe optimisation issue | helper CPU delta vs previous release ≤ 10 ms/s; > 30 ms/s blocks *(proposed)* | ship as is | follow-up unless > 30 ms/s |
| M-P2 | Long-gap merge re-encode on the M1 Air | M-P2 (from D-44) | 12 h gap bound / 300 s `exportTimeout` | extrapolated 12 h re-encode ≤ 240 s (80 % of 300 s) *(80 % proposed)* | 12 h / 300 s (10 h measured OK on the M5 Pro) | follow-up (a timeout keeps chunk files, no loss) |
| M-P3 | Idle wakeups when not recording | M-P3 | find the timer | no helper after 11 min idle; Parley ≤ 0.5 interrupt wakeups/s *(proposed)* | ship | follow-up |
| M-R1 | Passthrough merge on device | D-25 | none | informational: does passthrough ever succeed? | re-encode fallback | — |

Count: 22 measurements.

## Details

### M-A — muted-remote exact-zero census (spec §10 M-A; checklist N-01, N-02, measurement matrix)
- **Measure.** One cell per app (Meet in Chrome, Meet in Safari, Zoom app, Teams, FaceTime, iPhone
  relay) and route (AirPods, wired). For each cell:
  - whether the gate stayed open while muted (`remote_coverage.expected_seconds` vs the recording
    length);
  - callbacks per second;
  - exact-zero seconds inside the muted window (from the kept system WAV, `preserve_source_wav: true`);
  - first audio after unmute;
  - any `neverDelivered` or `tapRecoveryRung` after unmute;
  - rebuilds, and whether an alarm appeared.
- **No per-second `piro` / `outDevs` log.** The plan's per-second `piro` / `outDevs` columns assumed
  a helper debug line that does not exist. The H1 review also dropped `outDevs` from the lean probe.
  The census therefore works from per-recording numbers plus the WAV. If a per-second view is
  wanted, a debug-level log line in `LivenessWatchdogDriver.tick()` is a small follow-up.
- **Decision 1: the soft alarm knob.**
  - If ANY cell whose gate stayed open while muted shows an exact-zero run of ≥ 60 s, that app renders
    exact zeros for a muted remote. `remote_exact_zero_soft_alarm_seconds` then stays unset for good,
    and `docs/parameters.md` says why.
  - If NO cell does, across the whole matrix, the knob may ship at 300 s as a "can't confirm" (spec
    §10). That is a separate owner decision, not automatic.
- **Decision 2: the tap first-frame threshold.** In a cell whose gate CLOSED while muted, a
  `neverDelivered` or a rung after unmute means the app's first-audio edge is slower than 5 s. Then
  raise the tap's `firstFrameThresholdSeconds` to that cell's measured p99 + 2 s (with M-J).
- **Pass per cell.** No alarm, and `rebuilds ≤ 1`.
- **Default if not measured.** The knob stays off (`CaptureOptions.remoteExactZeroSoftAlarmSeconds = nil`).
  Thresholds unchanged.
- **Release.** N-01 and N-02 (Meet in a browser and Zoom, with headphones, under both
  `tap_auto_start` settings) are the owner's #1 no-false-positive case, and gate the release. The
  remaining cells fill the census and can follow.

### M-B — `tap_auto_start` true vs false (spec §10 M-B; checklist D-12)
- **Measure.** On the M1 Air, per setting:
  - callbacks per second with nothing playing, and after playback stops (under `true`, do callbacks
    continue once the writers leave?);
  - helper + coreaudiod CPU (`powermetrics`, 10 min);
  - `pmset -g assertions` after Stop;
  - audible artefacts on the built-in speakers and on the LG over HDMI with the display asleep.
- **Threshold to flip to `false`.** All of:
  - callbacks continuous (≥ 90/s) in every phase;
  - CPU (helper + coreaudiod) under `false` minus under `true` ≤ 10 ms/s (1 % of one core);
  - no audible artefact;
  - no coreaudiod assertion left after Stop.
- **Decision.** Flip the default in BOTH places, in one commit with the numbers and the
  `docs/parameters.md` row:
  - `CaptureOptions.init(tapAutoStart: Bool = true, …)`;
  - the nil mapping `config.tapAutoStart ?? true` in `CaptureOptions.init(config:)`.

  With `false`, "no callbacks" is unambiguous, the autostart re-arm stall disappears, and
  permission-denied zeros are visible from t = 0. The M-G risk also goes away (see M-G).
- **Default if not measured.** `true`. The gate carries the never-delivered decision alone, as it does
  already.

### M-C — Incident B and the ladder (spec §10 M-C; checklist D-10)
- **Measure.** In ≥ 3 reproductions:
  - which rung restored callbacks (`tapRecoveryRung` `rung` / `token`, then the system `firstFrames`);
  - how long each rung took;
  - whether any `recoveryStuck` appeared.

  Use the wired-mic control run.
- **Decision.**
  - If only `rebuildTap` ever restores callbacks, start the episode at `rebuildTap`. That means
    reordering `TapRecoveryLadder.nextRung`, keeping the 2 + 2 budget.
  - If a teardown's `AudioDeviceStop` takes > 1 s *(proposed)* or a `recoveryStuck` appears, the rung
    must run on a throwaway queue in `TapHealer` / `SystemTapSession`, so that `configQueue` is never
    wedged. Council B-I1 becomes Critical in that case. H2 already bounds Stop, so a hang no longer
    blocks Stop, but a hung rung still blocks later rungs.
  - The spec's cheaper rungs (`AudioDeviceStop`+`Start` on the same IOProc; recreate the IOProc) are
    not in the shipped ladder. If a reproduction shows they would have been enough, file them as a
    follow-up; don't add them blind.
- **Default if not measured.** The ladder as shipped: `rebuildAggregate` ×2 then `rebuildTap` ×2,
  within `fastWindowSeconds` 15, with a `heartbeatDeadlineSeconds` 3 check after each rung. Rungs run
  on `configQueue`. `TapHealer.stuckSeconds` 5 raises `remoteRecoveryFailed`, so a hang still alarms.
- **If Incident B does not reproduce in 3 tries.** Write "not reproduced" and keep the default.

### M-D — coreaudiod restart (spec §10 M-D; checklist D-13)
- **Measure.**
  - Whether `srst` reaches the helper (`serviceRestarted` present).
  - The gap until system frames return.
  - Whether the mic returns. The council's B-M2 fix re-registers the mic's device listeners and is
    unverified on hardware.
- **Decision.**
  - If `srst` does not arrive: no change. The heartbeat and the bad-object read on the aggregate
    already trigger the ladder. Record the result.
  - If frames never return and no alarm stays up: a bug, and a release blocker (never neither).
  - If the mic does not return: file it.
- **Default if not measured.** As shipped.

### M-E — aggregate listeners (spec §10 M-E; checklist D-11)
- **Measure.** Which of `goin` / `stpd` / `diff` fired during D-10, and whether each fired before the
  heartbeat verdict.
- **Decision.** None. They stay accelerators, and the heartbeat decides. If one fires often on healthy
  recordings and causes rebuilds, file it.
- **Default if not measured.** Accelerators, as shipped.

### M-F — per-app output device (spec §10 M-F; checklist N-03)
- **Measure.** Zoom set to Speakers while the default output is AirPods, with the remote talking.
- **Pass.** No alarm. The right channel has Zoom's audio. `remote_coverage.expected_seconds` ≈ the
  call length: the process gate opened although the default device was idle.
- **Decision.** A fail means the process-level gate is wrong: a release blocker.
- **Default if not measured.** Trust the probe facts (`run-afplay.txt`, `run-own-aggregate.txt`).

### M-G — the insurance rebuild during a muted stretch (spec §10 M-G; council A-I1 and A-4; checklist D-14 inside N-01 and N-02)
- **The risk.** With the permission authorized and a muted remote rendering exact zeros, after ~12 s
  `TapPermissionGuard` asks for ONE insurance rebuild per episode. Under `tap_auto_start = true`, it
  is unmeasured whether the rebuilt aggregate starts while the call app's output is already running
  (no new start edge). If it does not, `neverDelivered` follows, then the ladder, then possibly
  "The other side may not be recorded": a false alarm on the owner's #1 scenario.
- **Measure.** Under both settings:
  - the dead window, from the insurance rung's `tapRecoveryRung` to the next system `firstFrames`
    (log: "System tap: rebuilding for the System Audio Recording permission (insurance)");
  - `remote_coverage.rebuilds`;
  - any alarm.
- **Threshold.**
  - Next `firstFrames` < 1 s: pass.
  - 1–3 s: acceptable; note it.
  - > 3 s, or no `firstFrames` followed by `neverDelivered` and rungs: fail.
- **Decision on a fail under `true`.** Disable the insurance rebuild while the gate is open AND
  callbacks are flowing. The permission check itself stays. The code site is the
  `insuranceRebuildUsed` branch of `TapPermissionGuard` that returns `.rebuildTap(reason: .insurance)`.
  Under `false` the IOProc runs continuously, so a pass is expected.
- **Default if not measured: an open question for the owner.** Neither choice is safe:
  - keeping the insurance risks the false alarm above;
  - disabling it removes the only quiet heal for "coreaudiod refuses although TCC says granted".
    The soft "can't confirm" alarm is off (M-A), so that case would then be silent.

  **Proposal:** if M-B flips `tap_auto_start` to `false`, ship the insurance as is. If the default
  stays `true`, do not tag until N-01 and N-02 have been run under `true`. The runs take about 40 min.

### M-H — sleep, wake and HDMI display sleep (spec §10 M-H; checklist D-17, D-33)
- **Measure.**
  - With the LG as the output: does the IOProc stall while the display sleeps, and do `gone` / `goin`
    change?
  - After a system sleep: is the gap recorded, and do frames resume?
- **Decision.** If frames stop and nothing alarms: a blocker (never neither). Otherwise, informational.
- **Default if not measured.** As shipped: the wake re-arms both monitors and the ladder heals.

### M-J — first-frame latency (spec §10 M-J; checklist D-15)
- **Measure.** ≥ 10 samples per `tap_auto_start` setting:
  - start: "Capture started — …; awaiting frames" to "System audio (tap): normalized 48000Hz, 1ch, Int16";
  - rebuild: each `tapRecoveryRung` or `restartInPlace` to the next system `firstFrames`, from the
    anomalous runs' `.diag.jsonl`.

  Healthy sessions write no `.diag.jsonl`, so start samples come from the log.
- **Decision.** For each of the following, the new value = max(current, ceil(p99 + 2 s)):
  - `TrackLivenessMonitor.init(firstFrameThresholdSeconds: 5)`;
  - `stallThresholdSeconds: 3`;
  - `TapRecoveryLadder.heartbeatDeadlineSeconds` (3).

  They are only raised, never lowered.
- **Default if not measured.** 5 / 3 / 3.

### M-K — gate debounce, sustained health, and the one-tick dropout (C3 deferred minor; C4 round 1)
- **Measure.** Across every run that has a `.diag.jsonl`, look for a `livenessGap` (a stall) or a
  `tapRecoveryRung` within 5 s after the gate reopened, while the audio was fine by ear. That is the
  C3 concern: a one-tick dropout counts as expected time, so a slow tap restart can produce a spurious
  stall ~1 s after a gap. From D-04, D-10 and D-13, also note the intervals between a heal and a
  re-stall.
- **Threshold.** Zero spurious stalls or rungs *(proposed)*. For a heal followed by a re-stall:
  - within 30 s continues the old episode;
  - after 30 s starts a fresh one.

  Flag it if a genuinely flaky tap keeps re-stalling just past 30 s and never alarms while losing
  audio.
- **Decision.** On a spurious stall, file an issue that chooses between pausing the stall clock during
  a dropout and raising `TrackLivenessMonitor.gateCloseTicks` to 3. On a never-alarming flaky tap,
  file one to raise `TapRecoveryLadder.sustainedHealthSeconds`. **Do not tune blind.**
- **Default if not measured.** `gateCloseTicks = 2`, `sustainedHealthSeconds = 30`.
- **Why D-04 can't show it.** D-04's knob (`debug_drop_tap_frames`) cannot be toggled mid-recording:
  config is read only at launch. So the 30 s rule can't be exercised on demand there; it is observed
  opportunistically in D-10, D-13 and D-16. It is unit-tested (C4).

### M-L1 — app SIGKILL vs helper survival (spec §10 M-L1; checklist D-30)
- **Measure.** How long the OLD helper pid lives after `kill -9` of the app. Also check that the
  helper logged "Capture finalized after client disconnect" (H2 round 5's `NSXPCConnection.current()`
  identity assumption) and sealed the WAV.
- **Decision.** If the helper survives for more than ~1 s, open a follow-up issue for a bounded
  helper-side grace: a 120 s finalize timer layered on top of the resume path, never a replacement
  for it.
- **Default if not measured.** None. The resume path is primary.

### M-L2 — LaunchAgent relaunch, and the launchd-job signal (spec §10 M-L2; checklist D-02b, D-03)
- **Measure.**
  - The delay from `kill -SEGV` to the relaunched instance's first log line.
  - Whether the launchd-spawned survivor logs "Instance guard: launchd job = true". The
    `XPC_SERVICE_NAME` signal was confirmed only on a `launchctl submit` probe, never on the real
    bundle.
- **Decision.**
  - If the survivor says "false", `isLaunchdJob` needs another signal. One option is a `--launchd`
    argument written into the plist by `generatePlist`, which makes every existing plist "stale"
    once. A release blocker.
  - A relaunch slower than 5 s: file it, and note the launchd throttle.
- **Default if not measured.** The `XPC_SERVICE_NAME` signal.

### M-L3, M-L4, M-L5 — cap, sleep, disk (spec §10; checklist D-32, D-33, D-34)
Pass/fail acceptance items. No tunable is expected to move:
- the restart cap: `XPCRetryPolicy.defaultMaxRetries` 2, decay 600 s; the count resets only after 60 s
  of confirmed frames;
- the disk check: `DiskSpaceCheck`, which refuses a start below 2 chunks + 200 MB, and raises
  `diskLow` below 1 chunk at a rotation.

A crash loop, a missing sleep gap or a silent disk failure is a blocker.

### M-S1 — the DarkWake discriminator (H2 round 2 item 18, round 3; checklist D-44)
- **The assumption.** `SystemPowerObserver.isFullWake()` reads the graphics bit of IOPMrootDomain's
  "System Capabilities" to tell a full wake from a DarkWake at power-on. It reads 15 while awake; its
  DarkWake value was never measured.
- **Measure.** One lid-closed night on power with Power Nap on. Compare the `pmset -g log` `DarkWake`
  / `Wake` lines with the helper's "Power-on while paused for sleep (DarkWake) — pause kept",
  "Resuming after sleep (…)" and "Implicit wake — …" lines.
- **Threshold.**
  - No "implicit wake" within 5 s after "System sleep (IOKit)".
  - No "Resuming after sleep" at a `DarkWake` line.
  - "Implicit wake — expired" at most once, and only after a DarkWake longer than
    `SleepPauseClock.darkPowerOnExpirySeconds` (300 s).
- **Decision.** If the bit does not tell them apart, a night of Power Naps would reopen the mic with
  the devices off and raise false alarms. Before release, stop trusting the bit: end the pause only
  on the app's wake or the 300 s bound, and file the discriminator.
- **Default if not measured.** As shipped.

### M-S2 — the app's lost-wake watchdog vs DarkWake (L item 104; checklist D-44) (L — verify wording after the L merge)
- **Measure.** In the same night: whether "No wake arrived … waking implicitly" fires during a
  DarkWake. If it does, check whether the real morning wake still records the rest of the night as a
  gap, with a rotation.
- **Threshold.** `metadata.capture.gaps` covers lid-close → lid-open within ±60 s.
- **Decision.** A fail is an L bug, and a release blocker (a lost gap makes the record lie about
  time).
- **Default if not measured.** As shipped by L.

### M-T1 — the termination bound (L item 53; checklist D-38 to D-42) (L — verify wording after the L merge)
- **Measure.** On a logout, restart, Activity Monitor Quit, `osascript` quit or Sparkle relaunch
  while recording, including with a hung helper (D-42):
  - no "Log out has timed out" or "prevented logout" dialog;
  - the salvage at the next launch has the audio up to the quit.
- **Decision.** If the seal regularly misses the 5 s bound (the salvage loses the last chunk), seal
  earlier rather than hold the logout longer. `TerminationPolicy.terminationBound` stays within what
  loginwindow tolerates.
- **Default if not measured.** 5 s; `userQuitBound` 30 s.

### M-P1 — the output probe's cost on the M1 Air (H1 review; checklist M-P1)
- **Measure.** Helper and Parley CPU (`powermetrics` tasks, 10 min) while recording with nothing
  playing, under `tap_auto_start = true`. That leaves the mic, the 1 Hz tick and the probe. Compare
  with the previous release on the same Mac. The reviewer estimated ~1 % of a core before the
  short-circuit rewrite (`IsRunningOutput` first, stop at the first other running process, no
  `outputDevices`). It is unmeasured after it.
- **Threshold** *(proposed)*.
  - Delta ≤ 10 ms/s (1 % of one core): fine.
  - Up to 30 ms/s: file an optimisation, for example caching the process-object list and re-reading
    it on a `prs#` listener, with the tick-counting debounce kept at 1 Hz.
  - Above 30 ms/s: blocks the M1 Air target.

  Without a baseline build, record the absolute numbers.
- **Default if not measured.** Ship as is.

### M-P2 — a long-gap merge re-encode on the M1 Air vs the 300 s export timeout (R2 round 5 re-review; checklist M-P2 from D-44)
- **Measure.** The time from "AudioConcatenator: re-encoding with AAC (silence inserted)" to
  "AudioConcatenator: re-encode succeeded" for the overnight recording, plus its total length (gap +
  audio). Extrapolate linearly to the 12 h bound: t₁₂ = t × 12 h ÷ (gap + audio).
- **Threshold.** t₁₂ ≤ 240 s, i.e. 80 % of `AudioConcatenator.exportTimeout` (300 s) *(80 % proposed)*.
- **Decision.** Over the threshold, one of:
  - lower the 12 h gap bound (the `implausibleTiming` check) to the gap that fits in 240 s;
  - or raise `exportTimeout`.

  Today a timeout keeps the chunk files and merges nothing: no audio is lost, but there is no single
  `.m4a`.
- **Default if not measured.** 12 h / 300 s. A 10 h gap was measured OK on the M5 Pro.

### M-P3 — idle wakeups when not recording (spec principle; L items 35 and 54; checklist M-P3)
- **Measure.** After a recording and 12 min idle: whether the helper process is gone (idle-exit), and
  Parley's interrupt wakeups per second (`powermetrics` tasks, 5 min).
- **Threshold** *(proposed)*. No helper. Parley ≤ 0.5 wakeups/s with no periodic pattern.
- **Decision.** Over the threshold, find the timer and file it. Candidates: a rotation timer that
  outlived a stop, the folder retry, or the idle re-alarm timer with no alarm active.
- **Default if not measured.** Ship.

### M-R1 — passthrough merge on device (R4; checklist D-25)
- **Measure.** Whether a no-gap merge logs "passthrough export succeeded" on a real recording.
  Passthrough fails with -11838 in the test runner, so it has never run.
- **Decision.** None; the re-encode fallback is correct either way. If passthrough never succeeds,
  every merge re-encodes, and M-P2's timing applies to all of them.

## What must be measured before tagging
The rest can ship on their defaults and be filed as follow-ups:
- **M-G**, and M-B if the owner wants the M-G risk removed by the flip.
- **The M-A owner cells** (N-01, N-02 under both settings).
- **M-F.**
- **M-L2's signal** (D-02b).
- **M-S1 / M-S2** (one night).

## Versioning (plan X3)
MINOR (the v0.10.0 line, or the next MINOR after v0.9.0 is tagged). The release notes lead with:
- the transcript changes (§14): "your transcripts now state per side how much was captured; re-check
  recordings that reported `dual_stream: true` with no remote segments";
- the two default flips (§11): the Core Audio tap for new installs; FluidAudio as the engine, with
  Apple Speech labelled "not yet usable (#223)";
- the `tap_auto_start` flip, if M-B passed.
