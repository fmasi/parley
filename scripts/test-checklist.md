# Test Checklist — v0.7.x branch

## Version Infrastructure (#42 + #33)
- [ ] About menu item visible between Settings and Quit
- [ ] Click "About Audio Transcribe" — native About panel appears
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
- [ ] `AudioTranscribe transcribe -i file.m4a` — prompts for stereo channel handling
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
- [ ] `AudioTranscribe transcribe -i file.m4a` — splits and processes stereo AAC
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

## Regression
- [ ] Start recording, stop, transcription completes
- [ ] Settings save and reload correctly
- [ ] App survives quit and relaunch (LaunchAgent)

## Model manifest
- [ ] Settings: "Check for model updates online" toggle visible (between Transcription Engine and Recording sections) and OFF by default
- [ ] Toggle persists across app restart
- [ ] With toggle ON, "Check now" button appears
- [ ] "Check now" reports a status within 10s and stays under the toggle
- [ ] Launch log contains a "Manifest verify:" line within a few seconds of startup (subsystem com.audio-transcribe.app, category transcription)
- [ ] After deleting a file from the FluidAudio cache root (returned by `AsrModels.defaultCacheDirectory()`), next launch logs `Manifest verify: ... file(s) corrupt -- ...` or `... missing ...`
