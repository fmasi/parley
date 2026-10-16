# Meeting Sensing (#118) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a known meeting app (or browser) starts capturing the microphone, Parley *asks* the user to record — via a top-centre floating island, a menu-bar indicator and an in-menu banner — and, while recording, asks to stop when every watched call app has released the mic for 30 s. Never auto-records, never auto-stops, costs ~nothing when idle.

**Architecture:** A Core-Audio-only `MeetingSensor` (app layer, private serial queue) turns HAL listener wakes into coalesced `CaptureSnapshot`s (raw bundle IDs capturing input). A pure, value-typed `MeetingSenseEngine` (TranscriberCore) consumes snapshots + phase changes + the two user answers and emits actions. A `@MainActor MeetingPromptPresenter` (app layer) turns actions into the island / `AppState.detectedMeeting` and routes answers back, starting recordings through a hoisted `RecordingLauncher` → `RecordingCoordinator`.

**Tech Stack:** Swift 5.9 tools (language mode 5), Swift Testing (`@Test`/`#expect`, **not XCTest**), `@Observable`/`withObservationTracking`, CoreAudio HAL C API, AppKit `NSPanel` + `NSHostingView`, `os.Logger`/`OSSignposter`. No Xcode — CommandLineTools only.

**Spec:** `docs/superpowers/specs/2026-09-11-meeting-sensing-design.md` (rev 2, commit 8c86767). The plan argues from the spec; read both.

## Global Constraints

- **Never auto-record / auto-stop.** Every `startRecording`/`stopRecording` call traces to a user click (island, banner, menu). The engine only ever emits *offers*.
- **Performance target: MacBook Air M1 / 16 GB.** Idle = 0 timers, 0 periodic wakeups from sensing. Only one-shot timers (the 30 s stop debounce; the island's 20 s collapse while an offer is showing). Nothing on the main thread touches the HAL or EventKit. Per audio event: ≤ 1 coalesced scan on the sensor queue.
- **Airgap:** local Core Audio + process metadata only. No network, no calendar as a trigger (calendar is only used to *name* a recording the user chose to start).
- **Less code wins.** Reuse: `SessionNameWindowController` (panel pattern), `MicCaptureSession` (HAL listener pattern, `AudioObjectAddPropertyListenerBlock` with a retained block on a private queue), `ResumeOnce` (bounded await), `AlertBanner`/`MenuActionRow` (design system), the `RecordingCoordinatorTests` `Harness` + `FakeCaptureClient`.
- **Bundle IDs:** app `eu.fmasi.parley`, XPC helper `eu.fmasi.parley.capture-helper` (`AudioCaptureProtocol.swift:75`). Prefix `eu.fmasi.parley` is always excluded from classification.
- **Config key:** `meeting_sensing` ∈ {`off`, `prompt`}, default `prompt` when absent. Settings are Save-applied.
- **Tests** live in `SwiftTests/TranscriberTests/` (NOT `Tests/`). Only `TranscriberCore` is importable from tests; app-target files (`TranscriberApp/…`) are compile-checked with `swift build` and verified on device.
- **Commands (verbatim, from the repo root of this worktree):**
  - Unit tests (this is the invocation that works from the CLI; plain `swift test` fails with `no such module 'Testing'`):
    ```bash
    swift test --filter TranscriberTests \
      -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
    ```
    Narrow to one suite by adding a second `--filter <SuiteName>` (regex over test IDs), e.g. `--filter MeetingSenseEngineTests`. CI (`.github/workflows/test.yml:129`) runs the same with `--no-parallel`. Below, "**RUN TESTS**" means this command (with the suite filter named in the step).
  - App compile check (executable targets are not built by `swift test`): `swift build`
  - Device build + install + launch (resets TCC, re-grant on first launch): `python3 scripts/dev.py`; with log tail: `python3 scripts/dev.py --debug`
  - Log stream: `/usr/bin/log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug`
- **Commits:** one local commit per task, on `feature/meeting-sensing-118`. Do not push. Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_011vj2XghNE4QiT9up6d3eAQ
  ```
- **Red-first CI gate:** the PR's changed test files must FAIL at the merge base and PASS at HEAD. Every code task here starts with a failing test, so this holds naturally.
- **Do not merge until v0.9.0 is tagged.** This is a MINOR (v0.10.0): a new capability.

---

## File Structure

| Action | Path | Responsibility |
|---|---|---|
| Rename + rewrite | `TranscriberCore/MeetingSenseDecider.swift` → `TranscriberCore/MeetingSenseEngine.swift` | `MeetingSenseMode` (kept), `MeetingSensePhase`, `CaptureSnapshot`, `MeetingSenseInput`, `MeetingSenseAction`, `MeetingSenseState`, `MeetingSenseEngine.step` — pure |
| Create | `TranscriberCore/MeetingApps.swift` | `MeetingApp` value + `MeetingApps.classify(bundleID:)` — reviewable data |
| Rename + rewrite | `SwiftTests/TranscriberTests/MeetingSenseDeciderTests.swift` → `MeetingSenseEngineTests.swift` | engine rules |
| Create | `SwiftTests/TranscriberTests/MeetingAppsTests.swift` | classification table |
| Modify | `TranscriberCore/RecordingCoordinator.swift:179-258` | `startInFlight` + idle guard, `startRecording` returns `Bool` |
| Modify | `SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift` | concurrent-start test, fake gains an async start hook |
| Modify | `TranscriberCore/Config.swift`, `SwiftTests/TranscriberTests/ConfigTests.swift` | `meetingSensing` key |
| Modify | `TranscriberCore/AppState.swift`, `SwiftTests/TranscriberTests/AppStateTests.swift` | `DetectedMeeting`, `detectedMeeting`, icon |
| Modify | `TranscriberCore/ResumeOnce.swift` | make `public` (the app target needs it for the bounded calendar lookup) |
| Modify | `TranscriberApp/Services/CalendarService.swift` | async, bounded (≤ 1 s), off main |
| Create | `TranscriberApp/Services/RecordingLauncher.swift` | `selectedMicId`, `promptAndStart()`, `quickStart(app:calendarTitle:)` |
| Modify | `TranscriberApp/TranscriberApp.swift`, `TranscriberApp/Views/MenuView.swift` | hoist coordinator + launcher; presenter wiring; banner |
| Create | `TranscriberApp/Services/MeetingSensor.swift` | the only Core Audio code; listeners + coalesced scan |
| Create | `TranscriberApp/Services/MeetingIslandController.swift` | the non-activating top-centre `NSPanel` |
| Create | `TranscriberApp/Views/MeetingIslandView.swift` | expanded/compact pill, one primary button + chevron menu |
| Create | `TranscriberApp/Services/MeetingPromptPresenter.swift` | actions → UI, answers → engine, queued start, observation loops |
| Modify | `TranscriberApp/Views/SettingsView.swift`, `TranscriberApp/Views/SetupView.swift` | toggle + disclosure copy |
| Modify | `docs/parameters.md`, `scripts/test-checklist.md`, `docs/gotchas.md` (if Task 0 teaches one), `README.md`, `CLAUDE.md` | docs, device checklist, test badge/count |

**Interfaces shared across tasks (exact names — later tasks depend on them):**

```swift
// TranscriberCore/MeetingApps.swift (Task 1)
public struct MeetingApp: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case native, browser }
    public let id: String          // canonical family id, e.g. "us.zoom.xos"
    public let displayName: String // "Zoom"
    public let kind: Kind
}
public enum MeetingApps {
    public static let ownPrefix = "eu.fmasi.parley"
    public static func classify(bundleID: String) -> MeetingApp?
}

// TranscriberCore/MeetingSenseEngine.swift (Task 2)
public enum MeetingSenseMode: String, Codable, Equatable, Sendable { case off, prompt }   // kept
public enum MeetingSensePhase: Equatable, Sendable { case idle, recording, transcribing }
public struct CaptureSnapshot: Equatable, Sendable { public var capturingBundleIDs: Set<String> }
public enum MeetingSenseInput: Equatable, Sendable {
    case snapshot(CaptureSnapshot), phaseChanged(MeetingSensePhase), notNow, keepRecording
}
public enum MeetingSenseAction: Equatable, Sendable {
    case offerStart(MeetingApp, expand: Bool), withdrawStart
    case offerStop(MeetingApp), withdrawStop
    case watch(bundleIDs: Set<String>)         // raw bundle IDs the sensor holds per-process listeners on
    case scheduleScan(after: TimeInterval)     // one-shot; the sensor runs an ordinary scan when it fires
}
public struct MeetingSenseState: Equatable, Sendable { … public init() }
public enum MeetingSenseEngine {
    public static let expansionCooldown: TimeInterval = 300
    public static let stopDebounce: TimeInterval = 30
    public static func step(_ state: MeetingSenseState, input: MeetingSenseInput,
                            mode: MeetingSenseMode, now: Date) -> (state: MeetingSenseState, actions: [MeetingSenseAction])
}

// TranscriberCore/RecordingCoordinator.swift (Task 3)
@discardableResult public func startRecording(sessionName: String, microphoneDeviceId: String?) async -> Bool

// TranscriberCore/Config.swift (Task 4)
public var meetingSensing: MeetingSenseMode   // key "meeting_sensing", default .prompt

// TranscriberCore/AppState.swift (Task 4)
public struct DetectedMeeting: Equatable, Sendable { public enum Kind { case start, queued, stop }; public let app: MeetingApp; public let kind: Kind }
public var detectedMeeting: DetectedMeeting?

// TranscriberApp/Services/CalendarService.swift (Task 5)
func currentEventTitle(lookaheadMinutes: Int = 10, timeout: TimeInterval = 1) async -> String?

// TranscriberApp/Services/RecordingLauncher.swift (Task 6)
@MainActor @Observable final class RecordingLauncher {
    var selectedMicId: String?
    func promptAndStart() async
    func quickStart(app: MeetingApp, calendarTitle: String?) async -> Bool
}

// TranscriberApp/Services/MeetingSensor.swift (Task 7)
final class MeetingSensor {
    init(onSnapshot: @escaping @Sendable (CaptureSnapshot) -> Void)
    func start(); func stop()
    func setWatched(bundleIDs: Set<String>)
    func scheduleScan(after: TimeInterval)
}

// TranscriberApp/Services/MeetingIslandController.swift (Task 8)
struct MeetingIslandOffer { let title: String; var subtitle: String; let primaryTitle: String
                            let primary: @MainActor () -> Void; let menu: [(title: String, action: @MainActor () -> Void)]; let compactLabel: String }
@MainActor final class MeetingIslandController { func show(_ offer: MeetingIslandOffer, expanded: Bool); func update(subtitle: String); func hide() }

// TranscriberApp/Services/MeetingPromptPresenter.swift (Task 9)
@MainActor final class MeetingPromptPresenter {
    init(appState:, configManager:, coordinator:, launcher:, calendarService:)
    func activate()                       // starts the observation loops; sensor starts iff mode == .prompt
    func record(_ app: MeetingApp); func nameFirst(); func notNow(); func openSettings(); func stop(); func keepRecording()
}
```

---

## Task 0: On-device listener spike — MANUAL GATE (throwaway, not merged)

**Owner at the machine, with real Zoom, Teams, Chrome (Meet) and Safari (Meet) calls.** Nothing later may assume listener behaviour that this task did not observe. Two later tasks depend on its results: **Task 1 (classification table — exact bundle IDs)** and **Task 7 (sensor wake signals — which listeners fire; whether per-process listeners fire and leak)**.

**Files:**
- Create (outside the repo): `/tmp/parley-sense-spike/main.swift`
- Nothing in the repo is created or modified.

- [ ] **Step 1: Write the harness**

```swift
// /tmp/parley-sense-spike/main.swift — throwaway. Prints every HAL wake with a timestamp, then a scan.
// Usage: ./spike            → listen (device IsRunningSomewhere, system Devices, system ProcessObjectList,
//                              and a per-process IsRunningInput listener on EVERY process object)
//        ./spike --churn    → spawn+kill 100 afplay processes, report Remove OSStatus + RSS delta
import CoreAudio
import Foundation

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func objectList(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(sel); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &list) == noErr else { return [] }
    return list
}
func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(sel); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var v: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
    return s as String
}
func hasInput(_ dev: AudioObjectID) -> Bool {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return false }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}
func rssMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
func stamp() -> String { fmt.string(from: Date()) }

let system = AudioObjectID(kAudioObjectSystemObject)
let queue = DispatchQueue(label: "spike")
var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

func scan(reason: String) {
    let t0 = Date()
    let procs = objectList(system, kAudioHardwarePropertyProcessObjectList)
    var capturing: [String] = []
    for p in procs where uint32(p, kAudioProcessPropertyIsRunningInput) == 1 {
        let pid = uint32(p, kAudioProcessPropertyPID).map(String.init) ?? "?"
        capturing.append("\(string(p, kAudioProcessPropertyBundleID) ?? "<empty>")(pid \(pid))")
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    print("\(stamp()) SCAN[\(reason)] \(procs.count) procs, \(String(format: "%.1f", ms)) ms, capturing: \(capturing)")
}

func reconcileProcessListeners() {
    let procs = Set(objectList(system, kAudioHardwarePropertyProcessObjectList))
    for p in procs where processListeners[p] == nil {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            print("\(stamp()) FIRE process IsRunningInput obj=\(p) bundle=\(string(p, kAudioProcessPropertyBundleID) ?? "<empty>") value=\(uint32(p, kAudioProcessPropertyIsRunningInput) ?? 99)")
            scan(reason: "process")
        }
        var a = addr(kAudioProcessPropertyIsRunningInput)
        let st = AudioObjectAddPropertyListenerBlock(p, &a, queue, block)
        if st == noErr { processListeners[p] = block } else { print("add process listener \(p) failed: \(st)") }
    }
    for (p, block) in processListeners where !procs.contains(p) {
        var a = addr(kAudioProcessPropertyIsRunningInput)
        let st = AudioObjectRemovePropertyListenerBlock(p, &a, queue, block)
        print("\(stamp()) REMOVE listener on vanished obj=\(p) → OSStatus \(st)")
        processListeners[p] = nil
    }
}

func reconcileDeviceListeners() {
    let devs = Set(objectList(system, kAudioHardwarePropertyDevices).filter(hasInput))
    for d in devs where deviceListeners[d] == nil {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            print("\(stamp()) FIRE device IsRunningSomewhere dev=\(d) value=\(uint32(d, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 99)")
            scan(reason: "device")
        }
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if AudioObjectAddPropertyListenerBlock(d, &a, queue, block) == noErr { deviceListeners[d] = block }
    }
    for (d, block) in deviceListeners where !devs.contains(d) {
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        _ = AudioObjectRemovePropertyListenerBlock(d, &a, queue, block); deviceListeners[d] = nil
    }
}

let systemBlock: AudioObjectPropertyListenerBlock = { count, addrs in
    for i in 0..<Int(count) {
        let sel = addrs[i].mSelector
        let name = sel == kAudioHardwarePropertyDevices ? "Devices" : sel == kAudioHardwarePropertyProcessObjectList ? "ProcessObjectList" : "\(sel)"
        print("\(stamp()) FIRE system \(name)")
    }
    reconcileDeviceListeners(); reconcileProcessListeners(); scan(reason: "system")
}
var devAddr = addr(kAudioHardwarePropertyDevices)
var procAddr = addr(kAudioHardwarePropertyProcessObjectList)
print("add Devices listener: \(AudioObjectAddPropertyListenerBlock(system, &devAddr, queue, systemBlock))")
print("add ProcessObjectList listener: \(AudioObjectAddPropertyListenerBlock(system, &procAddr, queue, systemBlock))")
queue.sync { reconcileDeviceListeners(); reconcileProcessListeners(); scan(reason: "initial") }
print("devices with input listened: \(deviceListeners.count); process listeners: \(processListeners.count)")

if CommandLine.arguments.contains("--churn") {
    print("RSS before churn: \(rssMB()) MB, process listeners: \(processListeners.count)")
    for i in 1...100 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["/System/Library/Sounds/Pop.aiff"]; try! p.run()
        usleep(150_000); queue.sync { reconcileProcessListeners() }   // registers on the new process
        p.waitUntilExit(); usleep(150_000); queue.sync { reconcileProcessListeners() }  // removes on the dead one
        if i % 25 == 0 { print("after \(i): RSS \(rssMB()) MB, process listeners: \(processListeners.count)") }
    }
    print("RSS after churn: \(rssMB()) MB")
    exit(0)
}
print("Listening. Start/stop calls now. Ctrl-C to quit.")
RunLoop.main.run()
```

- [ ] **Step 2: Build and run**

```bash
mkdir -p /tmp/parley-sense-spike && cd /tmp/parley-sense-spike
swiftc -O main.swift -o spike -framework CoreAudio && ./spike
```

- [ ] **Step 3: Exercise each scenario and fill the table** (copy it into the PR description; keep the raw log in `/tmp`)

For each row: start the call, wait for the prompt-relevant wake, leave the call, wait 60 s, mute/unmute mid-call, switch mic mid-call.

| Scenario | Which listener FIRED on start (device / process-list / per-process) | Latency start → first FIRE (ms) | Bundle IDs with `IsRunningInput=1` | Fired on leave? | Input still open 60 s after leaving? | Mute/unmute fires? |
|---|---|---|---|---|---|---|
| Zoom native call | | | | | | |
| Teams native call | | | | | | |
| Meet in Chrome | | | | | | |
| Meet in Safari | | | | | | |
| Chrome dictation / voice search | | | | | n/a | n/a |
| FaceTime (expected: excluded; note its bundle IDs) | | | | | | |
| Second app starts while first already holds the device (Zoom then Chrome) | | | | | | |

Then `./spike --churn` and record:

| Churn (100 afplay) | Remove OSStatus on vanished objects | RSS before → after (MB) | Process-listener count stable? |
|---|---|---|---|
| | | | |

- [ ] **Step 4: Decide, and write the outcome into the spec §1/§2 (one paragraph under "Evidence")**

  - Per-process `IsRunningInput` listeners fire on start AND leave → Task 7 keeps them for the watched set (spec baseline).
  - They do NOT fire on release → **decided (owner-delegated, 2026-09-11):** the stop prompt stays a firm feature. While — and only while — the phase is `.recording` and the watched set is non-empty, Task 7 re-reads `IsRunningInput` for the watched apps' process objects on a **10 s one-shot timer, re-armed after each read** (a handful of property reads, ~0.1 ms). It is never armed while idle, so the zero-idle-wakeup budget is untouched; recording is already the heavy path. Keep the process-list listener as an extra wake. Engine unchanged (each read is an ordinary snapshot). Add the idle-vs-recording wakeup numbers to the device checklist.
  - Remove on a dead object returns non-`noErr` and RSS grows → Task 7 must drop the listener bookkeeping for vanished objects without calling Remove (they're gone), and log once; if RSS grows regardless, cap watched listeners at 4 and note it as gotcha #69 (Task 12).
  - Bundle IDs observed → the exact rows in Task 1's table (helpers and all).

- [ ] **Step 5: No commit.** `rm -rf /tmp/parley-sense-spike` after the results are pasted into the PR description.

---

## Task 1: Classification table — `MeetingApps.classify`

**Files:**
- Create: `TranscriberCore/MeetingApps.swift`
- Create: `SwiftTests/TranscriberTests/MeetingAppsTests.swift`
- Modify: `TranscriberCore/MeetingSenseDecider.swift` (delete the old `MeetingApps.bundleIDs` enum at lines 78-95; the rest is rewritten in Task 2)
- Modify: `SwiftTests/TranscriberTests/MeetingSenseDeciderTests.swift` (delete the `meetingAppsSetIsConferencingOnly` test at lines 58-64 — it references the removed set)

**Depends on Task 0:** the family prefixes below are the spec's; **replace/add rows with the bundle IDs Task 0 observed** before writing the test (Teams new, Zoom helpers, Safari's WebKit GPU process).

**Interfaces — Produces:** `MeetingApp`, `MeetingApps.classify(bundleID:)`, `MeetingApps.ownPrefix`.

- [ ] **Step 1: Write the failing tests**

```swift
// SwiftTests/TranscriberTests/MeetingAppsTests.swift
import Testing
@testable import TranscriberCore

@Suite("MeetingApps classification")
struct MeetingAppsTests {
    @Test("native apps map to their family, exact and helper")
    func nativeFamilies() {
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos")?.displayName == "Zoom")
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos.helper")?.displayName == "Zoom")   // TASK 0: confirm helper id
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams2")?.displayName == "Teams")
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams2.helper")?.displayName == "Teams")   // TASK 0
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams")?.displayName == "Teams")
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos")?.kind == .native)
    }

    @Test("browsers and their helpers are browser-kind")
    func browsers() {
        let chrome = MeetingApps.classify(bundleID: "com.google.Chrome.helper")
        #expect(chrome?.displayName == "Chrome")
        #expect(chrome?.kind == .browser)
        #expect(MeetingApps.classify(bundleID: "com.google.Chrome")?.id == chrome?.id)   // same family
        let safari = MeetingApps.classify(bundleID: "com.apple.WebKit.GPU")
        #expect(safari?.displayName == "Safari")
        #expect(safari?.kind == .browser)
        #expect(MeetingApps.classify(bundleID: "company.thebrowser.Browser")?.displayName == "Arc")
        #expect(MeetingApps.classify(bundleID: "com.microsoft.edgemac")?.displayName == "Edge")
        #expect(MeetingApps.classify(bundleID: "org.mozilla.firefox")?.displayName == "Firefox")
    }

    @Test("Parley's own processes are never classified")
    func parleyExcluded() {
        #expect(MeetingApps.classify(bundleID: "eu.fmasi.parley") == nil)
        #expect(MeetingApps.classify(bundleID: "eu.fmasi.parley.capture-helper") == nil)
    }

    @Test("unknown, empty and FaceTime bundle IDs are nil")
    func unknownIsNil() {
        #expect(MeetingApps.classify(bundleID: "") == nil)
        #expect(MeetingApps.classify(bundleID: "com.apple.FaceTime") == nil)
        #expect(MeetingApps.classify(bundleID: "com.example.dictation") == nil)
        // A prefix match needs the dot: "us.zoomfoo" is not Zoom.
        #expect(MeetingApps.classify(bundleID: "us.zoomfoo") == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

RUN TESTS with `--filter MeetingAppsTests`. Expected: build error `cannot find 'MeetingApps' in scope` (the old enum has no `classify`) — a compile failure of the test target is the red state here.

- [ ] **Step 3: Implement**

```swift
// TranscriberCore/MeetingApps.swift
import Foundation

/// A meeting-capable app family. Helpers (`com.google.Chrome.helper`, `us.zoom.xos.helper`) resolve to
/// the family the user sees, so one call never looks like two apps.
public struct MeetingApp: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A dedicated conferencing app — high confidence that mic use means a call.
        case native
        /// A browser — lower confidence (dictation, voice search). Prompts once, then the cooldown.
        case browser
    }
    public let id: String
    public let displayName: String
    public let kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id; self.displayName = displayName; self.kind = kind
    }
}

/// Reviewable data: which bundle IDs count as "a meeting app is using the microphone".
/// FaceTime is deliberately absent (personal calls, #118). Unknown IDs never prompt — precision over
/// recall, since a wrong prompt is the thing that makes users turn the feature off.
public enum MeetingApps {
    /// Parley itself: the app (level meters) and the XPC capture helper. Never classified.
    public static let ownPrefix = "eu.fmasi.parley"

    static let zoom    = MeetingApp(id: "us.zoom.xos",              displayName: "Zoom",    kind: .native)
    static let teams   = MeetingApp(id: "com.microsoft.teams2",     displayName: "Teams",   kind: .native)
    static let webex   = MeetingApp(id: "com.cisco.webexmeetingsapp", displayName: "Webex", kind: .native)
    static let discord = MeetingApp(id: "com.hnc.Discord",          displayName: "Discord", kind: .native)
    static let slack   = MeetingApp(id: "com.tinyspeck.slackmacgap", displayName: "Slack",  kind: .native)
    static let chrome  = MeetingApp(id: "com.google.Chrome",        displayName: "Chrome",  kind: .browser)
    static let safari  = MeetingApp(id: "com.apple.Safari",         displayName: "Safari",  kind: .browser)
    static let arc     = MeetingApp(id: "company.thebrowser.Browser", displayName: "Arc",   kind: .browser)
    static let edge    = MeetingApp(id: "com.microsoft.edgemac",    displayName: "Edge",    kind: .browser)
    static let firefox = MeetingApp(id: "org.mozilla.firefox",      displayName: "Firefox", kind: .browser)

    /// (family prefix, app). A bundle ID matches a row when it equals the prefix or starts with
    /// `prefix + "."` — so `us.zoom.xos.helper` is Zoom but `us.zoomfoo` is not.
    /// TASK 0 fixes this table: add every helper ID observed with IsRunningInput = 1.
    static let families: [(prefix: String, app: MeetingApp)] = [
        ("us.zoom", zoom),
        ("com.microsoft.teams", teams),          // classic + teams2 + helpers
        ("com.cisco.webexmeetingsapp", webex),
        ("com.webex.meetingmanager", webex),
        ("com.hnc.Discord", discord),
        ("com.tinyspeck.slackmacgap", slack),
        ("com.google.Chrome", chrome),
        ("com.apple.WebKit.GPU", safari),        // Safari/WebKit media runs here, with no Safari identity
        ("com.apple.Safari", safari),
        ("company.thebrowser.Browser", arc),
        ("com.microsoft.edgemac", edge),
        ("org.mozilla.firefox", firefox),
    ]

    public static func classify(bundleID: String) -> MeetingApp? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix(ownPrefix) else { return nil }
        return families.first { bundleID == $0.prefix || bundleID.hasPrefix($0.prefix + ".") }?.app
    }
}
```

Then in `TranscriberCore/MeetingSenseDecider.swift` delete lines 78-95 (the `MeetingApps` enum with `bundleIDs`) and in `MeetingSenseDeciderTests.swift` delete the `meetingAppsSetIsConferencingOnly` test.

- [ ] **Step 4: Run the tests**

RUN TESTS with `--filter MeetingAppsTests`. Expected: 4 passed. Then RUN TESTS with no suite filter to confirm nothing else referenced `bundleIDs`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/MeetingApps.swift SwiftTests/TranscriberTests/MeetingAppsTests.swift TranscriberCore/MeetingSenseDecider.swift SwiftTests/TranscriberTests/MeetingSenseDeciderTests.swift
git commit -m "feat(sensing): MeetingApps.classify — family/helper bundle-ID classification (#118)"
```

---

## Task 2: Pure engine — `MeetingSenseEngine.step`

**Files:**
- Rename + rewrite: `git mv TranscriberCore/MeetingSenseDecider.swift TranscriberCore/MeetingSenseEngine.swift`
- Rename + rewrite: `git mv SwiftTests/TranscriberTests/MeetingSenseDeciderTests.swift SwiftTests/TranscriberTests/MeetingSenseEngineTests.swift`

**Interfaces — Consumes:** `MeetingApps.classify`, `MeetingApp`. **Produces:** everything in the "Interfaces" block above for `MeetingSenseEngine.swift`.

**Rules (from spec §2, with two additions from planning):** (a) any snapshot that arrives *before* the 30 s deadline re-emits `.scheduleScan(after: remaining)` — so a timer that fires a few ms early cannot strand the stop offer; (b) when a pending start is withdrawn because its app released while another meeting app is still capturing, that other app is offered (compact or expanded per its own cooldown) — otherwise Zoom-drops-while-Chrome-holds leaves no surface.

- [ ] **Step 1: Write the failing tests** (replace the file's whole content)

```swift
// SwiftTests/TranscriberTests/MeetingSenseEngineTests.swift
import Foundation
import Testing
@testable import TranscriberCore

/// Drives the pure engine like the presenter does: one state, a sequence of inputs, an injected clock.
private struct Sim {
    var state = MeetingSenseState()
    var mode: MeetingSenseMode = .prompt
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: TimeInterval) -> Date { Self.epoch.addingTimeInterval(s) }

    @discardableResult
    mutating func step(_ input: MeetingSenseInput, at seconds: TimeInterval) -> [MeetingSenseAction] {
        let r = MeetingSenseEngine.step(state, input: input, mode: mode, now: at(seconds))
        state = r.state
        return r.actions
    }
    @discardableResult
    mutating func snap(_ ids: Set<String>, at seconds: TimeInterval) -> [MeetingSenseAction] {
        step(.snapshot(CaptureSnapshot(capturingBundleIDs: ids)), at: seconds)
    }
    @discardableResult
    mutating func phase(_ p: MeetingSensePhase, at seconds: TimeInterval) -> [MeetingSenseAction] {
        step(.phaseChanged(p), at: seconds)
    }
}

private let zoom = MeetingApps.classify(bundleID: "us.zoom.xos")!
private let chrome = MeetingApps.classify(bundleID: "com.google.Chrome")!
private let debounce = MeetingSenseEngine.stopDebounce
private let cooldown = MeetingSenseEngine.expansionCooldown

@Suite("MeetingSenseEngine — start offers")
struct MeetingSenseEngineStartTests {
    @Test("first snapshot counts as a transition: launching mid-call prompts (expanded)")
    func firstSnapshotOffers() {
        var s = Sim()
        #expect(s.snap(["us.zoom.xos"], at: 0) == [.offerStart(zoom, expand: true)])
        #expect(s.state.pendingStart == zoom)
    }

    @Test("a steady snapshot is not a transition")
    func steadyStateIsSilent() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap(["us.zoom.xos"], at: 1) == [])
    }

    @Test("unknown bundle IDs never prompt")
    func unknownIsSilent() {
        var s = Sim()
        #expect(s.snap(["com.example.dictation", ""], at: 0) == [])
    }

    @Test("still offers while transcribing")
    func offersWhileTranscribing() {
        var s = Sim()
        s.phase(.transcribing, at: 0)
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.offerStart(zoom, expand: true)])
    }

    @Test("a second app transitioning while one offer is pending folds in")
    func secondAppFoldsIn() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap(["us.zoom.xos", "com.google.Chrome"], at: 1) == [])
        #expect(s.state.pendingStart == zoom)
    }

    @Test("the offered app releasing withdraws the offer")
    func earlyReleaseWithdraws() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.snap([], at: 1) == [.withdrawStart])
        #expect(s.state.pendingStart == nil)
    }

    @Test("withdrawal promotes another app still capturing")
    func withdrawPromotesOther() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.snap(["us.zoom.xos", "com.google.Chrome"], at: 1)
        #expect(s.snap(["com.google.Chrome"], at: 2) == [.withdrawStart, .offerStart(chrome, expand: true)])
    }

    @Test("expansion cooldown gates only `expand`; the offer itself always comes")
    func expansionCooldown() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)                 // expanded
        s.snap([], at: 10)                             // call dropped
        #expect(s.snap(["us.zoom.xos"], at: 60) == [.offerStart(zoom, expand: false)])   // reconnect: compact
        s.snap([], at: 70)
        #expect(s.snap(["us.zoom.xos"], at: cooldown + 1) == [.offerStart(zoom, expand: true)])
    }

    @Test("Not now suppresses the episode until the app releases the mic")
    func notNowSuppressesEpisode() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.step(.notNow, at: 1) == [.withdrawStart])
        #expect(s.state.suppressed == [zoom])
        #expect(s.snap(["us.zoom.xos"], at: 2) == [])      // same episode: quiet
        s.snap([], at: 3)                                  // released → suppression cleared
        #expect(s.state.suppressed.isEmpty)
        #expect(s.snap(["us.zoom.xos"], at: 4) == [.offerStart(zoom, expand: false)])   // new episode
    }

    @Test("mode off withdraws a pending offer and never offers")
    func modeOffWithdraws() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.mode = .off
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.withdrawStart])
        #expect(s.snap(["com.google.Chrome"], at: 2) == [])
    }
}

@Suite("MeetingSenseEngine — recording, watched set, stop offers")
struct MeetingSenseEngineStopTests {
    /// Recording with Zoom already capturing (the prompt-Record or manual-Record path).
    private func recordingWithZoom() -> Sim {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        s.phase(.recording, at: 1)
        return s
    }

    @Test("phase → recording withdraws the start offer and seeds the watched set")
    func recordingSeedsWatched() {
        var s = Sim()
        s.snap(["us.zoom.xos"], at: 0)
        #expect(s.phase(.recording, at: 1) == [.withdrawStart, .watch(bundleIDs: ["us.zoom.xos"])])
        #expect(s.state.watched == [zoom])
    }

    @Test("re-attach: phase is recording before any snapshot; the first snapshot seeds watched, no start offer")
    func reattachSeedsFromFirstSnapshot() {
        var s = Sim()
        #expect(s.phase(.recording, at: 0) == [.watch(bundleIDs: [])])
        #expect(s.snap(["us.zoom.xos"], at: 1) == [.watch(bundleIDs: ["us.zoom.xos"])])
        #expect(s.state.watched == [zoom])
        #expect(s.state.pendingStart == nil)
    }

    @Test("an app that starts capturing mid-recording joins the watched set")
    func joinerIsWatched() {
        var s = recordingWithZoom()
        #expect(s.snap(["us.zoom.xos", "com.google.Chrome"], at: 2) == [.watch(bundleIDs: ["us.zoom.xos", "com.google.Chrome"])])
        #expect(s.state.watched == [zoom, chrome])
    }

    @Test("helper bundle IDs of a watched app accumulate into the watch list")
    func helpersAccumulate() {
        var s = recordingWithZoom()
        #expect(s.snap(["us.zoom.xos", "us.zoom.xos.helper"], at: 2) == [.watch(bundleIDs: ["us.zoom.xos", "us.zoom.xos.helper"])])
    }

    @Test("all watched released → schedule a scan at the debounce; at the deadline → one stop offer")
    func stopDebounceExactlyOnce() {
        var s = recordingWithZoom()
        #expect(s.snap([], at: 10) == [.scheduleScan(after: debounce)])
        #expect(s.snap([], at: 10 + debounce) == [.offerStop(zoom)])
        #expect(s.snap([], at: 11 + debounce) == [])
    }

    @Test("a snapshot before the deadline reschedules for the remainder (an early timer can't strand the offer)")
    func earlySnapshotReschedules() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        #expect(s.snap([], at: 20) == [.scheduleScan(after: debounce - 10)])
    }

    @Test("re-acquire (mute/unmute, device switch) cancels the pending release")
    func reacquireCancels() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        #expect(s.snap(["us.zoom.xos"], at: 20) == [])
        #expect(s.state.releasedAt == nil)
        #expect(s.snap([], at: 25) == [.scheduleScan(after: debounce)])   // a fresh release
        #expect(s.snap([], at: 25 + debounce - 1) == [.scheduleScan(after: 1)])
    }

    @Test("re-acquire after the stop offer withdraws it")
    func reacquireWithdrawsStop() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.snap(["us.zoom.xos"], at: 50) == [.withdrawStop])
    }

    @Test("Keep recording suppresses until the app re-acquires and releases again")
    func keepRecordingSuppresses() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.step(.keepRecording, at: 45) == [.withdrawStop])
        #expect(s.snap([], at: 200) == [])                              // still released, still quiet
        s.snap(["us.zoom.xos"], at: 300)                                // re-acquire
        #expect(s.snap([], at: 310) == [.scheduleScan(after: debounce)])
        #expect(s.snap([], at: 310 + debounce) == [.offerStop(zoom)])
    }

    @Test("recording with no meeting app ever capturing never offers to stop")
    func emptyWatchedNoStop() {
        var s = Sim()
        s.phase(.recording, at: 0)
        #expect(s.snap([], at: 10) == [])
        #expect(s.snap([], at: 100) == [])
    }

    @Test("no start offer while recording")
    func noStartWhileRecording() {
        var s = Sim()
        s.phase(.recording, at: 0)
        let actions = s.snap(["com.google.Chrome"], at: 1)
        #expect(!actions.contains(.offerStart(chrome, expand: true)))
        #expect(!actions.contains(.offerStart(chrome, expand: false)))
    }

    @Test("phase leaves recording: clears watched, withdraws the stop offer, releases the listeners")
    func leavingRecordingClears() {
        var s = recordingWithZoom()
        s.snap([], at: 10)
        s.snap([], at: 10 + debounce)
        #expect(s.phase(.transcribing, at: 50) == [.withdrawStop, .watch(bundleIDs: [])])
        #expect(s.state.watched.isEmpty)
        #expect(s.state.releasedAt == nil)
    }
}
```

- [ ] **Step 2: Run the suites to verify they fail**

RUN TESTS with `--filter MeetingSenseEngine`. Expected: compile errors (`MeetingSenseState`, `CaptureSnapshot`, … not found).

- [ ] **Step 3: Implement** (replace the whole content of `TranscriberCore/MeetingSenseEngine.swift`)

```swift
import Foundation

/// How the app reacts when it senses a meeting starting (a meeting app grabs the microphone).
/// Airgap-safe: the trigger is a local Core Audio HAL property, never the network or a calendar.
///
/// There is deliberately NO auto-record mode: meeting sensing only ever *prompts*, so the app never
/// records without an explicit user action (consent / courtroom-grade, locked in #118).
public enum MeetingSenseMode: String, Codable, Equatable, Sendable {
    case off
    case prompt
}

/// `AppState.Phase` without payloads — all the engine needs.
public enum MeetingSensePhase: Equatable, Sendable {
    case idle, recording, transcribing
}

/// What the sensor saw: the raw bundle IDs of every process currently running input IO.
public struct CaptureSnapshot: Equatable, Sendable {
    public var capturingBundleIDs: Set<String>
    public init(capturingBundleIDs: Set<String>) { self.capturingBundleIDs = capturingBundleIDs }
}

public enum MeetingSenseInput: Equatable, Sendable {
    case snapshot(CaptureSnapshot)
    case phaseChanged(MeetingSensePhase)
    /// The user answered "Not now" to the pending start offer.
    case notNow
    /// The user answered "Keep recording" to the stop offer.
    case keepRecording
}

public enum MeetingSenseAction: Equatable, Sendable {
    /// Show the start offer. `expand` = the attention-grabbing state; false = arrive compact.
    case offerStart(MeetingApp, expand: Bool)
    case withdrawStart
    case offerStop(MeetingApp)
    case withdrawStop
    /// The raw bundle IDs the sensor should hold per-process `IsRunningInput` listeners on. Empty = none.
    case watch(bundleIDs: Set<String>)
    /// Run an ordinary scan after this many seconds (one-shot; replaces any pending request).
    case scheduleScan(after: TimeInterval)
}

public struct MeetingSenseState: Equatable, Sendable {
    public var phase: MeetingSensePhase = .idle
    /// Meeting apps capturing at the last snapshot, with the time each was first seen capturing.
    /// Starts empty on purpose: apps already capturing at the first snapshot count as transitions
    /// (launching Parley mid-call, or turning the setting on mid-call, prompts — goal 1).
    public var capturing: [MeetingApp: Date] = [:]
    /// The raw bundle IDs of the last snapshot (so the watch list can name helpers, not families).
    public var lastSnapshot: Set<String> = []
    /// At most one start offer at a time.
    public var pendingStart: MeetingApp? = nil
    /// "Not now" / "Keep recording": quiet for this app until it releases the mic. The single
    /// suppression mechanism.
    public var suppressed: Set<MeetingApp> = []
    /// When each app last got the expanded island — the expansion-only cooldown.
    public var lastExpanded: [MeetingApp: Date] = [:]
    /// While recording: meeting apps seen capturing during this recording, and their raw bundle IDs.
    public var watched: Set<MeetingApp> = []
    public var watchedBundleIDs: Set<String> = []
    /// While recording: when every watched app was last seen released; nil while any is capturing.
    public var releasedAt: Date? = nil
    /// The stop offer for the current release span was emitted (exactly once per span).
    public var stopOffered = false

    public init() {}
}

/// Pure decision logic. No Core Audio, no AppKit, no clock of its own — `step` is a function of
/// (state, input, mode, now), which is what makes every rule unit-testable.
public enum MeetingSenseEngine {
    /// Minimum gap between two *expanded* start offers for the same app. A call that drops and
    /// reconnects keeps its persistent surface (compact island, banner, icon) but must not re-interrupt.
    public static let expansionCooldown: TimeInterval = 300
    /// How long every watched app must stay released before we offer to stop. Mute/unmute and device
    /// switches re-acquire within this window and cancel it.
    public static let stopDebounce: TimeInterval = 30

    public static func step(
        _ state: MeetingSenseState,
        input: MeetingSenseInput,
        mode: MeetingSenseMode,
        now: Date
    ) -> (state: MeetingSenseState, actions: [MeetingSenseAction]) {
        var s = state
        var out: [MeetingSenseAction] = []

        switch input {
        case .phaseChanged(let phase):
            let was = s.phase
            s.phase = phase
            if phase == .recording, was != .recording {
                // Manual Record, prompt Record, or crash re-attach: the offer is moot, and every meeting
                // app capturing right now is part of this recording.
                withdrawStart(&s, &out)
                s.watched = Set(s.capturing.keys)
                s.watchedBundleIDs = rawIDs(in: s.lastSnapshot, of: s.watched)
                s.releasedAt = nil
                s.stopOffered = false
                out.append(.watch(bundleIDs: s.watchedBundleIDs))
            } else if was == .recording, phase != .recording {
                s.watched = []
                s.watchedBundleIDs = []
                s.releasedAt = nil
                withdrawStop(&s, &out)
                out.append(.watch(bundleIDs: []))
            }
        case .notNow:
            if let app = s.pendingStart { s.suppressed.insert(app) }
            withdrawStart(&s, &out)
        case .keepRecording:
            if s.stopOffered { s.suppressed.formUnion(s.watched) }
            withdrawStop(&s, &out)
        case .snapshot(let snapshot):
            applySnapshot(snapshot, &s, &out, mode: mode, now: now)
        }

        if mode == .off {
            withdrawStart(&s, &out)
            withdrawStop(&s, &out)
        }
        return (s, out)
    }

    // MARK: - Snapshot rules

    private static func applySnapshot(
        _ snapshot: CaptureSnapshot,
        _ s: inout MeetingSenseState,
        _ out: inout [MeetingSenseAction],
        mode: MeetingSenseMode,
        now: Date
    ) {
        var nowCapturing: [MeetingApp: Date] = [:]
        for id in snapshot.capturingBundleIDs {
            guard let app = MeetingApps.classify(bundleID: id) else { continue }
            nowCapturing[app] = s.capturing[app] ?? now
        }
        let started = Set(nowCapturing.keys).subtracting(s.capturing.keys)
        let released = Set(s.capturing.keys).subtracting(nowCapturing.keys)
        s.capturing = nowCapturing
        s.lastSnapshot = snapshot.capturingBundleIDs
        // An episode ends when the app lets go of the mic; the next acquisition is a new episode.
        s.suppressed.subtract(released)
        guard mode == .prompt else { return }

        if s.phase == .recording {
            s.watched.formUnion(started)
            guard !s.watched.isEmpty else { return }
            let ids = rawIDs(in: snapshot.capturingBundleIDs, of: s.watched)
            if !ids.isSubset(of: s.watchedBundleIDs) {
                s.watchedBundleIDs.formUnion(ids)
                out.append(.watch(bundleIDs: s.watchedBundleIDs))
            }
            if !s.watched.isDisjoint(with: nowCapturing.keys) {
                s.releasedAt = nil
                withdrawStop(&s, &out)
            } else if let releasedAt = s.releasedAt {
                let elapsed = now.timeIntervalSince(releasedAt)
                if elapsed >= stopDebounce {
                    let candidates = s.watched.subtracting(s.suppressed)
                    if !s.stopOffered, let app = first(of: candidates) {
                        s.stopOffered = true
                        out.append(.offerStop(app))
                    }
                } else {
                    out.append(.scheduleScan(after: stopDebounce - elapsed))
                }
            } else {
                s.releasedAt = now
                out.append(.scheduleScan(after: stopDebounce))
            }
            return
        }

        // Idle or transcribing: start offers.
        var justWithdrew = false
        if let pending = s.pendingStart, nowCapturing[pending] == nil {
            withdrawStart(&s, &out)
            justWithdrew = true
        }
        guard s.pendingStart == nil else { return }
        // Normally only transitions offer; after a withdrawal, any other app still capturing takes over
        // (Zoom dropped while Chrome holds the mic must not leave the user with no surface).
        let candidates = (justWithdrew ? Set(nowCapturing.keys) : started).subtracting(s.suppressed)
        guard let app = first(of: candidates) else { return }
        let expand = s.lastExpanded[app].map { now.timeIntervalSince($0) >= expansionCooldown } ?? true
        if expand { s.lastExpanded[app] = now }
        s.pendingStart = app
        out.append(.offerStart(app, expand: expand))
    }

    // MARK: - Helpers

    private static func withdrawStart(_ s: inout MeetingSenseState, _ out: inout [MeetingSenseAction]) {
        guard s.pendingStart != nil else { return }
        s.pendingStart = nil
        out.append(.withdrawStart)
    }

    private static func withdrawStop(_ s: inout MeetingSenseState, _ out: inout [MeetingSenseAction]) {
        guard s.stopOffered else { return }
        s.stopOffered = false
        out.append(.withdrawStop)
    }

    /// The raw bundle IDs in `ids` that classify into one of `apps`.
    private static func rawIDs(in ids: Set<String>, of apps: Set<MeetingApp>) -> Set<String> {
        Set(ids.filter { id in MeetingApps.classify(bundleID: id).map(apps.contains) ?? false })
    }

    /// Deterministic pick when several apps qualify: alphabetical by display name.
    private static func first(of apps: Set<MeetingApp>) -> MeetingApp? {
        apps.min { $0.displayName < $1.displayName }
    }
}
```

- [ ] **Step 4: Run the tests**

RUN TESTS with `--filter MeetingSenseEngine`. Expected: 22 passed. Then RUN TESTS with no suite filter. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A TranscriberCore/MeetingSenseDecider.swift TranscriberCore/MeetingSenseEngine.swift SwiftTests/TranscriberTests/MeetingSenseDeciderTests.swift SwiftTests/TranscriberTests/MeetingSenseEngineTests.swift
git commit -m "feat(sensing): pure MeetingSenseEngine — start/stop offers, watched set, stop debounce (#118)"
```

---

## Task 3: Coordinator start guard

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:40-43` (flags) and `:179-258` (`startRecording`)
- Modify: `SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift` (fake gains `onStartAsync`; two tests)

**Interfaces — Produces:** `@discardableResult public func startRecording(sessionName:microphoneDeviceId:) async -> Bool`, `var startInFlight: Bool` (internal, for tests).

- [ ] **Step 1: Write the failing tests**

In `RecordingCoordinatorTests.swift`, inside `FakeCaptureClient` add after `var onStart: (() -> Void)?`:

```swift
    /// Awaited inside start() — lets a test hold the coordinator at its `await captureClient.start`.
    var onStartAsync: (() async -> Void)?
```

and in `FakeCaptureClient.start(...)`, after `onStart?()`:

```swift
        await onStartAsync?()
```

Add a latch and two tests in the suite that already holds `startRecordingSuccessPersistsSentinelAndEntersRecording` (around line 793):

```swift
/// A one-shot latch: `wait()` suspends until `open()`; `untilWaiterArrives()` resumes once someone waits.
private actor Latch {
    private var opened = false
    private var waiterArrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrival: CheckedContinuation<Void, Never>?

    func wait() async {
        waiterArrived = true
        arrival?.resume(); arrival = nil
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }; waiters = []
    }
    func untilWaiterArrives() async {
        if waiterArrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
}

    @Test func concurrentStartsYieldExactlyOneStart() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        let latch = Latch()
        h.client.onStartAsync = { await latch.wait() }

        async let first = h.coordinator.startRecording(sessionName: "A", microphoneDeviceId: nil)
        await latch.untilWaiterArrives()                       // `first` is parked inside the helper start
        #expect(h.coordinator.startInFlight)
        let second = await h.coordinator.startRecording(sessionName: "B", microphoneDeviceId: nil)
        #expect(second == false, "a second start must be refused while one is in flight")
        await latch.open()
        #expect(await first == true)
        #expect(h.client.startCalls.count == 1)
        #expect(h.appState.isRecording)
        #expect(h.coordinator.startInFlight == false)
    }

    @Test func startIsRefusedUnlessIdle() async throws {
        let h = try Harness()
        h.appState.phase = .transcribing(progress: "Transcribing…")
        #expect(await h.coordinator.startRecording(sessionName: "A", microphoneDeviceId: nil) == false)
        #expect(h.client.startCalls.isEmpty)
        h.appState.phase = .recording(since: Date())
        #expect(await h.coordinator.startRecording(sessionName: "A", microphoneDeviceId: nil) == false)
        #expect(h.client.startCalls.isEmpty)
    }
```

- [ ] **Step 2: Run to verify it fails**

RUN TESTS with `--filter RecordingCoordinator`. Expected: compile error — `startRecording` returns `Void`, `startInFlight` does not exist.

- [ ] **Step 3: Implement**

In `RecordingCoordinator.swift`, after `var stopInFlight = false` (line 43) add:

```swift
    /// True while startRecording() is between its guard and the phase flip (it suspends on the helper's
    /// start). With three entry points (menu, island, banner) two starts could otherwise interleave
    /// across that await → two sentinels, two helper starts. Internal for tests.
    var startInFlight = false
```

Change the signature and body of `startRecording` (line 179):

```swift
    /// Returns whether a recording was started. Refused (false) unless the phase is `.idle` and no other
    /// start is in flight — the only guard between the user's click and the helper opening the mic.
    @discardableResult
    public func startRecording(sessionName: String, microphoneDeviceId: String?) async -> Bool {
        guard appState.isIdle, !startInFlight else {
            Logger.state.info("Start ignored — phase \(String(describing: self.appState.phase), privacy: .public), startInFlight=\(self.startInFlight, privacy: .public)")
            return false
        }
        startInFlight = true
        defer { startInFlight = false }
        Logger.state.info("Recording started — session: \(sessionName, privacy: .sensitive)")
        // … existing body unchanged from `appState.errorMessage = nil` down to the do/catch …
```

At the end of the `do` block (after `stopRequestedDuringRecovery = false`, line 251) add `return true`; at the end of the `catch` block (after `notify("Recording Failed", …)`, line 256) add `return false`.

- [ ] **Step 4: Run the tests**

RUN TESTS with `--filter RecordingCoordinator`. Expected: all pass (existing callers ignore the result thanks to `@discardableResult`). Then RUN TESTS with no suite filter.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(coordinator): refuse a second startRecording while one is in flight or not idle (#118)"
```

---

## Task 4: Config key + AppState surface

**Files:**
- Modify: `TranscriberCore/Config.swift` (property, default, init, CodingKeys, decode)
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`
- Modify: `TranscriberCore/AppState.swift`
- Modify: `SwiftTests/TranscriberTests/AppStateTests.swift`

**Interfaces — Produces:** `Config.meetingSensing`, `DetectedMeeting`, `AppState.detectedMeeting`, icon `"mic.badge.plus"` while idle with a detected meeting.

- [ ] **Step 1: Write the failing tests**

Append to `ConfigTests.swift`'s suite:

```swift
    @Test func meetingSensingDefaultsToPromptAndRoundTrips() throws {
        #expect(Config.default.meetingSensing == .prompt)
        var config = Config.default
        config.meetingSensing = .off
        let data = try JSONEncoder().encode(config)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"meeting_sensing\":\"off\""))
        #expect(try JSONDecoder().decode(Config.self, from: data).meetingSensing == .off)
    }

    @Test func meetingSensingMissingKeyDecodesAsPrompt() throws {
        // A config.json written before this key existed: default ON (D6).
        let legacy = """
        {"recording_directory":"/tmp/r","silence_timeout_minutes":5,"silence_detection_enabled":true,
         "output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(Config.self, from: legacy).meetingSensing == .prompt)
    }
```

Append to `AppStateTests.swift`'s suite:

```swift
    @Test func detectedMeetingChangesTheIdleIcon() {
        let state = AppState()
        let zoom = MeetingApps.classify(bundleID: "us.zoom.xos")!
        #expect(state.menuBarIcon == "mic")
        state.detectedMeeting = DetectedMeeting(app: zoom, kind: .start)
        #expect(state.menuBarIcon == "mic.badge.plus")
        state.phase = .recording(since: Date())
        #expect(state.menuBarIcon == "microphone.and.signal.meter.fill", "recording icon wins")
        state.phase = .idle
        state.detectedMeeting = nil
        #expect(state.menuBarIcon == "mic")
    }
```

- [ ] **Step 2: Run to verify they fail**

RUN TESTS with `--filter 'ConfigTests|AppStateTests'`. Expected: compile errors (`meetingSensing`, `DetectedMeeting`).

- [ ] **Step 3: Implement**

`Config.swift` — add after `public var calendarLookaheadMinutes: Int` (line 158):

```swift
    /// Meeting sensing (#118): `.prompt` offers to record when a meeting app starts using the mic;
    /// `.off` disables sensing entirely. Default ON with disclosure (D6). Never auto-records.
    public var meetingSensing: MeetingSenseMode
```

In `static let default` add `meetingSensing: .prompt,` before `summary: nil`. In `public init(...)` add the parameter `meetingSensing: MeetingSenseMode = .prompt,` before `summary:` and `self.meetingSensing = meetingSensing`. In `CodingKeys` add `case meetingSensing = "meeting_sensing"`. In `init(from:)` add `meetingSensing = try c.decodeIfPresent(MeetingSenseMode.self, forKey: .meetingSensing) ?? .prompt`.

`AppState.swift` — add before `public final class AppState`:

```swift
/// A meeting the sensor noticed and the user has not answered yet. Drives the menu-bar icon and the
/// in-menu banner — the backup surfaces behind the island (#118).
public struct DetectedMeeting: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Zoom call in progress" + Record.
        case start
        /// The user chose Record while transcribing; starts when the phase becomes idle.
        case queued
        /// "Zoom released the microphone" + Stop.
        case stop
    }
    public let app: MeetingApp
    public let kind: Kind
    public init(app: MeetingApp, kind: Kind) { self.app = app; self.kind = kind }
}
```

Inside `AppState`, after `public var criticalError: String?`:

```swift
    /// Non-nil while a meeting-sensing offer is standing (start, queued, or stop).
    public var detectedMeeting: DetectedMeeting?
```

and in `menuBarIcon` change `case .idle: return "mic"` to:

```swift
        case .idle: return detectedMeeting != nil ? "mic.badge.plus" : "mic"
```

- [ ] **Step 4: Run the tests**

RUN TESTS with no suite filter. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift TranscriberCore/AppState.swift SwiftTests/TranscriberTests/AppStateTests.swift
git commit -m "feat(sensing): meeting_sensing config key (default prompt) + AppState.detectedMeeting (#118)"
```

---

## Task 5: Calendar lookup off the main thread, bounded

Ordered before the launcher because `quickStart` (Task 6) consumes this signature and must never block main.

**Files:**
- Modify: `TranscriberCore/ResumeOnce.swift` (make public — 3 keywords)
- Modify: `TranscriberApp/Services/CalendarService.swift`
- Modify: `TranscriberApp/Views/MenuView.swift:354-357` (the one caller; becomes `await`)

**Interfaces — Consumes:** `ResumeOnce`. **Produces:** `func currentEventTitle(lookaheadMinutes: Int = 10, timeout: TimeInterval = 1) async -> String?`.

No unit test: `CalendarService` is app-target and wraps EventKit; `CalendarEventPicker` (the pure part) is already tested and untouched. Verification is `swift build` + the device checklist item "Record from the island names the session from the calendar".

- [ ] **Step 1: Make `ResumeOnce` public**

```swift
public final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    …
    public init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    public func resume(_ value: T) { … }
}
```

- [ ] **Step 2: Rewrite `CalendarService`**

```swift
import EventKit
import TranscriberCore

/// EventKit lookup for the current meeting's title. The query is synchronous and can't be cancelled,
/// so it runs off main and is raced against `timeout`: past the deadline the caller gets nil and the
/// query's late result is discarded (#197). `CalendarEventPicker` holds the pure selection rule.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func currentEventTitle(lookaheadMinutes: Int = 10, timeout: TimeInterval = 1) async -> String? {
        nonisolated(unsafe) let store = self.store   // EKEventStore fetches are safe off the creating thread
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached(priority: .userInitiated) {
                once.resume(Self.lookup(store: store, lookaheadMinutes: lookaheadMinutes))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(nil)
            }
        }
    }

    nonisolated private static func lookup(store: EKEventStore, lookaheadMinutes: Int) -> String? {
        let now = Date()
        // The predicate window must include both the lookback for in-progress events and
        // the lookahead for imminent ones. EventKit needs at least a few hours back to
        // surface events that started earlier in the day.
        let lookahead = max(lookaheadMinutes, 0)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(TimeInterval(lookahead) * 60 + 60),
            calendars: nil
        )
        let events = store.events(matching: predicate)
        let notDeclined = events.filter { event in
            guard let attendees = event.attendees else { return true }
            guard let me = attendees.first(where: { $0.isCurrentUser }) else { return true }
            return me.participantStatus != .declined
        }
        return CalendarEventPicker.pickEvent(from: notDeclined, now: now, lookaheadMinutes: lookahead)?.title
    }
}
```

- [ ] **Step 3: Update the caller in `MenuView.promptAndStartRecording`** (temporary — Task 6 moves this function into the launcher):

```swift
    private func promptAndStartRecording() async {
        let suggestedName = await calendarService.currentEventTitle(
            lookaheadMinutes: configManager.config.calendarLookaheadMinutes
        )
        SessionNameWindowController.shared.show(
```

and in `toggleRecording()` change `promptAndStartRecording()` to `await promptAndStartRecording()`.

- [ ] **Step 4: Build**

Run: `swift build`. Expected: succeeds with no new warnings about `Sendable` in `CalendarService` (the `nonisolated(unsafe)` capture covers the store). Then RUN TESTS with no suite filter. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/ResumeOnce.swift TranscriberApp/Services/CalendarService.swift TranscriberApp/Views/MenuView.swift
git commit -m "perf(calendar): EventKit title lookup off main, bounded to 1 s (#197 part, #118)"
```

---

## Task 6: Hoist the coordinator + `RecordingLauncher`

**Files:**
- Create: `TranscriberApp/Services/RecordingLauncher.swift`
- Modify: `TranscriberApp/TranscriberApp.swift:86-101` (properties), `:106-189` (init), `:464-479` (scene)
- Modify: `TranscriberApp/Views/MenuView.swift:10-63` (properties/init), `:346-396` (start/mic paths)

**Interfaces — Consumes:** `RecordingCoordinator.startRecording(...) -> Bool` (Task 3), `CalendarService.currentEventTitle` (Task 5), `MeetingApp` (Task 1). **Produces:** `RecordingLauncher` (see Interfaces block), `TranscriberApp.coordinator`/`launcher` as `@State`, `MenuView.init(appState:coordinator:launcher:configManager:updater:permissionManager:)`.

Not unit-testable (app target). Verification: `swift build`, existing `RecordingCoordinatorTests` green, and the device checklist items "manual Record unchanged" and "mic label follows the switcher".

- [ ] **Step 1: Create the launcher**

```swift
// TranscriberApp/Services/RecordingLauncher.swift
import Foundation
import Observation
import TranscriberCore
import os

/// The two ways a recording starts, reachable from anywhere in the app (menu, island, banner) — hoisted
/// out of `MenuView` (#118). Owns the remembered mic pick; the coordinator owns the lifecycle.
@MainActor
@Observable
final class RecordingLauncher {
    /// The user's mic pick for the next recording (nil = system default). Observable: the menu's mic
    /// label reads it.
    var selectedMicId: String?
    private let coordinator: RecordingCoordinator
    private let configManager: ConfigManager
    private let calendarService: CalendarService

    init(coordinator: RecordingCoordinator, configManager: ConfigManager, calendarService: CalendarService) {
        self.coordinator = coordinator
        self.configManager = configManager
        self.calendarService = calendarService
        self.selectedMicId = configManager.config.lastMicrophoneDeviceId
    }

    /// The naming panel flow (moved verbatim from MenuView.promptAndStartRecording).
    func promptAndStart() async {
        let suggestedName = await calendarService.currentEventTitle(
            lookaheadMinutes: configManager.config.calendarLookaheadMinutes
        )
        SessionNameWindowController.shared.show(
            suggestedName: suggestedName,
            lastMicrophoneDeviceId: selectedMicId
        ) { [weak self] sessionName, micDeviceId in
            guard let self else { return }
            self.selectedMicId = micDeviceId
            let coordinator = self.coordinator
            Task { await coordinator.startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
        }
    }

    /// One click from "call started" to "recording": no panel. Name = the calendar title when the
    /// presenter already found one, else "<App> call"; mic = last used (the helper falls back to the
    /// default device if it is gone — `MicCaptureSession.buildAndStart`). Rename after transcription is
    /// unchanged. Returns whether the coordinator started (false = not idle / start in flight).
    func quickStart(app: MeetingApp, calendarTitle: String?) async -> Bool {
        let name = calendarTitle ?? "\(app.displayName) call"
        Logger.state.info("Quick start from meeting sensing — \(app.displayName, privacy: .public)")
        return await coordinator.startRecording(sessionName: name, microphoneDeviceId: selectedMicId)
    }
}
```

- [ ] **Step 2: Hoist in `TranscriberApp.swift`**

Replace the stored properties block (lines 88-93) with:

```swift
    @State private var appState = AppState()
    @State private var launchGate = LaunchGate()
    @State private var coordinator: RecordingCoordinator
    @State private var launcher: RecordingLauncher
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
```

In `init()`, immediately after `Self.yieldIfDuplicateInstance()` (line 120) — i.e. after the CLI check, so a CLI invocation never builds UI objects — add:

```swift
        // Recording orchestration lives here, not in MenuView: `MenuBarExtra(systemImage: appState.menuBarIcon)`
        // re-evaluates the scene on every icon change and used to construct a throwaway coordinator each
        // time (#118 hoist). Nothing in recovery depends on it — Flow A/B use the static setupCrashHandler.
        let state = appState
        let recordingCoordinator = RecordingCoordinator(
            appState: state,
            captureClient: captureClient,
            transcriptionRunner: transcriptionRunner,
            configManager: configManager,
            notify: { title, body in MenuView.postNotification(title: title, body: body) },
            notifyCritical: { title, body in MenuView.sendCriticalNotification(title: title, body: body) },
            presentTranscript: { jsonPath, config in
                RenameWindowController.shared.show(jsonPath: jsonPath) {
                    MenuView.autoSummarize(jsonPath: jsonPath, config: config)
                }
            }
        )
        _coordinator = State(initialValue: recordingCoordinator)
        _launcher = State(initialValue: RecordingLauncher(
            coordinator: recordingCoordinator, configManager: configManager, calendarService: calendarService
        ))
```

(`init()` of an `App` struct runs on the main actor, so constructing `@MainActor` objects here compiles; if the compiler objects, wrap the two constructions in `MainActor.assumeIsolated { … }`.) Delete the now-unused `let state = appState` at line 138 if it duplicates the one above.

Replace the `MenuView(...)` call in `body` (lines 467-475) with:

```swift
                MenuView(
                    appState: appState,
                    coordinator: coordinator,
                    launcher: launcher,
                    configManager: configManager,
                    updater: updaterController.updater,
                    permissionManager: launchGate.permissionManager
                )
```

- [ ] **Step 3: Slim `MenuView`**

Replace lines 10-63 (properties + init) with:

```swift
struct MenuView: View {
    @Bindable var appState: AppState
    let coordinator: RecordingCoordinator
    let launcher: RecordingLauncher
    let configManager: ConfigManager
    let updater: SPUUpdater
    /// Read for the ongoing notifications-off signal (#150); refreshed on panel open.
    let permissionManager: PermissionManager
    /// Closes the window-style MenuBarExtra panel (macOS 14+ honors dismiss here).
    @Environment(\.dismiss) private var dismissPanel

    init(
        appState: AppState,
        coordinator: RecordingCoordinator,
        launcher: RecordingLauncher,
        configManager: ConfigManager,
        updater: SPUUpdater,
        permissionManager: PermissionManager
    ) {
        self.appState = appState
        self.coordinator = coordinator
        self.launcher = launcher
        self.configManager = configManager
        self.updater = updater
        self.permissionManager = permissionManager
    }
```

Replace `toggleRecording` + `promptAndStartRecording` (lines 346-366) with:

```swift
    private func toggleRecording() async {
        if appState.isRecording {
            await coordinator.stopRecording()
        } else if appState.isIdle {
            await launcher.promptAndStart()
        }
    }
```

In `activeMicName` replace `selectedMicId` with `launcher.selectedMicId`; in `openMicPicker` replace `currentDeviceId: selectedMicId` with `currentDeviceId: launcher.selectedMicId` and `selectedMicId = newDeviceId` with `launcher.selectedMicId = newDeviceId`. Remove the `import UserNotifications`-dependent code? No — `postNotification` stays in MenuView (used by the coordinator closures). Remove the now-unused `captureClient`/`transcriptionRunner`/`calendarService` references (the compiler will point at each).

- [ ] **Step 4: Build + tests**

Run: `swift build`. Expected: success. RUN TESTS with no suite filter. Expected: all pass (`RecordingCoordinatorTests` unchanged). Then `python3 scripts/dev.py` and check manually: Start Recording from the menu still opens the naming panel and records; Stop still transcribes; the mic row label follows a switch.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/RecordingLauncher.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift
git commit -m "refactor(app): hoist RecordingCoordinator into TranscriberApp; add RecordingLauncher (#118)"
```

---

## Task 7: `MeetingSensor` — HAL listeners + coalesced scan

**Depends on Task 0.** The baseline below assumes Task 0 confirmed: (1) device `IsRunningSomewhere` and/or system `ProcessObjectList` fire on call start; (2) per-process `IsRunningInput` listeners fire on release; (3) Remove on a vanished object returns an error but nothing leaks. Adjust per Task 0 Step 4 before implementing.

**Files:**
- Create: `TranscriberApp/Services/MeetingSensor.swift`

**Interfaces — Consumes:** `CaptureSnapshot`. **Produces:** `MeetingSensor` (see Interfaces block).

Not unit-testable (Core Audio). Verification: `swift build`, then the log lines below on device (`log stream … --level debug`, category `audio`) and the idle-wakeups measurement in the checklist.

- [ ] **Step 1: Implement**

```swift
// TranscriberApp/Services/MeetingSensor.swift
import CoreAudio
import Foundation
import TranscriberCore
import os

/// The only component that touches Core Audio for meeting sensing (#118). Everything runs on one
/// private serial queue — never main — because HAL calls can block indefinitely (gotcha #68); a wedged
/// sensor wedges only itself.
///
/// Wake signals (event-driven, no polling — D5):
///   • `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device (a call can use a
///     non-default mic), re-registered on `kAudioHardwarePropertyDevices` churn — the pattern
///     device-proven in `MicCaptureSession` (gotcha #55).
///   • `kAudioHardwarePropertyProcessObjectList` on the system object — a call app connecting to the
///     HAL while another client already holds the device.
///   • `kAudioProcessPropertyIsRunningInput` on the *watched* process objects only (≤ a few, only
///     while recording): Parley's own helper holds the device then, so the device signal cannot see the
///     call app let go. The block is Block_copy'd until Remove (AudioHardware.h:390-393); nothing
///     documents what happens when a Process object dies, so this set stays small and explicit.
///
/// Any wake schedules ONE coalesced scan 250 ms later (further wakes inside the window fold into it).
/// The scan reads live state, so listener storms are harmless. Output: a `CaptureSnapshot` of raw
/// bundle IDs running input IO. No classification, no policy — that is the engine's.
final class MeetingSensor {
    private let queue = DispatchQueue(label: "eu.fmasi.parley.meeting-sensor", qos: .utility)
    private let onSnapshot: @Sendable (CaptureSnapshot) -> Void
    private let signposter = OSSignposter(subsystem: "eu.fmasi.parley", category: "meeting-sensor")

    // All state below is touched only on `queue`.
    private var running = false
    private var scanPending = false
    private var oneShot: DispatchWorkItem?
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenedDevices: Set<AudioObjectID> = []
    private var listenedProcesses: Set<AudioObjectID> = []
    private var watchedBundleIDs: Set<String> = []
    /// Process object → bundle ID from the last scan (only for capturing or watched processes).
    private var processBundleIDs: [AudioObjectID: String] = [:]
    private var loggedHALFailure = false

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    init(onSnapshot: @escaping @Sendable (CaptureSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    deinit { queue.sync { stopOnQueue() } }

    // MARK: - Public (thread-safe; every call hops to the queue)

    func start() { queue.async { self.startOnQueue() } }
    func stop() { queue.async { self.stopOnQueue() } }

    /// The engine's `.watch(bundleIDs:)`: hold per-process listeners on exactly these bundle IDs.
    func setWatched(bundleIDs: Set<String>) {
        queue.async {
            self.watchedBundleIDs = bundleIDs
            guard self.running else { return }
            self.reconcileProcessListeners()
        }
    }

    /// The engine's `.scheduleScan(after:)`: a one-shot that runs an ordinary scan. Replaces any pending one.
    func scheduleScan(after seconds: TimeInterval) {
        queue.async {
            self.oneShot?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.wake() }
            self.oneShot = item
            self.queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    // MARK: - Lifecycle (on queue)

    private func startOnQueue() {
        guard !running else { return }
        running = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.wake() }
        listener = block
        var devices = Self.address(kAudioHardwarePropertyDevices)
        var processes = Self.address(kAudioHardwarePropertyProcessObjectList)
        let s1 = AudioObjectAddPropertyListenerBlock(Self.system, &devices, queue, block)
        let s2 = AudioObjectAddPropertyListenerBlock(Self.system, &processes, queue, block)
        if s1 != noErr || s2 != noErr {
            Logger.audio.error("Meeting sensor: system HAL listener registration failed (\(s1), \(s2))")
        }
        scan()   // first scan: one-time HAL client init (~50 ms measured) — here, never on main
        Logger.audio.info("Meeting sensor started — \(self.listenedDevices.count) input device listener(s)")
    }

    private func stopOnQueue() {
        guard running, let block = listener else { return }
        running = false
        oneShot?.cancel(); oneShot = nil
        scanPending = false
        var devices = Self.address(kAudioHardwarePropertyDevices)
        var processes = Self.address(kAudioHardwarePropertyProcessObjectList)
        _ = AudioObjectRemovePropertyListenerBlock(Self.system, &devices, queue, block)
        _ = AudioObjectRemovePropertyListenerBlock(Self.system, &processes, queue, block)
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for device in listenedDevices {
            _ = AudioObjectRemovePropertyListenerBlock(device, &running, queue, block)
        }
        listenedDevices = []
        var input = Self.address(kAudioProcessPropertyIsRunningInput)
        for process in listenedProcesses {
            _ = AudioObjectRemovePropertyListenerBlock(process, &input, queue, block)
        }
        listenedProcesses = []
        listener = nil
        Logger.audio.info("Meeting sensor stopped")
    }

    // MARK: - Wake + scan (on queue)

    private func wake() {
        guard running, !scanPending else { return }
        scanPending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scan() }
    }

    private func scan() {
        scanPending = false
        guard running else { return }
        let interval = signposter.beginInterval("scan")
        defer { signposter.endInterval("scan", interval) }

        let processes = Self.objectList(Self.system, kAudioHardwarePropertyProcessObjectList)
        var capturing: Set<String> = []
        var bundles: [AudioObjectID: String] = [:]
        for process in processes {
            let isCapturing = Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1
            // Bundle IDs are read only where needed: capturing processes (for the snapshot) and, while
            // a watch is active, every process (to find the watched apps' helpers).
            guard isCapturing || !watchedBundleIDs.isEmpty else { continue }
            let bundleID = Self.string(process, kAudioProcessPropertyBundleID) ?? ""
            bundles[process] = bundleID
            if isCapturing { capturing.insert(bundleID) }
        }
        processBundleIDs = bundles
        reconcileDeviceListeners()
        reconcileProcessListeners()
        Logger.audio.debug("Meeting sensor scan: \(processes.count) processes, capturing \(capturing.sorted(), privacy: .public)")
        onSnapshot(CaptureSnapshot(capturingBundleIDs: capturing))
    }

    // MARK: - Listener reconciliation (on queue)

    private func reconcileDeviceListeners() {
        guard let block = listener else { return }
        let inputDevices = Set(Self.objectList(Self.system, kAudioHardwarePropertyDevices).filter(Self.hasInput))
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for device in inputDevices.subtracting(listenedDevices) {
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
            if status == noErr { listenedDevices.insert(device) } else { logOnce("device listener add failed: \(status)") }
        }
        for device in listenedDevices.subtracting(inputDevices) {
            _ = AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)   // may be gone already
            listenedDevices.remove(device)
        }
    }

    private func reconcileProcessListeners() {
        guard let block = listener else { return }
        let targets = Set(processBundleIDs.filter { watchedBundleIDs.contains($0.value) }.keys)
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        for process in targets.subtracting(listenedProcesses) {
            let status = AudioObjectAddPropertyListenerBlock(process, &address, queue, block)
            if status == noErr { listenedProcesses.insert(process) } else { logOnce("process listener add failed: \(status)") }
        }
        for process in listenedProcesses.subtracting(targets) {
            // TASK 0: if Remove on a vanished object returns non-noErr, that is expected — log at debug only.
            let status = AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            if status != noErr { Logger.audio.debug("Meeting sensor: remove listener on process \(process) → \(status)") }
            listenedProcesses.remove(process)
        }
    }

    private func logOnce(_ message: String) {
        guard !loggedHALFailure else { return }
        loggedHALFailure = true
        Logger.audio.error("Meeting sensor: \(message, privacy: .public)")
    }

    // MARK: - Core Audio property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector); var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector); var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`. Expected: success. (Nothing constructs the sensor yet — Task 9 wires it.)

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Services/MeetingSensor.swift
git commit -m "feat(sensing): MeetingSensor — HAL wake listeners + coalesced scan on a private queue (#118)"
```

---

## Task 8: The island — `MeetingIslandController` + `MeetingIslandView`

**Files:**
- Create: `TranscriberApp/Services/MeetingIslandController.swift`
- Create: `TranscriberApp/Views/MeetingIslandView.swift`

**Interfaces — Produces:** `MeetingIslandOffer`, `MeetingIslandController.show/update/hide`.

Design decisions locked here (report to the owner if any looks wrong): fixed sizes (expanded 440×56 pt, compact 150×28 pt) so the panel never needs a SwiftUI-driven resize; placement is *just below the menu bar*, centred, on `NSScreen.main`, for notched and non-notched displays alike (the visible frame already excludes the menu bar and notch — hugging the notch would overlap menu-bar items); collapse after 20 s only while the pointer is not over the pill.

- [ ] **Step 1: The view**

```swift
// TranscriberApp/Views/MeetingIslandView.swift
import SwiftUI

/// What the island shows. The presenter builds one per offer (start or stop) and owns the callbacks.
struct MeetingIslandOffer {
    let title: String
    var subtitle: String
    let primaryTitle: String
    let primary: @MainActor () -> Void
    /// Secondary choices behind the chevron: ("Name it first…", …), ("Not now", …), …
    let menu: [(title: String, action: @MainActor () -> Void)]
    /// Compact state text: the app name ("Zoom").
    let compactLabel: String
}

@MainActor
@Observable
final class MeetingIslandModel {
    var offer: MeetingIslandOffer
    var isExpanded: Bool
    var isHovering = false
    init(offer: MeetingIslandOffer, isExpanded: Bool) { self.offer = offer; self.isExpanded = isExpanded }
}

/// Notion-style pill: icon · title + subtitle · ONE primary button · chevron menu. Compact = red dot + app name.
struct MeetingIslandView: View {
    @Bindable var model: MeetingIslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let expandedSize = CGSize(width: 440, height: 56)
    static let compactSize = CGSize(width: 150, height: 28)

    var body: some View {
        Group {
            if model.isExpanded { expanded } else { compact }
        }
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onHover { model.isHovering = $0 }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.isExpanded)
        // One-shot: collapse 20 s after expanding, unless the pointer is on it (then re-arm). Never repeats.
        .task(id: model.isExpanded) {
            guard model.isExpanded else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { return }
                if !model.isHovering { model.isExpanded = false; return }
            }
        }
    }

    private var expanded: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.offer.title).font(.headline).lineLimit(1)
                Text(model.offer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(model.offer.primaryTitle) { model.offer.primary() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            Menu {
                ForEach(Array(model.offer.menu.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { item.action() }
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("More options")
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 8)
        .frame(width: Self.expandedSize.width, height: Self.expandedSize.height)
    }

    private var compact: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(model.offer.compactLabel).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(width: Self.compactSize.width, height: Self.compactSize.height)
        .contentShape(Capsule())
        .onTapGesture { model.isExpanded = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(model.offer.title) — \(model.offer.compactLabel). Activate to expand.")
    }
}
```

- [ ] **Step 2: The controller**

```swift
// TranscriberApp/Services/MeetingIslandController.swift
import AppKit
import SwiftUI
import os

/// The prompt surface (#118, D1): a top-centre, non-activating floating panel — Parley's own window, so
/// it needs no notification permission, ignores Focus, and shows over full-screen call apps without
/// taking focus from them. Created on the first offer, released on withdraw: no idle window.
/// Follows the `SessionNameWindowController` panel pattern.
@MainActor
final class MeetingIslandController {
    private var panel: NSPanel?
    private var model: MeetingIslandModel?

    func show(_ offer: MeetingIslandOffer, expanded: Bool) {
        if let model {
            model.offer = offer
            model.isExpanded = expanded
        } else {
            let model = MeetingIslandModel(offer: offer, isExpanded: expanded)
            self.model = model
            panel = makePanel(model: model)
        }
        reposition()
        // A non-activating panel is silent to VoiceOver unless we say something.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(offer.title) \(offer.subtitle)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        Logger.state.debug("Island shown (expanded: \(expanded))")
    }

    func update(subtitle: String) {
        model?.offer.subtitle = subtitle
    }

    func hide() {
        guard let panel else { return }
        let finish = { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
            self?.model = nil
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: finish)
        }
        Logger.state.debug("Island hidden")
    }

    private func makePanel(model: MeetingIslandModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: MeetingIslandView.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none          // keep it out of screen shares — unverified on macOS 15+, device test
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the SwiftUI capsule draws its own shadow
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        let hosting = NSHostingView(rootView: MeetingIslandView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; panel.animator().alphaValue = 1 }
        }
        return panel
    }

    /// Top-centre of the screen with the menu bar focus, just below the menu bar. `visibleFrame`
    /// already excludes the menu bar (and, on a notched display, the notch row), so one rule fits both.
    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // The panel is always the expanded size; the SwiftUI pill (expanded or compact) is centred inside
        // the hosting view, and the clear background makes the unused area invisible and click-through.
        let origin = NSPoint(x: frame.midX - MeetingIslandView.expandedSize.width / 2,
                             y: frame.maxY - MeetingIslandView.expandedSize.height - 8)
        panel.setFrame(NSRect(origin: origin, size: MeetingIslandView.expandedSize), display: true)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`. Expected: success.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/MeetingIslandController.swift TranscriberApp/Views/MeetingIslandView.swift
git commit -m "feat(sensing): top-centre non-activating island panel (#118)"
```

---

## Task 9: `MeetingPromptPresenter` + wiring + menu banner

**Files:**
- Create: `TranscriberApp/Services/MeetingPromptPresenter.swift`
- Modify: `TranscriberApp/TranscriberApp.swift` (create + activate the presenter after both launch gates; pass it to `MenuView`)
- Modify: `TranscriberApp/Views/MenuView.swift` (banner with Record/Stop; `presenter` property)

**Interfaces — Consumes:** everything from Tasks 1-8. **Produces:** `MeetingPromptPresenter` (see Interfaces block), `MenuView.init(... presenter: MeetingPromptPresenter ...)`.

- [ ] **Step 1: The presenter**

```swift
// TranscriberApp/Services/MeetingPromptPresenter.swift
import AppKit
import Foundation
import Observation
import TranscriberCore
import os

/// Re-runs `read` whenever an `@Observable` property it touched changes (recursive
/// `withObservationTracking`). `onChange` fires before the new value lands, so the re-read is deferred
/// one main-actor hop and sees it.
@MainActor
private func keepObserving(_ read: @escaping @MainActor () -> Void) {
    withObservationTracking { read() } onChange: {
        Task { @MainActor in keepObserving(read) }
    }
}

/// Turns engine actions into UI (island, menu-bar icon, banner) and routes the user's answers back
/// (#118). Owns the engine state, the sensor and the island; runs the two observation loops
/// (`AppState.phase`, `Config.meetingSensing`). Never starts or stops a recording on its own — every
/// `quickStart`/`stopRecording` below is the direct result of a click.
@MainActor
final class MeetingPromptPresenter {
    private static let disclosureShownKey = "meeting_sensing_disclosure_shown"

    private let appState: AppState
    private let configManager: ConfigManager
    private let coordinator: RecordingCoordinator
    private let launcher: RecordingLauncher
    private let calendarService: CalendarService
    private let island = MeetingIslandController()
    private var sensor: MeetingSensor!
    private var state = MeetingSenseState()
    private var mode: MeetingSenseMode = .off
    /// The user chose Record while transcribing; fires when the phase becomes idle, only if the app is
    /// still capturing then.
    private var queuedStart: MeetingApp?
    private var calendarTitle: String?

    init(appState: AppState, configManager: ConfigManager, coordinator: RecordingCoordinator,
         launcher: RecordingLauncher, calendarService: CalendarService) {
        self.appState = appState
        self.configManager = configManager
        self.coordinator = coordinator
        self.launcher = launcher
        self.calendarService = calendarService
        sensor = MeetingSensor { [weak self] snapshot in
            Task { @MainActor in self?.feed(.snapshot(snapshot)) }
        }
    }

    /// Call once, after launch-time crash recovery AND the launch gate have both completed — so a
    /// relaunch mid-recording never shows the engine an `.idle` phase with a call in progress.
    func activate() {
        keepObserving { [weak self] in
            guard let self else { return }
            self.feed(.phaseChanged(Self.sensePhase(of: self.appState.phase)))
            self.fireQueuedStartIfIdle()
        }
        keepObserving { [weak self] in
            guard let self else { return }
            self.modeChanged(self.configManager.config.meetingSensing)
        }
    }

    // MARK: - User answers (island menu / banner buttons)

    func record(_ app: MeetingApp) {
        island.hide()
        if appState.isTranscribing {
            queuedStart = app
            appState.detectedMeeting = DetectedMeeting(app: app, kind: .queued)
            return
        }
        let title = calendarTitle
        Task { [launcher] in
            if await !launcher.quickStart(app: app, calendarTitle: title) {
                Logger.state.warning("Quick start refused (not idle / start in flight)")
            }
        }
    }

    func nameFirst() {
        island.hide()   // the banner stays until the recording starts
        Task { [launcher] in await launcher.promptAndStart() }
    }

    func notNow() { feed(.notNow) }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    func stop() {
        island.hide()
        Task { [coordinator] in await coordinator.stopRecording() }
    }

    func keepRecording() { feed(.keepRecording) }

    // MARK: - Engine plumbing

    private func feed(_ input: MeetingSenseInput) {
        let result = MeetingSenseEngine.step(state, input: input, mode: mode, now: Date())
        state = result.state
        result.actions.forEach(apply)
    }

    private func modeChanged(_ newMode: MeetingSenseMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .prompt {
            sensor.start()
        } else {
            sensor.stop()
            feed(.snapshot(CaptureSnapshot(capturingBundleIDs: [])))   // mode .off → the engine withdraws
        }
    }

    private func apply(_ action: MeetingSenseAction) {
        switch action {
        case .offerStart(let app, let expand):
            showStartOffer(app, expand: expand)
        case .withdrawStart:
            island.hide()
            appState.detectedMeeting = nil
            queuedStart = nil
            calendarTitle = nil
        case .offerStop(let app):
            showStopOffer(app)
        case .withdrawStop:
            island.hide()
            appState.detectedMeeting = nil
        case .watch(let bundleIDs):
            sensor.setWatched(bundleIDs: bundleIDs)
        case .scheduleScan(let after):
            sensor.scheduleScan(after: after)
        }
    }

    private func showStartOffer(_ app: MeetingApp, expand: Bool) {
        let firstEver = !UserDefaults.standard.bool(forKey: Self.disclosureShownKey)
        let subtitle = firstEver
            ? "Parley noticed \(app.displayName) using the mic — it only checks which app, on this Mac, and never listens."
            : "\(app.displayName) is using the microphone"
        if firstEver { UserDefaults.standard.set(true, forKey: Self.disclosureShownKey) }
        island.show(MeetingIslandOffer(
            title: "Record this meeting?",
            subtitle: subtitle,
            primaryTitle: "Record",
            primary: { [weak self] in self?.record(app) },
            menu: [
                ("Name it first…", { [weak self] in self?.nameFirst() }),
                ("Not now", { [weak self] in self?.notNow() }),
                ("Turn off meeting detection…", { [weak self] in self?.openSettings() }),
            ],
            compactLabel: app.displayName
        ), expanded: expand)
        appState.detectedMeeting = DetectedMeeting(app: app, kind: .start)
        // Calendar title, off main and bounded; only decorates the subtitle after the disclosure.
        Task { [weak self] in
            guard let self else { return }
            let title = await self.calendarService.currentEventTitle(
                lookaheadMinutes: self.configManager.config.calendarLookaheadMinutes)
            guard let title, self.state.pendingStart == app else { return }
            self.calendarTitle = title
            if !firstEver { self.island.update(subtitle: "\(title) · \(app.displayName)") }
        }
    }

    private func showStopOffer(_ app: MeetingApp) {
        let session = RecordingSentinel.read()?.sessionName ?? "this recording"
        island.show(MeetingIslandOffer(
            title: "Stop recording?",
            subtitle: "\(app.displayName) released the microphone · \(session)",
            primaryTitle: "Stop",
            primary: { [weak self] in self?.stop() },
            menu: [("Keep recording", { [weak self] in self?.keepRecording() })],
            compactLabel: app.displayName
        ), expanded: true)
        appState.detectedMeeting = DetectedMeeting(app: app, kind: .stop)
    }

    private func fireQueuedStartIfIdle() {
        guard let app = queuedStart, appState.isIdle else { return }
        queuedStart = nil
        guard state.capturing[app] != nil else {   // the call ended meanwhile: drop it
            appState.detectedMeeting = nil
            return
        }
        let title = calendarTitle
        Task { [launcher] in _ = await launcher.quickStart(app: app, calendarTitle: title) }
    }

    private static func sensePhase(of phase: AppState.Phase) -> MeetingSensePhase {
        switch phase {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        }
    }
}
```

- [ ] **Step 2: Wire it in `TranscriberApp.swift`**

Add a stored property after `@State private var launcher: RecordingLauncher`:

```swift
    @State private var meetingPresenter: MeetingPromptPresenter
```

In `init()`, right after `_launcher = State(initialValue: …)`:

```swift
        let presenter = MeetingPromptPresenter(
            appState: state, configManager: configManager, coordinator: recordingCoordinator,
            launcher: _launcher.wrappedValue, calendarService: calendarService
        )
        _meetingPresenter = State(initialValue: presenter)
```

Replace the crash-recovery Task (lines 137-142) and the gate Task (lines 180-184) with ONE sequenced task — sensing starts only after both have completed (spec §1 Lifecycle):

```swift
        let client = captureClient
        let runner = transcriptionRunner
        let gate = launchGate
        let cm = configManager
        Task { @MainActor in
            await Self.recoverIfNeeded(captureClient: client, appState: state, transcriptionRunner: runner)
            await gate.checkAndGate(configManager: cm)
            // Setup may still be open (permissionsReady flips from its Continue button): wait for it.
            await Self.waitUntilReady(gate)
            presenter.activate()
        }
```

and add the helper next to `recoverIfNeeded`:

```swift
    @MainActor
    private static func waitUntilReady(_ gate: LaunchGate) async {
        while !gate.permissionsReady {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = gate.permissionsReady } onChange: { continuation.resume() }
            }
        }
    }
```

Pass the presenter to the menu: add `presenter: meetingPresenter,` to the `MenuView(...)` call.

- [ ] **Step 3: The banner in `MenuView`**

Add `let presenter: MeetingPromptPresenter` after `let launcher: RecordingLauncher` and the matching init parameter/assignment. In `body`, directly after the `alertBanners` block, add:

```swift
            if let detected = appState.detectedMeeting {
                meetingBanner(detected)
            }
```

and the view (mirrors `notificationWarningRow`'s quiet style):

```swift
    /// Backup surface for a standing meeting-sensing offer (#118): the island may have been closed
    /// without an answer, or collapsed. Same one-click Record/Stop as the island.
    private func meetingBanner(_ detected: DetectedMeeting) -> some View {
        let (message, action, icon): (String, String?, String) = {
            switch detected.kind {
            case .start: return ("\(detected.app.displayName) call in progress", "Record", "waveform.badge.mic")
            case .queued: return ("Will start when the previous recording finishes processing", nil, "clock")
            case .stop: return ("\(detected.app.displayName) released the microphone", "Stop", "stop.circle")
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.red).font(.footnote)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action) {
                    dismissPanel()
                    switch detected.kind {
                    case .start: presenter.record(detected.app)
                    case .stop: presenter.stop()
                    case .queued: break
                    }
                }
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }
```

- [ ] **Step 4: Build, then device smoke**

Run: `swift build`. Expected: success. Then `python3 scripts/dev.py --debug` and: start a Zoom call → within ~1 s the island appears expanded, the menu-bar icon changes, the menu shows the banner; click **Record** → recording starts named "Zoom call" (or the calendar title); leave the call → after 30 s the stop island appears; click **Stop** → transcribes. Watch the log for `Meeting sensor scan:` lines only on audio events — none while idle.

- [ ] **Step 5: Commit**

```bash
git add TranscriberApp/Services/MeetingPromptPresenter.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift
git commit -m "feat(sensing): MeetingPromptPresenter — island/icon/banner offers, answers, queued start (#118)"
```

---

## Task 10: Settings toggle + Setup disclosure

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift:137-150` (General → after the "Startup" section)
- Modify: `TranscriberApp/Views/SetupView.swift:99-113` (hero)

- [ ] **Step 1: Settings → General**

Insert after the `Section("Startup") { … }` block:

```swift
        Section("Meeting Detection") {
            Toggle("Offer to record when a meeting starts", isOn: Binding(
                get: { config.meetingSensing == .prompt },
                set: { config.meetingSensing = $0 ? .prompt : .off }
            ))
            Text("Parley checks which app is using the microphone — on this Mac only; it never listens. Works with Zoom, Teams, Webex, Slack, Discord, and calls in Chrome, Safari, Arc, Edge and Firefox.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
```

Save-applied like every other setting: `save()` writes `config` to `ConfigManager`, and the presenter's observation loop reacts to `configManager.config.meetingSensing` — no special-casing here.

- [ ] **Step 2: Setup window — one line under the promise** (inside `hero`, after the "Private, on-device meeting transcription." text):

```swift
            Text("When a meeting app starts using your mic, Parley offers to record — it only checks which app, never listens. Turn it off any time in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
```

- [ ] **Step 3: Build + device check**

Run: `swift build`. Then `python3 scripts/dev.py`: toggle off + Save → the log shows `Meeting sensor stopped` and a call no longer prompts; toggle on + Save → `Meeting sensor started`.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift TranscriberApp/Views/SetupView.swift
git commit -m "feat(sensing): Settings toggle + Setup disclosure line (#118, D6)"
```

---

## Task 11: Docs — parameters, device checklist, CLAUDE.md, README badge

**Files:**
- Modify: `docs/parameters.md:70-76` (System table)
- Modify: `scripts/test-checklist.md` (replace the top with this feature's section; prune sections that are not on this branch — the memory rule is "only current tests")
- Modify: `CLAUDE.md` (architecture lines for new files; the test count)
- Modify: `README.md:10` badge and `:204` layout line

- [ ] **Step 1: `docs/parameters.md`** — add to the System table:

```markdown
| Meeting sensing | `meeting_sensing` | `"prompt"` | `"prompt"` offers to record when a known meeting app or browser starts using the microphone (an island panel, the menu-bar icon and an in-menu banner), and offers to stop when every watched call app has released the mic for 30 s. `"off"` disables sensing. **Never auto-records or auto-stops** — every recording still starts from a click. Airgapped: reads only which local process holds the mic (Core Audio process objects), no audio, no network. Missing key = `"prompt"`. |
```

- [ ] **Step 2: `scripts/test-checklist.md`** — put this section first, under the build line:

```markdown
## Meeting sensing (#118 — this branch)
Setup: notifications OFF in System Settings (the island must not depend on them); a Zoom account,
Teams, Chrome and Safari; a calendar event covering "now" for the naming check.
- [ ] **Zoom native call → island within ~1 s**, expanded: title "Record this meeting?", subtitle "Zoom is using the microphone" (first ever: the disclosure line instead). Menu-bar icon changes; the menu shows the "Zoom call in progress" banner with Record.
- [ ] **Teams native, Meet in Chrome, Meet in Safari** → same, with the right app name.
- [ ] **Record from the island** → recording starts immediately, no naming panel; session named from the calendar event when one covers now, else "Zoom call". Island gone, icon back to recording, banner gone.
- [ ] **Name it first…** → the naming panel, prefilled; recording starts on Start.
- [ ] **Not now** → island gone; no re-prompt for this call; leave and rejoin → prompts again (compact if within 5 min).
- [ ] **Island untouched 20 s → compact pill** (red dot + app name); click → expands again.
- [ ] **Browser dictation (Chrome voice search)** → at most one prompt; Not now suppresses it.
- [ ] **FaceTime call** → no prompt.
- [ ] **Leave the call while recording → stop island after ~30 s**; Stop → transcribes. Keep recording → gone, no re-prompt until the app re-acquires and releases again.
- [ ] **Mute for 60 s mid-call** → no stop offer. Switch mic mid-call → no stop offer.
- [ ] **Full-screen Zoom** → island shows over it; Zoom keeps focus (typing in Zoom chat still works while the island is up).
- [ ] **Screen-share in Zoom** → the other side does NOT see the island (`sharingType = .none`). If they do: file it — fallback is compact-only during shares.
- [ ] **Second monitor** → island on the screen with the menu bar focus. Notched vs non-notched: sits just below the menu bar, centred.
- [ ] **Record from the island while Settings › Audio (mic picker + meter) is open on the same mic** → the recording starts and the app does not freeze (gotcha #68 corollary 2). If it hangs: `quickStart` must call `InputLevelMonitor.stopAndRelease` on open meters first.
- [ ] **Relaunch Parley mid-recording mid-call** (force-quit, relaunch, Flow A re-attach) → NO start offer; leave the call → stop offer still comes after 30 s.
- [ ] **Record chosen while transcribing** → banner "Will start when the previous recording finishes processing"; when idle → starts only if the call is still on; end the call before then → nothing starts, banner clears.
- [ ] **Settings toggle off + Save** → log `Meeting sensor stopped`; a call no longer prompts. On + Save → `Meeting sensor started`.
- [ ] **Idle cost:** Activity Monitor → Parley → "Idle Wake Ups" over 10 min with sensing on vs off: indistinguishable. No `Meeting sensor scan:` log lines while nothing starts/stops audio. Record scan durations from `log stream --predicate 'subsystem == "eu.fmasi.parley" AND category == "meeting-sensor"'` (signposts) — note M5 Pro figures and flag M1 Air as extrapolated if not measured there.
- [ ] **Manual Record from the menu** unchanged (naming panel, mic label follows the switcher).
```

- [ ] **Step 3: `CLAUDE.md`** — in the TranscriberApp file list add:

```markdown
- `TranscriberApp/Services/RecordingLauncher.swift` -- the two ways a recording starts (naming panel / quick start), hoisted out of MenuView; owns the remembered mic pick
- `TranscriberApp/Services/MeetingSensor.swift` -- meeting sensing (#118): Core Audio HAL wake listeners (input devices + process list + watched processes) → coalesced scan → `CaptureSnapshot`; private queue, no polling
- `TranscriberApp/Services/MeetingPromptPresenter.swift` -- turns `MeetingSenseEngine` actions into the island / menu-bar icon / banner and routes answers back; queued start while transcribing
- `TranscriberApp/Services/MeetingIslandController.swift` + `Views/MeetingIslandView.swift` -- top-centre non-activating island panel (expanded → compact after 20 s)
```

and in the TranscriberCore list:

```markdown
- `TranscriberCore/MeetingSenseEngine.swift` -- pure meeting-sensing engine: `step(state, input, mode, now) → (state, actions)`; start/stop offers, watched set, 30 s stop debounce, per-episode suppression, expansion cooldown
- `TranscriberCore/MeetingApps.swift` -- reviewable classification table: bundle ID (incl. helpers) → `MeetingApp` family; Parley's own prefix always excluded
```

- [ ] **Step 4: Test count** — RUN TESTS with no suite filter; take `N tests in M suites` from the final `Test run with … passed` line and write it into `README.md:10` (`tests-N%20passing`), `README.md:204` and the CLAUDE.md Build & Test block (`N tests across M suites`). Never estimate.

- [ ] **Step 5: Commit**

```bash
git add docs/parameters.md scripts/test-checklist.md CLAUDE.md README.md
git commit -m "docs(sensing): meeting_sensing parameter, device checklist, architecture notes, test count (#118)"
```

---

## Task 12: Gotcha entry — ONLY if Task 0 taught one

**Files:**
- Modify: `docs/gotchas.md` (append as #69), `CLAUDE.md` ("68 platform-specific gotchas" → 69, both mentions)

Candidates, each written only if observed in Task 0 with the measurement in the text: per-process `IsRunningInput` listeners do/don't fire on release; `AudioObjectRemovePropertyListenerBlock` on a vanished Process object returns `kAudioHardwareBadObjectError` and the block is (or is not) reclaimed; Safari's audio identity is `com.apple.WebKit.GPU` with no Safari bundle ID; a call app that keeps the input open after leaving. Follow the existing style: number, bold one-line rule, evidence, date.

- [ ] Commit: `git commit -am "docs(gotchas): #69 <one-line rule> (#118)"`

---

## Review gate (after the last task, before any push)

1. **Code council on the full diff BEFORE CI** (`docs/development-process.md`): `git diff main...HEAD` — dispatch the multi-agent council; both previous councils found real bugs inside fix code. Fix findings as additional commits on the branch.
2. **CI:** push the branch, open the PR against `main` with the Task 0 results table in the description, and monitor `test.yml` (the macOS suite wedges 2-in-3 runs — rerun, don't debug). Resolve every auto-review thread (unresolved threads block merge).
3. **Device test:** `python3 scripts/dev.py`, run every item in the "Meeting sensing (#118)" checklist section; paste the idle-wakeups and scan-duration numbers into the PR.
4. **Version:** MINOR → v0.10.0 (new capability).
5. **Hold the merge until v0.9.0 is tagged** — anything on `main` before then ships in v0.9.0.

---

## Self-review (done while writing; kept for the executor)

- **Spec coverage:** D1 island → Task 8/9; D2 per-process attribution → Task 7 scan; D3 browsers → Task 1; D4 stop prompt → Task 2 rules + Task 9 stop offer; D5 no polling → Task 7 (one-shot only) + Task 8 (20 s one-shot); D6 default on + disclosure → Task 4 (default), Task 9 (first-offer subtitle), Task 10 (caption + Setup line). §1 lifecycle sequencing → Task 9 Step 2. §2 every rule → Task 2 tests. §3 VoiceOver / Reduce Motion / sharingType → Task 8. §4 start guard → Task 3; hoist → Task 6; transcribing gate → Task 9 (`queuedStart`, lives in the presenter — it owns the engine state needed for the "still capturing" check). §5 → Task 5. §6 → Tasks 4, 10, 11. Failure modes → checklist items in Task 11. Known limitations → unchanged, file as issues at PR time.
- **Deviations from the spec text, on purpose:** `.watch` carries raw bundle IDs (the sensor needs process objects, not families); the engine gains `.notNow` / `.keepRecording` inputs (pure, testable, instead of the presenter mutating state); the queued start lives in the presenter; the island sits just below the menu bar on every display; a pre-deadline snapshot reschedules the remainder; withdrawal promotes another capturing app.
- **Type consistency:** `MeetingApp`, `CaptureSnapshot(capturingBundleIDs:)`, `MeetingSenseAction.watch(bundleIDs:)`, `.scheduleScan(after:)`, `DetectedMeeting(app:kind:)` with `.start/.queued/.stop`, `RecordingLauncher.quickStart(app:calendarTitle:) -> Bool`, `CalendarService.currentEventTitle(lookaheadMinutes:timeout:) async`, `MeetingSensor.setWatched(bundleIDs:)`/`scheduleScan(after:)` — used identically in Tasks 2, 4, 5, 6, 7, 9.
