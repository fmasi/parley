# Calendar-Based Session Naming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a session naming dialog (pre-populated from the user's calendar) before recording starts.

**Architecture:** A new `CalendarService` queries EventKit for the current meeting title. A `SessionNameDialog` view displays in an `NSPanel` (via `SessionNameWindowController`). `MenuView` orchestrates: calendar lookup → dialog → start recording.

**Tech Stack:** Swift, SwiftUI, EventKit, AppKit (NSPanel), XCTest

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `TranscriberApp/Services/CalendarService.swift` | EventKit queries, filtering, tiebreaker |
| Create | `TranscriberApp/Views/SessionNameDialog.swift` | SwiftUI view: text field + Start/Cancel |
| Create | `TranscriberApp/Services/SessionNameWindowController.swift` | Opens SessionNameDialog as NSPanel |
| Create | `Tests/TranscriberTests/CalendarServiceTests.swift` | Unit tests for calendar filtering logic |
| Modify | `TranscriberApp/Views/MenuView.swift` | Wire up dialog before recording |
| Modify | `TranscriberApp/TranscriberApp.swift` | Create CalendarService, request access |
| Modify | `TranscriberApp/Models/AppState.swift` | Add `lastJsonPath`, remove `showRenameSheet` |
| Modify | `packaging/Info.plist` | Add `NSCalendarsUsageDescription` |
| Modify | `Package.swift` | Add test target |
| Modify | `CLAUDE.md` | Document CalendarService in architecture |

---

### Task 0: Clean up prior incorrect changes

**Files:**
- Delete: `TranscriberApp/Views/SessionNameDialog.swift`
- Delete: `TranscriberApp/Services/SessionNameWindowController.swift`
- Revert: `TranscriberApp/Views/MenuView.swift` (to committed state)
- Revert: `TranscriberApp/Models/AppState.swift` (to committed state)
- Keep: `TranscriberApp/Services/RenameWindowController.swift` (new, correct)
- Keep: `TranscriberApp/Views/RenameDialog.swift` (modified, correct)
- Keep: `TranscriberApp/Services/TranscriptionRunner.swift` (modified, correct)

- [ ] **Step 1: Delete the incorrectly created files**

```bash
rm TranscriberApp/Views/SessionNameDialog.swift
rm TranscriberApp/Services/SessionNameWindowController.swift
```

- [ ] **Step 2: Revert MenuView.swift to committed state**

```bash
git checkout HEAD -- TranscriberApp/Views/MenuView.swift
```

- [ ] **Step 3: Revert AppState.swift to committed state**

```bash
git checkout HEAD -- TranscriberApp/Models/AppState.swift
```

- [ ] **Step 4: Verify build still passes**

```bash
swift build
```

Expected: Build complete with no errors.

- [ ] **Step 5: Commit the cleanup**

```bash
git add -A
git commit -m "chore: clean up incorrect session naming attempt

Revert MenuView and AppState to committed state.
Delete placeholder SessionNameDialog and SessionNameWindowController.
Keep correct RenameWindowController, RenameDialog, TranscriptionRunner fixes."
```

---

### Task 1: Add test target to Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Tests/TranscriberTests/` (directory)

- [ ] **Step 1: Add testTarget to Package.swift**

Add a `.testTarget` for `TranscriberTests` that depends on no app targets (CalendarService will be tested via `@testable import` once we restructure, but for now we'll put the pure logic in a testable function within the test file and later move it into CalendarService).

Actually — since `TranscriberApp` is an `.executableTarget`, we can't `@testable import` it directly. Instead, extract the pure filtering logic into a standalone function inside `CalendarService.swift` that takes `[EKEvent]` and returns `EKEvent?`. The test target will import `EventKit` directly and test a copied version of that logic.

Better approach: create a lightweight `TranscriberCore` library target for testable logic, with `CalendarService` in it.

Add to `Package.swift`:

```swift
.target(
    name: "TranscriberCore",
    path: "TranscriberCore"
),
```

And update the `TranscriberApp` target to depend on it:

```swift
.executableTarget(
    name: "TranscriberApp",
    dependencies: ["AudioCaptureProtocol", "SettingsAccess", "TranscriberCore"],
    path: "TranscriberApp"
),
```

And add the test target:

```swift
.testTarget(
    name: "TranscriberTests",
    dependencies: ["TranscriberCore"],
    path: "Tests/TranscriberTests"
),
```

The full `Package.swift` becomes:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "AudioTranscribe", targets: ["TranscriberApp"]),
        .executable(name: "audio-capture-helper-xpc", targets: ["AudioCaptureHelperXPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/SettingsAccess", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AudioCaptureProtocol",
            path: "AudioCaptureProtocol"
        ),
        .target(
            name: "TranscriberCore",
            path: "TranscriberCore"
        ),
        .executableTarget(
            name: "TranscriberApp",
            dependencies: ["AudioCaptureProtocol", "SettingsAccess", "TranscriberCore"],
            path: "TranscriberApp"
        ),
        .executableTarget(
            name: "AudioCaptureHelperXPC",
            dependencies: ["AudioCaptureProtocol"],
            path: "AudioCaptureHelper/XPC"
        ),
        .testTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore"],
            path: "Tests/TranscriberTests"
        ),
    ]
)
```

- [ ] **Step 2: Create TranscriberCore directory with placeholder**

```bash
mkdir -p TranscriberCore
mkdir -p Tests/TranscriberTests
```

Create `TranscriberCore/CalendarEventPicker.swift` with just enough to compile:

```swift
import EventKit

public enum CalendarEventPicker {
    /// Picks the best current event from a list.
    /// Filters out all-day events and declined events.
    /// Tiebreaker: most recently started.
    public static func bestCurrentEvent(from events: [EKEvent]) -> EKEvent? {
        nil // TDD — will implement after tests
    }
}
```

- [ ] **Step 3: Verify build passes**

```bash
swift build
```

Expected: Build complete.

- [ ] **Step 4: Commit**

```bash
git add Package.swift TranscriberCore/ Tests/
git commit -m "chore: add TranscriberCore library target and test target"
```

---

### Task 2: TDD — CalendarEventPicker filtering logic

**Files:**
- Test: `Tests/TranscriberTests/CalendarEventPickerTests.swift`
- Modify: `TranscriberCore/CalendarEventPicker.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/TranscriberTests/CalendarEventPickerTests.swift`:

```swift
import XCTest
import EventKit
@testable import TranscriberCore

final class CalendarEventPickerTests: XCTestCase {
    private let store = EKEventStore()

    private func makeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false
    ) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        return event
    }

    // MARK: - Empty input

    func testEmptyArrayReturnsNil() {
        let result = CalendarEventPicker.bestCurrentEvent(from: [])
        XCTAssertNil(result)
    }

    // MARK: - All-day filter

    func testFiltersOutAllDayEvents() {
        let allDay = makeEvent(
            title: "Holiday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay])
        XCTAssertNil(result)
    }

    func testKeepsNonAllDayEvents() {
        let meeting = makeEvent(
            title: "Standup",
            startDate: Date().addingTimeInterval(-1800),
            endDate: Date().addingTimeInterval(1800)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [meeting])
        XCTAssertEqual(result?.title, "Standup")
    }

    // MARK: - Tiebreaker: most recently started

    func testPicksMostRecentlyStartedEvent() {
        let earlier = makeEvent(
            title: "Earlier Meeting",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(1800)
        )
        let later = makeEvent(
            title: "Later Meeting",
            startDate: Date().addingTimeInterval(-600),
            endDate: Date().addingTimeInterval(3000)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [earlier, later])
        XCTAssertEqual(result?.title, "Later Meeting")
    }

    // MARK: - Mixed: all-day + timed

    func testFiltersAllDayAndPicksTimed() {
        let allDay = makeEvent(
            title: "Birthday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let timed = makeEvent(
            title: "Sprint Review",
            startDate: Date().addingTimeInterval(-900),
            endDate: Date().addingTimeInterval(2700)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay, timed])
        XCTAssertEqual(result?.title, "Sprint Review")
    }

    // MARK: - All filtered out

    func testAllEventsFilteredReturnsNil() {
        let allDay1 = makeEvent(
            title: "Holiday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let allDay2 = makeEvent(
            title: "Birthday",
            startDate: Date().addingTimeInterval(-7200),
            endDate: Date().addingTimeInterval(7200),
            isAllDay: true
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay1, allDay2])
        XCTAssertNil(result)
    }
}
```

Note: We cannot set `participantStatus` on `EKEvent` in unit tests (it's read-only, determined by the event store). The declined-event filter will be tested by verifying the code path exists, and validated manually. The `bestCurrentEvent` method will accept pre-filtered events, and the declined filter will happen in `CalendarService` at query time.

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter TranscriberTests 2>&1
```

Expected: Tests compile but `testKeepsNonAllDayEvents`, `testPicksMostRecentlyStartedEvent`, `testFiltersAllDayAndPicksTimed` fail (because `bestCurrentEvent` returns `nil`).

- [ ] **Step 3: Implement CalendarEventPicker**

Update `TranscriberCore/CalendarEventPicker.swift`:

```swift
import EventKit

public enum CalendarEventPicker {
    /// Picks the best current event from a list.
    /// Filters out all-day events.
    /// Tiebreaker: most recently started.
    ///
    /// Declined events should be filtered out by the caller at query time
    /// (via EKEventStore predicate or attendee check), since participantStatus
    /// is not settable in tests.
    public static func bestCurrentEvent(from events: [EKEvent]) -> EKEvent? {
        events
            .filter { !$0.isAllDay }
            .max { $0.startDate < $1.startDate }
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter TranscriberTests 2>&1
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/CalendarEventPicker.swift Tests/TranscriberTests/CalendarEventPickerTests.swift
git commit -m "feat: CalendarEventPicker with TDD — filter all-day, pick most recent"
```

---

### Task 3: CalendarService (EventKit integration)

**Files:**
- Create: `TranscriberApp/Services/CalendarService.swift`

- [ ] **Step 1: Create CalendarService**

Create `TranscriberApp/Services/CalendarService.swift`:

```swift
import EventKit
import TranscriberCore

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() {
        Task {
            try? await store.requestFullAccessToEvents()
        }
    }

    func currentEventTitle(from calendars: [EKCalendar]? = nil) -> String? {
        let now = Date()
        // Search a window around now to catch events that started recently
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(1 * 3600),
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        // Filter to events happening right now
        let current = events.filter { $0.startDate <= now && $0.endDate > now }

        // Filter out declined events
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

- [ ] **Step 2: Verify build passes**

```bash
swift build
```

Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/CalendarService.swift
git commit -m "feat: CalendarService with EventKit lookup and declined-event filter"
```

---

### Task 4: SessionNameDialog view

**Files:**
- Create: `TranscriberApp/Views/SessionNameDialog.swift`

- [ ] **Step 1: Create the SwiftUI dialog view**

Create `TranscriberApp/Views/SessionNameDialog.swift`:

```swift
import SwiftUI

struct SessionNameDialog: View {
    @State private var name: String
    @FocusState private var focused: Bool

    let onStart: (String) -> Void
    let onCancel: () -> Void

    init(
        suggestedName: String,
        onStart: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._name = State(initialValue: suggestedName)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name This Recording")
                .font(.headline)

            TextField("e.g. Weekly standup", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { start() }

            Text("Leave blank to use a timestamp.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func start() {
        onStart(name.trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 2: Verify build passes**

```bash
swift build
```

Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SessionNameDialog.swift
git commit -m "feat: SessionNameDialog SwiftUI view with text field and callbacks"
```

---

### Task 5: SessionNameWindowController

**Files:**
- Create: `TranscriberApp/Services/SessionNameWindowController.swift`

- [ ] **Step 1: Create the window controller**

Create `TranscriberApp/Services/SessionNameWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class SessionNameWindowController {
    static let shared = SessionNameWindowController()
    private var panel: NSPanel?

    func show(suggestedName: String?, onStart: @escaping (String) -> Void) {
        panel?.close()

        let closePanel = { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = SessionNameDialog(
            suggestedName: suggestedName ?? "",
            onStart: { name in
                closePanel()
                onStart(name)
            },
            onCancel: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "New Recording"
        newPanel.contentView = NSHostingView(rootView: dialog)
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
    }
}
```

- [ ] **Step 2: Verify build passes**

```bash
swift build
```

Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/SessionNameWindowController.swift
git commit -m "feat: SessionNameWindowController opens naming dialog as NSPanel"
```

---

### Task 6: Wire up MenuView recording flow

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`
- Modify: `TranscriberApp/Models/AppState.swift`
- Modify: `TranscriberApp/TranscriberApp.swift`

- [ ] **Step 1: Update AppState — add lastJsonPath, remove showRenameSheet**

Replace the full content of `TranscriberApp/Models/AppState.swift`:

```swift
import Foundation
import SwiftUI

@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case transcribing(progress: String)
    }

    var phase: Phase = .idle
    var lastTranscriptPath: String?
    var lastJsonPath: String?
    var errorMessage: String?

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    var menuBarIcon: String {
        switch phase {
        case .idle: return "mic"
        case .recording: return "record.circle"
        case .transcribing: return "hourglass"
        }
    }

    var recordingToggleLabel: String {
        switch phase {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing..."
        }
    }
}
```

- [ ] **Step 2: Update TranscriberApp.swift — add CalendarService**

Replace the full content of `TranscriberApp/TranscriberApp.swift`:

```swift
import SwiftUI
import UserNotifications

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()

    init() {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            ) { _, _ in }
        }
        calendarService.requestAccess()
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            MenuView(
                appState: appState,
                captureClient: captureClient,
                transcriptionRunner: transcriptionRunner,
                configManager: configManager,
                calendarService: calendarService
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }
}
```

- [ ] **Step 3: Update MenuView.swift — full rewrite with calendar + dialog flow**

Replace the full content of `TranscriberApp/Views/MenuView.swift`:

```swift
import SwiftUI
import SettingsAccess
import UserNotifications

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager
    let calendarService: CalendarService

    var body: some View {
        Button(appState.recordingToggleLabel) {
            Task { await toggleRecording() }
        }
        .disabled(appState.isTranscribing)

        Divider()

        Button("Open Recordings Folder") {
            let dir = URL(fileURLWithPath: configManager.config.recordingDirectory)
            NSWorkspace.shared.open(dir)
        }

        Button("Rename Speakers...") {
            if let jsonPath = appState.lastJsonPath {
                RenameWindowController.shared.show(jsonPath: URL(fileURLWithPath: jsonPath))
            }
        }
        .disabled(!appState.isIdle || appState.lastJsonPath == nil)

        SettingsLink {
            Text("Settings...")
        } preAction: {
        } postAction: {
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await stopRecording()
        } else if appState.isIdle {
            promptAndStartRecording()
        }
    }

    private func promptAndStartRecording() {
        let suggestedName = calendarService.currentEventTitle()
        SessionNameWindowController.shared.show(suggestedName: suggestedName) { sessionName in
            Task { await startRecording(sessionName: sessionName) }
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        var sanitized = name
        for char in ["/", ":", "\0"] {
            sanitized = sanitized.replacingOccurrences(of: char, with: "")
        }
        return sanitized
    }

    private func startRecording(sessionName: String) async {
        let config = configManager.config
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timestamp = timeFormatter.string(from: Date())

        let sanitized = sanitizeFilename(sessionName)
        let baseName = sanitized.isEmpty ? timestamp : "\(timestamp)-\(sanitized)"

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(dayDir)

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName
            )
            appState.phase = .recording(since: Date())
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let paths = try await captureClient.stop()
            appState.phase = .transcribing(progress: "Transcribing...")

            let config = configManager.config
            let result = try await transcriptionRunner.run(
                systemAudio: paths.systemAudio,
                micAudio: paths.micAudio,
                outputFormat: config.outputFormat,
                outputDirectory: paths.systemAudio.deletingLastPathComponent()
            )

            appState.lastTranscriptPath = result.outputPath.path
            appState.lastJsonPath = result.jsonPath?.path
            appState.phase = .idle
            sendNotification(path: result.outputPath)

            if let jsonPath = result.jsonPath {
                RenameWindowController.shared.show(jsonPath: jsonPath)
            }
        } catch {
            appState.errorMessage = error.localizedDescription
            appState.phase = .idle
        }
    }

    private func sendNotification(path: URL) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = path.lastPathComponent
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 4: Verify build passes**

```bash
swift build
```

Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Models/AppState.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat: wire calendar lookup and session naming dialog into recording flow"
```

---

### Task 7: Add NSCalendarsUsageDescription to Info.plist

**Files:**
- Modify: `packaging/Info.plist`

- [ ] **Step 1: Add calendar usage description**

Add the following key-value pair inside the `<dict>` in `packaging/Info.plist`, after the `NSMicrophoneUsageDescription` entry:

```xml
    <key>NSCalendarsUsageDescription</key>
    <string>Audio Transcribe uses your calendar to suggest a name for the recording based on your current meeting.</string>
```

- [ ] **Step 2: Commit**

```bash
git add packaging/Info.plist
git commit -m "feat: add NSCalendarsUsageDescription to Info.plist"
```

---

### Task 8: Update documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add CalendarService and SessionNameDialog to CLAUDE.md architecture**

In the `### SwiftUI App (TranscriberApp target)` section of `CLAUDE.md`, add these lines after the `TranscriberApp/Services/TranscriptionRunner.swift` entry:

```
- `TranscriberApp/Services/CalendarService.swift` -- EventKit lookup for current meeting title
- `TranscriberApp/Services/SessionNameWindowController.swift` -- opens session naming dialog as NSPanel
- `TranscriberApp/Views/SessionNameDialog.swift` -- session naming prompt before recording
```

Also add `TranscriberCore` as a new section after `### Shared Protocol`:

```
### Shared Logic (TranscriberCore target)
- `TranscriberCore/CalendarEventPicker.swift` -- pure logic: filter all-day events, pick most recent by start time
```

In the `## Key Gotchas` section, add:

```
9. MenuBarExtra with `.menu` style cannot present sheets — use NSPanel via window controllers
10. Calendar access requires `NSCalendarsUsageDescription` in Info.plist and `requestFullAccessToEvents()` at launch
```

- [ ] **Step 2: Verify the build still passes**

```bash
swift build && swift test --filter TranscriberTests
```

Expected: Build and tests pass.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CalendarService, SessionNameDialog, TranscriberCore to CLAUDE.md"
```

---

## Self-Review

**Spec coverage:**
- CalendarService with EventKit lookup → Task 3
- Filter all-day events → Task 2 (CalendarEventPicker)
- Filter declined events → Task 3 (CalendarService query)
- Tiebreaker: most recent start → Task 2 (CalendarEventPicker)
- SessionNameDialog view → Task 4
- SessionNameWindowController NSPanel → Task 5
- MenuView recording flow change → Task 6
- App entry point CalendarService init → Task 6
- Info.plist calendar description → Task 7
- Filename sanitization → Task 6 (sanitizeFilename in MenuView)
- Undo prior changes → Task 0
- Future extensibility (calendars parameter) → built into CalendarService API
- Documentation update → Task 8

**Placeholder scan:** No TBDs, TODOs, or vague steps. All code blocks are complete.

**Type consistency:**
- `CalendarEventPicker.bestCurrentEvent(from:)` — consistent in Task 2 (tests + impl) and Task 3 (caller)
- `CalendarService.currentEventTitle(from:)` — consistent in Task 3 (def) and Task 6 (caller)
- `SessionNameDialog(suggestedName:onStart:onCancel:)` — consistent in Task 4 (def) and Task 5 (caller)
- `SessionNameWindowController.shared.show(suggestedName:onStart:)` — consistent in Task 5 (def) and Task 6 (caller)
- `AppState.lastJsonPath` — consistent in Task 6 (AppState def and MenuView usage)

All clear.
