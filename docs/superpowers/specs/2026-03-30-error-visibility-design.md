# Error Visibility in Menu Bar

## Problem

`AppState.errorMessage` is set on capture start failure and transcription failure but never displayed to the user. Failures are completely silent — the app returns to idle with no indication that anything went wrong.

## Design

### Error Display: Menu Items

When `appState.errorMessage` is non-nil, two items appear at the top of the menu:

```
⚠ Error: Transcription failed: model not found...
Dismiss Error
─────────────
Start Recording
─────────────
Open Recordings Folder
Rename Speakers...
Settings...
─────────────
Quit
```

- **Error label**: disabled `Button` (non-interactive text). Message truncated to 80 characters with "..." suffix if longer.
- **Dismiss Error**: clickable `Button` that sets `appState.errorMessage = nil`. Both items disappear.

### Error Display: System Notification

On error, fire a `UNUserNotificationCenter` notification using the same pattern as the existing success notification:

- **Title**: "Recording Failed" (capture start error) or "Transcription Failed" (transcription error)
- **Body**: the error message (untruncated — notifications handle overflow with expansion)

### Error Clearing

`errorMessage` is set to `nil` when:

1. User clicks "Dismiss Error" in the menu
2. A new recording starts (`startRecording()` sets `errorMessage = nil` before attempting capture)

### Error Sources

Two existing call sites already set `appState.errorMessage`:

1. `startRecording()` catch block (line 93) — capture client fails to start
2. `stopRecording()` catch block (line 121) — transcription runner fails

Each call site will also fire the appropriate notification.

## Files Changed

- `TranscriberApp/Views/MenuView.swift` — add error menu items, dismiss button, error notifications, auto-clear on start

## Not Changed

- `TranscriberCore/AppState.swift` — `errorMessage: String?` already exists, no modifications needed
