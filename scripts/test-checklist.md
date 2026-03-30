# Test Checklist

## Microphone Picker
1. Click Start Recording — session name dialog appears
2. Mic dropdown shows "System Default" + all real input devices
3. Select a non-default mic — level meter shows input from THAT device only
4. Speak into selected mic — green/yellow bar animates
5. Click Start Recording — recording starts normally
6. Stop recording — transcription runs
7. Start another recording — last-used mic is pre-selected

## Recording end-to-end
8. Start/stop a recording with system default mic
9. Verify `_mic.wav` has audio from the correct device
10. Quit and relaunch — permissions still granted, no setup window
