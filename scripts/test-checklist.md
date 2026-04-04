# Test Checklist — v0.6.0

## Audio Archive
- [ ] Record a meeting (system + mic), verify .m4a created after transcription
- [ ] Verify .m4a is stereo (L=mic, R=system) — play in QuickTime, check both channels
- [ ] Verify source WAV files are deleted after successful archival
- [ ] Verify transcript JSON audio_paths points to .m4a after archival
- [ ] Open rename dialog after archival — verify speaker samples play correctly
- [ ] Change archive bitrate in Settings, record again, verify file size matches expected bitrate
- [ ] Set archive limit to 1 hour, record multiple sessions, verify oldest .m4a is cleaned up
- [ ] Verify transcript JSON/SRT/TXT files are never deleted by quota enforcement
- [ ] If archival fails (simulate by making output dir read-only), verify WAV files are preserved

## Audio Archive Settings
- [ ] Open Settings → Audio Archive section visible
- [ ] Bitrate picker shows 48/64/96/128 kbps options, default 64
- [ ] Archive limit stepper works, shows hours with MiB estimate
- [ ] Current usage displays correctly (0 MiB on fresh install)

## Chunked Recording
- [ ] Start recording — verify chunk-0 files created with `-0` suffix in output dir
- [ ] Wait past chunk duration (set to 1min for testing) — verify rotation in logs (new `-1` files)
- [ ] Stop after rotation — verify final transcript has all speech from both chunks
- [ ] Short meeting (< chunk duration) — verify single-chunk pipeline works identically
- [ ] Check session.json created during recording, deleted after transcription
- [ ] Check speaker labels consistent across chunks in final transcript
- [ ] Check absolute timestamps in transcript JSON (ISO 8601 `timestamp` field)
- [ ] Verify WAV files deleted after archival to AAC per chunk
- [ ] Verify log output shows chunk lifecycle events (`log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug`)
- [ ] Kill app mid-recording, relaunch — verify crash recovery reprocesses only missing chunks

## Regression
- [ ] Start recording, stop, verify transcription completes
- [ ] Rename dialog works after transcription
- [ ] XPC crash during recording — verify recovery and segment stitching still works
