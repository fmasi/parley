# Calendar-Based Session Naming

## Problem

When the user clicks "Start Recording", recording begins immediately with a timestamp-based filename. There is no opportunity to name the recording. The user wants a prompt that pre-populates with the current calendar event name.

## Solution

Add a session naming dialog that appears before recording starts, pre-populated with the current calendar meeting title via EventKit.

## Components

### 1. CalendarService (`TranscriberApp/Services/CalendarService.swift`)

A standalone service that owns an `EKEventStore` and provides calendar event lookup.

**API:**
- `requestAccess()` — calls `EKEventStore.requestFullAccessToEvents()`. Called once at app launch.
- `currentEventTitle(from calendars: [EKCalendar]?) -> String?` — queries events happening at `Date()`.

**Query logic:**
- Predicate: `startDate <= now <= endDate` across provided calendars (or all if `nil`)
- Filter out: `isAllDay == true`
- Filter out: events where self is an attendee with `participantStatus == .declined`
- Tiebreaker: pick event with most recent `startDate` (the meeting you most likely just joined)
- Returns `event.title` or `nil`

**Future extensibility:** The `calendars` parameter accepts `nil` (all calendars) today. Later, `Config` gains a `calendarIdentifiers: [String]` field, and callers resolve those to `[EKCalendar]` before passing them in.

### 2. SessionNameDialog (`TranscriberApp/Views/SessionNameDialog.swift`)

A SwiftUI view presenting the naming prompt.

- Text field pre-populated with the calendar event title (or empty if none)
- Hint: "Leave blank to use a timestamp"
- Two buttons: "Cancel" (aborts) and "Start Recording" (proceeds)
- Text field auto-focused, Enter triggers "Start Recording"
- Callbacks: `onStart: (String) -> Void`, `onCancel: () -> Void`

### 3. SessionNameWindowController (`TranscriberApp/Services/SessionNameWindowController.swift`)

Opens `SessionNameDialog` as a standalone `NSPanel`. Required because `MenuBarExtra` with `.menu` style cannot present sheets.

- `show(suggestedName: String?, onStart: (String) -> Void)` — creates a floating HUD panel
- Centers and activates the panel
- Closes on Start or Cancel

Same pattern as `RenameWindowController`.

### 4. Recording Flow Changes (`TranscriberApp/Views/MenuView.swift`)

**Current:** click "Start Recording" -> immediately starts capturing with timestamp filename.

**New:**
1. User clicks "Start Recording"
2. `MenuView` calls `CalendarService.currentEventTitle()` for a suggested name
3. `SessionNameWindowController.show(suggestedName:)` opens the dialog
4. User edits or accepts, clicks "Start Recording"
5. Recording begins with filename `<timestamp>-<session-name>` (e.g. `143022-Weekly Standup.wav`)
6. If user left name blank, filename is just `<timestamp>`
7. If user clicks "Cancel", nothing happens

**Filename sanitization:** Strip `/`, `:`, and `\0` from the session name. Spaces and other punctuation are fine on APFS.

### 5. App Entry Point Changes (`TranscriberApp/TranscriberApp.swift`)

- Create `CalendarService` instance
- Call `CalendarService.requestAccess()` in `init()` alongside existing notification permission request
- Pass `CalendarService` to `MenuView`

### 6. Info.plist Change

Add `NSCalendarsUsageDescription`:
> "Audio Transcribe uses your calendar to suggest a name for the recording based on your current meeting."

## Undo Prior Changes

My earlier attempts left files that need cleanup:

**Delete (will be recreated properly):**
- `TranscriberApp/Views/SessionNameDialog.swift`
- `TranscriberApp/Services/SessionNameWindowController.swift`

**Revert to committed state:**
- `TranscriberApp/Views/MenuView.swift`
- `TranscriberApp/Models/AppState.swift`

**Keep (correct fixes from earlier):**
- `TranscriberApp/Services/RenameWindowController.swift` — fixes rename dialog presentation via NSPanel
- `TranscriberApp/Views/RenameDialog.swift` — `onCancel` callback replacing broken `@Environment(\.dismiss)`
- `TranscriberApp/Services/TranscriptionRunner.swift` — derive JSON path from audio filename instead of parsing stdout

## Out of Scope

- Calendar selection in Settings (deferred — `nil` means all calendars for now)
- Speaker rename auto-trigger after transcription (separate concern, already wired)
- Any changes to Python scripts

## Implementation Notes

- Use TDD: write tests for `CalendarService` logic before implementation
- Use subagents for parallel independent work
- Update CLAUDE.md and README if architecture section needs it
- No upstream pushes without explicit user approval
