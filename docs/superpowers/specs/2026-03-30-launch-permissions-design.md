# Launch Permissions Setup Window

## Problem

Microphone and Screen Recording permissions are requested lazily on first recording attempt. This means the first recording fails or feels clunky while the user navigates System Settings. Calendar and Notifications are already requested at launch, but the experience is inconsistent.

## Solution

Show a setup window at first launch (and whenever required permissions are missing) that guides the user through granting all permissions before the app becomes functional.

## Permissions

| Permission | Required | Check API | Request API |
|---|---|---|---|
| Microphone | Yes | `AVCaptureDevice.authorizationStatus(for: .audio)` | `AVCaptureDevice.requestAccess(for: .audio)` |
| Screen Recording | Yes | Attempt `SCShareableContent.excludingDesktopWindows(...)` | Same call triggers system prompt |
| Calendar | No | `EKEventStore.authorizationStatus(for: .event)` | `store.requestFullAccessToEvents()` |
| Notifications | No | `UNUserNotificationCenter.current().notificationSettings()` | `requestAuthorization(options:)` |

## Architecture

### New Files

**`TranscriberCore/PermissionManager.swift`**
- `@Observable` class with published status for each permission (authorized / notDetermined / denied)
- `checkAll()` async method to query current status of all four permissions
- Individual `requestMicrophone()`, `requestScreenRecording()`, `requestCalendar()`, `requestNotifications()` async methods
- `allRequiredGranted: Bool` computed property (mic + screen recording both authorized)
- Screen Recording check: call `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` in a do/catch. Success = authorized, specific errors = denied/not determined.

**`TranscriberApp/Views/SetupView.swift`**
- SwiftUI view shown in the setup window
- Title: "Audio Transcribe needs a few permissions to work"
- Vertical stack of permission rows, each with:
  - SF Symbol icon + permission name + one-line explanation
  - Status badge: checkmark (granted) / "Grant" button (not yet) / warning (denied, links to System Settings)
- Required permissions (Mic, Screen Recording) listed first
- Optional permissions (Calendar, Notifications) below a separator, labeled optional
- "Continue" button at bottom, disabled until `allRequiredGranted` is true
- Status badges update live as permissions change

**`TranscriberApp/Services/SetupWindowController.swift`**
- `NSWindow` controller, same pattern as `SessionNameWindowController`
- Centered, non-resizable window
- `show(onReady:)` method with callback when "Continue" is clicked

### Modified Files

**`TranscriberApp/TranscriberApp.swift`**
- Add `@State var permissionsReady: Bool` flag
- On init, check required permissions via `PermissionManager.checkAll()`
- If both required permissions granted: `permissionsReady = true`, skip setup window
- If not: show setup window, set `permissionsReady = true` on "Continue" callback
- Remove `UNUserNotificationCenter.requestAuthorization` from init
- Remove `calendarService.requestAccess()` from init
- `MenuBarExtra` body shows disabled "Setup required..." when `permissionsReady == false`, normal `MenuView` when true

**`TranscriberApp/Services/CalendarService.swift`**
- Remove `requestAccess()` method (now handled by PermissionManager)

## App Launch Flow

1. App starts, `PermissionManager.checkAll()` runs
2. If mic + screen recording both granted -> skip to step 5
3. Show setup window with all four permissions
4. User grants permissions via "Grant" buttons, status updates live
5. User clicks "Continue" (enabled once required permissions granted)
6. Setup window closes, `MenuBarExtra` shows normal `MenuView`
7. On subsequent launches, repeat from step 1 (transparent if permissions still granted)
8. If a required permission was revoked between launches, setup window reappears

## Testing

### Automated (unit tests)
- `PermissionManager` status-checking logic with protocol-based injection
- `allRequiredGranted` computed property logic
- Existing 61 tests unaffected

### Manual (user must verify before commit/PR)
The following require a real macOS environment with TCC dialogs:
1. Fresh launch with no permissions granted: setup window appears
2. Granting Microphone: status badge updates to checkmark
3. Granting Screen Recording: status badge updates to checkmark
4. "Continue" button enables only when both required permissions are granted
5. Optional permissions (Calendar, Notifications) can be skipped
6. After granting all required + clicking Continue: menu bar shows normal UI, recording works
7. Subsequent launch with permissions already granted: no setup window, straight to menu bar
8. Revoking a required permission in System Settings + relaunching: setup window reappears
