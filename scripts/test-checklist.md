# Test Checklist — Engine Abstraction + FluidAudio Integration

## Settings
- [ ] Engine picker shows all available engines (FluidAudio, WhisperCpp, SpeechAnalyzer on macOS 26+)
- [ ] Switching engine persists to config.json
- [ ] Output Format picker still works (txt/srt/json)

## Transcription (FluidAudio engine)
- [ ] Record a short clip (15-30s) with system audio, stop recording
- [ ] Status shows "Transcribing..." during processing
- [ ] `.json` file appears in recording folder
- [ ] Format file (`.srt` or `.txt`) appears alongside JSON
- [ ] JSON segments have timestamps, speaker labels, and text
- [ ] Segments include `"confidence"` field (float from FluidAudio)
- [ ] Rename speakers dialog opens after transcription
- [ ] Play button works in rename dialog
- [ ] After rename → format file updated with new speaker names

## Dual-stream (system + mic)
- [ ] Record with both system audio and mic
- [ ] JSON shows segments from both streams with source tags (Remote/Local)
- [ ] Mic audio transcribed with correct AudioSource (check log for "source: microphone")
- [ ] System audio transcribed with correct AudioSource (check log for "source: system")

## Diarization (FluidAudio)
- [ ] Multi-speaker recording produces distinct Speaker 1, Speaker 2, etc.
- [ ] Diarization quality scores logged (check log stream)

## Text Normalization (ITN)
- [ ] Numbers spoken as words appear as digits in transcript (e.g. "two hundred" → "200")
- [ ] Check log for "ITN applied to N segments" (or absent if native lib unavailable — still OK)

## Logging (check via `log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug`)
- [ ] "Loading FluidAudio model (Parakeet)..." on first transcription
- [ ] "FluidAudio already loaded" on subsequent transcriptions
- [ ] "FluidAudio complete: N segments in Xs (confidence: X.XX)" with timing
- [ ] "FluidAudio diarization complete: N segments, M speakers" after diarization
- [ ] "JSON transcript written" line
- [ ] "Format file written" line (if output_format is srt/txt)

## Model download (first run)
- [ ] FluidAudio Parakeet model downloads automatically on first transcription (~500MB)
- [ ] Diarization models download automatically on first use (~10MB)
