# Test Checklist — Crash Recovery

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

## Edge Cases
- [ ] Reboot machine, then launch app — stale sentinel is cleaned up (no recovery attempt)
- [ ] Start recording, immediately Cmd+Q — clean exit, no restart
