# Test Checklist — Crash Recovery

## Setup screen (first launch)
- [ ] Engine picker appears below optional permissions with available engines listed
- [ ] FluidAudio selected + not cached → "Download" button appears (mirrors "Grant" pattern)
- [ ] Clicking Download → progress bar + live % appears; Download button disappears
- [ ] Continue is disabled until both: required permissions granted AND download complete
- [ ] Download complete → green checkmark; Continue becomes enabled
- [ ] Download fails → "Retry" button appears in red; Continue stays disabled
- [ ] Switching engine mid-download resets progress UI; Download button reappears if needed
- [ ] After Screen Recording relaunch: Setup screen re-appears with permissions checked + Download still required
- [ ] Engine choice persists to config.json (visible in Settings after setup)

## Normal Recording (regression check)
- [ ] Start recording, stop, verify transcription works as before
- [ ] No sentinel file left behind (`ls ~/.audio-transcribe/recording.json` — should not exist)
- [ ] Quit app normally (Cmd+Q) — verify it does NOT restart

## Flow A: UI Crash, XPC Alive
- [ ] Start recording
- [ ] Kill UI process: `kill -9 $(pgrep -f AudioTranscribe | head -1)`
- [ ] Verify app relaunches within ~2s (LaunchAgent)
- [ ] Menu bar icon shows recording state (re-attach)
- [ ] No notification or alert (silent recovery)
- [ ] Stop recording normally — transcription works

## Flow B: Both Crashed
- [ ] Start recording
- [ ] Kill both: `kill -9 $(pgrep -f AudioTranscribe); kill -9 $(pgrep -f audio-capture-helper-xpc)`
- [ ] Verify app relaunches within ~2s
- [ ] Notification appears: "Recording was briefly interrupted..."
- [ ] Warning icon in menu bar (exclamationmark.bubble)
- [ ] Warning dismisses when user clicks Dismiss
- [ ] New audio segment files appear in session directory (-2 suffix)
- [ ] Stop recording — both segments are transcribed

## Flow C: XPC Crash, UI Alive
- [ ] Start recording
- [ ] Kill XPC service: `kill -9 $(pgrep -f audio-capture-helper-xpc)`
- [ ] UI shows "Recording briefly interrupted" warning
- [ ] Notification appears: "Recording Resumed"
- [ ] New audio segment files appear (-2 suffix)
- [ ] Recording continues (menu still shows recording state)
- [ ] Stop recording — both segments are transcribed

## Multi-Segment Transcription
- [ ] After a crash-recovered recording with 2+ segments:
- [ ] Output JSON contains text from all segments
- [ ] Segments are sorted by timestamp
- [ ] No missing audio between segments (only ~1s gap)

## LaunchAgent
- [ ] `ls ~/Library/LaunchAgents/com.audio-transcribe.app.plist` exists after first launch
- [ ] Quit app — plist is removed
- [ ] Relaunch app — plist is re-created

## WAV File Integrity
- [ ] After killing XPC during recording, check WAV files are valid:
  - `file ~/.audio-transcribe/.../*.wav` should show "RIFF (little-endian) data, WAVE audio"
  - File size should be > 44 bytes (not just header)

## Model download (Settings save — eager download)
- [ ] Select FluidAudio in Settings — hint reads "Model will download ~500MB when you save" (if not yet cached)
- [ ] Click Save — progress bar + live % appear; Save button disabled during download
- [ ] After download: hint changes to "Model downloaded" (green checkmark)
- [ ] Re-open Settings — hint shows "Model ready" (already cached; no re-download on next Save)
- [ ] Start a recording right after Save — no download delay at recording start or transcription end
- [ ] Diarization models included in download (no lazy download during transcription)

## Edge Cases
- [ ] Reboot machine, then launch app — stale sentinel is cleaned up (no recovery attempt)
- [ ] Start recording, immediately Cmd+Q — clean exit, no restart

## Mic Indicator (menu bar)
- [ ] Mic indicator visible when idle — shows "System Default" or saved device name
- [ ] Mic indicator visible while recording
- [ ] Mic indicator visible while transcribing
- [ ] Shows correct device name after selecting a non-default mic in a prior session
- [ ] Clicking when idle: panel opens with "Set Default" button; selecting a different device + clicking "Set Default" persists to config (reopen menu to verify name updated)
- [ ] Clicking when idle: Cancel closes panel without changing config
- [ ] Clicking when recording: panel opens with "Switch" button; selecting a different device + clicking "Switch" hot-swaps the mic live
- [ ] Clicking when transcribing: panel opens with "Set Default" button (same as idle)
- [ ] Level meter is active in the picker panel (breathe into mic to verify)
- [ ] "Change Microphone..." menu item is gone (was recording-only, now replaced)

## VAD Quality Filter
- [ ] Record with background music → verify music segments filtered, not labeled as speaker
- [ ] Record meeting with long muted period → verify silence doesn't create phantom speaker
- [ ] Record with keyboard noise → verify clicks filtered from transcript
- [ ] Record normal meeting → verify no real speech segments lost (false negative check)
- [ ] Set vad_speech_threshold to 0.0 in config → verify VAD filtering disabled, all segments present
- [ ] Delete VAD model from cache → verify graceful degradation (no crash, no filtering)
- [ ] Check rename dialog → verify filtered segments don't appear as speaker samples
