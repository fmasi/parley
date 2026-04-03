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
