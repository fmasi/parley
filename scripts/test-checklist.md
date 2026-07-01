# Test Checklist — #103 Phase 2 (Core Audio system-audio tap)

## ⚠️ Must device-test before commit (capture subsystem)
Build/install this tree first: `python3 scripts/dev.py`
(Resets TCC — re-grant Screen Recording + Microphone on first launch.)

The new path is **off by default** (SCK stays the default). Enable it in
**Settings → Recording → System Audio Capture → "Core Audio Tap (captures calls)"**, then start a
NEW recording. On the first tap recording macOS prompts for **System Audio Recording** — allow it.
(If it silently captures nothing after a rebuild: `tccutil reset All eu.fmasi.parley` and relaunch.)

### Parity — the tap must not regress capturable meetings
- [ ] With the tap enabled, record a **Zoom/Teams/Meet** call. Remote audio is captured on the system channel (confirm by transcript content).
- [ ] Dual-stream `.m4a` is stereo (L=mic, R=system); the **R/system channel has the remote party**, not silence.
- [ ] Echo-dedup still behaves on **speakers** (remote bleed removed; your own speech preserved).

### ⭐ The win — telephony/VoIP that SCK misses
- [ ] Answer an **iPhone cellular call on the Mac** (Continuity). With the tap, the **system channel captures the remote party** (the case SCK left at the noise floor). Confirm in the transcript / by listening to the system channel.
- [ ] Repeat for a **WhatsApp / FaceTime** call.
- [ ] Run these on **headphones/AirPods** at least once — proves the tap captures the far end from the output graph, not mic bleed.

### Output-switch clock continuity (HAL rebuild)
- [ ] Mid-recording, switch the **output device** (speakers → AirPods, or unplug). System audio keeps recording after a brief gap (the aggregate rebuilds around the new default output). No crash; the mic is never interrupted.

### Lifecycle / teardown
- [ ] Stop a tap recording → WAVs finalize, archive to `.m4a`, transcript completes (no orphaned private aggregate device — check Audio MIDI Setup shows nothing leftover; the helper also sweeps orphans on next start).
- [ ] Toggle back to **Screen Recording (default)** → next recording uses SCK exactly as before (no behavior change on the default path).
- [ ] Permission-denied case: deny System Audio Recording → start fails with a clear, actionable message (not a silent empty recording).

### Timeline alignment
- [ ] In a tap recording with both speakers active, mic and system tracks stay **aligned** in the stereo `.m4a` (no drift / no large leading offset between L and R).

---

## Regression (always)
- [ ] Start recording → stop → transcription completes
- [ ] Multi-chunk recording merges to a single `.m4a`, plays back with no gaps
- [ ] Dual-stream `.m4a` is stereo (L=mic, R=system); source WAVs deleted after archival
- [ ] Rename dialog works; play button plays correct channel per speaker
- [ ] Summary auto-generates (`-summary.md`) when an LLM endpoint is configured
- [ ] App survives quit + relaunch (LaunchAgent)
- [ ] During a recording, `log stream --predicate 'subsystem == "eu.fmasi.parley"'` shows names/paths as `<private>`
