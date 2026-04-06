# Test Checklist — v0.7.x

## Echo Deduplication
- [ ] Record with YouTube on speakers (no headphones), speak a few sentences
- [ ] After transcription, check logs: `log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug | grep "Echo dedup"`
- [ ] Verify embedding scores visible (not `<private>`) — should show cosine values
- [ ] Verify your speech preserved (Local Speaker segments with your words in transcript)
- [ ] Verify YouTube bleed removed (`echo_segments_removed > 0` in JSON metadata)
- [ ] Open transcript JSON — confirm no local segments contain text identical to remote segments

## Summary Generation
- [ ] Verify LM Studio running with model loaded (or OpenAI endpoint configured)
- [ ] After transcription + rename dialog, verify summary auto-generates
- [ ] Check `-summary.md` file created alongside transcript
- [ ] For dual-stream: verify transcript sent to LLM includes `(local)`/`(remote)` labels
- [ ] Review summary — no echo content attributed to local speakers

## Rename Dialog
- [ ] After transcription, rename dialog appears
- [ ] Play button works — audio plays through both speakers (mono extraction)
- [ ] Correct channel: local speaker plays mic audio, remote speaker plays system audio
- [ ] Multiple samples: forward button cycles through samples
- [ ] Rename and save — verify names updated in JSON and SRT/TXT

## CLI AAC Re-processing
- [ ] `AudioTranscribe transcribe -i file.m4a` — splits and processes stereo AAC
- [ ] `--debug` flag streams logs to stderr
- [ ] Echo dedup runs (check `echo_segments_removed` in output JSON)
- [ ] Output JSON written to same directory as input (or `--output-dir`)

## Audio Archive
- [ ] Record a meeting (system + mic), verify `.m4a` created after transcription
- [ ] Verify `.m4a` is stereo (L=mic, R=system)
- [ ] Verify source WAV files deleted after successful archival
- [ ] Verify transcript JSON `audio_paths` points to `.m4a`

## Chunked Recording
- [ ] Start recording — verify chunk-0 files created with `-0` suffix
- [ ] Wait past chunk duration (set to 1min for testing) — verify rotation in logs
- [ ] Stop after rotation — verify final transcript has speech from both chunks
- [ ] Speaker labels consistent across chunks in final transcript

## Regression
- [ ] Start recording, stop, verify transcription completes
- [ ] Rename dialog works after transcription
- [ ] Settings save and reload correctly
- [ ] XPC crash during recording — verify recovery
