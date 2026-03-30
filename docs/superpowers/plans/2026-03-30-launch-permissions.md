# Launch Permissions Setup Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a setup window at launch that gates the app until Microphone and Screen Recording permissions are granted, replacing the current scattered permission requests.

**Architecture:** New `PermissionManager` (@Observable) in TranscriberCore checks/requests all four permissions. New `SetupView` + `SetupWindowController` in TranscriberApp present the setup UI. `TranscriberApp.swift` gates the MenuBarExtra behind a `permissionsReady` flag.

**Tech Stack:** SwiftUI, AppKit (NSWindow), AVFoundation, ScreenCaptureKit, EventKit, UserNotifications, Swift Testing

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `TranscriberCore/PermissionManager.swift` | Create | Check + request all 4 permissions, publish statuses |
| `SwiftTests/TranscriberTests/PermissionManagerTests.swift` | Create | Unit tests for PermissionManager logic |
| `TranscriberApp/Views/SetupView.swift` | Create | SwiftUI setup window content |
| `TranscriberApp/Services/SetupWindowController.swift` | Create | NSWindow controller for setup window |
| `TranscriberApp/TranscriberApp.swift` | Modify | Launch gating, remove old permission requests |
| `TranscriberApp/Services/CalendarService.swift` | Modify | Remove `requestAccess()` |

---

### Task 1: PermissionManager — Status Enum and Protocol

**Files:**
- Create: `TranscriberCore/PermissionManager.swift`
- Create: `SwiftTests/TranscriberTests/PermissionManagerTests.swift`

The PermissionManager needs to call system APIs (AVCaptureDevice, SCShareableContent, etc.) which can't run in unit tests. We define a `PermissionChecker` protocol so tests can inject a mock.

- [ ] **Step 1: Write failing tests for PermissionStatus and allRequiredGranted**

```swift
// SwiftTests/TranscriberTests/PermissionManagerTests.swift
import Testing
@testable import TranscriberCore

struct PermissionManagerTests {

    // MARK: - PermissionStatus

    @Test func authorizedIsGranted() {
        #expect(PermissionStatus.authorized.isGranted == true)
    }

    @Test func notDeterminedIsNotGranted() {
        #expect(PermissionStatus.notDetermined.isGranted == false)
    }

    @Test func deniedIsNotGranted() {
        #expect(PermissionStatus.denied.isGranted == false)
    }

    // MARK: - allRequiredGranted
    // These tests are async because screenRecording and notifications
    // require async checks — init leaves them as .notDetermined.

    @Test func allRequiredGrantedWhenBothAuthorized() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .authorized,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == true)
    }

    @Test func allRequiredNotGrantedWhenMicMissing() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .authorized,
            calendar: .authorized,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }

    @Test func allRequiredNotGrantedWhenScreenRecordingMissing() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .denied,
            calendar: .authorized,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }

    @Test func allRequiredNotGrantedWhenBothMissing() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .notDetermined,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()
        #expect(manager.allRequiredGranted == false)
    }
}

// MARK: - Mock

struct MockPermissionChecker: PermissionChecking {
    var microphone: PermissionStatus
    var screenRecording: PermissionStatus
    var calendar: PermissionStatus
    var notifications: PermissionStatus

    func checkMicrophone() -> PermissionStatus { microphone }
    func checkScreenRecording() async -> PermissionStatus { screenRecording }
    func checkCalendar() -> PermissionStatus { calendar }
    func checkNotifications() async -> PermissionStatus { notifications }

    func requestMicrophone() async -> PermissionStatus { microphone }
    func requestScreenRecording() async -> PermissionStatus { screenRecording }
    func requestCalendar() async -> PermissionStatus { calendar }
    func requestNotifications() async -> PermissionStatus { notifications }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/
```

Expected: compilation errors — `PermissionStatus`, `PermissionChecking`, `PermissionManager` not defined.

- [ ] **Step 3: Implement PermissionStatus, PermissionChecking protocol, and PermissionManager**

```swift
// TranscriberCore/PermissionManager.swift
import Foundation
import Observation

public enum PermissionStatus: Sendable {
    case authorized
    case notDetermined
    case denied

    public var isGranted: Bool { self == .authorized }
}

public protocol PermissionChecking: Sendable {
    func checkMicrophone() -> PermissionStatus
    func checkScreenRecording() async -> PermissionStatus
    func checkCalendar() -> PermissionStatus
    func checkNotifications() async -> PermissionStatus

    func requestMicrophone() async -> PermissionStatus
    func requestScreenRecording() async -> PermissionStatus
    func requestCalendar() async -> PermissionStatus
    func requestNotifications() async -> PermissionStatus
}

@Observable
public final class PermissionManager {
    public var microphone: PermissionStatus = .notDetermined
    public var screenRecording: PermissionStatus = .notDetermined
    public var calendar: PermissionStatus = .notDetermined
    public var notifications: PermissionStatus = .notDetermined

    private let checker: PermissionChecking

    public init(checker: PermissionChecking) {
        self.microphone = checker.checkMicrophone()
        self.screenRecording = .notDetermined
        self.calendar = checker.checkCalendar()
        self.notifications = .notDetermined
    }

    public var allRequiredGranted: Bool {
        microphone.isGranted && screenRecording.isGranted
    }

    public func checkAll() async {
        microphone = checker.checkMicrophone()
        screenRecording = await checker.checkScreenRecording()
        calendar = checker.checkCalendar()
        notifications = await checker.checkNotifications()
    }

    public func requestMicrophone() async {
        microphone = await checker.requestMicrophone()
    }

    public func requestScreenRecording() async {
        screenRecording = await checker.requestScreenRecording()
    }

    public func requestCalendar() async {
        calendar = await checker.requestCalendar()
    }

    public func requestNotifications() async {
        notifications = await checker.requestNotifications()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/
```

Expected: all PermissionManagerTests pass, existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/PermissionManager.swift SwiftTests/TranscriberTests/PermissionManagerTests.swift
git commit -m "feat: add PermissionManager with status enum, protocol, and tests"
```

---

### Task 2: PermissionManager — checkAll() Tests

**Files:**
- Modify: `SwiftTests/TranscriberTests/PermissionManagerTests.swift`

- [ ] **Step 1: Add tests for checkAll()**

Append to `PermissionManagerTests`:

```swift
    // MARK: - checkAll

    @Test func checkAllUpdatesAllStatuses() async {
        let checker = MockPermissionChecker(
            microphone: .authorized,
            screenRecording: .authorized,
            calendar: .denied,
            notifications: .authorized
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()

        #expect(manager.microphone == .authorized)
        #expect(manager.screenRecording == .authorized)
        #expect(manager.calendar == .denied)
        #expect(manager.notifications == .authorized)
    }

    @Test func checkAllWithNothingGranted() async {
        let checker = MockPermissionChecker(
            microphone: .notDetermined,
            screenRecording: .notDetermined,
            calendar: .notDetermined,
            notifications: .notDetermined
        )
        let manager = PermissionManager(checker: checker)
        await manager.checkAll()

        #expect(manager.microphone == .notDetermined)
        #expect(manager.screenRecording == .notDetermined)
        #expect(manager.calendar == .notDetermined)
        #expect(manager.notifications == .notDetermined)
        #expect(manager.allRequiredGranted == false)
    }
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/
```

Expected: all tests pass (implementation from Task 1 already covers this).

- [ ] **Step 3: Commit**

```bash
git add SwiftTests/TranscriberTests/PermissionManagerTests.swift
git commit -m "test: add checkAll() tests for PermissionManager"
```

---

### Task 3: SystemPermissionChecker — Real Implementation

**Files:**
- Create: `TranscriberApp/Services/SystemPermissionChecker.swift`

This is the real checker that calls macOS system APIs. It lives in `TranscriberApp` (not `TranscriberCore`) because it imports AVFoundation, ScreenCaptureKit, EventKit, and UserNotifications which shouldn't be dependencies of the core library. No unit tests — these are thin wrappers around system APIs; tested manually.

- [ ] **Step 1: Implement SystemPermissionChecker**

```swift
// TranscriberApp/Services/SystemPermissionChecker.swift
import AVFoundation
import EventKit
import ScreenCaptureKit
import TranscriberCore
import UserNotifications

struct SystemPermissionChecker: PermissionChecking {
    func checkMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func checkScreenRecording() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            return .authorized
        } catch {
            let desc = "\(error)"
            if desc.contains("notAuthorized") || desc.contains("denied") {
                return .denied
            }
            return .notDetermined
        }
    }

    func checkCalendar() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func checkNotifications() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    func requestScreenRecording() async -> PermissionStatus {
        await checkScreenRecording()
    }

    func requestCalendar() async -> PermissionStatus {
        let store = EKEventStore()
        do {
            try await store.requestFullAccessToEvents()
            return .authorized
        } catch {
            return .denied
        }
    }

    func requestNotifications() async -> PermissionStatus {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/SystemPermissionChecker.swift
git commit -m "feat: add SystemPermissionChecker for real macOS permission APIs"
```

---

### Task 4: SetupView

**Files:**
- Create: `TranscriberApp/Views/SetupView.swift`

- [ ] **Step 1: Implement SetupView**

```swift
// TranscriberApp/Views/SetupView.swift
import SwiftUI
import TranscriberCore

struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let onReady: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Audio Transcribe needs a few permissions to work")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    detail: "Record your voice during meetings",
                    status: permissionManager.microphone,
                    onGrant: { Task { await permissionManager.requestMicrophone() } }
                )

                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    name: "Screen Recording",
                    detail: "Capture system audio from meeting apps",
                    status: permissionManager.screenRecording,
                    onGrant: { Task {
                        await permissionManager.requestScreenRecording()
                        // Screen Recording may require relaunch; re-check after a delay
                        try? await Task.sleep(for: .seconds(1))
                        await permissionManager.checkAll()
                    }}
                )

                Divider()

                Text("Optional")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                PermissionRow(
                    icon: "calendar",
                    name: "Calendar",
                    detail: "Suggest recording name from current meeting",
                    status: permissionManager.calendar,
                    onGrant: { Task { await permissionManager.requestCalendar() } }
                )

                PermissionRow(
                    icon: "bell.fill",
                    name: "Notifications",
                    detail: "Alert you when transcription finishes",
                    status: permissionManager.notifications,
                    onGrant: { Task { await permissionManager.requestNotifications() } }
                )
            }

            HStack {
                Spacer()
                Button("Continue") { onReady() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissionManager.allRequiredGranted)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct PermissionRow: View {
    let icon: String
    let name: String
    let detail: String
    let status: PermissionStatus
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Grant") { onGrant() }
                .controlSize(.small)
        case .denied:
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SetupView.swift
git commit -m "feat: add SetupView with permission rows and Continue button"
```

---

### Task 5: SetupWindowController

**Files:**
- Create: `TranscriberApp/Services/SetupWindowController.swift`

Follows the same pattern as `SessionNameWindowController.swift`.

- [ ] **Step 1: Implement SetupWindowController**

```swift
// TranscriberApp/Services/SetupWindowController.swift
import AppKit
import SwiftUI
import TranscriberCore

@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show(permissionManager: PermissionManager, onReady: @escaping () -> Void) {
        window?.close()

        let closeWindow = { [weak self] in
            self?.window?.close()
            self?.window = nil
        }

        let view = SetupView(permissionManager: permissionManager) {
            closeWindow()
            onReady()
        }

        let newWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Audio Transcribe Setup"
        newWindow.contentView = NSHostingView(rootView: view)
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/SetupWindowController.swift
git commit -m "feat: add SetupWindowController for permission setup window"
```

---

### Task 6: Wire Up TranscriberApp Launch Gating

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift`
- Modify: `TranscriberApp/Services/CalendarService.swift`
- [ ] **Step 1: Update TranscriberApp.swift**

Replace the entire file content:

```swift
// TranscriberApp/TranscriberApp.swift
import SwiftUI
import TranscriberCore

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    @State private var permissionsReady = false
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
    private let permissionManager: PermissionManager

    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            if permissionsReady {
                MenuView(
                    appState: appState,
                    captureClient: captureClient,
                    transcriptionRunner: transcriptionRunner,
                    configManager: configManager,
                    calendarService: calendarService
                )
            } else {
                Button("Setup required...") {}
                    .disabled(true)
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }

    private func showSetupIfNeeded() {
        Task {
            await permissionManager.checkAll()
            if permissionManager.allRequiredGranted {
                permissionsReady = true
            } else {
                SetupWindowController.shared.show(
                    permissionManager: permissionManager
                ) {
                    permissionsReady = true
                }
            }
        }
    }
}
```

Note: `showSetupIfNeeded()` needs to be called when the app appears. Since `MenuBarExtra` doesn't have `onAppear`, we trigger it from a task in init or via `NSApplication` delegate. The simplest approach: call it at the end of `init()`.

Update `init()` to:

```swift
    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
        // Permission check + setup window shown after app launches
        Task { @MainActor in
            await permissionManager.checkAll()
            if permissionManager.allRequiredGranted {
                permissionsReady = true
            } else {
                SetupWindowController.shared.show(
                    permissionManager: permissionManager
                ) {
                    permissionsReady = true
                }
            }
        }
    }
```

Remove `showSetupIfNeeded()` as a separate method since the logic lives in init's Task. The final file:

```swift
import SwiftUI
import TranscriberCore

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    @State private var permissionsReady = false
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
    private let permissionManager: PermissionManager

    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
        Task { @MainActor in
            await permissionManager.checkAll()
            if permissionManager.allRequiredGranted {
                permissionsReady = true
            } else {
                SetupWindowController.shared.show(
                    permissionManager: permissionManager
                ) {
                    permissionsReady = true
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            if permissionsReady {
                MenuView(
                    appState: appState,
                    captureClient: captureClient,
                    transcriptionRunner: transcriptionRunner,
                    configManager: configManager,
                    calendarService: calendarService
                )
            } else {
                Button("Setup required...") {}
                    .disabled(true)
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }
}
```

- [ ] **Step 2: Remove `requestAccess()` from CalendarService.swift**

Remove the `requestAccess()` method entirely (lines 8-11). The file becomes:

```swift
import EventKit
import TranscriberCore

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func currentEventTitle(from calendars: [EKCalendar]? = nil) -> String? {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(1 * 3600),
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        let current = events.filter { $0.startDate <= now && $0.endDate > now }

        let notDeclined = current.filter { event in
            guard let attendees = event.attendees else { return true }
            let selfAttendee = attendees.first { $0.isCurrentUser }
            guard let me = selfAttendee else { return true }
            return me.participantStatus != .declined
        }

        return CalendarEventPicker.bestCurrentEvent(from: notDeclined)?.title
    }
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests to verify nothing broke**

```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/
```

Expected: all tests pass (including new PermissionManager tests and existing 61 tests).

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/TranscriberApp.swift TranscriberApp/Services/CalendarService.swift
git commit -m "feat: gate app launch on required permissions via setup window"
```

---

### Task 7: Manual Testing Before PR

**Files:** None — manual verification only.

This task MUST be performed by the user on a real macOS machine. The engineer should provide these instructions and wait for confirmation before proceeding to any push/PR.

- [ ] **Step 1: Build the app bundle**

```bash
swift build
```

- [ ] **Step 2: Provide manual test checklist to user**

Ask the user to verify each of these scenarios:

1. **Fresh launch (reset TCC if possible):** Setup window appears showing all four permissions with "Grant" buttons
2. **Grant Microphone:** Click "Grant" for Microphone — system dialog appears, after granting, badge shows green checkmark
3. **Grant Screen Recording:** Click "Grant" for Screen Recording — system dialog appears (may require System Settings navigation), badge updates
4. **Continue button:** Disabled until both Mic + Screen Recording show green checkmarks. Optional permissions (Calendar, Notifications) don't affect the button.
5. **Click Continue:** Setup window closes, menu bar shows normal "Start Recording" UI
6. **Recording works:** Start and stop a recording to verify audio capture still works end-to-end
7. **Subsequent launch:** Quit and relaunch — no setup window, straight to normal menu bar
8. **Permission revocation (if testable):** Revoke Screen Recording in System Settings, relaunch — setup window reappears

- [ ] **Step 3: Wait for user confirmation**

Do not push or create a PR until the user confirms all manual tests pass.

---

### Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add SetupWindowController and PermissionManager to architecture docs**

Add under the SwiftUI App section, after the SessionNameWindowController entry:

```markdown
- `TranscriberApp/Services/SetupWindowController.swift` -- opens permission setup window as NSWindow at launch
```

Add under the TranscriberCore target section:

```markdown
- `TranscriberCore/PermissionManager.swift` -- @Observable permission status tracker with PermissionChecking protocol
```

Add to Key Gotchas:

```markdown
11. Screen Recording has no requestAuthorization API — trigger system prompt via SCShareableContent.excludingDesktopWindows(...) and check result
12. All required permissions (Mic, Screen Recording) are gated at launch via SetupWindowController — don't add scattered permission requests elsewhere
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add PermissionManager and SetupWindowController to CLAUDE.md"
```
