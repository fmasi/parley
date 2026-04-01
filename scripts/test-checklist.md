# Test Checklist — WhisperKit Migration

## Setup Flow
- [ ] Setup window shows "Transcription Model" section with Whisper Model row
- [ ] If model already downloaded → green checkmark shown
- [ ] If model not downloaded → "Download" button appears, downloads with progress bar
- [ ] "Continue" button disabled until permissions granted AND model downloaded

## Settings
- [ ] "Transcription Model" section shows model picker (Fast / High Quality)
- [ ] No HuggingFace Token field anywhere
- [ ] Output Format picker still works (txt/srt/json)

## Transcription (WhisperKit)
- [ ] Record a short clip (15-30s), stop recording
- [ ] Status shows "Transcribing..." during processing
- [ ] `.json` file appears in recording folder
- [ ] Format file (`.srt` or `.txt`) appears alongside JSON (matching output_format setting)
- [ ] JSON segments have clean text — no `<|startoftranscript|>` or `<|0.00|>` tokens
- [ ] Rename speakers dialog opens after transcription
- [ ] Play button works in rename dialog
- [ ] After rename → format file updated with new speaker names

## Logging (check in log stream)
- [ ] "Creating WhisperKitTranscriber" on first transcription
- [ ] "WhisperKit already loaded" on subsequent transcriptions (no 113s wait)
- [ ] "Transcription complete: N segments in Xs" with timing
- [ ] "JSON transcript written" line
- [ ] "Format file written" line (if output_format is srt/txt)
