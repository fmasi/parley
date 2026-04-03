# Test Checklist — Engine Abstraction + FluidAudio Integration

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

## Settings
- [ ] Engine picker shows all available engines (FluidAudio, SpeechAnalyzer on macOS 26+)
- [ ] Switching engine persists to config.json
- [ ] Output Format picker still works (txt/srt/json)

## Transcription (FluidAudio engine)
- [ ] Record a short clip (15-30s) with system audio, stop recording
- [ ] Status shows "Transcribing..." during processing
- [ ] `.json` file appears in recording folder
- [ ] Format file (`.srt` or `.txt`) appears alongside JSON
- [ ] JSON segments have timestamps, speaker labels, and text
- [ ] Segments include `"confidence"` field (float from FluidAudio)

## Rename Speakers Dialog
- [ ] Rename dialog opens after transcription
- [ ] Play button plays audio from the longest segment (not first segment)
- [ ] Forward button cycles through up to 3 sample clips per speaker
- [ ] Sample counter shows "1/3", "2/3", etc.
- [ ] Sample text updates when cycling
- [ ] Speakers with < 5 segments are hidden from dialog
- [ ] After rename, format file updated with new speaker names
- [ ] `rename-gui` CLI: `.build/debug/AudioTranscribe rename-gui -i <json>` opens GUI dialog

## Dual-stream (system + mic)
- [ ] Record with both system audio and mic
- [ ] JSON shows segments from both streams with source tags (Remote/Local)
- [ ] Mic audio transcribed with correct AudioSource (check log for "source: microphone")
- [ ] System audio transcribed with correct AudioSource (check log for "source: system")

## Diarization (FluidAudio)
- [ ] Multi-speaker recording produces distinct Speaker 1, Speaker 2, etc.
- [ ] Diarization quality scores logged (check log stream)
- [ ] On multi-remote-speaker calls, check that remote speakers are separated (not merged)

## Text Normalization (ITN)
- [ ] Numbers spoken as words appear as digits in transcript (e.g. "two hundred" -> "200")
- [ ] Check log for "ITN applied to N segments" (or absent if native lib unavailable — still OK)

## Logging (check via `log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug`)
- [ ] "Loading FluidAudio model (Parakeet)..." on first transcription
- [ ] "FluidAudio already loaded" on subsequent transcriptions
- [ ] "FluidAudio complete: N segments in Xs (confidence: X.XX)" with timing
- [ ] "FluidAudio diarization complete: N segments, M speakers" after diarization
- [ ] "JSON transcript written" line
- [ ] "Format file written" line (if output_format is srt/txt)

## Model download (Settings save — eager download)
- [ ] Select FluidAudio in Settings — hint reads "Model will download ~500MB when you save" (if not yet cached)
- [ ] Click Save — progress bar + live % appear; Save button disabled during download
- [ ] After download: hint changes to "Model downloaded" (green checkmark)
- [ ] Re-open Settings — hint shows "Model ready" (already cached; no re-download on next Save)
- [ ] Start a recording right after Save — no download delay at recording start or transcription end
- [ ] Diarization models still download automatically on first use (~10MB)
