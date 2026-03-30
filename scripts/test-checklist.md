# Test Checklist

## Liquid Glass Dialog Shape
1. Click Start Recording — session name dialog appears
2. Glass background is a **rounded rectangle**, not an oval/capsule
3. All content (title, text field, mic picker, buttons) is fully inside the glass
4. Cancel and re-open — shape is still correct

## Transcription + Rename Speakers
5. Stop a recording — status shows "Transcribing..." and stays for ~30s+ (not instant)
6. Transcription completes — `.json` + `.srt` file appear in recording folder
7. Rename speakers dialog auto-opens after transcription and **stays visible when clicked**
8. Each speaker shows **sample text** (first couple of quotes) below their name
9. Rename dialog glass background is a **rounded rectangle**, not an oval/capsule
10. "Rename Speakers..." menu item is enabled after transcription (not grayed out)
11. Click "Rename Speakers..." from menu — dialog opens reliably

## Microphone Picker
7. Click Start Recording — session name dialog appears
8. Mic dropdown shows "System Default" + all real input devices
9. Select a non-default mic — level meter shows input from THAT device only
10. Speak into selected mic — green/yellow bar animates
11. Click Start Recording — recording starts normally
12. Stop recording — transcription runs
13. Start another recording — last-used mic is pre-selected

## Recording end-to-end
14. Start/stop a recording with system default mic
15. Verify `_mic.wav` has audio from the correct device
16. Quit and relaunch — permissions still granted, no setup window
