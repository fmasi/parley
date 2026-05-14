# XPC Crash Resilience + Critical Error Visibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent silent recording loss by adding auto-retry on XPC crash and unmissable critical error alerts when retry fails.

**Architecture:** Add `criticalError` property to AppState with highest-priority icon. Add retry counter to crash handler in MenuView. Move sentinel write before `startCapture`. Send `.critical` notification when retry exhausted.

**Tech Stack:** Swift, SwiftUI, UserNotifications, Swift Testing

---

### Task 1: Add `criticalError` to AppState + icon priority

**Files:**
- Modify: `TranscriberCore/AppState.swift:25-68`
- Test: `SwiftTests/TranscriberTests/AppStateTests.swift`

- [ ] **Step 1: Write failing tests for criticalError**

Add these tests at the end of `AppStateTests.swift`:

```swift
// MARK: - Critical error

@Test func criticalErrorChangesIconToFilledTriangle() {
    let state = AppState()
    state.criticalError = "Recording failed"
    #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
}

@Test func criticalErrorTakesPriorityOverRegularError() {
    let state = AppState()
    state.errorMessage = "Regular error"
    state.criticalError = "Critical error"
    #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
}

@Test func criticalErrorTakesPriorityOverRecordingPhase() {
    let state = AppState()
    state.phase = .recording(since: Date())
    state.criticalError = "Recording failed"
    #expect(state.menuBarIcon == "exclamationmark.triangle.fill")
}

@Test func clearingCriticalErrorRestoresNormalIcon() {
    let state = AppState()
    state.criticalError = "Recording failed"
    state.criticalError = nil
    #expect(state.menuBarIcon == "mic")
}

@Test func criticalErrorIsNilInitially() {
    let state = AppState()
    #expect(state.criticalError == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
swift test --filter TranscriberTests.AppStateTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```
Expected: Compilation error — `criticalError` property does not exist.

- [ ] **Step 3: Add `criticalError` property and update `menuBarIcon`**

In `TranscriberCore/AppState.swift`, add the property after `interruptionWarning` (line 25):

```swift
/// Non-nil when recording failed unrecoverably (e.g. XPC crash with failed retry).
/// Shown as a critical alert in the menu. Stays until user explicitly dismisses.
public var criticalError: String?
```

Update `menuBarIcon` computed property to check `criticalError` first (highest priority):

```swift
public var menuBarIcon: String {
    if criticalError != nil { return "exclamationmark.triangle.fill" }
    if errorMessage != nil { return "exclamationmark.triangle" }
    switch phase {
    case .idle: return "mic"
    case .recording:
        if interruptionWarning != nil { return "exclamationmark.bubble" }
        return "microphone.and.signal.meter.fill"
    case .transcribing: return "hourglass"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
swift test --filter TranscriberTests.AppStateTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```
Expected: All AppStateTests pass (existing + new).

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AppState.swift SwiftTests/TranscriberTests/AppStateTests.swift
git commit -m "feat: add criticalError to AppState with highest-priority icon"
```

---

### Task 2: Show critical error in MenuView with dismiss button

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift:14-22`

- [ ] **Step 1: Add critical error section to MenuView**

In `MenuView.swift`, add a critical error block *before* the existing `interruptionWarning` block (line 14). This ensures it appears at the top of the menu:

```swift
if let critical = appState.criticalError {
    Button("🔴 \(critical)") {}
        .disabled(true)
    Button("Acknowledge") {
        appState.criticalError = nil
    }
    Divider()
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
swift build
```
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: show critical error with dismiss in menu dropdown"
```

---

### Task 3: Add `sendCriticalNotification` helper to MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift:312-328`

- [ ] **Step 1: Add the critical notification helper**

Add this method after the existing `sendNotification` method in `MenuView.swift`:

```swift
private func sendCriticalNotification(title: String, body: String) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    Logger.state.error("CRITICAL: \(title, privacy: .public) — \(body, privacy: .public)")
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .defaultCritical
    content.interruptionLevel = .critical
    let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error {
            Logger.state.error("Critical notification failed: \(error, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
swift build
```
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: add sendCriticalNotification helper for .critical alerts"
```

---

### Task 4: Add retry logic to XPC crash handler

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift:244-281`

- [ ] **Step 1: Add retry counter property to MenuView**

Add a `@State` property to `MenuView` (after the existing properties, around line 12):

```swift
@State private var xpcRetryCount = 0
```

- [ ] **Step 2: Reset retry counter on successful recording start**

In `startRecording(sessionName:microphoneDeviceId:)`, after `appState.phase = .recording(since: Date())` (line 147), add:

```swift
xpcRetryCount = 0
```

- [ ] **Step 3: Rewrite `handleXPCCrash` with retry logic**

Replace the entire `handleXPCCrash` method with:

```swift
private func handleXPCCrash(appState: AppState, captureClient: AudioCaptureClient) async {
    xpcRetryCount += 1
    Logger.state.warning("XPC crash during recording — attempt \(xpcRetryCount) of 2")

    guard let sentinel = RecordingSentinel.read() else {
        Logger.state.error("No sentinel found during crash recovery")
        appState.criticalError = "Recording failed — no recovery data available."
        appState.phase = .idle
        sendCriticalNotification(
            title: "Recording Failed",
            body: "Microphone capture crashed. No recovery data found."
        )
        return
    }

    let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
    let seg = sentinel.segment + 1
    let baseName = segmentBaseName(originalPath: sentinel.systemAudioPath, segment: seg)

    let newSentinel = sentinel.incrementedSegment(
        systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
        micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
    )

    do {
        try await captureClient.start(
            outputDirectory: outputDir,
            baseName: baseName,
            microphoneDeviceId: sentinel.micDeviceUID
        )
        try RecordingSentinel.write(newSentinel)
        appState.interruptionWarning = "Recording briefly interrupted. Resuming."
        sendNotification(
            title: "Recording Resumed",
            body: "Recording was briefly interrupted and has been restarted."
        )
    } catch {
        if xpcRetryCount < 2 {
            Logger.state.warning("Retry \(xpcRetryCount) failed, will retry on next crash: \(error, privacy: .public)")
            appState.interruptionWarning = "Recording interrupted — retrying..."
        } else {
            Logger.state.error("All retries exhausted: \(error, privacy: .public)")
            appState.criticalError = "Recording failed — microphone capture crashed and could not restart."
            appState.phase = .idle
            RecordingSentinel.delete()
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed after retry. Your recording may be incomplete."
            )
        }
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
swift build
```
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: XPC crash retry (1 attempt) with critical alert on exhaustion"
```

---

### Task 5: Move sentinel write before `startCapture`

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift:91-153`

- [ ] **Step 1: Move sentinel write before `captureClient.start`**

In `startRecording(sessionName:microphoneDeviceId:)`, restructure the `do` block so the sentinel is written before `startCapture`. Move the sentinel creation and write above the `captureClient.start` call:

Replace the current `do { ... } catch { ... }` block (lines 121-152) with:

```swift
do {
    let sentinel = RecordingSentinel(
        startedAt: Date(),
        sessionName: sanitized.isEmpty ? "Recording" : sessionName,
        systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
        micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path,
        micDeviceUID: microphoneDeviceId,
        segment: 1,
        chunkIndex: 0
    )
    try RecordingSentinel.write(sentinel)

    try await captureClient.start(
        outputDirectory: outputDir,
        baseName: baseName,
        microphoneDeviceId: microphoneDeviceId
    )

    try transcriptionRunner.setupChunkedPipeline(
        captureClient: captureClient,
        outputDirectory: outputDir,
        sessionBaseName: chunkBaseName,
        config: config
    )
    transcriptionRunner.startChunkRotation()

    appState.phase = .recording(since: Date())
    xpcRetryCount = 0
} catch {
    RecordingSentinel.delete()
    appState.errorMessage = error.localizedDescription
    sendNotification(title: "Recording Failed", body: error.localizedDescription)
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
swift build
```
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "fix: write sentinel before startCapture to cover instant XPC crash"
```

---

### Task 6: Update static crash handler in TranscriberApp to use critical error

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift:164-210`

The static `setupCrashHandler` in `TranscriberApp.swift` is used during app-launch recovery (Flow A/B). It should also escalate to `criticalError` on failure instead of just `errorMessage`.

- [ ] **Step 1: Update the catch block in `setupCrashHandler`**

In `TranscriberApp.swift`, replace the catch block in `setupCrashHandler` (lines 203-207):

Old:
```swift
} catch {
    appState.errorMessage = "Recording lost — failed to restart: \(error.localizedDescription)"
    appState.phase = .idle
    RecordingSentinel.delete()
}
```

New:
```swift
} catch {
    Logger.state.error("Recovery crash handler failed: \(error, privacy: .public)")
    appState.criticalError = "Recording failed — capture crashed and could not restart."
    appState.phase = .idle
    RecordingSentinel.delete()

    if Bundle.main.bundleIdentifier != nil {
        let content = UNMutableNotificationContent()
        content.title = "Recording Failed"
        content.body = "Capture crashed during recovery and could not restart."
        content.sound = .defaultCritical
        content.interruptionLevel = .critical
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
swift build
```
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/TranscriberApp.swift
git commit -m "feat: escalate to criticalError in static recovery crash handler"
```

---

### Task 7: Run full test suite

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run:
```bash
swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```
Expected: All tests pass (existing + 5 new AppState tests).

- [ ] **Step 2: Verify build for all targets**

Run:
```bash
swift build
```
Expected: Clean build.
