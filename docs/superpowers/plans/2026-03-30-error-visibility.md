# Error Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make error messages visible to the user via menu bar items and system notifications.

**Architecture:** Add a `truncatedErrorMessage` computed property to `AppState` (testable), then update `MenuView` to show error/dismiss items and fire error notifications. Single-file UI change plus one small model addition.

**Tech Stack:** SwiftUI, Swift Testing, UNUserNotificationCenter

---

### Task 1: Add truncated error message to AppState (TDD)

**Files:**
- Modify: `TranscriberCore/AppState.swift`
- Modify: `SwiftTests/TranscriberTests/AppStateTests.swift`

- [ ] **Step 1: Write failing tests for `truncatedErrorMessage`**

Add to `SwiftTests/TranscriberTests/AppStateTests.swift`:

```swift
// MARK: - Truncated error message

@Test func truncatedErrorMessageIsNilWhenNoError() {
    let state = AppState()
    #expect(state.truncatedErrorMessage == nil)
}

@Test func truncatedErrorMessageReturnsShortMessagesUnchanged() {
    let state = AppState()
    state.errorMessage = "Connection refused"
    #expect(state.truncatedErrorMessage == "Connection refused")
}

@Test func truncatedErrorMessageTruncatesAt80Chars() {
    let state = AppState()
    state.errorMessage = String(repeating: "a", count: 100)
    let truncated = state.truncatedErrorMessage!
    #expect(truncated.count == 83) // 80 + "..."
    #expect(truncated.hasSuffix("..."))
}

@Test func truncatedErrorMessageExactly80CharsNotTruncated() {
    let state = AppState()
    state.errorMessage = String(repeating: "b", count: 80)
    #expect(state.truncatedErrorMessage == String(repeating: "b", count: 80))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriberTests.AppStateTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: FAIL — `truncatedErrorMessage` does not exist

- [ ] **Step 3: Implement `truncatedErrorMessage`**

Add to `TranscriberCore/AppState.swift`, inside the `AppState` class, after `errorMessage`:

```swift
public var truncatedErrorMessage: String? {
    guard let msg = errorMessage else { return nil }
    if msg.count <= 80 { return msg }
    return String(msg.prefix(80)) + "..."
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriberTests.AppStateTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AppState.swift SwiftTests/TranscriberTests/AppStateTests.swift
git commit -m "feat: add truncatedErrorMessage computed property to AppState"
```

---

### Task 2: Add error items to MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add error section at top of menu body**

In `TranscriberApp/Views/MenuView.swift`, replace the opening of `var body: some View {` with error items before the recording toggle. The full body becomes:

```swift
var body: some View {
    if let errorText = appState.truncatedErrorMessage {
        Button("⚠ \(errorText)") {}
            .disabled(true)
        Button("Dismiss Error") {
            appState.errorMessage = nil
        }
        Divider()
    }

    Button(appState.recordingToggleLabel) {
        Task { await toggleRecording() }
    }
    .disabled(appState.isTranscribing)

    // ... rest unchanged
```

- [ ] **Step 2: Clear error on new recording start**

In the `startRecording(sessionName:microphoneDeviceId:)` method, add `appState.errorMessage = nil` as the first line (before `configManager.update`):

```swift
private func startRecording(sessionName: String, microphoneDeviceId: String?) async {
    appState.errorMessage = nil

    // Persist the mic choice for next time
    configManager.update { $0.lastMicrophoneDeviceId = microphoneDeviceId }
    // ... rest unchanged
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: show error message and dismiss button in menu bar"
```

---

### Task 3: Add error notifications

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Extract notification helper and add error variant**

In `TranscriberApp/Views/MenuView.swift`, replace the existing `sendNotification(path:)` method with a general-purpose helper, then add calls at error sites:

```swift
private func sendNotification(title: String, body: String) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}
```

- [ ] **Step 2: Update success notification call**

In `stopRecording()`, replace the old `sendNotification(path:)` call:

```swift
// Old:
sendNotification(path: result.outputPath)

// New:
sendNotification(title: "Transcription Complete", body: result.outputPath.lastPathComponent)
```

- [ ] **Step 3: Add error notifications at both error sites**

In `startRecording`, update the catch block:

```swift
} catch {
    appState.errorMessage = error.localizedDescription
    sendNotification(title: "Recording Failed", body: error.localizedDescription)
}
```

In `stopRecording`, update the catch block:

```swift
} catch {
    appState.errorMessage = error.localizedDescription
    sendNotification(title: "Transcription Failed", body: error.localizedDescription)
    appState.phase = .idle
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: send system notifications on recording/transcription errors"
```

---

### Task 4: Update test checklist

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Add error visibility manual test items**

Add a new section to `scripts/test-checklist.md`:

```markdown
## Error Visibility
- [ ] Kill transcribe.py mid-run → menu shows "⚠ Error: ..." + "Dismiss Error"
- [ ] Click "Dismiss Error" → error items disappear from menu
- [ ] Start new recording after error → error items auto-clear
- [ ] Error notification appears in Notification Center
- [ ] Success notification still appears after normal transcription
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: add error visibility items to test checklist"
```
