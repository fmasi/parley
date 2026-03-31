# Test Checklist

## Liquid Glass Dialog Shape
1. Click Start Recording — session name dialog appears with rounded rectangle glass (not oval)
2. Glass is flush at top (no gap with title bar), rounded at bottom

## Transcription + Rename Speakers
3. Stop a recording — status shows "Transcribing..." and stays for ~30s+
4. Transcription completes — `.json` + `.srt` file appear in recording folder
5. Rename speakers dialog auto-opens and **stays visible when clicked**
6. Each speaker shows **sample text** below their name
7. Each speaker has a **play button** — plays their first segment from the source WAV
8. "Rename Speakers..." menu item is enabled (not grayed out)
9. Click "Rename Speakers..." from menu — dialog opens reliably

## Error Visibility
- [ ] Kill transcribe.py mid-run → menu shows "⚠ Error: ..." + "Dismiss Error"
- [ ] Click "Dismiss Error" → error items disappear from menu
- [ ] Start new recording after error → error items auto-clear
- [ ] Error notification appears in Notification Center
- [ ] Success notification still appears after normal transcription

## Unified Logging
- [ ] Run `python scripts/dev.py --debug` — log stream starts after app launches
- [ ] Start recording — see "Recording started" and "Starting capture" in log stream
- [ ] Observe "System audio: ...Hz" and "Mic audio: ...Hz" format detection lines
- [ ] Stop recording — see "Stopping capture" and "Launching transcription" lines
- [ ] Python progress lines appear as `[python] Transcribing audio...` etc.
- [ ] Transcription completes — see duration in "Transcription complete" line
- [ ] Ctrl+C stops log stream; app keeps running
