# Test Checklist — v0.7.x branch

## ⚠️ Capture resilience — DEVICE TEST REQUIRED before push (#86, #92, #93, #94, #95, #7, #61, #54)
This branch changes the live audio-capture path. It is **gated on a real Bluetooth-call route-change
test** — it cannot be validated by unit tests. Reproduce your actual scenario: put on AirPods, then
answer a FaceTime / WhatsApp call and record.

### Benign route change is NOT a crash (#86) — the headline test
- [ ] Start recording. Mid-recording, force an audio-route change: answer a FaceTime/WhatsApp call so it grabs the mic (AirPods HFP↔A2DP), or connect/disconnect AirPods.
- [ ] Recording **keeps going** — you see a calm "Audio device changed — recording resumed automatically" (or "briefly interrupted — continuing") bubble, **NOT** a red crash error.
- [ ] Mic stays on your chosen device — you do **NOT** have to manually re-switch to the right mic afterward (re-pin works).
- [ ] After stop, the transcript spans the **whole** session — no missing minutes at the route change.
- [ ] Log shows `Stream restarted in place — mic re-pinned:` (subsystem `eu.fmasi.parley`, category audio).

### Live helper-crash data-loss fix (#92) — the "Andrew lost 16 min" regression
- [ ] Record ≥2 min. Force-kill the helper mid-recording: `pkill -f audio-capture-helper-xpc`.
- [ ] App recovers (resume bubble). Keep talking ~1 min, then stop.
- [ ] Final transcript contains **both** the pre-crash audio (the orphan chunk) **and** the post-crash audio — nothing dropped.

### Recovered-segment archival + metadata (#93, #7)
- [ ] After a crash-recovered session (segments `-0`, `-1`, … on disk), transcript `metadata.audio_files` lists **every** recovered segment and each was archived to `.m4a` (not just the base).

### Anomaly-gated diagnostics + provenance (#95)
- [ ] After an **anomalous** session (one with a route change or forced crash), a `<sessionId>.diag.jsonl` exists in the day's recording folder and contains `streamStopError` / `restartInPlace` (or `xpcInterruption`) events.
- [ ] After a **clean** session (no interruption), **no** `.diag.jsonl` is written.
- [ ] **Every** transcript JSON has `metadata.capture_provenance` (engine, system_format, mic_format, route_changes, retries, recovered, anomaly_count) — clean and anomalous alike.

### Retry decay, not lifetime cap (#61)
- [ ] Over a long meeting with a few **well-spaced** route changes (>10 min apart), the app does **not** hit the "microphone capture crashed repeatedly" critical error — the decay window resets the counter.
- [ ] A **tight** loop (≥3 interruptions within ~10 min) still trips the critical-error panel.

### Format change / buffer safety (#94)
- [ ] Audio after a route change is **not** corrupted or wrong-speed (system stays 48kHz mono). No crash on the route change (bounded mic memcpy).

### Built-in mic / multichannel — the "wrong microphone" root cause (device-test 2026-06-26)
- [ ] Mid-recording, switch the mic to the **MacBook built-in mic** (or let a route change fall back to it). Speak.
- [ ] Your voice is **present** in the local track afterward — NOT silent. (Before this fix the built-in mic's 3-channel format was rejected and every mic buffer was dropped.)
- [ ] Log does **NOT** show a flood of `Mic audio: unsupported format … ch=3`. Optionally confirm `AudioConverter: new converter …ch → 48000Hz 1ch` appears for the built-in mic.
- [ ] If a mic format ever IS unsupported, the session writes a `.diag.jsonl` (the failure is now recorded as an anomaly), and `metadata.capture_provenance.mic_format` reflects the mic actually in use at the end.

## Rename → Parley migration (#75)
**Resets macOS TCC permissions** (bundle ID changed `com.audio-transcribe.app` → `eu.fmasi.parley`). Do a clean-up + re-auth pass:
- [ ] Remove the old install + LaunchAgent: `rm -rf /Applications/AudioTranscribe.app` and `launchctl unload ~/Library/LaunchAgents/com.audio-transcribe.app.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.audio-transcribe.app.plist`
- [ ] If `~/.audio-transcribe` exists, it auto-migrates to `~/Library/Application Support/Parley` on first launch — verify `config.json` + `token-ratios.json` carried over and `~/.audio-transcribe` is gone
- [ ] App launches as **Parley**; re-grant Screen Recording + Microphone when prompted
- [ ] Menu/About/Setup windows read "Parley", not "Audio Transcribe"
- [ ] Full pipeline: record → transcribe → (optional) summarize works end to end
- [ ] `/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"'` shows logs during a recording
- [ ] Re-shoot `docs/assets/` screenshots (window titles still say "Audio Transcribe")

## Version Infrastructure (#42 + #33)
- [ ] About menu item visible between Settings and Quit
- [ ] Click "About Parley" — native About panel appears
- [ ] About panel shows version like `0.6.1 (xxxxxxx)` (not "dev" or "2.0.0")
- [ ] Record a short session, check output JSON `"software_version"` in metadata
- [ ] `software_version` value matches `git describe` format (e.g. `v0.6.1-25-gxxxxxxx`)

## Mic Selection
- [ ] Menu bar shows config default mic name on launch
- [ ] Click mic button (idle), switch — label updates immediately
- [ ] Restart app — mic reverts to config default (session pick not persisted)
- [ ] Start recording dialog — pre-selects config default
- [ ] Change mic in start dialog — after recording, restart, default unchanged
- [ ] Mid-recording mic switch — restart app, default unchanged
- [ ] Open Settings — default mic picker shows current config default
- [ ] Change mic in Settings, Save — restart app, new default persists

## Audio Chunk Concatenation
- [ ] Record session longer than chunk duration — multiple chunks created
- [ ] After finalization, single merged `.m4a` exists (not per-chunk files)
- [ ] Merged audio plays back correctly (no gaps, no corruption)
- [ ] Set `merge_chunked_audio: false` in config — verify per-chunk files preserved

## CLI Stereo Channel Handling
- [ ] `Parley transcribe -i file.m4a` — prompts for stereo channel handling
- [ ] `--split` flag splits stereo without prompting
- [ ] `--no-split` flag processes as mono without prompting

## Echo Deduplication
- [ ] Record with YouTube on speakers (no headphones), speak a few sentences
- [ ] Verify your speech preserved (Local Speaker segments in transcript)
- [ ] Verify YouTube bleed removed (`echo_segments_removed > 0` in JSON metadata)
- [ ] Open transcript JSON — no local segments contain text identical to remote segments

## Summary Generation
- [ ] Verify LLM endpoint configured (LM Studio or OpenAI)
- [ ] After transcription + rename dialog, summary auto-generates
- [ ] `-summary.md` file created alongside transcript
- [ ] Dual-stream transcripts include `(local)`/`(remote)` labels in summary input
- [ ] Summary has no echo content attributed to local speakers

## Rename Dialog
- [ ] After transcription, rename dialog appears
- [ ] Play button works — audio plays (mono extraction from archive)
- [ ] Correct channel: local speaker plays mic audio, remote speaker plays system audio
- [ ] Forward button cycles through samples
- [ ] Rename and save — names updated in JSON and SRT/TXT

## CLI AAC Re-processing
- [ ] `Parley transcribe -i file.m4a` — splits and processes stereo AAC
- [ ] `--debug` flag streams logs to stderr
- [ ] Echo dedup runs (check `echo_segments_removed` in output)

## XPC Crash Recovery
- [ ] Recording survives XPC crash — auto-restart with warning banner
- [ ] After 2 consecutive crashes — critical error panel appears
- [ ] Critical error panel is a floating NSPanel (impossible to miss)
- [ ] Sentinel file cleaned up after stop or crash escalation

## Streaming AudioArchiver
- [ ] Record a meeting (system + mic), verify `.m4a` created after transcription
- [ ] `.m4a` is stereo (L=mic, R=system)
- [ ] Source WAV files deleted after successful archival

## Chunked Recording
- [ ] Start recording — chunk-0 files created
- [ ] Wait past chunk duration — rotation visible in logs
- [ ] Stop after rotation — final transcript has speech from both chunks
- [ ] Speaker labels consistent across chunks

## Crash-safe WAV header (#79)
- [ ] Record >1s, then force-kill the XPC service (or app) mid-chunk before stop
- [ ] The orphaned chunk WAV opens with correct duration (not 0s) via `afinfo` — header was flushed during recording
- [ ] On next transcription, an orphaned chunk's audio appears in the transcript (repairHeader recovered it); log shows `WAV header repaired: ... data size N -> M bytes`

## Crash-recovery segment completeness (#84, #85)
- [ ] After a recording that survived ≥1 crash (segments `-0` and `-2` on disk, `-1` missing), the final transcript spans the WHOLE meeting — the pre-crash segment is NOT dropped at the numbering gap
- [ ] Transcript `metadata.audio_files` lists every recovered segment, not just the last one
- [ ] Recovery/CLI path repairs an orphaned segment header before transcribing (log shows `WAV header repaired`); orphan’s audio appears in the transcript

## Regression
- [ ] Start recording, stop, transcription completes
- [ ] Settings save and reload correctly
- [ ] App survives quit and relaunch (LaunchAgent)

## Model manifest
- [ ] Settings: "Check for model updates online" toggle visible (between Transcription Engine and Recording sections) and OFF by default
- [ ] Toggle persists across app restart
- [ ] With toggle ON, "Check now" button appears
- [ ] "Check now" reports a status within 10s and stays under the toggle
- [ ] Launch log contains a "Manifest verify:" line within a few seconds of startup (subsystem eu.fmasi.parley, category transcription)
- [ ] After deleting a file from the FluidAudio cache root (returned by `AsrModels.defaultCacheDirectory()`), next launch logs `Manifest verify: ... file(s) corrupt -- ...` or `... missing ...`
