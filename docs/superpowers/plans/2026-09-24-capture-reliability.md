# Capture Reliability Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For each side of a recording, exactly one of "captured / healed within seconds / user told loudly and persistently" is always true, and the saved record states truthfully how much of each side was captured.

**Architecture:** Every decision becomes a pure, unit-tested type in `TranscriberCore` (the `TapPermissionGuard` / `CaptureReadiness` pattern): a per-track liveness monitor fed by heartbeats stamped at the top of each audio callback and gated on "some OTHER process is running output"; a tap recovery ladder; a helper-owned, app-pulled alarm registry; per-track coverage accounting into provenance; and pure lifecycle decisions (interruption arming, LaunchAgent health, relaunch, disk). The helper (`AudioCaptureHelperXPC`) and the app (`TranscriberApp`) stay thin shells, because neither target has unit tests.

**Tech Stack:** Swift 5.9 tools / Swift 6.x toolchain, Swift Testing (not XCTest), `@MainActor`, `os.Logger`, CoreAudio HAL property listeners, NSXPC. Build: `python3 scripts/dev.py --build`. Tests: see Global Constraints.

**Spec:** `docs/superpowers/specs/2026-09-24-capture-reliability-design.md` — the plan argues from it; read both. Section references below (§4.2, M-B, …) are into the spec.

## Global Constraints

- macOS 15.0+, Apple Silicon. No Xcode on the dev machine for `swift test`; the app target only compiles through `python3 scripts/dev.py --build` (it expands SwiftUI macros). Every task that touches `TranscriberApp/` or `AudioCaptureHelper/` ends with that build.
- Tests use **Swift Testing** (`@Test`, `#expect`, `Issue.record`) under `SwiftTests/TranscriberTests/` (never `Tests/`).
- Test command. The brief's full-suite invocation is `swift test --no-parallel --filter TranscriberTests <flags>`; define the flags once per shell session so every task's `Run:` line is exact:
  ```bash
  export PARLEY_TEST="swift test --no-parallel -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/"
  $PARLEY_TEST --filter TranscriberTests                # the full suite (≈1220 tests today)
  $PARLEY_TEST --filter 'TrackLivenessMonitorTests'     # one suite (regex on the test id)
  ```
  `DiarizationMetamorphicTests` has a pre-existing flaky failure that also fails on `main`; it is not yours.
- **Red-first is enforced by CI** (`scripts/verify-regression-tests.sh`): every new or changed test file must FAIL at the merge base (a compile error against a new symbol counts) and PASS at HEAD. A characterization test of existing behaviour must carry `// RED-FIRST-EXEMPT: <reason>`. Each task says which of the two its tests are.
- App and helper ship together in one bundle: `AudioCaptureProtocol` additions are new methods (never signature changes of existing ones) and reverse-channel additions are `@objc optional`, matching `captureQualityAnomaly`.
- Airgap holds: no network, no telemetry. Log privacy: names/paths `.private`/`.sensitive`, never `.public`.
- Rate band stays **0.95–1.05** (`RateDriftMonitor`); the audit's [0.9, 1.1] is refuted. Coverage uses deficit ≥ 15 s AND ≥ 10 % (§4.4).
- `SystemTapSession.stopAndFinalize`-on-disconnect stays (§8.3). No "helper keeps capturing after disconnect" until M-L1 is measured.
- Never propose SCK as a fix (§13). SCK code is only touched where a shared type forces it.
- Process per `docs/development-process.md`: each phase ends with a code council over the phase's whole diff BEFORE pushing, then CI, then the device items in P4 for that phase. Version: **MINOR** (§14).
- Product defaults in §11 (SCK default, SpeechAnalyzer default, quota scope) are NOT changed by any task here without the owner's written answer; P2.9 ships the preflight and label only.
- Commit after every task (`git add <files>` + the message given). Do not push.

## Review Focus

The five inputs the spec implies but no task's tests naturally exercise; each is pinned to a test in the owning task:

1. **Gate flapping at 1 Hz** (a call app toggling its output IO every second) — the monitor must report one gap per episode, not one per flap. Pinned: P0.3 `gateFlapReportsAtMostOncePerEpisode`.
2. **A helper newer than the app sends an unknown `AlarmKind`** — decoding must keep the known alarms, not drop the whole snapshot. Pinned: P0.4 `snapshotWithUnknownKindKeepsTheOthers`.
3. **A heartbeat timestamp newer than "now"** (two clocks read on different queues) — must read as healthy, never as a negative or huge gap. Pinned: P0.3 `heartbeatInTheFutureIsHealthy`.
4. **Two ladder triggers inside one backoff window** (an aggregate listener and a monitor verdict for the same stall) — one rung runs, not two racing rebuilds. Pinned: P1.1 `secondTriggerWhileARungIsInFlightIsIgnored`.
5. **Coverage where the probe failed open** (`expectedSeconds == 0`, `deliveredSeconds > 0`) — status is `healthy`, never `neverDelivered` or `idle`. Pinned: P2.1 `deliveredWithNothingExpectedIsHealthyNotIdle`.

## File Structure

New pure cores (all `TranscriberCore/`, each with a matching `SwiftTests/TranscriberTests/<Name>Tests.swift`):

| File | Responsibility |
|---|---|
| `XPCInterruptionPolicy.swift` | crash-detection arming per capture generation (§8.1) |
| `LaunchAgentHealth.swift` | judge plist/launchctl state → repair action (§8.2) |
| `TrackLivenessMonitor.swift` | never-delivered / stalled / cleared / first-frames per track (§4.2); replaces `LivenessGapDetector.swift` |
| `OutputActivity.swift` | "any other process running output" (§4.3) |
| `CaptureAlarm.swift` | `AlarmKind`, `ActiveAlarm`, `CaptureAlarmRegistry`, `CaptureStatusSnapshot`, `AlarmRealarmPolicy` (§6) |
| `TapRecoveryLadder.swift` | rungs, backoff, budget, slow retry (§5) |
| `TrackAccounting.swift` | per-track coverage and status (§7.1) |
| `RelaunchDecision.swift` | reattach / resume / salvage at launch (§8.3) |
| `DiskSpaceCheck.swift` | bytes per chunk, start/rotation thresholds (§8.7) |
| `MonotonicWallClock.swift` | wall clock anchored to `ContinuousClock` (§8.12) |
| `LiveDiagnosticsLog.swift` | append-as-you-go anomaly log and merge (§8.11) |

Modified cores: `CaptureDiagnostics.swift` (new event kinds, provenance coverage, counters), `ChunkSession.swift` (`ChunkIssue`, `ProcessedChunk.issues`, `SessionState.issues`, id-checked read), `ChunkProcessor.swift`, `TranscriptionRunner.swift`, `AudioArchiver.swift`, `AudioConcatenator.swift`, `SpeakerAssignment.swift`, `TranscriptRediarizer.swift`, `TranscriptAssembler.swift`, `CaptureQualityNotice.swift`, `MeetingSummarizer.swift`, `SummaryPromptBuilder.swift`, `RecordingCoordinator.swift`, `RecordingCaptureClient.swift`, `RecordingSentinel.swift`, `AppState.swift`, `LaunchAgentManager.swift`, `PadRatioMonitor.swift`, `TapPermissionGuard.swift`, `EngineID.swift`, `Config.swift`.

Thin shells: helper `AudioCaptureHelper/XPC/{OutputActivityProbe,TapHealer}.swift` (new), `SystemTapSession.swift`, `MicCaptureSession.swift`, `AudioCaptureService.swift`, `AudioOutputHandler.swift`, `LivenessWatchdogDriver.swift`, `main.swift`; protocol `AudioCaptureProtocol/AudioCaptureProtocol.swift`; app `TranscriberApp/Services/{CaptureAlarmWindowController,SystemEventObserver}.swift` (new), `AudioCaptureClient.swift`, `TranscriberApp.swift`, `Views/MenuView.swift`, `Views/CaptureAlarmView.swift` (new), `Views/RenameDialog.swift`.

Deleted: `TranscriberCore/LivenessGapDetector.swift`, `SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift`, the `PadRatioMonitorDeadTrackTests` suite (false coverage, L-N2), `TranscriberApp.setupCrashHandler` / `recoverIfNeeded` (moved into the coordinator).

## Phases

| Phase | Content | Size | Riskiest task |
|---|---|---|---|
| P0 | live-safety criticals: interruption arming, LaunchAgent, heartbeat + never-delivered, alarm contract, retry cap + coordinator at launch | 5 tasks, ~4 days | P0.4 (XPC contract across two targets with no tests) |
| P1 | tap healing ladder, aggregate/srst listeners, TapAutoStart knob | 5 tasks, ~4 days + M-B/M-C/M-D device time | P1.2 (HAL calls that may block on a paused context) |
| P2 | honest record: coverage provenance, chunk issues, archiver/concatenator, dedup, salvage, re-detect, small honesty fixes, engine preflight | 9 tasks, ~5 days | P2.3 (silence insertion in the composition; deletes lossless sources) |
| P3 | lifecycle: honest relaunch, stop/start races, disk, deadlines, sleep/wake, evidence | 6 tasks, ~5 days + M-L1..L5 | P3.1 (depends on M-L1; resumes a session across a process death) |
| P4 | device-test protocol, gotchas, checklist, docs, threshold decisions | 3 tasks, ~3 days of device time | none technical; owner time |

Each phase ends with: full suite green → `python3 scripts/dev.py --build` clean → code council over `git diff <phase-start>..HEAD` → fix the must-list → push for CI → the phase's device items in P4.1.

---

# Phase 0 — live-safety criticals

### Task P0.1: `XPCInterruptionPolicy` — crash detection armed per capture generation

**Files:**
- Create: `TranscriberCore/XPCInterruptionPolicy.swift`
- Modify: `TranscriberCore/CaptureDiagnostics.swift:8-109` (add `.helperIdleExit`)
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:10-111, 206-243, 351-362`
- Test: `SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift` (new, red-first: compile error at parent)

**Interfaces:**
- Consumes: `CrashClassification` (`CrashReportScanner.swift:5-8`).
- Produces:
  ```swift
  public struct XPCInterruptionPolicy: Equatable, Sendable {
      public enum Decision: Equatable, Sendable { case ignoreIdle, verifyCapture, briefInterruption, crash }
      public private(set) var captureGeneration: Int
      public private(set) var expectingCapture: Bool
      public init()
      public mutating func captureStarted()
      public mutating func captureStopped()
      public mutating func onInterruption(classification: CrashClassification) -> Decision
      public mutating func onVerified(stillCapturing: Bool, generation: Int) -> Decision
      public mutating func onInvalidation() -> Decision
  }
  ```
  `CaptureEventKind.helperIdleExit` (severity `.info`).

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// L-N1 (validated lifecycle §2.1): launchd idle-exits the helper ~10 min after the app goes
/// quiet. The client read that as a crash, latched "handled", and never ran recovery again for
/// the life of the process — the 2026-09-24 16:00 recording ran with crash detection disarmed.
@Suite struct XPCInterruptionPolicyTests {

    @Test func idleInterruptionIsIgnoredWithoutPingOrLatch() {
        var p = XPCInterruptionPolicy()
        #expect(p.onInterruption(classification: .transientBlip) == .ignoreIdle)
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.expectingCapture == false)
    }

    /// The exact incident shape: an idle-exit, then a recording starts, then a real crash.
    @Test func crashAfterAnIdleInterruptionStillFires() {
        var p = XPCInterruptionPolicy()
        _ = p.onInterruption(classification: .transientBlip)
        _ = p.onInvalidation()
        p.captureStarted()
        #expect(p.onInterruption(classification: .likelyCrash) == .crash)
    }

    @Test func blipVerifiesThenEscalatesOnceWhenTheHelperIsNotCapturing() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        #expect(p.onInterruption(classification: .transientBlip) == .verifyCapture)
        #expect(p.onVerified(stillCapturing: false, generation: gen) == .crash)
        // The trailing invalidation of the same dead connection must not fire a second recovery.
        #expect(p.onInvalidation() == .ignoreIdle)
    }

    @Test func blipWithTheHelperStillCapturingIsBrief() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        #expect(p.onVerified(stillCapturing: true, generation: gen) == .briefInterruption)
        // Still armed: a later real crash fires.
        #expect(p.onInvalidation() == .crash)
    }

    /// A restart bumped the generation while a verification ping from the old one was in flight.
    @Test func verificationFromAPreviousGenerationIsIgnored() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let old = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        p.captureStarted()
        #expect(p.onVerified(stillCapturing: false, generation: old) == .ignoreIdle)
    }

    @Test func stopDisarms() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        p.captureStopped()
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.onInterruption(classification: .likelyCrash) == .ignoreIdle)
    }

    @Test func aRestartReArmsAfterACrash() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        #expect(p.onInvalidation() == .crash)
        #expect(p.onInvalidation() == .ignoreIdle)   // one recovery per generation
        p.captureStarted()                           // the coordinator's restart
        #expect(p.onInvalidation() == .crash)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$PARLEY_TEST --filter 'XPCInterruptionPolicyTests'`
Expected: compile error, `cannot find 'XPCInterruptionPolicy' in scope`.

- [ ] **Step 3: Implement the policy**

`TranscriberCore/XPCInterruptionPolicy.swift`:
```swift
import Foundation

/// Decides what an XPC interruption or invalidation means, armed per capture generation.
///
/// Why a generation and not a Bool (L-N1): launchd idle-exits the embedded helper ~10 min after
/// its last message. The client's old `crashHandlerFired` latch treated that as "crash handled"
/// and was reset only in `connect()`, which never ran again — so every later real crash was
/// ignored. Arming happens in `captureStarted()` and every decision fires at most once per
/// generation; outside a capture nothing is pinged, latched or spawned.
public struct XPCInterruptionPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Not capturing (an idle-exit), or this generation already escalated: do nothing.
        case ignoreIdle
        /// No crash report: ask the helper whether it is still capturing, then call `onVerified`.
        case verifyCapture
        /// The helper is still capturing — a connection blip, keep recording.
        case briefInterruption
        /// Run crash recovery. Fires at most once per generation.
        case crash
    }

    public private(set) var captureGeneration = 0
    public private(set) var expectingCapture = false
    private var firedGeneration: Int?

    public init() {}

    public mutating func captureStarted() {
        captureGeneration += 1
        expectingCapture = true
    }

    public mutating func captureStopped() {
        expectingCapture = false
    }

    private var alreadyFired: Bool { firedGeneration == captureGeneration }

    public mutating func onInterruption(classification: CrashClassification) -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        if classification == .likelyCrash {
            firedGeneration = captureGeneration
            return .crash
        }
        return .verifyCapture
    }

    public mutating func onVerified(stillCapturing: Bool, generation: Int) -> Decision {
        guard expectingCapture, generation == captureGeneration, !alreadyFired else { return .ignoreIdle }
        if stillCapturing { return .briefInterruption }
        firedGeneration = captureGeneration
        return .crash
    }

    public mutating func onInvalidation() -> Decision {
        guard expectingCapture, !alreadyFired else { return .ignoreIdle }
        firedGeneration = captureGeneration
        return .crash
    }
}
```

Add to `CaptureEventKind` (`CaptureDiagnostics.swift`, after `.launchRecovery`):
```swift
    /// launchd idle-exited the helper while nothing was being captured. Informational: the
    /// connection interruption this produces is NOT a crash and must not arm or consume crash
    /// recovery (L-N1). Severity `.info`.
    case helperIdleExit
```

- [ ] **Step 4: Run to verify it passes**

Run: `$PARLEY_TEST --filter 'XPCInterruptionPolicyTests'`
Expected: 7 tests pass.

- [ ] **Step 5: Wire it into `AudioCaptureClient`**

In `TranscriberApp/Services/AudioCaptureClient.swift`:
- Replace `private var crashHandlerFired = false` (line 12) with `private var interruptionPolicy = XPCInterruptionPolicy()`.
- Delete `crashHandlerFired = false` at line 52 and the comment block at lines 215-217.
- Replace the interruption handler body (lines 63-95) with:
```swift
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let boundConnection = self.connection
                let classification = CrashReportScanner.classifyLive()
                switch self.interruptionPolicy.onInterruption(classification: classification) {
                case .ignoreIdle:
                    // Not capturing: launchd idle-exited the helper. No ping (a ping would spawn a
                    // throwaway helper), no latch. Recorded so a session's ring can show it.
                    self.record(.helperIdleExit, .info)
                    Logger.audio.info("XPC interrupted while idle — helper idle-exit, ignored")
                case .crash:
                    self.record(.xpcInterruption, .anomaly, ["classification": "crash"])
                    Logger.audio.warning("XPC interrupted — crash report present, treating as crash")
                    self.onServiceCrash?()
                case .verifyCapture:
                    self.record(.xpcInterruption, .warning, ["classification": "blip"])
                    let generation = self.interruptionPolicy.captureGeneration
                    Logger.audio.warning("XPC interrupted — no crash report; verifying capture is alive")
                    let stillCapturing = await self.isCapturing()
                    guard self.connection === boundConnection else { return }
                    switch self.interruptionPolicy.onVerified(stillCapturing: stillCapturing, generation: generation) {
                    case .briefInterruption: self.onBriefInterruption?()
                    case .crash:
                        Logger.audio.warning("XPC interrupted — helper not capturing, escalating to crash recovery")
                        self.onServiceCrash?()
                    case .ignoreIdle, .verifyCapture: break
                    }
                case .briefInterruption:
                    break   // onInterruption never returns this; onVerified does
                }
            }
        }
```
- Replace the invalidation handler body (lines 96-107) with:
```swift
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.connection = nil
                switch self.interruptionPolicy.onInvalidation() {
                case .crash:
                    Logger.audio.warning("XPC connection invalidated during capture")
                    self.record(.xpcInvalidation, .anomaly)
                    self.onServiceCrash?()
                default:
                    Logger.audio.info("XPC connection invalidated while idle")
                    self.record(.xpcInvalidation, .info)
                }
            }
        }
```
- In `start(...)` (line 206), add `interruptionPolicy.captureStarted()` as the first statement after `diagnostics.clear()`. In `stop()` (line 243), add `interruptionPolicy.captureStopped()` as the first statement.

- [ ] **Step 6: Build the app and run the full suite**

Run: `python3 scripts/dev.py --build` then `$PARLEY_TEST --filter TranscriberTests`
Expected: build clean; suite green (minus the pre-existing metamorphic flake).

- [ ] **Step 7: Commit**

```bash
git add TranscriberCore/XPCInterruptionPolicy.swift TranscriberCore/CaptureDiagnostics.swift TranscriberApp/Services/AudioCaptureClient.swift SwiftTests/TranscriberTests/XPCInterruptionPolicyTests.swift
git commit -m "fix(xpc): arm crash detection per capture generation — an idle-exit no longer disarms recovery (L-N1)"
```

---

### Task P0.2: `LaunchAgentHealth` — verify and repair crash protection at every launch

**Files:**
- Create: `TranscriberCore/LaunchAgentHealth.swift`
- Modify: `TranscriberCore/LaunchAgentManager.swift:62-124`
- Modify: `TranscriberCore/AppState.swift` (add `crashProtectionOff`)
- Modify: `TranscriberApp/TranscriberApp.swift:222-232`, `TranscriberApp/Views/MenuView.swift:17-31, 233-262`
- Test: `SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift` (new, red-first: compile error at parent); `SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift` (add one test for `programPath(inPlist:)`)

**Interfaces:**
- Produces:
  ```swift
  public enum LaunchAgentHealth {
      public enum State: Equatable, Sendable { case healthy, missing, stalePath(found: String), notLoaded }
      public enum Action: Equatable, Sendable { case none, installAndBootstrap, rewriteAndBootstrap, bootstrap }
      public static func assess(plistProgramPath: String?, executablePath: String, loaded: Bool) -> State
      public static func action(for state: State) -> Action
      public static func userMessage(for state: State) -> String?
  }
  // LaunchAgentManager
  public static func programPath(inPlist xml: String) -> String?
  public static func isLoaded(uid: uid_t = getuid()) async -> Bool
  public static func verifyAndRepair(executablePath: String? = nil, launchAgentsDir: URL? = nil, uid: uid_t = getuid()) async -> LaunchAgentHealth.State
  ```
  `AppState.crashProtectionOff: Bool` (P0.4 folds it into `activeAlarms`).

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// L11: the plist existed (mtime Sep 17, path correct) but `launchctl print gui/501/eu.fmasi.parley`
/// said "Could not find service" — Quit's unload removed the job and left the file, and launch
/// only checked the file. Crash protection was off all day, including during the 16:00 recording.
@Suite struct LaunchAgentHealthTests {
    let exe = "/Applications/Parley.app/Contents/MacOS/Parley"

    @Test func loadedWithCurrentPathIsHealthy() {
        #expect(LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: true) == .healthy)
        #expect(LaunchAgentHealth.action(for: .healthy) == .none)
    }

    @Test func missingPlistInstallsAndBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: nil, executablePath: exe, loaded: false)
        #expect(s == .missing)
        #expect(LaunchAgentHealth.action(for: s) == .installAndBootstrap)
    }

    /// The incident: file present, job gone.
    @Test func presentButNotLoadedBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: false)
        #expect(s == .notLoaded)
        #expect(LaunchAgentHealth.action(for: s) == .bootstrap)
    }

    /// The app moved (a Sparkle update into a new path, or a dev build): a loaded job pointing at
    /// the old binary relaunches the wrong app or nothing.
    @Test func stalePathIsRewrittenEvenWhenLoaded() {
        let old = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        let s = LaunchAgentHealth.assess(plistProgramPath: old, executablePath: exe, loaded: true)
        #expect(s == .stalePath(found: old))
        #expect(LaunchAgentHealth.action(for: s) == .rewriteAndBootstrap)
    }

    @Test func onlyUnhealthyStatesHaveAUserMessage() {
        #expect(LaunchAgentHealth.userMessage(for: .healthy) == nil)
        #expect(LaunchAgentHealth.userMessage(for: .notLoaded)?.contains("Crash protection") == true)
    }
}
```

Add to `LaunchAgentManagerTests.swift`:
```swift
    @Test func programPathIsParsedFromTheGeneratedPlist() {
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: plist) == "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: "<plist><dict></dict></plist>") == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'LaunchAgentHealthTests|LaunchAgentManagerTests'`
Expected: compile errors on `LaunchAgentHealth` and `programPath(inPlist:)`.

- [ ] **Step 3: Implement**

`TranscriberCore/LaunchAgentHealth.swift`:
```swift
import Foundation

/// Pure judgement of the crash-relaunch LaunchAgent (L11). `isInstalled()` used to mean "the plist
/// file exists"; launchd's opinion is what relaunches the app, so the job must be LOADED and must
/// point at the binary that is running.
public enum LaunchAgentHealth {
    public enum State: Equatable, Sendable {
        case healthy
        case missing
        case stalePath(found: String)
        case notLoaded
    }

    public enum Action: Equatable, Sendable {
        case none
        case installAndBootstrap
        case rewriteAndBootstrap
        case bootstrap
    }

    public static func assess(plistProgramPath: String?, executablePath: String, loaded: Bool) -> State {
        guard let plistProgramPath else { return .missing }
        if plistProgramPath != executablePath { return .stalePath(found: plistProgramPath) }
        return loaded ? .healthy : .notLoaded
    }

    public static func action(for state: State) -> Action {
        switch state {
        case .healthy: return .none
        case .missing: return .installAndBootstrap
        case .stalePath: return .rewriteAndBootstrap
        case .notLoaded: return .bootstrap
        }
    }

    /// The sticky row's text; nil when there is nothing to say.
    public static func userMessage(for state: State) -> String? {
        switch state {
        case .healthy: return nil
        case .missing, .notLoaded, .stalePath:
            return "Crash protection is off — if Parley crashes mid-recording it will not relaunch. Quit and reopen Parley to repair it."
        }
    }
}
```

In `LaunchAgentManager.swift`:
- Add after `generatePlist`:
```swift
    /// `ProgramArguments[0]` of a plist string, or nil if absent. Regex on the generated shape:
    /// this manager writes the only plist it ever reads.
    public static func programPath(inPlist xml: String) -> String? {
        let pattern = #"<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r = Range(m.range(at: 1), in: xml) else { return nil }
        return String(xml[r])
    }

    /// Whether launchd currently has the job (`launchctl print gui/<uid>/<label>` exits 0).
    public static func isLoaded(uid: uid_t = getuid()) async -> Bool {
        await runLaunchctl(args: ["print", "gui/\(uid)/\(label)"]) == 0
    }

    /// Judge, repair, and re-judge. Returns the state AFTER repair, so the caller can show the
    /// "crash protection is off" row only when repair failed.
    public static func verifyAndRepair(
        executablePath: String? = nil, launchAgentsDir: URL? = nil, uid: uid_t = getuid()
    ) async -> LaunchAgentHealth.State {
        let exePath = executablePath ?? Bundle.main.executablePath ?? Bundle.main.bundlePath
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)
        let plistPath = (try? String(contentsOf: plistURL, encoding: .utf8)).flatMap(programPath(inPlist:))
        let state = LaunchAgentHealth.assess(plistProgramPath: plistPath, executablePath: exePath, loaded: await isLoaded(uid: uid))
        switch LaunchAgentHealth.action(for: state) {
        case .none:
            return state
        case .installAndBootstrap, .rewriteAndBootstrap:
            // A stale job must be booted out first or bootstrap fails with "already loaded".
            _ = await runLaunchctl(args: ["bootout", "gui/\(uid)/\(label)"])
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false)
            _ = await runLaunchctl(args: ["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootstrap:
            _ = await runLaunchctl(args: ["bootstrap", "gui/\(uid)", plistURL.path])
        }
        let after = LaunchAgentHealth.assess(plistProgramPath: programPath(inPlist: (try? String(contentsOf: plistURL, encoding: .utf8)) ?? ""), executablePath: exePath, loaded: await isLoaded(uid: uid))
        Logger.config.info("LaunchAgentManager: health \(String(describing: state), privacy: .public) → \(String(describing: after), privacy: .public)")
        return after
    }
```
- In `uninstall(...)` (lines 98-115): remove the plist FIRST, then `bootout gui/<uid>/<label>` (replace `unload -w`). Update the doc comment: the SIGTERM ordering is why the file used to survive. Keep the `unloadAgent` parameter name for the tests.
- In `install(...)`: replace `["load", "-w", plistURL.path]` with `["bootstrap", "gui/\(getuid())", plistURL.path]`.

In `AppState.swift` add `public var crashProtectionOff = false` and include `|| crashProtectionOff` in `hasMenuAlerts`.

In `TranscriberApp.swift` replace lines 222-232 with:
```swift
        let stateForAgent = appState
        Task(priority: .utility) {
            let health = await LaunchAgentManager.verifyAndRepair()
            await MainActor.run {
                stateForAgent.crashProtectionOff = LaunchAgentHealth.userMessage(for: health) != nil
                if let message = LaunchAgentHealth.userMessage(for: health) {
                    MenuView.postNotification(title: "Crash protection is off", body: message)
                }
            }
        }
```
In `MenuView.alertBanners` add, before the `criticalError` banner:
```swift
        if appState.crashProtectionOff, let message = LaunchAgentHealth.userMessage(for: .notLoaded) {
            MenuActionRow(icon: "shield.slash", title: "Crash protection is off", subtitle: message) {}
        }
```

- [ ] **Step 4: Run to verify they pass**

Run: `$PARLEY_TEST --filter 'LaunchAgentHealthTests|LaunchAgentManagerTests'`
Expected: all pass (the existing `installWritesPlistFile` etc. still pass with `loadAgent: false`).

- [ ] **Step 5: Build, full suite, commit**

Run: `python3 scripts/dev.py --build` then `$PARLEY_TEST --filter TranscriberTests`. Expected green.
```bash
git add TranscriberCore/LaunchAgentHealth.swift TranscriberCore/LaunchAgentManager.swift TranscriberCore/AppState.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift SwiftTests/TranscriberTests/LaunchAgentHealthTests.swift SwiftTests/TranscriberTests/LaunchAgentManagerTests.swift
git commit -m "fix(launchagent): verify + bootstrap crash protection at launch, sticky row when it cannot be repaired (L11)"
```

---

### Task P0.3: `TrackLivenessMonitor` + `OutputActivity` — heartbeat, never-delivered, first frames

**Files:**
- Create: `TranscriberCore/TrackLivenessMonitor.swift`, `TranscriberCore/OutputActivity.swift`
- Create: `AudioCaptureHelper/XPC/OutputActivityProbe.swift`
- Delete: `TranscriberCore/LivenessGapDetector.swift`, `SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift`
- Modify: `TranscriberCore/PadRatioMonitor.swift:28-31, 66-71, 111-123, 125-136` (remove `neverDelivered`, `deadFrames`, `lastRate`, `finish()`), `SwiftTests/TranscriberTests/PadRatioMonitorTests.swift:222-250` (delete the `PadRatioMonitorDeadTrackTests` suite)
- Modify: `TranscriberCore/CaptureDiagnostics.swift` (kinds `.neverDelivered`, `.livenessRecovered`, `.firstFrames`; remove `.trackNeverDelivered`)
- Modify: `AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift` (whole file), `SystemTapSession.swift:31-110, 439-443, 683-694`, `MicCaptureSession.swift:26-75, 420-428`, `AudioOutputHandler.swift:142-172, 718-741`, `AudioCaptureService.swift:111-128, 235-239`, `main.swift:26-38`
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift:76-94` (add `captureDidDeliverFirstFrames(track:)`)
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:384-424` (reverse channel), `TranscriberCore/RecordingCaptureClient.swift` (add `onFirstFrames`)
- Test: `SwiftTests/TranscriberTests/TrackLivenessMonitorTests.swift`, `OutputActivityTests.swift` (new, red-first: compile errors at parent); `RecordingCoordinatorTests.swift` `FakeCaptureClient` gains `onFirstFrames` (the protocol change forces it; no assertion change)

**Interfaces:**
- Produces:
  ```swift
  public struct TrackLivenessMonitor: Equatable, Sendable {
      public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }
      public enum Verdict: Equatable, Sendable {
          case healthy
          case firstFrames                       // first heartbeat after arm(); once per generation
          case neverDelivered(seconds: Double)   // once per episode
          case stalled(seconds: Double)          // once per episode
          case cleared(ClearReason)              // the open episode ended
      }
      public let track: String
      public let firstFrameThresholdSeconds: Double   // default 5
      public let stallThresholdSeconds: Double        // default 3
      public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3)
      public mutating func arm(nowNanos: UInt64)      // start / rebuild / wake: a new generation
      public mutating func pause()                    // sleep: nothing judged until arm
      public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict
      public var hasOpenEpisode: Bool { get }
  }
  public enum OutputActivity {
      public struct ProcessOutputState: Equatable, Sendable { public let pid: Int32; public let isRunningOutput: Bool; public let outputDevices: [UInt32]; public init(...) }
      public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool
  }
  ```
  Helper: `OutputActivityProbe` (`func othersRunningOutput() -> Bool`, `var onChange: (() -> Void)?`, fails open); `SystemTapSession.lastHeartbeatNanos() -> UInt64`, `MicCaptureSession.lastHeartbeatNanos() -> UInt64`; `LivenessWatchdogDriver.arm(track:)`, `pause()`, `onVerdict: ((String, TrackLivenessMonitor.Verdict) -> Void)?`.
  Protocol: `@objc optional func captureDidDeliverFirstFrames(track: String)`; `RecordingCaptureClient.onFirstFrames: (@Sendable (String) -> Void)?`.
  Event kinds: `.neverDelivered` (anomaly, in `qualityCompromising`), `.livenessRecovered` (info), `.firstFrames` (info).

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TrackLivenessMonitorTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// H1 / L2 / L-N2: a track that NEVER delivers was invisible — `LivenessGapDetector` refused to
/// judge `lastArrivalNanos == 0`, `PadRatioMonitor.finish()` needed a rate it only learned from a
/// frame, and `trackNeverDelivered` could not fire in production. Incident B (2026-09-24, 46 min,
/// 0 callbacks while WebKit ran output) is the end-to-end proof.
@Suite struct TrackLivenessMonitorTests {
    private func ns(_ s: Double) -> UInt64 { UInt64(s * 1_000_000_000) }

    @Test func nothingIsJudgedBeforeArm() {
        var m = TrackLivenessMonitor(track: "system")
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
    }

    /// Incident B: armed, gate open (another process running output), no callback ever.
    @Test func expectedButNeverDeliveredFiresOnceAfterTheFirstFrameThreshold() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(10))
        #expect(m.check(nowNanos: ns(14), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(15), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
        #expect(m.check(nowNanos: ns(16), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)   // once
        #expect(m.hasOpenEpisode)
    }

    /// Gotcha #66: recording started before the call — nothing is expected until the gate opens,
    /// and the clock starts when it opens, not when capture started.
    @Test func gateClosedIsNeverAFaultAndTheClockStartsAtGateOpen() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(600), lastHeartbeatNanos: 0, gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(601), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(605), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(606), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func firstHeartbeatAfterArmIsReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true) == .firstFrames)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(1.9), gateOpen: true) == .healthy)
    }

    /// A heartbeat from BEFORE the arm is the previous generation's: a rebuild that never resumes
    /// is a never-delivered on the new generation, not a healthy track (the #86 false-success shape).
    @Test func heartbeatFromThePreviousGenerationDoesNotCount() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)   // delivering
        m.arm(nowNanos: ns(50))                                                       // rebuild
        #expect(m.check(nowNanos: ns(55), lastHeartbeatNanos: ns(49), gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func deliveredThenSilentIsAStallReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        var fired = 0
        for t in stride(from: 2.0, through: 30.0, by: 1.0) {
            if case .stalled = m.check(nowNanos: ns(t), lastHeartbeatNanos: ns(1), gateOpen: true) { fired += 1 }
        }
        #expect(fired == 1)
    }

    @Test func aHeartbeatClearsTheEpisodeAndReArmsIt() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 4))
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
        #expect(!m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(6), gateOpen: true) == .stalled(seconds: 4))
    }

    @Test func gateClosingClearsAnOpenEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true)   // neverDelivered
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: 0, gateOpen: false) == .cleared(.gateClosed))
    }

    /// Review focus 1: a call app toggling its output IO every second must not produce a report
    /// per flap. Only a gap that has been continuously open for the threshold is reported.
    @Test func gateFlapReportsAtMostOncePerEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0
        for t in 1...40 {
            let open = t % 2 == 0
            if case .neverDelivered = m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) { reports += 1 }
        }
        #expect(reports == 0, "the gate never stayed open for 5 s, so nothing was expected for 5 s")
    }

    /// Review focus 3: heartbeats are stamped on the audio queue and read on the watchdog queue.
    @Test func heartbeatInTheFutureIsHealthy() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(2.5), gateOpen: true) == .healthy)
    }

    @Test func pauseSuspendsJudgementUntilTheNextArm() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        m.pause()
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        m.arm(nowNanos: ns(100))
        #expect(m.check(nowNanos: ns(105), lastHeartbeatNanos: ns(1), gateOpen: true) == .neverDelivered(seconds: 5))
    }
}
```

`SwiftTests/TranscriberTests/OutputActivityTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// Q4.1 / H3b: the "is anything playing?" gate must be process-level and must exclude the helper
/// itself — the probe showed our own anchor-only aggregate reports `IsRunningOutput = 1`, and a
/// process on a non-default device is invisible to the old default-output check.
@Suite struct OutputActivityTests {
    typealias P = OutputActivity.ProcessOutputState

    @Test func nobodyRunningOutputIsClosed() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 10, isRunningOutput: false, outputDevices: [])], ownPid: 99) == false)
    }

    @Test func anotherProcessRunningOutputOpensTheGateWhateverTheDevice() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 2430, isRunningOutput: true, outputDevices: [84])], ownPid: 99))
    }

    /// run-own-aggregate.txt: pid 37097 (our probe) reported piro=1 outDevs=[84].
    @Test func ourOwnAggregateNeverOpensTheGate() {
        #expect(OutputActivity.othersRunningOutput([P(pid: 99, isRunningOutput: true, outputDevices: [84])], ownPid: 99) == false)
    }

    @Test func emptyListIsClosed() {
        #expect(OutputActivity.othersRunningOutput([], ownPid: 99) == false)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'TrackLivenessMonitorTests|OutputActivityTests'`
Expected: compile errors (`TrackLivenessMonitor`, `OutputActivity` not found).

- [ ] **Step 3: Implement the two cores**

`TranscriberCore/TrackLivenessMonitor.swift`:
```swift
import Foundation

/// Pure decision core of the 1 Hz off-audio-queue liveness watchdog, per track (§4.2).
///
/// Judges the HEARTBEAT (the OS calling our audio callback), not the content, from the moment
/// `arm()` says "expect frames from here": capture start, every tap/mic rebuild, every wake.
/// Unlike its predecessor it judges a track that has never delivered — that was Incident B.
public struct TrackLivenessMonitor: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }

    public enum Verdict: Equatable, Sendable {
        case healthy
        case firstFrames
        case neverDelivered(seconds: Double)
        case stalled(seconds: Double)
        case cleared(ClearReason)
    }

    public let track: String
    public let firstFrameThresholdSeconds: Double
    public let stallThresholdSeconds: Double

    private var armedAtNanos: UInt64?
    /// When the gate was last seen opening. Tracks the GATE, not the generation: an arm() while the
    /// gate is already open must judge from the arm time, not from the next tick.
    private var gateOpenSinceNanos: UInt64?
    private var gateObservedThisGeneration = false
    private var heartbeatSeenThisGeneration = false
    private var firstFramesReported = false
    private var episodeOpen = false

    public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3) {
        self.track = track
        self.firstFrameThresholdSeconds = firstFrameThresholdSeconds
        self.stallThresholdSeconds = stallThresholdSeconds
    }

    public var hasOpenEpisode: Bool { episodeOpen }

    public mutating func arm(nowNanos: UInt64) {
        armedAtNanos = nowNanos
        gateObservedThisGeneration = false
        heartbeatSeenThisGeneration = false
        firstFramesReported = false
        episodeOpen = false
    }

    public mutating func pause() {
        armedAtNanos = nil
        episodeOpen = false
    }

    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict {
        guard let armedAt = armedAtNanos else { return .healthy }
        guard gateOpen else {
            gateOpenSinceNanos = nil
            gateObservedThisGeneration = true
            if episodeOpen { episodeOpen = false; return .cleared(.gateClosed) }
            return .healthy
        }
        // First observation after an arm with the gate already open: it was open at the arm (the
        // tick is 1 Hz, so this is at most 1 s pessimistic). A closed→open transition starts now.
        if gateOpenSinceNanos == nil { gateOpenSinceNanos = gateObservedThisGeneration ? nowNanos : armedAt }
        gateObservedThisGeneration = true

        let heartbeatThisGeneration = lastHeartbeatNanos > armedAt
        if heartbeatThisGeneration {
            heartbeatSeenThisGeneration = true
            // A stamp newer than "now" (two queues, two clock reads) is a heartbeat, not a gap.
            let gapSeconds = nowNanos > lastHeartbeatNanos ? Double(nowNanos - lastHeartbeatNanos) / 1e9 : 0
            if episodeOpen, gapSeconds < stallThresholdSeconds { episodeOpen = false; return .cleared(.heartbeat) }
            if !firstFramesReported { firstFramesReported = true; return .firstFrames }
            if gapSeconds >= stallThresholdSeconds, !episodeOpen { episodeOpen = true; return .stalled(seconds: gapSeconds) }
            return .healthy
        }

        let judgeFrom = max(armedAt, gateOpenSinceNanos ?? armedAt)
        let waited = nowNanos > judgeFrom ? Double(nowNanos - judgeFrom) / 1e9 : 0
        if waited >= firstFrameThresholdSeconds, !episodeOpen {
            episodeOpen = true
            return .neverDelivered(seconds: waited)
        }
        return .healthy
    }
}
```

`TranscriberCore/OutputActivity.swift`:
```swift
import Foundation

/// "Is any OTHER process rendering output right now?" — the only "expected to produce" rule for
/// the tap (§4.3). Process-level, so it is route-independent and sees per-app output devices;
/// excludes our own pid because the helper's own aggregate reports itself as running output.
public enum OutputActivity {
    public struct ProcessOutputState: Equatable, Sendable {
        public let pid: Int32
        public let isRunningOutput: Bool
        public let outputDevices: [UInt32]
        public init(pid: Int32, isRunningOutput: Bool, outputDevices: [UInt32]) {
            self.pid = pid; self.isRunningOutput = isRunningOutput; self.outputDevices = outputDevices
        }
    }

    public static func othersRunningOutput(_ states: [ProcessOutputState], ownPid: Int32) -> Bool {
        states.contains { $0.pid != ownPid && $0.isRunningOutput }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `$PARLEY_TEST --filter 'TrackLivenessMonitorTests|OutputActivityTests'`
Expected: 15 tests pass.

- [ ] **Step 5: Retire the dead detector and the false-coverage test**

- `git rm TranscriberCore/LivenessGapDetector.swift SwiftTests/TranscriberTests/LivenessGapDetectorTests.swift`.
- `PadRatioMonitor.swift`: delete the `neverDelivered` case (lines 27-31), the `deadFrames`/`lastRate` fields (66-71), the `finish()` method (111-123), and the `guard hasDeliveredData` branch's `deadFrames += …; lastRate = rate` (92-93) so it reads `guard hasDeliveredData else { return .notYet }`; trim the `reset()` doc (127-131) to "Deliberately does NOT clear `hasDeliveredData`: a track that delivered in chunk 0 keeps its pad ratio judged in every later chunk."
- `PadRatioMonitorTests.swift`: delete lines 222-250 (`PadRatioMonitorDeadTrackTests`).
- `CaptureDiagnostics.swift`: remove `case trackNeverDelivered` and its entry in `qualityCompromising`; add:
```swift
    /// A track that was EXPECTED to deliver (mic: always; tap: another process running output)
    /// produced no heartbeat within the first-frame threshold after capture start, a rebuild or a
    /// wake — Incident B's exact shape (46 min, 0 callbacks). Severity `.anomaly`.
    case neverDelivered
    /// A reported `neverDelivered`/`livenessGap` episode ended: the heartbeat is back. `.info`.
    case livenessRecovered
    /// First heartbeat of a generation (start / rebuild / wake). `.info`; drives the honest "Resumed".
    case firstFrames
```
  and add `.neverDelivered` to `qualityCompromising`.
- `AudioOutputHandler.swift`: delete `noteDeadTrack` (718-741) and its two calls (148-149) plus `deadTrackReported` (39); keep the rest of `finalizeAll()`.

- [ ] **Step 6: Helper shells — heartbeats, probe, driver**

`AudioCaptureHelper/XPC/OutputActivityProbe.swift` (new):
```swift
import CoreAudio
import Foundation
import os
import TranscriberCore

/// Reads Core Audio's process objects and answers "is any OTHER process running output?" (§4.3).
/// Fails OPEN on any read failure. Registers `kAudioHardwarePropertyProcessObjectList` so a
/// process appearing/leaving triggers an immediate re-check (`onChange`).
final class OutputActivityProbe {
    private let queue = DispatchQueue(label: "audio-capture.output-activity")
    private var listener: AudioObjectPropertyListenerBlock?
    var onChange: (() -> Void)?

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0; var size = UInt32(4); var a = address(sel)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var a = address(sel, scope); var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard size == 0 || AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
        return out
    }

    /// nil = unreadable (caller fails open).
    func snapshot() -> [OutputActivity.ProcessOutputState]? {
        guard let procs = Self.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
        return procs.map { p in
            OutputActivity.ProcessOutputState(
                pid: Int32(bitPattern: Self.u32(p, kAudioProcessPropertyPID) ?? 0),
                isRunningOutput: Self.u32(p, kAudioProcessPropertyIsRunningOutput) == 1,
                outputDevices: Self.ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput) ?? []
            )
        }
    }

    func othersRunningOutput() -> Bool {
        guard let states = snapshot() else {
            Logger.audio.error("Output activity: process list unreadable — assuming output is running")
            return true
        }
        return OutputActivity.othersRunningOutput(states, ownPid: getpid())
    }

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        var a = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block) == noErr {
            listener = block
        }
    }

    func stop() {
        guard let block = listener else { return }
        var a = Self.address(kAudioHardwarePropertyProcessObjectList)
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        listener = nil
    }
}
```

`SystemTapSession.swift`: add `private let heartbeat = OSAllocatedUnfairLock<UInt64>(initialState: 0)` and `func lastHeartbeatNanos() -> UInt64 { heartbeat.withLock { $0 } }`; in `handleTapBuffers` (line 439) insert `heartbeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }` as the FIRST statement, before the `stateLock.sync` read. Add `var onGenerationChanged: (() -> Void)?` and call it at the end of `buildAggregateAndStart` (after `onBuilt?()`). Delete `isOutputDeviceRunningSomewhere()` (683-694): the probe replaces it.

`MicCaptureSession.swift`: same `heartbeat` lock + `lastHeartbeatNanos()`; stamp as the first statement of `captureOutput(_:didOutput:from:)` (line 420); add `var onGenerationChanged: (() -> Void)?` called at the end of `buildAndStart` after the raced check (line 203).

`LivenessWatchdogDriver.swift` — replace the file:
```swift
import Foundation
import TranscriberCore

/// Off-audio-queue 1 Hz driver for the per-track `TrackLivenessMonitor`s (§4.2). Owns the timer
/// on its OWN serial queue — a callback that stopped cannot notice its own silence.
final class LivenessWatchdogDriver {
    let queue = DispatchQueue(label: "audio-capture.liveness-watchdog")
    private var timer: DispatchSourceTimer?
    private var monitors: [String: TrackLivenessMonitor] = [
        "mic": TrackLivenessMonitor(track: "mic"),
        "system": TrackLivenessMonitor(track: "system"),
    ]
    private let outputActivity = OutputActivityProbe()
    private var lastGateOpen = true

    var lastMicHeartbeatNanos: (() -> UInt64)?
    var lastSystemHeartbeatNanos: (() -> UInt64)?
    var isUsingSystemTap = false
    /// Every non-healthy verdict, on `queue`: (track, verdict).
    var onVerdict: ((String, TrackLivenessMonitor.Verdict) -> Void)?
    /// The gate state on every tick (for coverage accounting): (gateOpen, nowNanos).
    var onGate: ((Bool, UInt64) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.outputActivity.onChange = { [weak self] in self?.queue.async { self?.tick() } }
            self.outputActivity.start()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    /// Start / rebuild / wake of one track: judge from now, expect first frames within 5 s.
    func arm(track: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in self?.monitors[track]?.arm(nowNanos: now) }
    }

    /// Sleep: nothing is judged until the next arm.
    func pause() { queue.async { [weak self] in self?.monitors.keys.forEach { self?.monitors[$0]?.pause() } } }

    /// An aggregate listener (`goin`→0, `stpd`, `diff`) said IO may have stopped. Accelerators never
    /// rebuild blindly (§5): one second later, if no heartbeat has arrived since the event and the
    /// track is expected, report a stall now instead of waiting for the 3 s threshold.
    func accelerate(track: String) {
        let eventNanos = DispatchTime.now().uptimeNanoseconds
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let heartbeat = (track == "mic" ? self.lastMicHeartbeatNanos : self.lastSystemHeartbeatNanos)?() ?? 0
            let expected = track == "mic" || !self.isUsingSystemTap || self.outputActivity.othersRunningOutput()
            guard heartbeat <= eventNanos, expected else { return }
            self.onVerdict?(track, .stalled(seconds: 1))
        }
    }

    private func stopLocked() {
        timer?.cancel(); timer = nil
        outputActivity.stop()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gateOpen = isUsingSystemTap ? outputActivity.othersRunningOutput() : true
        onGate?(gateOpen, now)
        if let hb = lastMicHeartbeatNanos, var m = monitors["mic"] {
            let v = m.check(nowNanos: now, lastHeartbeatNanos: hb(), gateOpen: true)
            monitors["mic"] = m
            if v != .healthy { onVerdict?("mic", v) }
        }
        if let hb = lastSystemHeartbeatNanos, var m = monitors["system"] {
            let v = m.check(nowNanos: now, lastHeartbeatNanos: hb(), gateOpen: gateOpen)
            monitors["system"] = m
            if v != .healthy { onVerdict?("system", v) }
        }
    }
}
```

`AudioCaptureService.swift` — replace `startLivenessWatchdog` (111-128) with:
```swift
    private func startLivenessWatchdog(mic: MicCaptureSession, tap: SystemTapSession?, isUsingSystemTap: Bool) {
        livenessWatchdog.lastMicHeartbeatNanos = { [weak mic] in mic?.lastHeartbeatNanos() ?? 0 }
        livenessWatchdog.lastSystemHeartbeatNanos = { [weak tap] in tap?.lastHeartbeatNanos() ?? 0 }
        livenessWatchdog.isUsingSystemTap = isUsingSystemTap
        livenessWatchdog.onVerdict = { [weak self] track, verdict in self?.handleLiveness(track: track, verdict: verdict) }
        mic.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: "mic") }
        tap?.onGenerationChanged = { [weak self] in self?.livenessWatchdog.arm(track: "system") }
        livenessWatchdog.start()
        livenessWatchdog.arm(track: "mic")
        if isUsingSystemTap { livenessWatchdog.arm(track: "system") }
    }

    /// Verdicts arrive on the watchdog queue. P0: record + surface; P1 routes the system track
    /// into the recovery ladder and P0.4 into the alarm registry.
    private func handleLiveness(track: String, verdict: TrackLivenessMonitor.Verdict) {
        switch verdict {
        case .firstFrames:
            record(.firstFrames, .info, ["track": track])
            onFirstFrames?(track)
        case .neverDelivered(let s):
            record(.neverDelivered, .anomaly, ["track": track, "seconds": "\(Int(s))"])
            onQualityAnomaly?(CaptureEventKind.neverDelivered.rawValue, track == "mic"
                ? "The microphone isn’t delivering any audio." : "The other side of the call isn’t reaching Parley although audio is playing.")
        case .stalled(let s):
            record(.livenessGap, .anomaly, ["track": track, "seconds": "\(Int(s))"])
            onQualityAnomaly?(CaptureEventKind.livenessGap.rawValue, track == "mic"
                ? "The microphone stopped delivering audio \(Int(s))s ago." : "System audio stopped delivering \(Int(s))s ago.")
        case .cleared(let reason):
            record(.livenessRecovered, .info, ["track": track, "reason": "\(reason)"])
        case .healthy:
            break
        }
    }
```
Add `var onFirstFrames: ((String) -> Void)?` next to `onQualityAnomaly` (line 67). Change the call at line 237 to `self.startLivenessWatchdog(mic: <the mic session>, tap: self.stateLock.sync { self.tapSession }, isUsingSystemTap: source == .coreAudioTap)` — `startMicSession` already returns the resolved id; make it return `(MicCaptureSession, String?)` so the session is in hand. Delete the `.deliveryGap` wiring (121-126); `TapPermissionGuard.deliveryGap` stays until P1.3 removes it.

`main.swift` line 34: add `service.onFirstFrames = { track in DispatchQueue.global(qos: .utility).async { client?.captureDidDeliverFirstFrames?(track: track) } }`.

`AudioCaptureProtocol.swift`, inside `AudioCaptureClientProtocol`:
```swift
    /// First heartbeat of a capture generation on `track` ("mic" | "system") — after start, a
    /// rebuild, or a wake. The app says "Resumed" only on this, never on `start()` returning (L2).
    @objc optional func captureDidDeliverFirstFrames(track: String)
```
`AudioCaptureClient.swift`: `var onFirstFrames: (@Sendable (String) -> Void)?`; `ReverseChannel.captureDidDeliverFirstFrames(track:)` hops to main and calls it. `RecordingCaptureClient.swift`: add `var onFirstFrames: (@Sendable (String) -> Void)? { get set }`. `RecordingCoordinatorTests.swift` `FakeCaptureClient`: add `var onFirstFrames: (@Sendable (String) -> Void)?`.

- [ ] **Step 7: Build, full suite, commit**

Run: `python3 scripts/dev.py --build` then `$PARLEY_TEST --filter TranscriberTests`. Expected: green; `PadRatioMonitorTests` no longer contains the dead-track suite.
```bash
git add -A TranscriberCore AudioCaptureHelper AudioCaptureProtocol TranscriberApp SwiftTests
git commit -m "feat(liveness): heartbeat-based TrackLivenessMonitor + process-level output gate; never-delivered is caught in 5 s (H1, L2, L-N2, Q4.1)"
```

---

### Task P0.4: Alarm contract — `CaptureAlarmRegistry`, status snapshot, `AppState.activeAlarms`, presenter

**Files:**
- Create: `TranscriberCore/CaptureAlarm.swift`
- Create: `TranscriberApp/Services/CaptureAlarmWindowController.swift`, `TranscriberApp/Views/CaptureAlarmView.swift`
- Modify: `TranscriberCore/AppState.swift` (whole), `TranscriberCore/RecordingCaptureClient.swift`, `TranscriberCore/RecordingCoordinator.swift:222-267, 658-666`
- Modify: `AudioCaptureProtocol/AudioCaptureProtocol.swift` (add `captureStatus`, `captureAlarmsChanged`)
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (registry, `captureStatus`, raise/clear at every live anomaly site), `main.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift`, `TranscriberApp/Views/MenuView.swift:233-262`, `TranscriberApp/TranscriberApp.swift`
- Test: `SwiftTests/TranscriberTests/CaptureAlarmTests.swift` (new, red-first), `AppStateTests.swift` (new tests referencing `activeAlarms`: red-first), `RecordingCoordinatorTests.swift` (`FakeCaptureClient.captureStatus`; change `crashRestartClearsTheStickyState` at line 415 — see Step 5)

**Interfaces:**
- Produces (`CaptureAlarm.swift`):
  ```swift
  public enum AlarmKind: String, Codable, CaseIterable, Sendable {
      case micNotDelivering, micDigitalSilence, remoteNotDelivering, remoteRecoveryFailed,
           remotePermissionDenied, remoteCantConfirm, diskWriteFailure,
           diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff,
           recordingResumedWithGap, recordingStopped, recordingFolderUnavailable
      public var isHelperOwned: Bool
      public var track: String?            // "mic" | "system" | nil
      public var isAcknowledgeable: Bool   // recordingResumedWithGap, recordingStopped
  }
  public struct ActiveAlarm: Codable, Equatable, Sendable {
      public let kind: AlarmKind; public let raisedAt: Date; public var lastNotifiedAt: Date?
      public let message: String; public let episode: Int
  }
  public struct CaptureAlarmRegistry: Codable, Equatable, Sendable {
      public private(set) var alarms: [AlarmKind: ActiveAlarm]
      public init()
      @discardableResult public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool
      @discardableResult public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm?
      public mutating func clearTrack(_ track: String) -> [ActiveAlarm]
      public mutating func replaceHelperOwned(with snapshot: [ActiveAlarm])
      public var isEmpty: Bool
      public var sorted: [ActiveAlarm]     // by raisedAt
  }
  public struct TrackHealthSnapshot: Codable, Equatable, Sendable { track, expected, heartbeatAgeSeconds: Double?, generation: Int }
  public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
      public let helperSessionId: String; public let isCapturing: Bool
      public let alarms: [ActiveAlarm]; public let tracks: [TrackHealthSnapshot]
      public func encoded() -> Data
      public static func decode(_ data: Data) -> CaptureStatusSnapshot?   // tolerant of unknown kinds
  }
  public enum AlarmRealarmPolicy {
      public static let notifyInterval: TimeInterval = 120
      public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool
      public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool  // CaptureReadiness.repairSnooze
  }
  ```
  `AppState`: `activeAlarms: [AlarmKind: ActiveAlarm]`, `applyHelperSnapshot(_:)`, `raiseAppAlarm(_:message:)`, `clearAppAlarm(_:)`, `acknowledge(_:)`; `remoteAudioNotCaptured` becomes computed; `crashProtectionOff` becomes an alarm.
  Protocol: `func captureStatus(reply: @escaping (Data?) -> Void)`; `@objc optional func captureAlarmsChanged(snapshot: Data)`.
  `RecordingCaptureClient`: `func captureStatus() async -> CaptureStatusSnapshot?`, `var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?`.

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/CaptureAlarmTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// H3/H9/L5 (§6): alarms are state, per track, sticky until the condition clears, re-notified
/// periodically. Incident A's watchdog fired once and stayed silent for 51 minutes.
@Suite struct CaptureAlarmTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func raiseIsIdempotentAndKeepsTheOriginalTimestamp() {
        var r = CaptureAlarmRegistry()
        #expect(r.raise(.remoteNotDelivering, message: "m", now: t0) == true)
        #expect(r.raise(.remoteNotDelivering, message: "m2", now: t0 + 10) == false)
        #expect(r.alarms[.remoteNotDelivering]?.raisedAt == t0)
        #expect(r.alarms[.remoteNotDelivering]?.message == "m")
    }

    @Test func clearReturnsTheAlarmAndEmptiesTheSlot() {
        var r = CaptureAlarmRegistry()
        r.raise(.micDigitalSilence, message: "m", now: t0)
        #expect(r.clear(.micDigitalSilence)?.kind == .micDigitalSilence)
        #expect(r.clear(.micDigitalSilence) == nil)
        #expect(r.isEmpty)
    }

    @Test func clearTrackClearsOnlyThatTracksAlarms() {
        var r = CaptureAlarmRegistry()
        r.raise(.micNotDelivering, message: "m", now: t0)
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        r.raise(.remotePermissionDenied, message: "p", now: t0)
        #expect(r.clearTrack("system").map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.remoteNotDelivering, .remotePermissionDenied])
        #expect(r.alarms.keys.contains(.micNotDelivering))
    }

    @Test func episodeCountsRaises() {
        var r = CaptureAlarmRegistry()
        r.raise(.micNotDelivering, message: "m", now: t0); _ = r.clear(.micNotDelivering)
        r.raise(.micNotDelivering, message: "m", now: t0 + 1)
        #expect(r.alarms[.micNotDelivering]?.episode == 2)
    }

    /// App side: helper-owned kinds follow the snapshot; app-owned ones are untouched.
    @Test func replacingHelperOwnedAlarmsKeepsAppOwnedOnes() {
        var r = CaptureAlarmRegistry()
        r.raise(.crashProtectionOff, message: "c", now: t0)
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        let fresh = ActiveAlarm(kind: .micDigitalSilence, raisedAt: t0 + 5, lastNotifiedAt: nil, message: "z", episode: 1)
        r.replaceHelperOwned(with: [fresh])
        #expect(Set(r.alarms.keys) == [.crashProtectionOff, .micDigitalSilence])
    }

    @Test func snapshotRoundTrips() throws {
        var r = CaptureAlarmRegistry()
        r.raise(.remoteNotDelivering, message: "r", now: t0)
        let s = CaptureStatusSnapshot(helperSessionId: "h1", isCapturing: true, alarms: r.sorted,
                                      tracks: [TrackHealthSnapshot(track: "system", expected: true, heartbeatAgeSeconds: 7.5, generation: 2)])
        let decoded = try #require(CaptureStatusSnapshot.decode(s.encoded()))
        #expect(decoded == s)
    }

    /// Review focus 2: a newer helper may send a kind this app does not know.
    @Test func snapshotWithUnknownKindKeepsTheOthers() throws {
        let json = """
        {"helperSessionId":"h","isCapturing":true,"tracks":[],
         "alarms":[{"kind":"somethingNew","raisedAt":"2026-09-24T16:00:00Z","message":"x","episode":1},
                   {"kind":"micDigitalSilence","raisedAt":"2026-09-24T16:00:00Z","message":"y","episode":1}]}
        """
        let decoded = try #require(CaptureStatusSnapshot.decode(Data(json.utf8)))
        #expect(decoded.alarms.map(\.kind) == [.micDigitalSilence])
    }

    @Test func renotifyEveryTwoMinutesWhileActive() {
        var a = ActiveAlarm(kind: .remoteNotDelivering, raisedAt: t0, lastNotifiedAt: t0, message: "m", episode: 1)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 119) == false)
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0 + 120))
        a.lastNotifiedAt = nil
        #expect(AlarmRealarmPolicy.shouldRenotify(a, now: t0), "never notified: notify now")
    }

    @Test func windowReopensAfterTheSnooze() {
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: nil, now: t0))
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + 60) == false)
        #expect(AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt: t0, now: t0 + CaptureReadiness.repairSnooze))
    }

    @Test func kindsKnowTheirTrackAndOwner() {
        #expect(AlarmKind.micNotDelivering.track == "mic")
        #expect(AlarmKind.remotePermissionDenied.track == "system")
        #expect(AlarmKind.crashProtectionOff.track == nil)
        #expect(AlarmKind.micNotDelivering.isHelperOwned)
        #expect(AlarmKind.recordingStopped.isHelperOwned == false)
        #expect(AlarmKind.recordingStopped.isAcknowledgeable)
    }
}
```

Add to `AppStateTests.swift`:
```swift
    // MARK: - Alarms (§6)

    @Test func helperSnapshotPopulatesActiveAlarmsAndTheStickyRemoteFlag() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(CaptureStatusSnapshot(
            helperSessionId: "h", isCapturing: true,
            alarms: [ActiveAlarm(kind: .remotePermissionDenied, raisedAt: Date(), lastNotifiedAt: nil, message: "denied", episode: 1)],
            tracks: []))
        #expect(state.activeAlarms[.remotePermissionDenied] != nil)
        #expect(state.remoteAudioNotCaptured)
        #expect(state.hasMenuAlerts)
    }

    @Test func benignNoticeNeverTouchesAnAlarm() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.rotationFailed, message: "rotation failed")
        state.interruptionWarning = "Audio device changed — recording resumed automatically."
        state.interruptionWarning = nil
        #expect(state.activeAlarms[.rotationFailed] != nil)
    }

    @Test func recordingEndClearsPerRecordingAlarmsButNotCrashProtection() {
        let state = AppState()
        state.raiseAppAlarm(.crashProtectionOff, message: "off")
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.diskLow, message: "low")
        state.phase = .idle
        #expect(state.activeAlarms[.diskLow] == nil)
        #expect(state.activeAlarms[.crashProtectionOff] != nil)
    }

    @Test func acknowledgeClearsOnlyAcknowledgeableKinds() {
        let state = AppState()
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.recordingResumedWithGap, message: "gap")
        state.raiseAppAlarm(.diskLow, message: "low")
        state.acknowledge(.recordingResumedWithGap)
        state.acknowledge(.diskLow)
        #expect(state.activeAlarms[.recordingResumedWithGap] == nil)
        #expect(state.activeAlarms[.diskLow] != nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'CaptureAlarmTests|AppStateTests'`
Expected: compile errors on the new types and `AppState` members.

- [ ] **Step 3: Implement `CaptureAlarm.swift`**

```swift
import Foundation

/// Alarm STATE (§6): per track, owned by the helper or the app, sticky until its condition
/// clears. Replaces the one-shot `captureQualityAnomaly` events + the single overwritable
/// `interruptionWarning` slot for anything that means "a side is not being recorded".
public enum AlarmKind: String, Codable, CaseIterable, Sendable {
    case micNotDelivering, micDigitalSilence
    case remoteNotDelivering, remoteRecoveryFailed, remotePermissionDenied, remoteCantConfirm
    case diskWriteFailure
    case diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff
    case recordingResumedWithGap, recordingStopped, recordingFolderUnavailable

    public var isHelperOwned: Bool {
        switch self {
        case .micNotDelivering, .micDigitalSilence, .remoteNotDelivering, .remoteRecoveryFailed,
             .remotePermissionDenied, .remoteCantConfirm, .diskWriteFailure: return true
        default: return false
        }
    }

    public var track: String? {
        switch self {
        case .micNotDelivering, .micDigitalSilence: return "mic"
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm: return "system"
        default: return nil
        }
    }

    /// Past events the user dismisses; everything else clears only when the condition clears.
    public var isAcknowledgeable: Bool { self == .recordingResumedWithGap || self == .recordingStopped }

    /// Survives the end of a recording: a machine-level condition, or a past event the user has
    /// not acknowledged yet ("the recording STOPPED at 16:02" must outlive the recording it is about).
    public var outlivesRecording: Bool { self == .crashProtectionOff || isAcknowledgeable }
}

public struct ActiveAlarm: Codable, Equatable, Sendable {
    public let kind: AlarmKind
    public let raisedAt: Date
    public var lastNotifiedAt: Date?
    public let message: String
    public let episode: Int

    public init(kind: AlarmKind, raisedAt: Date, lastNotifiedAt: Date?, message: String, episode: Int) {
        self.kind = kind; self.raisedAt = raisedAt; self.lastNotifiedAt = lastNotifiedAt
        self.message = message; self.episode = episode
    }
}

public struct CaptureAlarmRegistry: Codable, Equatable, Sendable {
    public private(set) var alarms: [AlarmKind: ActiveAlarm] = [:]
    private var episodes: [AlarmKind: Int] = [:]

    public init() {}

    /// True when newly raised; a repeat keeps the original alarm untouched.
    @discardableResult
    public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool {
        guard alarms[kind] == nil else { return false }
        let episode = (episodes[kind] ?? 0) + 1
        episodes[kind] = episode
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: now, lastNotifiedAt: nil, message: message, episode: episode)
        return true
    }

    @discardableResult
    public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm? { alarms.removeValue(forKey: kind) }

    public mutating func clearTrack(_ track: String) -> [ActiveAlarm] {
        let cleared = alarms.values.filter { $0.kind.track == track }
        for a in cleared { alarms.removeValue(forKey: a.kind) }
        return cleared
    }

    public mutating func markNotified(_ kind: AlarmKind, now: Date) { alarms[kind]?.lastNotifiedAt = now }

    /// App side: the helper's snapshot is the truth for helper-owned kinds.
    public mutating func replaceHelperOwned(with snapshot: [ActiveAlarm]) {
        for kind in AlarmKind.allCases where kind.isHelperOwned { alarms.removeValue(forKey: kind) }
        for a in snapshot where a.kind.isHelperOwned { alarms[a.kind] = a }
    }

    public var isEmpty: Bool { alarms.isEmpty }
    public var sorted: [ActiveAlarm] { alarms.values.sorted { $0.raisedAt < $1.raisedAt } }
}

public struct TrackHealthSnapshot: Codable, Equatable, Sendable {
    public let track: String
    public let expected: Bool
    public let heartbeatAgeSeconds: Double?
    public let generation: Int
    public init(track: String, expected: Bool, heartbeatAgeSeconds: Double?, generation: Int) {
        self.track = track; self.expected = expected; self.heartbeatAgeSeconds = heartbeatAgeSeconds; self.generation = generation
    }
}

/// What the app PULLS from the helper on connect, every 5 s while recording, and after any
/// restart — and what the helper PUSHES on every change. JSON over XPC.
public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
    public let helperSessionId: String
    public let isCapturing: Bool
    public let alarms: [ActiveAlarm]
    public let tracks: [TrackHealthSnapshot]

    public init(helperSessionId: String, isCapturing: Bool, alarms: [ActiveAlarm], tracks: [TrackHealthSnapshot]) {
        self.helperSessionId = helperSessionId; self.isCapturing = isCapturing; self.alarms = alarms; self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey { case helperSessionId, isCapturing, alarms, tracks }

    /// Tolerant: an alarm whose kind this build does not know is dropped, the rest survive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperSessionId = try c.decode(String.self, forKey: .helperSessionId)
        isCapturing = try c.decode(Bool.self, forKey: .isCapturing)
        tracks = try c.decodeIfPresent([TrackHealthSnapshot].self, forKey: .tracks) ?? []
        var raw = try c.nestedUnkeyedContainer(forKey: .alarms)
        var kept: [ActiveAlarm] = []
        while !raw.isAtEnd {
            if let a = try? raw.decode(ActiveAlarm.self) { kept.append(a) } else { _ = try? raw.decode(AnyDecodable.self) }
        }
        alarms = kept
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }
    public func encoded() -> Data { (try? Self.coder().0.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> CaptureStatusSnapshot? { try? coder().1.decode(CaptureStatusSnapshot.self, from: data) }
}

/// Swallows one unknown array element while decoding (used by the tolerant snapshot decoder).
private struct AnyDecodable: Decodable { init(from decoder: Decoder) throws { _ = try? decoder.container(keyedBy: NoKeys.self) } ; private enum NoKeys: CodingKey {} }

public enum AlarmRealarmPolicy {
    public static let notifyInterval: TimeInterval = 120

    public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool {
        guard let last = alarm.lastNotifiedAt else { return true }
        return now.timeIntervalSince(last) >= notifyInterval
    }

    public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool {
        CaptureReadiness.shouldPresentRepair(lastDismissedAt: lastDismissedAt, now: now)
    }
}
```

`AppState.swift` — replace `remoteAudioNotCaptured`/`remoteAudioProblem` storage and the `crashProtectionOff` Bool from P0.2 with:
```swift
    /// Sticky alarms (§6). Helper-owned kinds mirror the helper's snapshot; app-owned kinds are
    /// raised here. Nothing benign can overwrite them; `interruptionWarning` stays the transient slot.
    public private(set) var alarms = CaptureAlarmRegistry()
    public var activeAlarms: [AlarmKind: ActiveAlarm] { alarms.alarms }

    public func applyHelperSnapshot(_ snapshot: CaptureStatusSnapshot) {
        alarms.replaceHelperOwned(with: snapshot.alarms)
    }
    @discardableResult
    public func raiseAppAlarm(_ kind: AlarmKind, message: String, now: Date = Date()) -> Bool {
        alarms.raise(kind, message: message, now: now)
    }
    public func clearAppAlarm(_ kind: AlarmKind) { _ = alarms.clear(kind) }
    public func acknowledge(_ kind: AlarmKind) { guard kind.isAcknowledgeable else { return }; _ = alarms.clear(kind) }
    public func markNotified(_ kind: AlarmKind, now: Date = Date()) { alarms.markNotified(kind, now: now) }

    /// The other side is not being captured, for whatever reason the helper reported.
    public var remoteAudioNotCaptured: Bool { alarms.alarms.keys.contains { $0.track == "system" } }
    public var crashProtectionOff: Bool { alarms.alarms[.crashProtectionOff] != nil }
```
In `phase.didSet` replace `if !isRecording { clearRemoteAudioProblem() }` with `if !isRecording { for kind in Array(alarms.alarms.keys) where !kind.outlivesRecording { _ = alarms.clear(kind) } }` (copy the keys first: the loop mutates the dictionary). Delete `noteSystemAudioLost`, `clearRemoteAudioProblem`, `remoteAudioProblem`; reduce `noteQualityAnomaly` to `interruptionWarning = message` returning `false` (the permission repair is now driven by the alarm, see Step 5). `hasMenuAlerts` = `criticalError != nil || interruptionWarning != nil || truncatedErrorMessage != nil || !alarms.isEmpty`. `menuBarIcon`: `.recording` → `"exclamationmark.bubble"` when `!alarms.isEmpty || interruptionWarning != nil`; `.idle` → `"exclamationmark.triangle"` when `crashProtectionOff`.

- [ ] **Step 4: Run to verify they pass**

Run: `$PARLEY_TEST --filter 'CaptureAlarmTests|AppStateTests'`
Expected: pass. (P0.2's `MenuView` row now reads `appState.crashProtectionOff` unchanged — computed.)

- [ ] **Step 5: Helper side — registry, `captureStatus`, push**

`AudioCaptureService.swift`:
- Add `private let alarms = OSAllocatedUnfairLock(initialState: CaptureAlarmRegistry())`, `private let helperSessionId = UUID().uuidString` (per process), `var onAlarmsChanged: ((Data) -> Void)?`.
- Add:
```swift
    private func snapshot() -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(
            helperSessionId: helperSessionId,
            isCapturing: stateLock.sync { isCapturing },
            alarms: alarms.withLock { $0.sorted },
            tracks: [])   // P2.1 fills tracks from TrackAccounting
    }
    private func raiseAlarm(_ kind: AlarmKind, _ message: String) {
        let changed = alarms.withLock { $0.raise(kind, message: message, now: Date()) }
        guard changed else { return }
        record(.alarmRaised, .anomaly, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot().encoded())
    }
    private func clearAlarm(_ kind: AlarmKind) {
        guard alarms.withLock({ $0.clear(kind) }) != nil else { return }
        record(.alarmCleared, .info, ["kind": kind.rawValue])
        onAlarmsChanged?(snapshot().encoded())
    }
    private func clearTrackAlarms(_ track: String) {
        let cleared = alarms.withLock { $0.clearTrack(track) }
        guard !cleared.isEmpty else { return }
        for a in cleared { record(.alarmCleared, .info, ["kind": a.kind.rawValue]) }
        onAlarmsChanged?(snapshot().encoded())
    }
    func captureStatus(reply: @escaping (Data?) -> Void) { reply(snapshot().encoded()) }
```
- Raise/clear sites: `handleLiveness` — `.neverDelivered`/`.stalled` on `mic` → `raiseAlarm(.micNotDelivering, …)` (P1.3 gates the system track behind the ladder; in P0 raise `.remoteNotDelivering` directly); `.cleared` → `clearAlarm(track == "mic" ? .micNotDelivering : .remoteNotDelivering)`; `.firstFrames` → `clearTrackAlarms(track)` for the `NotDelivering` kinds only. `noteExactZeroMic` path: `onQualityAnomaly` for `exactZeroMic` → also `raiseAlarm(.micDigitalSilence, message)`; add `AudioOutputHandler.onMicAudioResumed: (() -> Void)?` fired when `ExactZeroRunMonitor` sees a non-zero batch after a reported run (add a `resumed` verdict to `ExactZeroRunMonitor.record` — red-first test in `ExactZeroRunMonitorTests`: `silentRunThenAudioReportsResumedOnce`) → `clearAlarm(.micDigitalSilence)`. `apply(.reportDenied(status))` → `raiseAlarm(status == nil ? .remoteCantConfirm : .remotePermissionDenied, message)`; `.reportRestored` → `clearAlarm(.remotePermissionDenied); clearAlarm(.remoteCantConfirm)`. `wireWriteFailure` → `raiseAlarm(.diskWriteFailure, message)`; add `WavFileWriter.onWriteRecovered` (first successful write after a failure; set `writeFailureReported = false` there) → `clearAlarm(.diskWriteFailure)`. `tap.onUnavailable` → `raiseAlarm(.remoteRecoveryFailed, reason)` (P1.3 replaces with the ladder). On `stopCapture`/`stopAndFinalize`/`cleanupAfterFailure`: `alarms.withLock { $0 = CaptureAlarmRegistry() }`.
- Add `CaptureEventKind.alarmRaised` (anomaly, NOT in `qualityCompromising` — the underlying kind already is) and `.alarmCleared` (info).

`main.swift`: `service.onAlarmsChanged = { data in DispatchQueue.global(qos: .utility).async { client?.captureAlarmsChanged?(snapshot: data) } }`.

`AudioCaptureProtocol.swift`: add to `AudioCaptureProtocol`:
```swift
    /// The helper's current alarm state + per-track health as JSON `CaptureStatusSnapshot` (§6.2).
    /// The app pulls this on every connect and every 5 s while recording; `status` stays as is.
    func captureStatus(reply: @escaping (Data?) -> Void)
```
and to `AudioCaptureClientProtocol`: `@objc optional func captureAlarmsChanged(snapshot: Data)`.

- [ ] **Step 6: App side — pull, present, re-alarm**

`AudioCaptureClient.swift`: `var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?`; `func captureStatus() async -> CaptureStatusSnapshot?` (3 s deadline via `ResumeOnce`, same shape as `systemAudioPermissionStatus()`); `ReverseChannel.captureAlarmsChanged(snapshot:)` decodes and hops to main. In `connect()`, after `conn.resume()`: `Task { if let s = await self.captureStatus() { self.onAlarmsChanged?(s) } }`. `RecordingCaptureClient.swift`: add both members; `FakeCaptureClient` in `RecordingCoordinatorTests.swift`: `var statusSnapshot: CaptureStatusSnapshot?`, `func captureStatus() async -> CaptureStatusSnapshot? { statusSnapshot }`, `var onAlarmsChanged`.

`RecordingCoordinator.swift`:
- In `startRecording` (after line 267) and in the re-attach path: `captureClient.onAlarmsChanged = { [weak self] s in Task { @MainActor in self?.appState.applyHelperSnapshot(s); self?.presentAlarms() } }`; `captureClient.onFirstFrames = { [weak self] track in Task { @MainActor in self?.noteFirstFrames(track: track) } }`.
- Replace the `onQualityAnomaly` closure body (260-267) with `self.appState.interruptionWarning = message` (transient only) — the permission window now opens from `presentAlarms()` when `.remotePermissionDenied`/`.remoteCantConfirm` appears: `if appState.activeAlarms[.remotePermissionDenied] != nil || appState.activeAlarms[.remoteCantConfirm] != nil { onSystemAudioPermissionDenied() }`.
- Delete `appState.clearRemoteAudioProblem()` at line 661 (§6.2).
- Add a status poll: `private var statusPoll: Task<Void, Never>?`; started when the phase becomes `.recording` (in `startRecording` after line 298 and in the re-attach path), cancelled when it leaves:
```swift
    /// Injected UI: (alarms sorted, newly raised kinds) → open/refresh the window, notify, rows.
    private let presentAlarmsUI: @MainActor ([ActiveAlarm], [AlarmKind]) -> Void
    var statusPollInterval: Duration = .seconds(5)   // tests shorten it
    private var missedPolls = 0

    private func startStatusPoll() {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while let self, !Task.isCancelled, self.appState.isRecording {
                try? await Task.sleep(for: self.statusPollInterval)
                await self.pollHelperStatus()
            }
        }
    }

    func pollHelperStatus() async {
        if let s = await captureClient.captureStatus() {
            missedPolls = 0
            appState.clearAppAlarm(.helperUnresponsive)
            appState.applyHelperSnapshot(s)
        } else {
            missedPolls += 1
            if missedPolls >= 3 {
                appState.raiseAppAlarm(.helperUnresponsive, message: "The capture helper stopped answering. The recording may have stopped — check the audio files after you stop.")
            }
        }
        presentAlarms()
    }

    private var presentedKinds: Set<AlarmKind> = []
    func presentAlarms(now: Date = Date()) {
        let active = appState.alarms.sorted
        let newKinds = active.map(\.kind).filter { !presentedKinds.contains($0) }
        presentedKinds = Set(active.map(\.kind))
        let due = active.filter { AlarmRealarmPolicy.shouldRenotify($0, now: now) }
        for a in due { appState.markNotified(a.kind, now: now) }
        if !newKinds.isEmpty || !due.isEmpty { presentAlarmsUI(active, newKinds) }
        if newKinds.contains(.remotePermissionDenied) || newKinds.contains(.remoteCantConfirm) { onSystemAudioPermissionDenied() }
    }
```
  `presentAlarmsUI` is a new `init` parameter (default `{ _, _ in }` so the test harness compiles unchanged).
- `noteFirstFrames(track:)`: if `track == "mic"`, and a restart is awaiting confirmation (P0.5 adds the flag), notify "Recording Resumed"; always `appState.interruptionWarning = nil` when it was the "waiting for audio" text.

`TranscriberApp/Services/CaptureAlarmWindowController.swift` (new, `@MainActor final class`, singleton `shared`): `func present(_ alarms: [ActiveAlarm], newlyRaised: [AlarmKind], appState: AppState)` — if `newlyRaised` is non-empty, or `AlarmRealarmPolicy.shouldReopenWindow(lastDismissedAt:now:)`: open/refresh an `NSPanel` (`[.titled, .closable, .utilityWindow]`, `.floating`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, NO `NSApp.activate`) hosting `CaptureAlarmView(alarms:onLater:onAcknowledge:)`; post `MenuView.postNotification(title: "Parley isn’t recording everything", body: <first message>)` (`.timeSensitive`, `.default` sound) for every `newlyRaised` kind and every due re-notify; "Later" sets `lastDismissedAt` and closes; `windowWillClose` counts as Later. `CaptureAlarmView.swift`: a list of rows (icon by track, message, an **Acknowledge** button for acknowledgeable kinds, **Open System Settings** for `remotePermissionDenied` via `PrivacyPane`), and a **Later** button. Skip the `.remotePermissionDenied` row when `PermissionRepairWindowController.shared` has its own window open.

`MenuView.swift`: `alertBanners` renders one `MenuActionRow` per `appState.alarms.sorted` (icon `"speaker.slash.fill"` for system, `"mic.slash.fill"` for mic, `"shield.slash"` for `crashProtectionOff`, `"externaldrive.badge.exclamationmark"` for disk), not dismissible; tapping a `system`-track row calls `PermissionRepairWindowController.shared.verify(trigger: .userRequest)`, any other row opens `CaptureAlarmWindowController.shared`. Remove the P0.2 ad-hoc row. The coordinator's `presentAlarmsUI` closure in `MenuView.init` (and in `TranscriberApp.init` after P0.5) is `{ alarms, new in CaptureAlarmWindowController.shared.present(alarms, newlyRaised: new, appState: appState) }`.

`TranscriberApp.swift`: P0.2's LaunchAgent block becomes `stateForAgent.raiseAppAlarm(.crashProtectionOff, message: message)` / `clearAppAlarm`.

`RecordingCoordinatorTests.swift` line 415 `crashRestartClearsTheStickyState`: rename to `crashRestartKeepsTheStickyStateUntilFramesArrive`, assert the helper-owned alarm is still present after `handleXPCCrash()` and gone after `h.client.onAlarmsChanged?(CaptureStatusSnapshot(helperSessionId: "h2", isCapturing: true, alarms: [], tracks: []))` (red-first: the old assertion inverts).

- [ ] **Step 7: Build, full suite, commit**

Run: `python3 scripts/dev.py --build` then `$PARLEY_TEST --filter TranscriberTests`. Expected green.
```bash
git add -A TranscriberCore AudioCaptureHelper AudioCaptureProtocol TranscriberApp SwiftTests
git commit -m "feat(alarms): helper-owned per-track alarm state, pulled every 5 s and pushed on change; loud, sticky, re-notified every 2 min (H3, H9, L5, Inv 3)"
```

---

### Task P0.5: Retry cap on confirmed frames; coordinator owns launch recovery

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift` (`handleXPCCrash` 638-679; new `recoverAtLaunch`, `wireCaptureCallbacks`, `noteFirstFrames`, `confirmRecoveryHealthy`)
- Modify: `TranscriberApp/TranscriberApp.swift:115-233, 259-506` (own the coordinator; delete `recoverIfNeeded`/`setupCrashHandler`), `TranscriberApp/Views/MenuView.swift:33-89, 381-406` (take the coordinator)
- Test: `SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift:773-799` (change), plus new tests (red-first: assertion inverts / new members)

**Interfaces:**
- Produces:
  ```swift
  // RecordingCoordinator
  public var recoveryConfirmationSeconds: TimeInterval   // default 60; tests set 0
  func noteFirstFrames(track: String, now: Date = Date())
  func confirmRecoveryHealthy(now: Date = Date())        // resets xpcRetryCount if ≥ confirmation window since first frames and still recording
  public func recoverAtLaunch() async                    // the former TranscriberApp.recoverIfNeeded, behaviour-neutral in P0 (P3.1 changes the decisions)
  public init(..., engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))? = nil, ...)
      // nil → `transcriptionRunner.prepareEngine(config:)`; tests inject `{ _ in (FakeEngine(), FakeDiarizer()) }`
  ```

- [ ] **Step 1: Change the enshrined test and add the new ones**

In `RecordingCoordinatorTests.swift` replace line 795 with:
```swift
        // L9: `start()` returning proves nothing (the helper replies before its first frame, and a
        // first-sample crash comes back as another interruption). The streak resets only after
        // confirmed frames — see retryStreakResetsOnlyAfterConfirmedFrames.
        #expect(h.coordinator.xpcRetryCount == 1)
        // Honest "Resumed" (L2): nothing is announced until frames arrive.
        #expect(h.notified.value.isEmpty)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
```
Add after that test:
```swift
    @Test func retryStreakResetsOnlyAfterConfirmedFrames() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryConfirmationSeconds = 60

        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 1)

        let t0 = Date()
        h.coordinator.noteFirstFrames(track: "mic", now: t0)
        #expect(h.notified.value.map(\.title) == ["Recording Resumed"])
        h.coordinator.confirmRecoveryHealthy(now: t0 + 30)
        #expect(h.coordinator.xpcRetryCount == 1, "30 s of frames is not yet confirmation")
        h.coordinator.confirmRecoveryHealthy(now: t0 + 60)
        #expect(h.coordinator.xpcRetryCount == 0)
    }

    /// Gotcha #50 / L9: a helper that crashes on its first sample never delivers frames, so the
    /// streak never resets and the third crash inside the window gives up.
    @Test func firstSampleCrashLoopGivesUpAtTheCap() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 2)
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle)
        #expect(h.criticals.value.map(\.title) == ["Recording Failed"])
    }

    @Test func firstFramesOutsideARecoveryDoNotAnnounceResumed() async throws {
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.coordinator.noteFirstFrames(track: "mic")
        #expect(h.notified.value.isEmpty)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'RecordingCoordinatorTests'`
Expected: compile errors on `recoveryConfirmationSeconds`, `noteFirstFrames`, `confirmRecoveryHealthy`; the changed assertion at 795 would fail (`== 0` today).

- [ ] **Step 3: Implement in `RecordingCoordinator`**

- State: `public var recoveryConfirmationSeconds: TimeInterval = 60`, `private var awaitingRecoveryFrames = false`, `private var recoveryFramesAt: Date?`.
- In `handleXPCCrash` after `try RecordingSentinel.write(newSentinel, …)` (line 648) and the deferred-stop branch: delete `xpcRetryCount = 0` (658) and `appState.clearRemoteAudioProblem()` (661); replace the notify (663-666) with:
```swift
            awaitingRecoveryFrames = true
            recoveryFramesAt = nil
            appState.interruptionWarning = "Recording restarted — waiting for audio…"
```
- Add:
```swift
    func noteFirstFrames(track: String, now: Date = Date()) {
        guard track == "mic", appState.isRecording, awaitingRecoveryFrames else { return }
        awaitingRecoveryFrames = false
        recoveryFramesAt = now
        appState.interruptionWarning = "Recording briefly interrupted. Resumed."
        notify("Recording Resumed", "Recording was briefly interrupted and has been restarted.")
        let window = recoveryConfirmationSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.confirmRecoveryHealthy()
        }
    }

    /// L9: the streak resets only after `recoveryConfirmationSeconds` of frames since the restart's
    /// first frame, and only if no newer crash has been registered since.
    func confirmRecoveryHealthy(now: Date = Date()) {
        guard appState.isRecording, let since = recoveryFramesAt,
              now.timeIntervalSince(since) >= recoveryConfirmationSeconds,
              lastCrashAt.map({ $0 <= since }) ?? true else { return }
        xpcRetryCount = 0
        recoveryFramesAt = nil
    }
```
- `wireCaptureCallbacks()` (new, private): the closures currently set in `startRecording` lines 222-267 plus `onFirstFrames`, `onAlarmsChanged`; call it from `startRecording` and from `recoverAtLaunch`.
- `recoverAtLaunch()`: move `TranscriberApp.recoverIfNeeded` (259-404) verbatim into the coordinator, replacing `captureClient` with `self.captureClient`, `RenameWindowController.shared.show + autoSummarize` with `presentTranscript(url, config)`, `CriticalAlertController.shared.show` with `notifyCritical`, the `UNUserNotificationCenter` block with `notify`, `transcriptionRunner.prepareEngine` unchanged, and `setupCrashHandler` calls with `wireCaptureCallbacks()` + `startStatusPoll()`. The Flow-A branch also calls `Task { await pollHelperStatus() }` so alarms are restored on re-attach. Keep the `systemUptime` stale check as is (P3.1 replaces it). Delete `mirrorMicSwitches` usage (the shared wiring covers it).

- [ ] **Step 4: App wiring**

`TranscriberApp.swift`: add `private let coordinator: RecordingCoordinator`, constructed in `init()` right after `captureClient` with the closures from `MenuView.init` (moved here verbatim; `presentAlarmsUI` → `CaptureAlarmWindowController.shared.present`); replace the `recoverIfNeeded` Task (176-178) with `Task { @MainActor in await coordinator.recoverAtLaunch() }`; delete `recoverIfNeeded` and `setupCrashHandler`; pass `coordinator:` to `MenuView`. `MenuView.swift`: `let coordinator: RecordingCoordinator` replaces the `@State` + the construction in `init`.

- [ ] **Step 5: Run, build, full suite, commit**

Run: `$PARLEY_TEST --filter 'RecordingCoordinatorTests'` → pass; `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests` → green.
```bash
git add TranscriberCore/RecordingCoordinator.swift TranscriberApp/TranscriberApp.swift TranscriberApp/Views/MenuView.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift
git commit -m "fix(recovery): retry streak resets on 60 s of confirmed frames, honest Resumed, coordinator owns launch recovery (L9, L2)"
```

---

### P0 checkpoint

- [ ] Full suite green; `python3 scripts/dev.py --build` clean; README test badge + CLAUDE.md count updated to the new totals.
- [ ] Code council over `git diff <P0 start>..HEAD` with lenses: correctness, boundaries (XPC compat, queues), silent failure, tests-assert-something. Fix the must-list.
- [ ] Push; CI (`test` + `red-first`) green.
- [ ] Device: P4.1 items D-01…D-06 (idle-exit then crash; LaunchAgent print after launch/quit/crash; a `pkill -STOP` helper raises `helperUnresponsive`; Incident-B never-delivered on a fake-stalled tap via `tccutil reset AudioCapture` → alarm within 10 s; muted remote → no alarm).

---

# Phase 1 — tap healing ladder, listeners, srst, TapAutoStart

### Task P1.1: `TapRecoveryLadder` — rungs, backoff, budget, slow retry

**Files:**
- Create: `TranscriberCore/TapRecoveryLadder.swift`
- Test: `SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift` (new, red-first: compile error at parent)

**Interfaces:**
- Produces:
  ```swift
  public struct TapRecoveryLadder: Equatable, Sendable {
      public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }
      public enum Trigger: Equatable, Sendable {
          case stalled, neverDelivered, listenerStopped, wake, rebuildFailed,
               serviceRestarted, permissionGrant, permissionInsurance
      }
      public enum Action: Equatable, Sendable {
          case none
          case run(Rung, afterSeconds: Double)
          case awaitHeartbeat(seconds: Double)
          case giveUp(retryAfterSeconds: Double)
      }
      public static let backoff: [Double]                // [0.25, 0.5, 1, 2] between attempts
      public static let fastWindowSeconds: Double        // 15
      public static let heartbeatDeadlineSeconds: Double // 3
      public static let slowRetrySeconds: Double         // 60
      public static let rungBudget: Int                  // 2 per rung per episode
      public private(set) var inFlight: Rung?
      public private(set) var awaitingHeartbeat: Bool
      public private(set) var exhausted: Bool
      public private(set) var totalRebuilds: Int
      public init()
      public mutating func trigger(_ t: Trigger, now: Double) -> Action
      public mutating func rungCompleted(_ rung: Rung, succeeded: Bool, now: Double) -> Action
      public mutating func heartbeatObserved() -> Action
      public mutating func heartbeatDeadlineMissed(now: Double) -> Action
      public mutating func slowRetryDue(now: Double) -> Action
  }
  ```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// §5: a silent tap is rebuilt — aggregate first, then the whole tap — with backoff and a budget,
/// then alarmed, then retried slowly. Incident B had the rebuild code; nothing ever triggered it,
/// and one thrown rebuild was permanent (`onUnavailable`).
@Suite struct TapRecoveryLadderTests {
    typealias L = TapRecoveryLadder

    @Test func firstTriggerRunsAnAggregateRebuildImmediately() {
        var l = L()
        #expect(l.trigger(.stalled, now: 0) == .run(.rebuildAggregate, afterSeconds: 0))
        #expect(l.inFlight == .rebuildAggregate)
    }

    /// Review focus 4: an aggregate listener and a monitor verdict describe the same stall.
    @Test func secondTriggerWhileARungIsInFlightIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.listenerStopped, now: 0.1) == .none)
        #expect(l.trigger(.neverDelivered, now: 0.2) == .none)
        #expect(l.totalRebuilds == 1)
    }

    @Test func aSuccessfulRungWaitsForAHeartbeat() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(.rebuildAggregate, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        #expect(l.trigger(.stalled, now: 1) == .none, "already waiting; a verdict must not start a second rebuild")
    }

    @Test func aHeartbeatClosesTheEpisode() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(.rebuildAggregate, succeeded: true, now: 0.4)
        #expect(l.heartbeatObserved() == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat && !l.exhausted)
        #expect(l.trigger(.stalled, now: 100) == .run(.rebuildAggregate, afterSeconds: 0), "a later, separate stall starts a fresh episode")
    }

    @Test func missedHeartbeatBacksOffThenEscalatesToTheTapRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(.rebuildAggregate, succeeded: true, now: 0.3)
        #expect(l.heartbeatDeadlineMissed(now: 3.3) == .run(.rebuildAggregate, afterSeconds: 0.25))
        _ = l.rungCompleted(.rebuildAggregate, succeeded: true, now: 3.9)
        #expect(l.heartbeatDeadlineMissed(now: 6.9) == .run(.rebuildTap, afterSeconds: 0.5))
        _ = l.rungCompleted(.rebuildTap, succeeded: true, now: 7.6)
        #expect(l.heartbeatDeadlineMissed(now: 10.6) == .run(.rebuildTap, afterSeconds: 1))
    }

    @Test func aThrownRungMovesOnAfterBackoff() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(.rebuildAggregate, succeeded: false, now: 0.2) == .run(.rebuildAggregate, afterSeconds: 0.25))
    }

    @Test func budgetExhaustedGivesUpWithASlowRetry() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        for _ in 0..<4 {
            _ = l.rungCompleted(l.inFlight!, succeeded: true, now: 1)
            _ = l.heartbeatDeadlineMissed(now: 4)
        }
        #expect(l.exhausted)
        #expect(l.trigger(.stalled, now: 5) == .none, "exhausted: the slow retry owns it")
        #expect(l.slowRetryDue(now: 65) == .run(.rebuildTap, afterSeconds: 0))
        _ = l.rungCompleted(.rebuildTap, succeeded: false, now: 66)
        #expect(l.exhausted)
    }

    @Test func giveUpActionCarriesTheSlowRetryInterval() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        var last: L.Action = .none
        for _ in 0..<4 {
            _ = l.rungCompleted(l.inFlight!, succeeded: true, now: 1)
            last = l.heartbeatDeadlineMissed(now: 4)
        }
        #expect(last == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    @Test func aFastWindowTimeoutGivesUpEvenWithBudgetLeft() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(.rebuildAggregate, succeeded: true, now: 0.5)
        #expect(l.heartbeatDeadlineMissed(now: 20) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// coreaudiod restart: every id is dead, nothing below a new tap can help.
    @Test func serviceRestartedJumpsStraightToANewTap() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.serviceRestarted, now: 0.1) == .run(.rebuildTap, afterSeconds: 0))
    }

    /// A grant reaches only a tap built after it: never budgeted, never delayed, even when exhausted.
    @Test func permissionGrantRunsEvenWhenExhausted() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        for _ in 0..<4 { _ = l.rungCompleted(l.inFlight!, succeeded: true, now: 1); _ = l.heartbeatDeadlineMissed(now: 4) }
        #expect(l.trigger(.permissionGrant, now: 5) == .run(.rebuildAggregate, afterSeconds: 0))
    }

    /// The grey zone's insurance rebuild: once, only when nothing else is going on.
    @Test func permissionInsuranceRunsOnlyOnAQuietLadder() {
        var l = L()
        #expect(l.trigger(.permissionInsurance, now: 0) == .run(.rebuildAggregate, afterSeconds: 0))
        _ = l.rungCompleted(.rebuildAggregate, succeeded: true, now: 0.3)
        _ = l.heartbeatObserved()
        var busy = L()
        _ = busy.trigger(.stalled, now: 0)
        #expect(busy.trigger(.permissionInsurance, now: 0.1) == .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `$PARLEY_TEST --filter 'TapRecoveryLadderTests'` — Expected: compile error.

- [ ] **Step 3: Implement**

`TranscriberCore/TapRecoveryLadder.swift`:
```swift
import Foundation

/// The tap's healing ladder (§5). Pure: fed triggers, rung results and heartbeat timing; answers
/// with the one thing to do next. The helper's `TapHealer` runs the rungs and the timers.
public struct TapRecoveryLadder: Equatable, Sendable {
    public enum Rung: String, Codable, Equatable, Sendable { case rebuildAggregate, rebuildTap }

    public enum Trigger: Equatable, Sendable {
        case stalled, neverDelivered, listenerStopped, wake, rebuildFailed
        case serviceRestarted, permissionGrant, permissionInsurance
    }

    public enum Action: Equatable, Sendable {
        case none
        case run(Rung, afterSeconds: Double)
        case awaitHeartbeat(seconds: Double)
        case giveUp(retryAfterSeconds: Double)
    }

    public static let backoff: [Double] = [0.25, 0.5, 1, 2]
    public static let fastWindowSeconds: Double = 15
    public static let heartbeatDeadlineSeconds: Double = 3
    public static let slowRetrySeconds: Double = 60
    public static let rungBudget = 2

    private var episodeStartedAt: Double?
    private var attempts: [Rung: Int] = [:]
    public private(set) var inFlight: Rung?
    public private(set) var awaitingHeartbeat = false
    public private(set) var exhausted = false
    public private(set) var totalRebuilds = 0

    public init() {}

    public mutating func trigger(_ t: Trigger, now: Double) -> Action {
        switch t {
        case .serviceRestarted:
            reset()
            episodeStartedAt = now
            return start(.rebuildTap, delay: 0)
        case .permissionGrant:
            if inFlight != nil { return .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            awaitingHeartbeat = false
            return start(.rebuildAggregate, delay: 0)
        case .permissionInsurance:
            guard inFlight == nil, !awaitingHeartbeat, !exhausted, episodeStartedAt == nil else { return .none }
            episodeStartedAt = now
            return start(.rebuildAggregate, delay: 0)
        case .stalled, .neverDelivered, .listenerStopped, .wake, .rebuildFailed:
            if inFlight != nil || awaitingHeartbeat { return .none }
            if exhausted { return t == .rebuildFailed ? .giveUp(retryAfterSeconds: Self.slowRetrySeconds) : .none }
            if episodeStartedAt == nil { episodeStartedAt = now }
            return nextRung(now: now)
        }
    }

    public mutating func rungCompleted(_ rung: Rung, succeeded: Bool, now: Double) -> Action {
        guard inFlight == rung else { return .none }
        inFlight = nil
        if succeeded {
            awaitingHeartbeat = true
            return .awaitHeartbeat(seconds: Self.heartbeatDeadlineSeconds)
        }
        return trigger(.rebuildFailed, now: now)
    }

    public mutating func heartbeatObserved() -> Action {
        reset()
        return .none
    }

    public mutating func heartbeatDeadlineMissed(now: Double) -> Action {
        guard awaitingHeartbeat else { return .none }
        awaitingHeartbeat = false
        return nextRung(now: now)
    }

    public mutating func slowRetryDue(now: Double) -> Action {
        guard exhausted, inFlight == nil else { return .none }
        inFlight = .rebuildTap
        totalRebuilds += 1
        return .run(.rebuildTap, afterSeconds: 0)
    }

    private mutating func nextRung(now: Double) -> Action {
        let used = attempts.values.reduce(0, +)
        if used > 0, now - (episodeStartedAt ?? now) > Self.fastWindowSeconds { return giveUp() }
        let rung: Rung
        if (attempts[.rebuildAggregate] ?? 0) < Self.rungBudget { rung = .rebuildAggregate }
        else if (attempts[.rebuildTap] ?? 0) < Self.rungBudget { rung = .rebuildTap }
        else { return giveUp() }
        let delay = used == 0 ? 0 : Self.backoff[min(used - 1, Self.backoff.count - 1)]
        return start(rung, delay: delay)
    }

    private mutating func start(_ rung: Rung, delay: Double) -> Action {
        inFlight = rung
        attempts[rung, default: 0] += 1
        totalRebuilds += 1
        return .run(rung, afterSeconds: delay)
    }

    private mutating func giveUp() -> Action {
        inFlight = nil
        awaitingHeartbeat = false
        exhausted = true
        return .giveUp(retryAfterSeconds: Self.slowRetrySeconds)
    }

    private mutating func reset() {
        episodeStartedAt = nil
        attempts = [:]
        inFlight = nil
        awaitingHeartbeat = false
        exhausted = false
    }
}
```

- [ ] **Step 4: Run to verify it passes, commit**

Run: `$PARLEY_TEST --filter 'TapRecoveryLadderTests'` — Expected: 12 pass.
```bash
git add TranscriberCore/TapRecoveryLadder.swift SwiftTests/TranscriberTests/TapRecoveryLadderTests.swift
git commit -m "feat(tap): TapRecoveryLadder — rungs, backoff, budget, slow retry (Q4.3, H5)"
```

---

### Task P1.2: `SystemTapSession` — aggregate listeners, tap rung, results instead of `onUnavailable`

**Files:**
- Modify: `AudioCaptureHelper/XPC/SystemTapSession.swift:36-43, 68-80, 116-135, 336-362, 389-432, 505-540, 591-661`
- Modify: `TranscriberCore/CaptureDiagnostics.swift` (kinds `.tapRecoveryRung` warning, `.tapRecoveryGivenUp` anomaly, `.recoveryStuck` anomaly, `.aggregateIOStopped` warning)
- No unit tests (helper target); verified by the P1.3 wiring build and P4 device items D-10…D-13.

**Interfaces:**
- Produces on `SystemTapSession`:
  ```swift
  var onAggregateEvent: ((String) -> Void)?      // fourcc: "goin" (value 0 only), "stpd", "diff", "agrp"; on monitorQueue
  var onRebuildResult: ((TapRecoveryLadder.Rung, Bool, String) -> Void)?   // (rung, succeeded, reason); on configQueue
  func rebuild(rung: TapRecoveryLadder.Rung, reason: String)               // async on configQueue
  var generation: Int { get }                     // bumped per buildAggregateAndStart
  ```
  Removes: `onUnavailable`, `rebuild(reason:)`, `isOutputDeviceRunningSomewhere()` (P0.3 already removed the latter).

- [ ] **Step 1: Aggregate listeners**

Add fields: `private var aggregateListenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []` (stateLock), `var onAggregateEvent: ((String) -> Void)?`, `private(set) var generation = 0` (under `stateLock`, read via a `generationValue()` accessor).

At the end of `buildAggregateAndStart` (after `stateLock.sync { aggregateID = agg; procID = proc }`, before the log at 349), add:
```swift
        registerAggregateListeners(on: agg)
        stateLock.sync { generation += 1 }
```
with:
```swift
    private static let aggregateSelectors: [(AudioObjectPropertySelector, String)] = [
        (kAudioDevicePropertyDeviceIsRunning, "goin"),
        (kAudioDevicePropertyIOStoppedAbnormally, "stpd"),
        (kAudioDevicePropertyDeviceHasChanged, "diff"),
        (kAudioAggregateDevicePropertyActiveSubDeviceList, "agrp"),
    ]

    /// Accelerators only (§5): they force an immediate heartbeat check in the healer; the
    /// heartbeat decides. Registered per aggregate generation, removed in `teardownIO`.
    private func registerAggregateListeners(on agg: AudioObjectID) {
        var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for (selector, name) in Self.aggregateSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if name == "goin" {
                    var running: UInt32 = 1; var size = UInt32(4)
                    var a = addr
                    if AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &running) == noErr, running != 0 { return }
                }
                Logger.audio.warning("System tap aggregate event '\(name, privacy: .public)'")
                self.onEvent?(.aggregateIOStopped, .warning, ["source": "system-tap", "selector": name])
                self.onAggregateEvent?(name)
            }
            if AudioObjectAddPropertyListenerBlock(agg, &addr, monitorQueue, block) == noErr {
                registered.append((addr, block))
            }
        }
        stateLock.sync { aggregateListenerBlocks = registered }
    }
```
In `teardownIO` (line 391), before `AudioDeviceStop`, remove them: read-and-clear `aggregateListenerBlocks` under `stateLock`, then `AudioObjectRemovePropertyListenerBlock(agg, &addr, monitorQueue, block)` for each.

- [ ] **Step 2: Rungs and results**

Replace `rebuild(reason:)` (639-641) and `rebuildForOutputChange` (645-661) with:
```swift
    /// Run one healing rung on `configQueue`. The result goes to `onRebuildResult`; the healer
    /// decides what happens next. A stop that raced in makes this a no-op.
    func rebuild(rung: TapRecoveryLadder.Rung, reason: String) {
        if stateLock.sync(execute: { isStopping }) { return }
        configQueue.async { [weak self] in
            guard let self else { return }
            if self.stateLock.sync(execute: { self.isStopping }) { return }
            self.teardownIO()
            do {
                if rung == .rebuildTap {
                    self.destroyTap()
                    try self.createTap()
                }
                try self.buildAggregateAndStart()
                Logger.audio.info("System tap \(rung.rawValue, privacy: .public) done (\(reason, privacy: .public))")
                self.onEvent?(.restartInPlace, .warning, ["source": "system-tap", "reason": reason, "rung": rung.rawValue])
                self.onRebuildResult?(rung, true, reason)
            } catch {
                Logger.audio.error("System tap \(rung.rawValue, privacy: .public) failed (\(reason, privacy: .public)): \(error, privacy: .public)")
                self.onEvent?(.restartFailed, .anomaly, ["source": "system-tap", "reason": "\(rung.rawValue) failed: \(reason)", "error": "\(error)"])
                self.onRebuildResult?(rung, false, reason)
            }
        }
    }

    /// Output-device change (HAL listener): the same aggregate rebuild, reported into the ladder.
    private func rebuildForOutputChange() { rebuild(rung: .rebuildAggregate, reason: "output device changed") }
```
`checkRateDrift` line 755: `rebuild(rung: .rebuildAggregate, reason: "rate drift remediation")`. `handleDeviceListChange` keeps `scheduleOutputReevaluation()`. Delete `var onUnavailable`.

- [ ] **Step 3: Event kinds**

`CaptureDiagnostics.swift`: add `.aggregateIOStopped` (warning), `.tapRecoveryRung` (warning), `.tapRecoveryGivenUp` (anomaly; add to `qualityCompromising`), `.recoveryStuck` (anomaly; add to `qualityCompromising`).

- [ ] **Step 4: Build and commit**

Run: `python3 scripts/dev.py --build` (will fail until P1.3 rewires `onUnavailable` callers — do P1.3 before committing, or stub the callers now: replace the `tap.onUnavailable = …` block in `AudioCaptureService.startSystemTap` with nothing and the `restartSystemAudio`/`apply(.rebuildTap)` call with `tap?.rebuild(rung: .rebuildAggregate, reason: "system audio permission")`). Expected: build clean.
```bash
git add AudioCaptureHelper/XPC/SystemTapSession.swift AudioCaptureHelper/XPC/AudioCaptureService.swift TranscriberCore/CaptureDiagnostics.swift
git commit -m "feat(tap): aggregate goin/stpd/diff/agrp listeners, tap rung, rebuild results instead of a permanent onUnavailable (Q1, Q2b, Q4.2)"
```

---

### Task P1.3: `TapHealer` + `MicHealPolicy` — wire verdicts into healing, alarms after healing

**Files:**
- Create: `AudioCaptureHelper/XPC/TapHealer.swift`, `TranscriberCore/MicHealPolicy.swift`
- Modify: `AudioCaptureHelper/XPC/AudioCaptureService.swift` (`handleLiveness`, `startSystemTap`, `apply(_:)`, `restartSystemAudio`), `AudioCaptureHelper/XPC/MicCaptureSession.swift` (expose `heal()`)
- Modify: `TranscriberCore/TapPermissionGuard.swift:24-32, 45-52, 127-147` (retire `deliveryGap`, `noBuffersAfterRebuild`, `wantsOutputState`; add the soft-alarm knob), `TranscriberCore/Config.swift` (`remoteExactZeroSoftAlarmSeconds`)
- Test: `SwiftTests/TranscriberTests/MicHealPolicyTests.swift` (new, red-first), `TapPermissionGuardTests.swift` (mark `// RED-FIRST-EXEMPT: tests for the retired deliveryGap/noBuffersAfterRebuild path are removed; the remaining tests are unchanged characterization` and add the soft-alarm tests in a NEW file `TapPermissionGuardSoftAlarmTests.swift`, red-first)

**Interfaces:**
- `MicHealPolicy` (pure): `enum Action { case heal, healAndAlarm, clear, none }`; `mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict) -> Action` — first `neverDelivered`/`stalled` of an episode → `.heal`; a second without a clear → `.healAndAlarm` (and every later one → `.heal`); `.cleared`/`.firstFrames` → `.clear`.
- `TapHealer` (helper): `init(queue:)`, `weak var tap`, `func trigger(_:)`, `func heartbeatObserved()`, `func rebuildResult(_:succeeded:)`, `var onEvent`, `var onGiveUp: (() -> Void)?`, `var onRecovered: (() -> Void)?`, `var onStuck: (() -> Void)?`, `var totalRebuilds: Int`.
- `TapPermissionGuard.init(zeroThresholdSeconds:softAlarmSeconds: Double? = nil)`; `tick(now:)` (no `outputRunning`); `Evidence` loses `.deliveryGap`; new action `.reportCantConfirm` is NOT added — the soft alarm reuses `.reportDenied(nil)`.
- `Config.remoteExactZeroSoftAlarmSeconds: Int?` (key `remote_exact_zero_soft_alarm_seconds`, default nil = off, §10 M-A).

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/MicHealPolicyTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// H4 (mic side of §5): a silent mic is rebuilt first; the alarm comes only if that did not bring
/// frames back. `MicCaptureSession.attemptRecover()` has always existed; nothing called it for a
/// silent-but-not-errored session.
@Suite struct MicHealPolicyTests {
    @Test func firstSilenceHealsWithoutAlarming() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func silenceAfterAHealAttemptAlarmsAndHealsAgain() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .healAndAlarm)
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func framesClearTheEpisode() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.firstFrames) == .clear)
        #expect(p.onVerdict(.stalled(seconds: 3)) == .heal)
    }
    @Test func healthyIsNothing() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.healthy) == .none)
    }
}
```

`SwiftTests/TranscriberTests/TapPermissionGuardSoftAlarmTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// §9 / M-A: exact zeros with the permission authorized are the muted-remote shape and never alarm
/// on their own. A "can't confirm" after a long run ships OFF (nil) until the exact-zero census
/// shows no call app renders zeros when muted.
@Suite struct TapPermissionGuardSoftAlarmTests {
    private let zeros = [Int16](repeating: 0, count: 4_800)

    private func feed(_ g: inout TapPermissionGuard, seconds: Double) -> [TapPermissionGuard.Action] {
        var actions: [TapPermissionGuard.Action] = []
        var t = 0.0
        for _ in 0..<Int(seconds * 10) { actions += g.samples(zeros, rate: 48_000, now: t); actions += g.tick(now: t); t += 0.1 }
        return actions
    }

    @Test func offByDefaultTenMinutesOfZerosNeverAlarms() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        let actions = feed(&g, seconds: 600)
        #expect(!actions.contains { if case .reportDenied = $0 { return true }; return false })
        // The quiet investigation still happens: one check, and (on authorized) one insurance rebuild.
        #expect(actions.filter { $0 == .checkPermission(.exactZeroRun) }.count == 1)
    }

    @Test func whenEnabledItSaysCantConfirmOnceAfterTheWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        var actions = feed(&g, seconds: 299)
        #expect(!actions.contains(.reportDenied(nil)))
        actions = feed(&g, seconds: 2)
        #expect(actions.filter { $0 == .reportDenied(nil) }.count == 1)
    }

    @Test func realAudioResetsTheSoftWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = feed(&g, seconds: 200)
        _ = g.samples([Int16](repeating: 0, count: 4_799) + [1], rate: 48_000, now: 200)
        let actions = feed(&g, seconds: 200)
        #expect(!actions.contains(.reportDenied(nil)))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `$PARLEY_TEST --filter 'MicHealPolicyTests|TapPermissionGuardSoftAlarmTests'` — Expected: compile errors (`MicHealPolicy`, `softAlarmSeconds:`).

- [ ] **Step 3: Implement the cores**

`TranscriberCore/MicHealPolicy.swift`:
```swift
import Foundation

/// Mic side of "heal, then alarm" (§5, §6.1): the first silence verdict of an episode rebuilds the
/// AVCaptureSession; a second, still silent, alarms as well. Frames end the episode.
public struct MicHealPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case heal, healAndAlarm, clear, none }
    private var healsThisEpisode = 0
    public init() {}

    public mutating func onVerdict(_ v: TrackLivenessMonitor.Verdict) -> Action {
        switch v {
        case .neverDelivered, .stalled:
            healsThisEpisode += 1
            return healsThisEpisode == 2 ? .healAndAlarm : .heal
        case .cleared, .firstFrames:
            healsThisEpisode = 0
            return .clear
        case .healthy:
            return .none
        }
    }
}
```

`TapPermissionGuard.swift`: delete `Evidence.deliveryGap`, `noBuffersAfterRebuild`, `deliveryGap(now:)`, the first `if awaitingAudio, outputRunning == true …` block in `tick` (136-140) and `wantsOutputState`; change `tick(now:)` to a single parameter. Add `private let softAlarmSeconds: Double?`, `private var zeroRunStartedAt: Double?` (set in `samples` when a batch is all-zero and nil otherwise; reset to nil on real audio), and in `tick(now:)` before the existing guard:
```swift
        if let soft = softAlarmSeconds, let since = zeroRunStartedAt, now - since >= soft, !problemReported {
            return report(nil, now: now)
        }
```
`init(zeroThresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds, softAlarmSeconds: Double? = nil)`.

`Config.swift`: `public var remoteExactZeroSoftAlarmSeconds: Int?` with key `remote_exact_zero_soft_alarm_seconds` (decodeIfPresent). `docs/parameters.md` row: default `nil` (off), "see the exact-zero census (M-A) before enabling".

- [ ] **Step 4: Run to verify they pass**

Run: `$PARLEY_TEST --filter 'MicHealPolicyTests|TapPermissionGuardSoftAlarmTests|TapPermissionGuardTests'` — Expected: pass (after removing the `deliveryGap`/`wantsOutputState` tests and adding the exemption marker).

- [ ] **Step 5: `TapHealer` and the service wiring**

`AudioCaptureHelper/XPC/TapHealer.swift`:
```swift
import Foundation
import os
import TranscriberCore

/// Runs `TapRecoveryLadder`'s actions: dispatches rungs to `SystemTapSession`, arms the
/// heartbeat deadline, the stuck watchdog and the slow retry. Single serial queue; no decisions
/// of its own.
final class TapHealer {
    private let queue = DispatchQueue(label: "audio-capture.tap-healer")
    private var ladder = TapRecoveryLadder()
    private let epoch = DispatchTime.now().uptimeNanoseconds
    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - epoch) / 1e9 }
    private var heartbeatDeadline: DispatchWorkItem?
    private var stuckWatchdog: DispatchWorkItem?
    private var slowRetry: DispatchWorkItem?
    static let stuckSeconds: Double = 5

    weak var tap: SystemTapSession?
    var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?
    var onGiveUp: (() -> Void)?
    var onRecovered: (() -> Void)?
    var onStuck: (() -> Void)?
    var totalRebuilds: Int { queue.sync { ladder.totalRebuilds } }

    func trigger(_ t: TapRecoveryLadder.Trigger) {
        queue.async { self.apply(self.ladder.trigger(t, now: self.now)) }
    }

    func heartbeatObserved() {
        queue.async {
            let wasHealing = self.ladder.inFlight != nil || self.ladder.awaitingHeartbeat || self.ladder.exhausted
            self.heartbeatDeadline?.cancel(); self.slowRetry?.cancel()
            _ = self.ladder.heartbeatObserved()
            if wasHealing { self.onRecovered?() }
        }
    }

    func rebuildResult(_ rung: TapRecoveryLadder.Rung, succeeded: Bool) {
        queue.async {
            self.stuckWatchdog?.cancel()
            self.apply(self.ladder.rungCompleted(rung, succeeded: succeeded, now: self.now))
        }
    }

    func cancelAll() {
        queue.async { [self] in heartbeatDeadline?.cancel(); stuckWatchdog?.cancel(); slowRetry?.cancel() }
    }

    private func apply(_ action: TapRecoveryLadder.Action) {
        switch action {
        case .none:
            break
        case .run(let rung, let delay):
            onEvent?(.tapRecoveryRung, .warning, ["rung": rung.rawValue, "delay": "\(delay)", "total": "\(ladder.totalRebuilds)"])
            let stuck = DispatchWorkItem { [weak self] in
                self?.onEvent?(.recoveryStuck, .anomaly, ["rung": rung.rawValue])
                self?.onStuck?()
            }
            stuckWatchdog = stuck
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + Self.stuckSeconds, execute: stuck)
                self.tap?.rebuild(rung: rung, reason: "healing ladder")
            }
        case .awaitHeartbeat(let seconds):
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply(self.ladder.heartbeatDeadlineMissed(now: self.now))
            }
            heartbeatDeadline = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        case .giveUp(let retryAfter):
            onEvent?(.tapRecoveryGivenUp, .anomaly, ["rebuilds": "\(ladder.totalRebuilds)"])
            onGiveUp?()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply(self.ladder.slowRetryDue(now: self.now))
            }
            slowRetry = item
            queue.asyncAfter(deadline: .now() + retryAfter, execute: item)
        }
    }
}
```

`AudioCaptureService.swift`:
- `private let tapHealer = TapHealer()`, `private var micHealPolicy = MicHealPolicy()` (watchdog queue only).
- In `startSystemTap`: `tapHealer.tap = tap`; `tap.onRebuildResult = { [weak self] rung, ok, _ in self?.tapHealer.rebuildResult(rung, succeeded: ok) }`; `tap.onAggregateEvent = { [weak self] _ in self?.livenessWatchdog.accelerate(track: "system") }` (a heartbeat check 1 s later, never a blind rebuild — the resulting `.stalled` verdict is what reaches the ladder); `tapHealer.onEvent = { [weak self] k, s, d in self?.record(k, s, d) }`; `tapHealer.onGiveUp = { [weak self] in self?.raiseAlarm(.remoteNotDelivering, "The other side of the call isn’t reaching Parley although audio is playing. Parley keeps retrying; if this persists, check the output device in the call app.") }`; `tapHealer.onRecovered = { [weak self] in self?.clearAlarm(.remoteNotDelivering); self?.clearAlarm(.remoteRecoveryFailed) }`; `tapHealer.onStuck = { [weak self] in self?.raiseAlarm(.remoteRecoveryFailed, "Parley could not restart system-audio capture. The other side may not be recorded.") }`.
- `handleLiveness`: system track → `.neverDelivered`/`.stalled`: record + `tapHealer.trigger(.neverDelivered / .stalled)` (no alarm here); `.firstFrames`/`.cleared(.heartbeat)` → `tapHealer.heartbeatObserved()` + `onFirstFrames` on `.firstFrames`; `.cleared(.gateClosed)` → `clearAlarm(.remoteNotDelivering)`. Mic track → `switch micHealPolicy.onVerdict(v)`: `.heal` → `micSession?.heal()`; `.healAndAlarm` → `micSession?.heal()` + `raiseAlarm(.micNotDelivering, "The microphone isn’t delivering any audio. Try another microphone from the menu.")`; `.clear` → `clearAlarm(.micNotDelivering)`.
- `apply(_:)`: `.rebuildTap` → `tapHealer.trigger(tapGuard.builtWithoutGrant ? .permissionGrant : .permissionInsurance)`. Hmm — `builtWithoutGrant` is cleared by the guard before it returns `.rebuildTap`; add a payload instead: change the action to `.rebuildTap(reason: RebuildReason)` with `enum RebuildReason { case grant, insurance }` (TapPermissionGuardTests assert `== [.rebuildTap]` → they change to `[.rebuildTap(.grant)]` / `.rebuildTap(.insurance)`; that is a real behaviour change, red-first, so drop the exemption marker on the file and let those assertions be the red).
- `startTapGuardTimer` handler: `self.apply(self.tapGuard.tick(now: self.guardNow()))`.
- `startSystemTap`: `tapGuard = TapPermissionGuard(softAlarmSeconds: options.remoteExactZeroSoftAlarmSeconds.map(Double.init))` (options from P1.4; until then `nil`).
- `stopCapture`/`stopAndFinalize`/`cleanupAfterFailure`: `tapHealer.cancelAll()`.

`MicCaptureSession.swift`: add `func heal() { attemptRecover() }` (public within the module) with a doc: "silent-but-not-errored session; the monitor's verdict is the only caller".

- [ ] **Step 6: Build, full suite, commit**

Run: `python3 scripts/dev.py --build`; `$PARLEY_TEST --filter TranscriberTests`. Expected green.
```bash
git add -A TranscriberCore AudioCaptureHelper SwiftTests docs/parameters.md
git commit -m "feat(healing): TapHealer runs the ladder from liveness verdicts; mic heals before alarming; permission guard keeps permission logic only (H3, H4, H5, Q4.4)"
```

---

### Task P1.4: `CaptureOptions` and the `tap_auto_start` knob

**Files:**
- Create: `TranscriberCore/CaptureOptions.swift`
- Modify: `TranscriberCore/Config.swift` (`tapAutoStart: Bool?`), `AudioCaptureProtocol/AudioCaptureProtocol.swift` (`configureCapture(optionsJSON:reply:)`), `AudioCaptureHelper/XPC/AudioCaptureService.swift` (pending options; pass into `SystemTapSession`), `AudioCaptureHelper/XPC/SystemTapSession.swift:106-109, 241` (init parameter), `TranscriberApp/Services/AudioCaptureClient.swift` (`start` sends options first), `TranscriberCore/RecordingCaptureClient.swift` (`start(... options:)`), `TranscriberCore/RecordingCoordinator.swift` (build options from config), `docs/parameters.md`
- Test: `SwiftTests/TranscriberTests/CaptureOptionsTests.swift` (new, red-first), `ConfigTests.swift` (round-trip of the two new keys, red-first), `RecordingCoordinatorTests.swift` `FakeCaptureClient.start` gains `options:` (compile-forced)

**Interfaces:**
```swift
public struct CaptureOptions: Codable, Equatable, Sendable {
    public var tapAutoStart: Bool               // default true until M-B passes (§5)
    public var remoteExactZeroSoftAlarmSeconds: Int?
    public init(tapAutoStart: Bool = true, remoteExactZeroSoftAlarmSeconds: Int? = nil)
    public init(config: Config)
    public func encoded() -> Data
    public static func decode(_ data: Data?) -> CaptureOptions   // nil / garbage → defaults
}
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/CaptureOptionsTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// M-B: `TapAutoStart` decides whether "no callbacks" is ambiguous. It becomes a diagnostic knob
/// so the device test can A/B it without a rebuild; the default flips only on a measured pass.
@Suite struct CaptureOptionsTests {
    @Test func defaultsMatchTheShippedBehaviour() {
        let o = CaptureOptions()
        #expect(o.tapAutoStart == true)
        #expect(o.remoteExactZeroSoftAlarmSeconds == nil)
    }
    @Test func builtFromConfig() {
        var c = Config.default
        c.tapAutoStart = false
        c.remoteExactZeroSoftAlarmSeconds = 300
        let o = CaptureOptions(config: c)
        #expect(o.tapAutoStart == false && o.remoteExactZeroSoftAlarmSeconds == 300)
    }
    @Test func roundTripsAndFailsSoft() {
        let o = CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: 120)
        #expect(CaptureOptions.decode(o.encoded()) == o)
        #expect(CaptureOptions.decode(nil) == CaptureOptions())
        #expect(CaptureOptions.decode(Data("nope".utf8)) == CaptureOptions())
    }
}
```
`ConfigTests.swift`: add a round-trip test asserting `tap_auto_start` and `remote_exact_zero_soft_alarm_seconds` encode/decode and default to nil.

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'CaptureOptionsTests|ConfigTests'` → compile errors.

- [ ] **Step 3: Implement**

`CaptureOptions.swift` as in Interfaces (JSONEncoder/Decoder, `decode` returns defaults on nil or failure). `Config.swift`: `public var tapAutoStart: Bool?` (key `tap_auto_start`, decodeIfPresent). `AudioCaptureProtocol`: `func configureCapture(optionsJSON: Data, reply: @escaping (Bool) -> Void)`; the helper stores `pendingOptions = CaptureOptions.decode(optionsJSON)` under `stateLock` and reads it in `startCapture` (`let options = stateLock.sync { pendingOptions }`), records `"tap_auto_start": "\(options.tapAutoStart)"` in the `.captureStart` detail, and passes `tapAutoStart:` to `SystemTapSession.init` which writes it at line 241. `AudioCaptureClient.start(..., options: CaptureOptions)` calls `configureCapture` first (3 s deadline, failure logged and ignored — the helper then uses defaults). `RecordingCaptureClient.start` gains `options: CaptureOptions`; the coordinator passes `CaptureOptions(config: configManager.config)`; `FakeCaptureClient` records it. `docs/parameters.md`: two rows.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add -A TranscriberCore AudioCaptureHelper AudioCaptureProtocol TranscriberApp SwiftTests docs/parameters.md
git commit -m "feat(tap): tap_auto_start + remote_exact_zero_soft_alarm_seconds as capture options (Q3b, Q4.6, M-B)"
```

---

### Task P1.5: coreaudiod restart (`srst`) and listener re-registration

**Files:**
- Modify: `AudioCaptureHelper/XPC/SystemTapSession.swift:505-540, 591-621` (srst listener; `reregisterSystemListeners()`), `AudioCaptureHelper/XPC/OutputActivityProbe.swift` (`restart()`), `AudioCaptureHelper/XPC/LivenessWatchdogDriver.swift` (`serviceRestarted()`), `AudioCaptureHelper/XPC/AudioCaptureService.swift`, `TranscriberCore/CaptureDiagnostics.swift` (`.serviceRestarted` warning)
- No unit test (helper); device item D-13 (M-D).

- [ ] **Step 1: Implement**

`SystemTapSession.startDeviceMonitoring`: register a third system-object listener for `kAudioHardwarePropertyServiceRestarted` on `monitorQueue` whose block logs, emits `onEvent?(.serviceRestarted, .warning, ["source": "system-tap"])`, calls `onServiceRestarted?()`. `stopDeviceMonitoring` removes it. Add `func reregisterSystemListeners()` = `stopDeviceMonitoring(); startDeviceMonitoring()` — called inside `rebuild(rung: .rebuildTap …)` after `createTap()` (the header says client state must be re-established).
`OutputActivityProbe.restart()` = `stop(); start()`. `LivenessWatchdogDriver.serviceRestarted()` → `queue.async { outputActivity.restart() }`.
`AudioCaptureService`: `tap.onServiceRestarted = { [weak self] in guard let self else { return }; self.livenessWatchdog.serviceRestarted(); self.tapHealer.trigger(.serviceRestarted); self.stateLock.sync { self.micSession }?.heal() }`.

- [ ] **Step 2: Build, commit**

```bash
git add AudioCaptureHelper/XPC TranscriberCore/CaptureDiagnostics.swift
git commit -m "feat(tap): coreaudiod restart → new tap + listeners re-registered, mic re-opened (Q1g, Q3c)"
```

---

### P1 checkpoint

- [ ] Full suite green; build clean; council over the P1 diff (lens: HAL calls that can block on `configQueue`; every rung reports a result; no rebuild without a trigger; no alarm before the fast budget is spent).
- [ ] CI green.
- [ ] Device (P4.1): D-10 M-C Incident-B reproduction (which rung clears it, `AudioDeviceStop` latency), D-11 M-E (`stpd`/`goin` on a real aggregate), D-12 M-B TapAutoStart A/B (callbacks, powermetrics, artefacts), D-13 M-D coreaudiod restart, D-14 M-G insurance rebuild dead window, D-15 M-J first-frame latency. **Decisions after D-12/D-15:** `CaptureOptions.tapAutoStart` default (and `Config` docs), and the two thresholds in `TrackLivenessMonitor.init` defaults — recorded in the commit message with the measurements.

---

# Phase 2 — honest record and post-capture data loss

### Task P2.1: `TrackAccounting` — per-track coverage in provenance, `dual_stream` from capture, summary header

**Files:**
- Create: `TranscriberCore/TrackAccounting.swift`
- Modify: `TranscriberCore/CaptureDiagnostics.swift` (`.trackCoverage` info kind; `CaptureProvenance.localCoverage/remoteCoverage/localStatus/remoteStatus`; `makeProvenance` sums), `TranscriberCore/TranscriptAssembler.swift` (`metadata.capture`), `TranscriberCore/TranscriptionRunner.swift:396-400, 442-454`, `TranscriberCore/MeetingSummarizer.swift:174-217`, `TranscriberCore/SummaryProvider.swift` (`SummaryMetadata.remoteCapture/localCapture`), `TranscriberCore/SummaryPromptBuilder.swift`, `TranscriberCore/CaptureAlarm.swift` (`TrackHealthSnapshot` unchanged; `CaptureStatusSnapshot.tracks` now filled)
- Modify (helper): `AudioCaptureHelper/XPC/AudioCaptureService.swift` (accumulate; emit at rotation + stop; `snapshot().tracks`), `AudioOutputHandler.swift:47-53, 142-172, 382-413, 574-595` (pad/delivered/exact-zero counters, expected-seconds provider), `LivenessWatchdogDriver.swift` (`onGate`), `SystemTapSession.swift`/`MicCaptureSession.swift` (heartbeat counts)
- Test: `SwiftTests/TranscriberTests/TrackAccountingTests.swift` (new), `CaptureDiagnosticsTests.swift` (add provenance-sum test), `TranscriptionRunnerTests.swift` (add `dual_stream` test), `SummaryPromptBuilderTests.swift` (header line), `MeetingSummarizerTests.swift` (parses `metadata.capture`) — all red-first

**Interfaces:**
```swift
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }
    public var expectedSeconds: Double, heartbeatCallbacks: Int, deliveredSeconds: Double, exactZeroSeconds: Double,
               paddedSeconds: Double, longestGapSeconds: Double, gapCount: Int, rebuilds: Int
    public init()
    public static let minimumDeficitSeconds: Double   // 15
    public static let deficitRatio: Double            // 0.10
    public func status(isTap: Bool, contentAnomalies: Int) -> Status
    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting)
    public func asDetail(prefix: String) -> [String: String]     // "remote_expected_seconds": "12.3", …
    public init?(detail: [String: String], prefix: String)
    public func asMetadataDictionary(status: Status) -> [String: Any]  // snake_case + "status"
}
// CaptureProvenance: + localCoverage: TrackAccounting?, remoteCoverage: TrackAccounting?, localStatus: String?, remoteStatus: String?
// SummaryMetadata: + remoteCapture: CaptureSideNote?, localCapture: CaptureSideNote?  where
public struct CaptureSideNote: Equatable, Sendable { public let status: String; public let deliveredSeconds: Double; public let expectedSeconds: Double }
```

- [ ] **Step 1: Write the failing tests**

`SwiftTests/TranscriberTests/TrackAccountingTests.swift`:
```swift
import Testing
@testable import TranscriberCore

/// §7.1: the record says per side how much was expected and delivered. Incident B's provenance
/// said `system_delivered_seconds 0, anomaly_count 0` and nothing about 2736 s of expected output.
@Suite struct TrackAccountingTests {
    @Test func nothingExpectedNothingDeliveredIsIdleForTheTap() {
        var a = TrackAccounting()
        a.expectedSeconds = 0.4
        #expect(a.status(isTap: true, contentAnomalies: 0) == .idle)
        #expect(a.status(isTap: false, contentAnomalies: 0) == .healthy, "the mic is always expected; a 0.4 s session is just short")
    }

    /// Incident B.
    @Test func expectedButNeverDeliveredIsNeverDelivered() {
        var a = TrackAccounting()
        a.expectedSeconds = 2736
        #expect(a.status(isTap: true, contentAnomalies: 0) == .neverDelivered)
    }

    @Test func aDeficitOfTenPercentAndFifteenSecondsIsCompromised() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 84
        #expect(a.status(isTap: true, contentAnomalies: 0) == .compromised)
        a.deliveredSeconds = 91
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "9 % short: within tolerance")
        a.expectedSeconds = 60; a.deliveredSeconds = 50
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy, "10 s short: under the 15 s floor")
    }

    @Test func aContentAnomalyIsCompromisedRegardlessOfCoverage() {
        var a = TrackAccounting()
        a.expectedSeconds = 100; a.deliveredSeconds = 100
        #expect(a.status(isTap: false, contentAnomalies: 1) == .compromised)
    }

    /// Review focus 5: the probe failed open / TapAutoStart=false zeros — frames without a gate.
    @Test func deliveredWithNothingExpectedIsHealthyNotIdle() {
        var a = TrackAccounting()
        a.deliveredSeconds = 30
        #expect(a.status(isTap: true, contentAnomalies: 0) == .healthy)
    }

    @Test func detailRoundTripsAndSums() throws {
        var a = TrackAccounting()
        a.expectedSeconds = 10; a.deliveredSeconds = 9.5; a.exactZeroSeconds = 1; a.paddedSeconds = 0.5
        a.longestGapSeconds = 3; a.gapCount = 1; a.rebuilds = 2; a.heartbeatCallbacks = 940
        let back = try #require(TrackAccounting(detail: a.asDetail(prefix: "remote"), prefix: "remote"))
        #expect(back == a)
        var sum = a; sum += back
        #expect(sum.expectedSeconds == 20 && sum.rebuilds == 4 && sum.longestGapSeconds == 3)
    }
}
```

Add to `CaptureDiagnosticsTests.swift`:
```swift
    /// A crash-recovered recording has several helper sessions, each with its own captureStop.
    @Test func provenanceSumsCoverageAcrossHelperSessions() {
        var d = CaptureDiagnostics()
        var a = TrackAccounting(); a.expectedSeconds = 100; a.deliveredSeconds = 100
        var b = TrackAccounting(); b.expectedSeconds = 50; b.deliveredSeconds = 0
        d.record(CaptureEvent(timestamp: Date(), origin: .helper, kind: .captureStop, severity: .info, detail: a.asDetail(prefix: "remote")))
        d.record(CaptureEvent(timestamp: Date(), origin: .helper, kind: .captureStop, severity: .info, detail: b.asDetail(prefix: "remote")))
        let p = d.makeProvenance(engine: "e", systemFormat: nil, micFormat: nil, micDevice: nil)
        #expect(p.remoteCoverage?.expectedSeconds == 150)
        #expect(p.remoteCoverage?.deliveredSeconds == 100)
        #expect(p.remoteStatus == "compromised")
        #expect(p.systemDeliveredSeconds == 100)   // legacy field derived from coverage
    }
```

Add to `TranscriptionRunnerTests.swift`:
```swift
    /// P8: `dual_stream` is the capture-time flag the writer persisted, not "did a local segment survive".
    @Test func finalizeStampsDualStreamFromTheChunkFlags() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = ProcessedChunk(index: 0, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-0.m4a",
            segments: [.init(start: 0, end: 5, text: "hi", speaker: "Remote Speaker 1", source: "remote")],
            speakerDatabase: ["Remote Speaker 1": [1, 0, 0]], localSpeakerDatabase: [:], isDualStream: true)
        let state = SessionState(sessionId: "m", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluid_audio", chunkDurationMinutes: 10, chunks: [chunk])
        let result = try await TranscriptionRunner().finalize(sessionState: state, outputDirectory: dir, config: .default)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonPath)) as? [String: Any]
        let metadata = json?["metadata"] as? [String: Any]
        #expect(metadata?["dual_stream"] as? Bool == true)
    }
```

Add to `SummaryPromptBuilderTests.swift` and `MeetingSummarizerTests.swift` (red-first: new members):
```swift
    @Test func headerNamesAnUncapturedRemoteSide() {
        let m = SummaryMetadata(sessionName: "s", date: Date(), durationSeconds: 60, speakers: ["Frederic"],
                                dualStream: true, echoSegmentsRemoved: 0,
                                remoteCapture: CaptureSideNote(status: "neverDelivered", deliveredSeconds: 0, expectedSeconds: 2736))
        let msg = SummaryPromptBuilder.userMessage(metadata: m, segments: [])
        #expect(msg.contains("Remote audio: not captured (0 s delivered of 2736 s expected)"))
    }
    // MeetingSummarizerTests:
    @Test func parsesCaptureCoverageFromMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["metadata": ["capture": ["remote": ["status": "neverDelivered", "delivered_seconds": 0.0, "expected_seconds": 2736.0]]], "segments": []]).write(to: url)
        let (_, meta) = try MeetingSummarizer.parseTranscriptForTesting(at: url)
        #expect(meta.remoteCapture?.status == "neverDelivered")
    }
```
(`parseTranscriptForTesting` is an internal `static` wrapper over the private `parseTranscript`.)

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'TrackAccountingTests|CaptureDiagnosticsTests|TranscriptionRunnerTests|SummaryPromptBuilderTests|MeetingSummarizerTests'` → compile errors.

- [ ] **Step 3: Implement the core**

`TranscriberCore/TrackAccounting.swift`:
```swift
import Foundation

/// Per-track coverage (§7.1): what was expected, what arrived, what was fabricated. Kept as plain
/// counters outside the evicting diagnostic ring; emitted at every rotation and at stop.
public struct TrackAccounting: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, idle, neverDelivered, compromised }

    public var expectedSeconds: Double = 0
    public var heartbeatCallbacks: Int = 0
    public var deliveredSeconds: Double = 0
    public var exactZeroSeconds: Double = 0
    public var paddedSeconds: Double = 0
    public var longestGapSeconds: Double = 0
    public var gapCount: Int = 0
    public var rebuilds: Int = 0

    public static let minimumDeficitSeconds: Double = 15
    public static let deficitRatio: Double = 0.10

    public init() {}

    public func status(isTap: Bool, contentAnomalies: Int) -> Status {
        if contentAnomalies > 0 { return .compromised }
        if isTap, expectedSeconds < 1, deliveredSeconds == 0 { return .idle }
        if expectedSeconds >= 5, deliveredSeconds == 0 { return .neverDelivered }
        let deficit = expectedSeconds - deliveredSeconds
        if expectedSeconds > 0, deficit >= Self.minimumDeficitSeconds, deficit / expectedSeconds >= Self.deficitRatio {
            return .compromised
        }
        return .healthy
    }

    public static func += (lhs: inout TrackAccounting, rhs: TrackAccounting) {
        lhs.expectedSeconds += rhs.expectedSeconds
        lhs.heartbeatCallbacks += rhs.heartbeatCallbacks
        lhs.deliveredSeconds += rhs.deliveredSeconds
        lhs.exactZeroSeconds += rhs.exactZeroSeconds
        lhs.paddedSeconds += rhs.paddedSeconds
        lhs.longestGapSeconds = max(lhs.longestGapSeconds, rhs.longestGapSeconds)
        lhs.gapCount += rhs.gapCount
        lhs.rebuilds += rhs.rebuilds
    }

    private static let keys = ["expected_seconds", "heartbeat_callbacks", "delivered_seconds", "exact_zero_seconds",
                               "padded_seconds", "longest_gap_seconds", "gap_count", "rebuilds"]

    public func asDetail(prefix: String) -> [String: String] {
        let values: [String] = [String(format: "%.1f", expectedSeconds), "\(heartbeatCallbacks)", String(format: "%.1f", deliveredSeconds),
                                String(format: "%.1f", exactZeroSeconds), String(format: "%.1f", paddedSeconds),
                                String(format: "%.1f", longestGapSeconds), "\(gapCount)", "\(rebuilds)"]
        return Dictionary(uniqueKeysWithValues: zip(Self.keys.map { "\(prefix)_\($0)" }, values))
    }

    public init?(detail: [String: String], prefix: String) {
        guard let e = detail["\(prefix)_expected_seconds"].flatMap(Double.init) else { return nil }
        expectedSeconds = e
        heartbeatCallbacks = detail["\(prefix)_heartbeat_callbacks"].flatMap(Int.init) ?? 0
        deliveredSeconds = detail["\(prefix)_delivered_seconds"].flatMap(Double.init) ?? 0
        exactZeroSeconds = detail["\(prefix)_exact_zero_seconds"].flatMap(Double.init) ?? 0
        paddedSeconds = detail["\(prefix)_padded_seconds"].flatMap(Double.init) ?? 0
        longestGapSeconds = detail["\(prefix)_longest_gap_seconds"].flatMap(Double.init) ?? 0
        gapCount = detail["\(prefix)_gap_count"].flatMap(Int.init) ?? 0
        rebuilds = detail["\(prefix)_rebuilds"].flatMap(Int.init) ?? 0
    }

    public func asMetadataDictionary(status: Status) -> [String: Any] {
        ["status": status.rawValue, "expected_seconds": expectedSeconds, "delivered_seconds": deliveredSeconds,
         "exact_zero_seconds": exactZeroSeconds, "padded_seconds": paddedSeconds, "longest_gap_seconds": longestGapSeconds,
         "gap_count": gapCount, "rebuilds": rebuilds, "heartbeat_callbacks": heartbeatCallbacks]
    }
}
```

`CaptureDiagnostics.swift`: `CaptureProvenance` gains the four optional fields (init defaults nil, `decodeIfPresent`, `asMetadataDictionary` emits `local_coverage`/`remote_coverage` via `asMetadataDictionary(status:)`). `makeProvenance`: `remoteCoverage = sum(captureStop → TrackAccounting(detail:prefix:"remote"))`, `localCoverage` likewise with `"local"`; `remoteStatus = remoteCoverage?.status(isTap: true, contentAnomalies: qualityEvents.filter { ["system", "system-tap", "tap"].contains($0.detail["track"] ?? $0.detail["source"] ?? "") }.count)`; `localStatus` with `"mic"`; `systemDeliveredSeconds = remoteCoverage.map { Int($0.deliveredSeconds) }`, `systemExactZeroSeconds` likewise (drop `tapTrackSeconds`). Add `.trackCoverage` (info).

`TranscriptAssembler.assemble`: when `provenance?.remoteCoverage` or `localCoverage` is set, `metadata["capture"] = ["local": …, "remote": …]` (each `asMetadataDictionary(status:)` with the stamped status; P3.5 adds `gaps`).

`TranscriptionRunner.finalize`: line 397 → `let isDualStream = sortedChunks.contains(where: \.isDualStream)`.

`SummaryProvider.swift`: `CaptureSideNote` + `SummaryMetadata.remoteCapture/localCapture` (defaulted nil in init). `MeetingSummarizer.parseTranscript`: read `metadata.capture.remote/local` (`status`, `delivered_seconds`, `expected_seconds`) into the notes; add `static func parseTranscriptForTesting(at:) throws -> ([SummarySegment], SummaryMetadata)`. `SummaryPromptBuilder.userMessage`: after `Participants:`, add `captureLine(metadata)` — `"Remote audio: not captured (0 s delivered of 2736 s expected)"` for `neverDelivered`, `"Remote audio: partly captured (…)"` for `compromised`, `"Remote audio: nothing was playing on this Mac (no remote side)"` for `idle`, nothing for `healthy`; same for local with "Your microphone". Append to `systemPrompt` Rules: `- If a "Remote audio"/"Your microphone" line says a side was not captured, state that in the Summary section before anything else`.

- [ ] **Step 4: Helper accumulation**

`AudioOutputHandler`: add `totalSystemPadFrames`, `totalMicPadFrames`, `micExactZeroFrames` (count all-zero batches in `appendAlignedMic`); `func trackTotals() -> (micDelivered: Int64, micPad: Int64, micZero: Int64, sysDelivered: Int64, sysPad: Int64)` (read on `audioQueue` via `audioQueue.sync` from the service, as `tapTrackFacts` did). `var systemExpectedSeconds: (() -> Double)?`; `finalizeAll` line 166: `if !(isUsingSystemTap && (systemExpectedSeconds?() ?? 0) < 1)`.
`SystemTapSession`/`MicCaptureSession`: the heartbeat lock becomes `OSAllocatedUnfairLock<(nanos: UInt64, count: Int)>`; `heartbeatCount()`.
`AudioCaptureService`: `private let coverage = OSAllocatedUnfairLock(initialState: ["mic": TrackAccounting(), "system": TrackAccounting()])`; `livenessWatchdog.onGate = { open, _ in coverage["system"].expectedSeconds += open ? 1 : 0; coverage["mic"].expectedSeconds += 1 }`; `handleLiveness` `.stalled(s)`/`.neverDelivered(s)` → `gapCount += 1; longestGapSeconds = max(…, s)`; `tapHealer.onEvent` `.tapRecoveryRung` → `rebuilds += 1`; `func coverageFacts() -> [String: String]` (on an XPC thread: reads `handler.trackTotals()` via `audioQueue.sync`, `tapGuard.exactZeroFrames`, heartbeat counts, merges into the accounting → `asDetail(prefix: "remote") + asDetail(prefix: "local")`) replaces `tapTrackFacts()` in `stopCapture`/`stopAndFinalize`; `rotateChunk` records `.trackCoverage` with `["chunk": newBaseName] + coverageFacts()`; `snapshot().tracks` = `[TrackHealthSnapshot(track:expected:heartbeatAgeSeconds:generation:)]` from the same data.

- [ ] **Step 5: Run, build, full suite, commit**

```bash
git add -A TranscriberCore AudioCaptureHelper SwiftTests
git commit -m "feat(provenance): per-track coverage + status in provenance and metadata.capture; dual_stream from capture; summary states an uncaptured side (B7/B8, H8, P8, Q4.5, Inv 4)"
```

---

### Task P2.2: `ChunkIssue` — nothing swallowed inside a chunk stays silent

**Files:**
- Modify: `TranscriberCore/ChunkSession.swift` (`ChunkIssue`, `ProcessedChunk.issues`, `SessionState.issues`), `TranscriberCore/ChunkProcessor.swift:96-248, 263-331`, `TranscriberCore/TranscriptionRunner.swift:440-454`, `TranscriberCore/TranscriptAssembler.swift`, `TranscriberCore/CaptureQualityNotice.swift`, `TranscriberCore/RecordingCoordinator.swift:733-778`, `TranscriberCore/StreamLabeling.swift` (returns `absorbed`), `TranscriberCore/DiarizationCleanup.swift` (`absorbMinorityClustersCounting`)
- Test: `SwiftTests/TranscriberTests/ChunkProcessorTests.swift` (add), `ChunkSessionTests.swift` (add decode default), `CaptureQualityNoticeTests.swift` (add), `TranscriptAssemblerTests.swift` (add) — red-first

**Interfaces:**
```swift
public struct ChunkIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case asrFailed = "asr_failed", diarizationFailed = "diarization_failed", vadUnavailable = "vad_unavailable",
             streamEmpty = "stream_empty", archiveFailed = "archive_failed", sessionWriteFailed = "session_write_failed",
             duplicatesDropped = "duplicates_dropped", segmentsFiltered = "segments_filtered",
             clustersAbsorbed = "clusters_absorbed", echoFlagged = "echo_flagged"
    }
    public let code: Code; public let track: String?; public let count: Int?
    public var affectsContent: Bool   // asrFailed, diarizationFailed, streamEmpty, archiveFailed, sessionWriteFailed
}
// ProcessedChunk.issues: [ChunkIssue] (default [])   SessionState.issues: [SessionIssue {chunk: Int, issue: ChunkIssue}]
// TranscriptAssembler.assemble(..., processingIssues: [[String: Any]] = [])
// CaptureQualityNotice.completionTitle(anomalyCount:issueCount:segmentCount:), completionBody(fileName:anomalyCount:issueCount:segmentCount:), issueCount(inTranscriptAt:), segmentCount(inTranscriptAt:)
```

- [ ] **Step 1: Write the failing tests**

`ChunkProcessorTests.swift` additions:
```swift
    struct ThrowingEngine: TranscriptionEngine {
        let name = "Throwing"
        struct Boom: Error {}
        func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw Boom() }
        func isReady() -> Bool { true }
        func prepare() async throws {}
    }

    /// P3: an ASR failure used to become an empty chunk and "Transcription Complete".
    @Test func anAsrFailureIsRecordedAsAChunkIssueAndKeepsTheWav() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sysURL = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sysURL, seconds: 1)
        let processor = ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: ThrowingEngine(), diarizer: FakeDiarizer())
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: 0, systemPath: sysURL.path,
            micPath: dir.appendingPathComponent("meeting-0_mic.wav").path, startTime: Date(timeIntervalSince1970: 0)))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .asrFailed, track: "remote", count: nil)))
        #expect(FileManager.default.fileExists(atPath: sysURL.path), "the WAV of an ASR-failed chunk is kept for re-transcription")
    }

    @Test func anEmptyStreamIsRecordedNotJustLogged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sysURL = dir.appendingPathComponent("meeting-0.wav")
        try RecoveryFixtures.writeFakeWav(at: sysURL, seconds: 0)   // 44-byte header
        let processor = ChunkProcessor(config: .default, outputDirectory: dir,
            sessionState: SessionState(sessionId: "meeting", meetingStart: Date(timeIntervalSince1970: 0), engine: "fluidAudio", chunkDurationMinutes: 10),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: 0, systemPath: sysURL.path,
            micPath: dir.appendingPathComponent("meeting-0_mic.wav").path, startTime: Date(timeIntervalSince1970: 0)))
        let chunk = try #require(await processor.getSessionState().chunks.first)
        #expect(chunk.issues.contains(ChunkIssue(code: .streamEmpty, track: "remote", count: nil)))
    }
```
`ChunkSessionTests.swift`: a `ProcessedChunk` JSON without `issues` decodes with `issues == []`; with `"issues":[{"code":"asr_failed","track":"remote"}]` decodes the issue.
`CaptureQualityNoticeTests.swift`:
```swift
    @Test func processingIssuesGetTheirOwnTitle() {
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, issueCount: 2, segmentCount: 40) == "Transcription Complete — 2 chunks had processing problems")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 0, issueCount: 0, segmentCount: 0) == "Transcription Complete — no speech was transcribed")
        #expect(CaptureQualityNotice.completionTitle(anomalyCount: 1, issueCount: 1, segmentCount: 40) == "Transcription Complete — check the record")
    }
```
`TranscriptAssemblerTests.swift`: `assemble(... processingIssues: [["chunk": 0, "code": "asr_failed", "track": "remote"]])` → `metadata.processing_issues.count == 1`, `metadata.processing_issue_count == 1`.

- [ ] **Step 2: Run to verify they fail** → compile errors (`issues`, `ChunkIssue`, new signatures).

- [ ] **Step 3: Implement**

`ChunkSession.swift`: `ChunkIssue` as above; `ProcessedChunk.issues: [ChunkIssue]` (init default `[]`, `decodeIfPresent ?? []`, CodingKey `issues`); `SessionState.issues: [SessionIssue]` (`SessionIssue: Codable {chunk: Int, issue: ChunkIssue}`, default `[]`).
`ChunkProcessor`: `StreamResult` gains `issues: [ChunkIssue]`; `transcribeStream` records `.streamEmpty` (header-only), `.asrFailed` (catch), `.diarizationFailed` (catch), `.vadUnavailable` (`speechMap == nil` with a diarizer), `.clustersAbsorbed(count)` (from `StreamLabeling.withDiarization` → returns `absorbed: Int`; `DiarizationCleanup.absorbMinorityClustersCounting` returns `(DiarizationResult, Int)` and the old function wraps it); the track is `source` ("remote"/"local"). `processChunkAsync`: `var issues = systemResult.issues + micResult.issues`; echo dedup → `.echoFlagged(count)` when > 0; archive catch → `.archiveFailed`; ASR-failed chunk → archive with `preserveSourceWAV: true` (both WAVs stay next to the m4a); session write catch → `stateStore.noteSessionWriteFailure(chunkIndex)` (appends `SessionIssue(chunk:, issue: .sessionWriteFailed)`), included in the next snapshot. `ProcessedChunk(... issues: issues)`.
`TranscriptionRunner.finalize`: `processingIssues = sortedChunks.flatMap { c in c.issues.map { ["chunk": c.index, "code": $0.code.rawValue, "track": $0.track as Any, "count": $0.count as Any] } } + sessionState.issues.map {…}`; `diarization: diarizer != nil && !processingIssues.contains { $0["code"] as? String == "diarization_failed" }`.
`TranscriptAssembler.assemble(... processingIssues:)` → `metadata["processing_issues"]`, `metadata["processing_issue_count"] = count of content-affecting`.
`CaptureQualityNotice`: new signatures; `issueCount(inTranscriptAt:)` reads `processing_issue_count`; `segmentCount(inTranscriptAt:)` reads `segments.count`. `RecordingCoordinator.presentCompletedTranscription` reads all three off the artifact and passes them.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add -A TranscriberCore SwiftTests
git commit -m "feat(record): ProcessedChunk.issues → metadata.processing_issues; the completion notice names processing problems and empty transcripts; ASR-failed chunks keep their WAV (P3, P7)"
```

---

### Task P2.3: Archiver mirror branch; concatenator that never deletes a lossless source

**Files:**
- Modify: `TranscriberCore/AudioArchiver.swift:61-87`, `TranscriberCore/AudioConcatenator.swift` (whole), `TranscriberCore/TranscriptionRunner.swift:402-429`, `TranscriberCore/TranscriptAssembler.swift` (`merged_audio`)
- Test: `AudioArchiverTests.swift` (add), `AudioConcatenatorTests.swift` (add) — red-first (new error case / new parameter)

**Interfaces:**
```swift
public struct ChunkAudio: Sendable { public let url: URL; public let startTime: Date?; public init(url: URL, startTime: Date?) }
public enum AudioConcatenatorError { … case mixedSources([String]) }
public struct AudioConcatenationResult { outputPath, usedPassthrough, gapsInsertedSeconds: Double }
public static func concatenate(chunks: [ChunkAudio], outputDirectory: URL, outputName: String, deleteSources: Bool) async throws -> AudioConcatenationResult
public static func concatenate(sources: [URL], outputDirectory: URL, outputName: String) async throws -> AudioConcatenationResult   // wraps: startTime nil, deleteSources true
```

- [ ] **Step 1: Write the failing tests**

`AudioArchiverTests.swift`:
```swift
    /// P4 mirror of #183: a mic that delivered zero frames for a whole chunk left a 16 kHz header;
    /// the rate guard refused, the chunk fell back to its WAV, and the concatenator re-encoded the
    /// mono system WAV into BOTH channels (probe: RMS L=0.259 R=0.259) and deleted it.
    @Test func micEmptyHeaderWithSystemAudioArchivesAsSystemOnly() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let sys = dir.appendingPathComponent("m-0.wav"), mic = dir.appendingPathComponent("m-0_mic.wav")
        try Self.createTestWav(at: sys, durationSeconds: 1, sampleRate: 48_000, frequency: 440)
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 0)   // header only, declares 48 kHz/0 frames
        let result = try await AudioArchiver.archive(systemAudio: sys, micAudio: mic, outputDirectory: dir, bitrateKbps: 64)
        #expect(result.archivePath.lastPathComponent == "m-0.m4a")
        let rms = try channelRMS(result.archivePath, from: 0.2, to: 0.8)
        #expect(rms[1] > 0.05 && rms[0] < 0.01, "system audio on the RIGHT channel, left silent")
        #expect(!FileManager.default.fileExists(atPath: mic.path))
        #expect(!FileManager.default.fileExists(atPath: sys.path))
    }
```
(`channelRMS` is a small AVAudioFile helper added to the suite, same as the probe's.)

`AudioConcatenatorTests.swift`:
```swift
    @Test func mixedWavAndM4aSourcesAreRefusedAndNothingIsDeleted() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.wav")
        try await Self.createTestM4a(at: a); try RecoveryFixtures.writeFakeWav(at: b, seconds: 1)
        await #expect(throws: AudioConcatenatorError.self) {
            _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: true)
        }
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func preserveKeepsTheSources() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a); try await Self.createTestM4a(at: b)
        _ = try await AudioConcatenator.concatenate(chunks: [ChunkAudio(url: a, startTime: nil), ChunkAudio(url: b, startTime: nil)], outputDirectory: dir, outputName: "c", deleteSources: false)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    /// P9: a crash restart leaves a gap between chunk 0's end and chunk 1's start; the merged audio
    /// must keep the transcript's wall-clock timeline.
    @Test func gapsBetweenChunksAreFilledWithSilence() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let a = dir.appendingPathComponent("c-0.m4a"), b = dir.appendingPathComponent("c-1.m4a")
        try await Self.createTestM4a(at: a, durationSeconds: 1); try await Self.createTestM4a(at: b, durationSeconds: 1)
        let t0 = Date(timeIntervalSince1970: 0)
        let r = try await AudioConcatenator.concatenate(
            chunks: [ChunkAudio(url: a, startTime: t0), ChunkAudio(url: b, startTime: t0.addingTimeInterval(3))],
            outputDirectory: dir, outputName: "c", deleteSources: true)
        let d = try await AVURLAsset(url: r.outputPath).load(.duration).seconds
        #expect(abs(d - 4) < 0.3)
        #expect(abs(r.gapsInsertedSeconds - 2) < 0.1)
    }
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'AudioArchiverTests|AudioConcatenatorTests'` → compile errors / the archiver throws a rate mismatch.

- [ ] **Step 3: Implement**

`AudioArchiver.archive`: after the existing `sysFile.length == 0, micFile.length > 0` branch add the mirror:
```swift
        if micFile.length == 0, sysFile.length > 0 {
            Logger.files.info("AudioArchiver: mic track is empty — archiving '\(baseName, privacy: .sensitive)' as system-only")
            let result = try await archiveSystemOnly(systemAudio: systemAudio, outputDirectory: outputDirectory,
                                                     bitrateKbps: bitrateKbps, preserveSourceWAV: preserveSourceWAV)
            if !preserveSourceWAV { try? FileManager.default.removeItem(at: micAudio) }
            return result
        }
```
`AudioConcatenator`: new `concatenate(chunks:outputDirectory:outputName:deleteSources:)`: refuse if `Set(chunks.map { $0.url.pathExtension.lowercased() }).count > 1` or any non-`m4a` (`throw .mixedSources(names)`); build the composition inserting `compositionTrack.insertEmptyTimeRange(CMTimeRange(start: insertTime, duration: gap))` when `chunk.startTime - previousEnd > 1 s` (previousEnd = previous startTime + previous duration), summing `gapsInsertedSeconds`; after export, verify `|duration − (Σ durations + gaps)| ≤ 0.25 + 0.05 × chunks.count` else `throw .exportFailed("duration mismatch …")` and keep sources; delete sources only when `deleteSources` and every source is `.m4a`. Keep the `sources:` overload delegating with `startTime: nil, deleteSources: true`.
`TranscriptionRunner.finalize` 410-429: `concatenate(chunks: sortedChunks.map { ChunkAudio(url: outputDirectory.appendingPathComponent($0.audioPath), startTime: $0.startTime) }, …, deleteSources: !(config.preserveSourceWAV ?? false))`; stamp `metadata["merged_audio"] = ["passthrough": r.usedPassthrough, "gaps_inserted_seconds": r.gapsInsertedSeconds]` through a new `mergedAudio:` parameter on `assemble`.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/AudioArchiver.swift TranscriberCore/AudioConcatenator.swift TranscriberCore/TranscriptionRunner.swift TranscriberCore/TranscriptAssembler.swift SwiftTests/TranscriberTests/AudioArchiverTests.swift SwiftTests/TranscriberTests/AudioConcatenatorTests.swift
git commit -m "fix(archive): mic-empty mirror branch; concatenator refuses mixed sources, honours preserve, verifies duration, fills gaps from chunk start times (P4, P9)"
```

---

### Task P2.4: Text dedup only for abutting repeats, counted

**Files:**
- Modify: `TranscriberCore/SpeakerAssignment.swift:70-85`, `TranscriberCore/FluidAudioEngine.swift:123`, `TranscriberCore/SpeechAnalyzerEngine.swift:141`, `TranscriberCore/ChunkProcessor.swift:284-290`, `TranscriberCore/TranscriptionRunner.swift:696`
- Test: `SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift` (change the dedup tests: a repeat 10 s later must SURVIVE — red-first assertion inversion), `EngineTests.swift` (if any test asserts dedup inside an engine, move it here)

- [ ] **Step 1: Write / change the tests**

In `SpeakerAssignmentTests.swift` (find the existing `deduplicate` tests with `grep -n deduplicate`), replace with:
```swift
    /// P2: "Yes." … "Yes." minutes apart are two answers. 20 same-stream repeats 0.6–80 s apart
    /// survived in real transcripts only because the case differed.
    @Test func aRepeatFarApartSurvives() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "Yes."), TranscriptSegment(start: 11, end: 12, text: "Yes.")]
        let r = SpeakerAssignment.deduplicate(segs)
        #expect(r.segments.count == 2 && r.dropped == 0)
    }
    @Test func anAbuttingRepeatIsDroppedAndCounted() {
        let segs = [TranscriptSegment(start: 0, end: 1, text: "Yes."), TranscriptSegment(start: 1.1, end: 2, text: " yes. ")]
        let r = SpeakerAssignment.deduplicate(segs)
        #expect(r.segments.count == 1 && r.dropped == 1)
    }
    @Test func zeroDurationIsStillDropped() {
        let r = SpeakerAssignment.deduplicate([TranscriptSegment(start: 5, end: 5, text: "x")])
        #expect(r.segments.isEmpty && r.dropped == 1)
    }
```

- [ ] **Step 2: Run to verify they fail** → compile error on `.segments`/`.dropped`.

- [ ] **Step 3: Implement**

```swift
    /// Remove zero-duration segments and a repeat that ABUTS the previous segment (a decoder
    /// stutter). A repeat further away is a real repeated answer and is kept (P2).
    public static func deduplicate(_ segments: [TranscriptSegment], maxGapSeconds: Double = 0.25)
        -> (segments: [TranscriptSegment], dropped: Int) {
        var cleaned: [TranscriptSegment] = []
        var dropped = 0
        for seg in segments {
            if seg.start == seg.end { dropped += 1; continue }
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces).lowercased()
            if let prev = cleaned.last,
               prev.text.trimmingCharacters(in: .whitespaces).lowercased() == trimmed,
               seg.start <= prev.end + maxGapSeconds {
                dropped += 1
                continue
            }
            cleaned.append(seg)
        }
        return (cleaned, dropped)
    }
```
Remove the calls from both engines; in `ChunkProcessor.transcribeStream` and `TranscriptionRunner.transcribeStream` call it right after `transcribe(...)` and record `ChunkIssue(code: .duplicatesDropped, track: source, count: dropped)` when > 0.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/SpeakerAssignment.swift TranscriberCore/FluidAudioEngine.swift TranscriberCore/SpeechAnalyzerEngine.swift TranscriberCore/ChunkProcessor.swift TranscriberCore/TranscriptionRunner.swift SwiftTests/TranscriberTests/SpeakerAssignmentTests.swift
git commit -m "fix(asr): dedup drops only abutting repeats; moved out of the engines and counted per chunk (P2)"
```

---

### Task P2.5: Salvage says what it did; Flow B is presented, not silent

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift` (`salvageAbandonedSession` → `SalvageOutcome`; `handleXPCCrash` 596-610, 667-679; `stopRecording` 532-558; `recoverAtLaunch` Flow B chunked), `TranscriberCore/RecoveryMessages.swift` (new, pure text)
- Test: `RecordingCoordinatorTests.swift` (`RecordingCoordinatorSalvageTests`: outcome + message; red-first), `RecoveryMessagesTests.swift` (new)

**Interfaces:**
```swift
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind; public let chunkCount: Int
}
public enum RecoveryMessages {
    public static func recordingFailed(after outcome: SalvageOutcome, lastGoodUntil: Date?) -> String
    public static func stopFailed(after outcome: SalvageOutcome) -> String
    public static func relaunchStopped(at: Date, outcome: SalvageOutcome) -> String
}
```

- [ ] **Step 1: Tests**

`RecoveryMessagesTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// P6: "The portion recorded before the failure has been transcribed" was said even when no
/// transcript existed and finalize had thrown.
@Suite struct RecoveryMessagesTests {
    let url = URL(fileURLWithPath: "/tmp/m.json")
    @Test func writtenTranscriptIsNamed() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3), lastGoodUntil: nil)
        #expect(m.contains("m.json") && m.contains("3 chunks"))
    }
    @Test func nothingWrittenSaysSo() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0), lastGoodUntil: nil)
        #expect(m.contains("No transcript could be written") && !m.contains("has been transcribed"))
    }
    @Test func finalizeFailureKeepsTheAudioAndSaysWhy() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 2), lastGoodUntil: nil)
        #expect(m.contains("disk full") && m.contains("kept on disk"))
    }
}
```
In `RecordingCoordinatorSalvageTests` (existing, line ~983): `salvageEmptySessionTearsDownWithoutTranscript` asserts `outcome.kind == .nothingToSalvage`; `salvageNonEmptySessionStampsProvenanceBeforeFinalizing` asserts `.finalizeFailed` when the fixture's `.m4a` paths do not exist (today it silently `try?`s) — check what the fixture produces at execution time and assert the real outcome.

- [ ] **Step 2: Run to verify they fail** → compile errors.

- [ ] **Step 3: Implement**

`salvageAbandonedSession` returns `SalvageOutcome` (`nothingToSalvage` on empty; `transcriptWritten(url)` on success; `finalizeFailed("\(error.localizedDescription)")` in a real `catch`). `finalizeAbandonedSession` returns it too (or `.nothingToSalvage` when no processor). The three message sites use `RecoveryMessages`. `recoverAtLaunch` Flow B chunked: on a result → `await presentCompletedTranscription(result)` (which posts the completion notice + rename), then `notifyCritical("Recording stopped", RecoveryMessages.relaunchStopped(at: sentinel.startedAt, outcome:))` and `appState.raiseAppAlarm(.recordingStopped, message:)`; on nil → the `nothingToSalvage` message.

- [ ] **Step 4: Run, full suite, commit**

```bash
git add TranscriberCore/RecordingCoordinator.swift TranscriberCore/RecoveryMessages.swift SwiftTests/TranscriberTests/RecordingCoordinatorTests.swift SwiftTests/TranscriberTests/RecoveryMessagesTests.swift
git commit -m "fix(recovery): salvage reports what it wrote; relaunch salvage is presented and says the recording stopped (P6)"
```

---

### Task P2.6: Re-detect that cannot shift the timeline or lose text

**Files:**
- Modify: `TranscriberCore/TranscriptRediarizer.swift:210-310, 360-420`, `TranscriberApp/Views/RenameDialog.swift:250-275`
- Test: `SwiftTests/TranscriberTests/TranscriptRediarizerTests.swift` (add three, red-first)

- [ ] **Step 1: Write the failing tests** (new suite in `TranscriptRediarizerTests.swift`, same fixture style as `TranscriptRediarizerProgressTests.makeMicOnlyRecording`)

```swift
@Suite(.serialized)
struct TranscriptRediarizerTimelineTests {
    /// Counts the samples the diarizer received, so timeline padding is observable.
    final class CountingDiarizer: DiarizationProvider, @unchecked Sendable {
        private(set) var samplesSeen = 0
        func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
            try await FakeDiarizer().diarize(audioPath: audioPath, numSpeakers: numSpeakers)
        }
        func diarize(audio: [Float], numSpeakers: Int?, progress: (@Sendable (Int, Int) -> Void)?) async throws -> DiarizationResult {
            samplesSeen = audio.count
            return try await FakeDiarizer().diarize(audio: audio, numSpeakers: numSpeakers, progress: progress)
        }
    }

    private func writeSilentWav(at url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Chunk 0 = mic-only WAV (`.skip` for the remote channel, 10 s); chunk 1 = system-only WAV (1 s).
    private func makeTwoChunkRecording(withDurations: Bool = true) throws -> (transcript: URL, chunk1: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rediar-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic0 = dir.appendingPathComponent("call-0_mic.wav"), sys1 = dir.appendingPathComponent("call-1.wav")
        try writeSilentWav(at: mic0, seconds: 10); try writeSilentWav(at: sys1, seconds: 1)
        var metadata: [String: Any] = ["audio_paths": [mic0.path, sys1.path]]
        if withDurations { metadata["chunk_durations"] = [10.0, 1.0] }
        let transcript = dir.appendingPathComponent("t.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": metadata,
            "segments": [["start": 10.2, "end": 10.8, "text": "hi", "speaker": "Remote Speaker 1", "source": "remote"]],
        ]).write(to: transcript)
        return (transcript, sys1, { try? FileManager.default.removeItem(at: dir) })
    }

    /// P5: a `.skip` chunk contributed nothing and every later chunk's timeline shifted by its length.
    @Test func skipChunksArePaddedWithTheirDuration() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let d = CountingDiarizer()
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: d)
        #expect(d.samplesSeen == 11 * 16_000)
    }

    @Test func aSkipChunkWithUnknownDurationIsRefused() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(withDurations: false); defer { cleanup() }
        await #expect(throws: TranscriptRediarizer.RediarizeError.self) {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        }
    }

    @Test func aMissingListedChunkIsRefused() async throws {
        let (t, chunk1, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        try FileManager.default.removeItem(at: chunk1)
        do {
            _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
            Issue.record("expected chunkMissing")
        } catch TranscriptRediarizer.RediarizeError.chunkMissing(let name) {
            #expect(name == "call-1.wav")
        }
    }

    @Test func aBackupIsWrittenBeforeOverwriting() async throws {
        let (t, _, cleanup) = try makeTwoChunkRecording(); defer { cleanup() }
        let before = try Data(contentsOf: t)
        _ = try await TranscriptRediarizer.rediarize(transcript: t, source: "remote", speakerCount: 1, diarizer: FakeDiarizer())
        let backup = t.deletingPathExtension().appendingPathExtension("rediarize-backup.json")
        #expect(try Data(contentsOf: backup) == before)
        #expect(try Data(contentsOf: t) != before)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `$PARLEY_TEST --filter 'TranscriptRediarizerTimelineTests'` → compile error on `chunkMissing`; the padding test would see 16 000 samples.

- [ ] **Step 3: Implement**

`RediarizeError` gains `chunkMissing(String)` ("Chunk <name> is missing — re-detect cannot rebuild the timeline without it.") and `chunkDurationUnknown(String)`. `decodeChannelAudio`: if `existing.count != chunks.count` → `throw .chunkMissing(<first missing lastPathComponent>)`; `.skip` → `combined.append(contentsOf: [Float](repeating: 0, count: Int(duration * 16_000)))` where `duration = chunkDurations[index]` read from `metadata.chunk_durations` (threaded in as a new parameter), else `throw .chunkDurationUnknown(name)`; drop the VAD analysis (`speechMap = nil` in both branches: the segments already passed the gate once); before the final write, copy the transcript to `url.deletingPathExtension().appendingPathExtension("rediarize-backup.json")` (overwrite). `RenameDialog.rediarize`: keep the `Outcome` and show `"\(outcome.speakerCount) speaker(s) found · \(outcome.segmentsRelabeled) lines relabeled"` under the stepper.

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add TranscriberCore/TranscriptRediarizer.swift TranscriberApp/Views/RenameDialog.swift SwiftTests/TranscriberTests/TranscriptRediarizerTests.swift
git commit -m "fix(rediarize): refuse missing chunks, pad skipped ones, no second VAD pass, backup before overwrite, outcome shown (P5)"
```

---

### Task P2.7: Small honesty fixes — session id, quota placement, summary truncation, absorption hint

**Files:**
- Modify: `TranscriberCore/ChunkSession.swift:181-193` (`read(directory:sessionId:)`), `TranscriberCore/CrashRecoveryPlanner.swift:28-33, 41-46`, `TranscriberCore/ChunkedSessionRecovery.swift:12`, `TranscriberCore/ChunkProcessor.swift:202-221` (quota after the catch), `TranscriberCore/SummaryProvider.swift` (`SummaryResponse`, `summarizeDetailed` with a default), `TranscriberCore/OpenAISummaryProvider.swift:205-215` (`finish_reason == "length"`), `TranscriberCore/LMStudioSummaryProvider.swift:91-97`, `TranscriberCore/MeetingSummarizer.swift:22-47` (banner), `TranscriberApp/Views/RenameDialog.swift` (hint when `clusters_absorbed` present)
- Test: `ChunkSessionTests.swift` (mismatch → nil), `OpenAISummaryProviderTests.swift` (`finish_reason: length` → `truncated`), `MeetingSummarizerTests.swift` (banner prepended) — red-first

- [ ] **Step 1: Tests** — `SessionState.read(directory: dir, sessionId: "other")` returns nil for a file with `sessionId: "m"`; a provider response with `"finish_reason":"length"` yields `SummaryResponse.truncated == true`; `MeetingSummarizer.summarize` with a fake provider returning `truncated: true` writes a `.md` whose first line starts with `> ⚠️ This summary may be incomplete`.
- [ ] **Step 2: Implement** — as listed. `read(directory:)` stays (legacy), the recovery callers pass the id. Quota: move `StorageManager.enforceQuota` into its own `do/catch` after the archive block (log only; the scope is unchanged, §11.3). `SummaryProvider`: `public struct SummaryResponse { let markdown: String; let truncated: Bool }`, `func summarizeDetailed(...) async throws -> SummaryResponse` with a protocol extension default `SummaryResponse(markdown: try await summarize(...), truncated: false)`; both providers implement it; `MeetingSummarizer.summarize` calls it and prepends `"> ⚠️ This summary may be incomplete: the model reached its output limit.\n\n"` when truncated. RenameDialog: read `metadata.processing_issues` for `clusters_absorbed` and show "1 quiet voice was merged into the main speaker — set a count and Re-detect to undo".
- [ ] **Step 3: Run, build, full suite, commit**

```bash
git add -A TranscriberCore TranscriberApp/Views/RenameDialog.swift SwiftTests
git commit -m "fix(record): session id check on read, quota outside the archive catch, truncated-summary banner, absorption hint (P7, P12, P13, P14)"
```

---

### Task P2.8 (deferrable): Filters keep the text — `filtered` and `echo` flags instead of deletion

**Files:**
- Modify: `TranscriberCore/SpeakerAssignment.swift:42-60, 642-668`, `TranscriberCore/EchoDeduplicator.swift:145-172`, `TranscriberCore/ChunkSession.swift` (`Segment.filtered/echo`), `TranscriberCore/ChunkProcessor.swift:139-164`, `TranscriberCore/TranscriptMerger.swift`, `TranscriberCore/TranscriptAssembler.swift`, `TranscriberCore/TranscriptWriter.swift:23-56`, `TranscriberCore/MeetingSummarizer.swift:186-194`, `TranscriberCore/TranscriptRenamer.swift` (skip flagged samples)
- Test: `SpeakerAssignmentVadTests.swift`, `EchoDeduplicatorTests.swift` (assertions change from "removed" to "flagged": red-first), `TranscriptWriterTests.swift` (flagged lines hidden in TXT/SRT), `MeetingSummarizerTests.swift` (flagged excluded)

- [ ] **Step 1: Tests** — in `EchoDeduplicatorTests`, every `#expect(result.segments.count == N)` for a removal becomes `#expect(result.segments.filter { !$0.echo }.count == N)` plus `#expect(result.flaggedCount == k)`; in `SpeakerAssignmentVadTests`, the "filtered" case asserts the segment is present with `filtered == true` and `speaker == "Unknown"`; `TranscriptWriterTests`: a JSON with a `"filtered": true` segment renders no line for it; `MeetingSummarizerTests`: `parseTranscript` drops `echo`/`filtered` segments.
- [ ] **Step 2: Implement** — `LabeledSegment.filtered = false, echo = false`; `SpeakerAssignment.assign` keeps the `!shouldInclude` segment with `filtered: true, speaker: unknownSpeaker`; `EchoDeduplicator.deduplicate` returns every input with `echo: true` on matches, `DeduplicationResult.flaggedCount` (keep `removedCount` as a deprecated alias returning the same number for one release); `ProcessedChunk.Segment` + `MergedSegment` carry both flags (Codable default false); `TranscriptAssembler` writes `"filtered": true` / `"echo": true` only when set; `TranscriptWriter.formatTXT/SRT` skip flagged; `MeetingSummarizer.parseTranscript` skips flagged; `TranscriptRenamer` sample collection skips flagged; `ChunkProcessor` records `.segmentsFiltered(count)` and `.echoFlagged(count)`; metadata key `echo_segments_removed` keeps its value (count of flagged) for readers.
- [ ] **Step 3: Run, full suite, commit** — `git commit -m "feat(record): VAD/quality gate and echo dedup flag segments instead of deleting them; TXT/SRT/summary hide them (P10, P11)"`

---

### Task P2.9: Engine preflight and honest labels (the default flip is the owner's, §11.2)

**Files:**
- Create: `TranscriberCore/EnginePreflight.swift`
- Modify: `TranscriberCore/EngineID.swift:38-62` (`isUsableEndToEnd`, label), `TranscriberApp/Views/SetupView.swift:243-300, 326-380` (`Continue` runs the preflight), `TranscriberApp/Views/SettingsView.swift:320-340, 530-545` (Save runs it)
- Test: `EngineIDTests.swift` (add), `EnginePreflightTests.swift` (new) — red-first

- [ ] **Step 1: Tests**
```swift
    // EngineIDTests
    @Test func speechAnalyzerIsNotUsableEndToEndUntilALanguageSettingExists() {
        #expect(EngineID.speechAnalyzer.descriptor.isUsableEndToEnd == false)
        #expect(EngineID.fluidAudio.descriptor.isUsableEndToEnd)
        #expect(EngineID.speechAnalyzer.descriptor.displayName.contains("not yet usable"))
        #expect(!EngineID.usableEngines.contains(.speechAnalyzer))
    }
    // EnginePreflightTests
    @Test func aThrowingEngineFailsPreflight() async {
        await #expect(throws: (any Error).self) { try await EnginePreflight.run(engine: ThrowingEngine()) }
    }
    @Test func aWorkingEnginePassesOnASyntheticSecond() async throws {
        try await EnginePreflight.run(engine: FakeEngine())
    }
```
- [ ] **Step 2: Implement** — `EngineDescriptor.isUsableEndToEnd: Bool` (SA false with the reason in `description`: "needs a language setting — not yet usable (#147)"); `EngineID.usableEngines = availableEngines.filter(\.descriptor.isUsableEndToEnd)`; Setup/Settings pickers list `usableEngines`; `EnginePreflight.run(engine:)` writes a 1 s 16 kHz sine WAV to a temp file (`RecoveryFixtures`-style writer moved into Core as `SyntheticWAV.write(to:seconds:)`), calls `transcribe(audioPath:language:nil,audioSource:.system)` and rethrows; Setup Continue and Settings Save call it on the selected engine and show an alert "This engine cannot transcribe on this Mac: <error>" and refuse. `EngineID.default` unchanged — add `// OWNER DECISION (§11.2): flip to .fluidAudio once approved`.
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "feat(engine): preflight the chosen engine at Setup/Save; SpeechAnalyzer labelled not yet usable (P1 mitigation; default flip is the owner's)"`

---

### P2 checkpoint

- [ ] Full suite green; build clean; council over the P2 diff (lens: any path that still deletes a lossless source; every `try?` in ChunkProcessor/TranscriptionRunner accounted for as an issue; metadata keys documented).
- [ ] CI green.
- [ ] Device (P4.1): D-20 (a real 2-chunk call → `metadata.capture`, `processing_issues: []`, `dual_stream`), D-21 (mic-empty chunk archives system-only, merged L/R correct), D-22 (re-detect on a recording with a `.skip` chunk keeps the timeline), D-23 (summary header on the 09-24 incident JSON re-summarised).

---

# Phase 3 — lifecycle hardening

### Task P3.1: Honest relaunch — `RelaunchDecision`, sentinel liveness, stale-by-boot-session

**Files:**
- Create: `TranscriberCore/RelaunchDecision.swift`, `TranscriberCore/BootSession.swift`
- Modify: `TranscriberCore/RecordingSentinel.swift` (`lastAliveAt`, `bootSessionUUID`; tolerant decode), `TranscriberCore/RecordingCoordinator.swift` (`recoverAtLaunch` decisions; alive timer; `resumeSession(from:)`), `TranscriberCore/CaptureDiagnostics.swift` (`.captureGap` anomaly), `TranscriberCore/CrashRecoveryPlanner.swift` (unchanged API, used)
- Test: `RelaunchDecisionTests.swift` (new), `RecordingSentinelTests.swift` (add), `RecordingCoordinatorTests.swift` (add `recoverAtLaunch` cases) — red-first

**Interfaces:**
```swift
public enum BootSession { public static func currentUUID() -> String? }   // sysctl kern.bootsessionuuid
// RecordingSentinel: + lastAliveAt: Date?, bootSessionUUID: String?
public enum RelaunchDecision: Equatable, Sendable {
    case reattach                                   // helper still capturing
    case resumeSameSession(gapStart: Date)          // helper dead, sentinel fresh (< resumeWindow)
    case salvageAndStop(reason: Reason)             // helper dead, sentinel old
    case salvageStale                               // from a previous boot session
    case waitForFolder                              // recording folder unreachable
    public enum Reason: Equatable, Sendable { case tooOld(seconds: TimeInterval), noLiveness }
    public static let resumeWindow: TimeInterval    // 180
    public static func decide(sentinel: RecordingSentinel, now: Date, helperCapturing: Bool,
                              currentBootSessionUUID: String?, folderReachable: Bool) -> RelaunchDecision
}
// RecordingCoordinator: var aliveRefreshInterval: Duration (default 60 s); func refreshSentinelLiveness(now:)
```

- [ ] **Step 1: Tests**

`RelaunchDecisionTests.swift`:
```swift
import Foundation
import Testing
@testable import TranscriberCore

/// L1/L3 (§8.3): an app crash mid-meeting used to end the recording silently (the helper stops
/// on disconnect; Flow B salvaged and showed a rename dialog). A stale-sentinel check based on
/// `systemUptime` judged 7.2 h of sleep as "before the last boot".
@Suite struct RelaunchDecisionTests {
    let now = Date(timeIntervalSince1970: 10_000)
    func sentinel(alive: TimeInterval?, boot: String? = "B1") -> RecordingSentinel {
        var s = RecordingSentinel(startedAt: now.addingTimeInterval(-3600), sessionName: "s", systemAudioPath: "/r/2026/s-0.wav", micAudioPath: "/r/2026/s-0_mic.wav")
        s.lastAliveAt = alive.map { now.addingTimeInterval(-$0) }
        s.bootSessionUUID = boot
        return s
    }

    @Test func helperStillCapturingReattaches() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: 30), now: now, helperCapturing: true, currentBootSessionUUID: "B1", folderReachable: true) == .reattach)
    }
    @Test func freshSentinelAndDeadHelperResumesTheSameSession() {
        let s = sentinel(alive: 30)
        #expect(RelaunchDecision.decide(sentinel: s, now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: true) == .resumeSameSession(gapStart: s.lastAliveAt!))
    }
    @Test func oldSentinelSalvagesAndStops() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: 600), now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: true) == .salvageAndStop(reason: .tooOld(seconds: 600)))
    }
    @Test func aSentinelWithoutLivenessSalvages() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: nil), now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: true) == .salvageAndStop(reason: .noLiveness))
    }
    @Test func aDifferentBootSessionIsStaleEvenIfRecent() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: 30, boot: "B0"), now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: true) == .salvageStale)
    }
    @Test func unreachableFolderWaitsAndNeverDeletes() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: 30), now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: false) == .waitForFolder)
    }
    @Test func unknownBootSessionIsNotStale() {
        #expect(RelaunchDecision.decide(sentinel: sentinel(alive: 30, boot: nil), now: now, helperCapturing: false, currentBootSessionUUID: "B1", folderReachable: true) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
    }
}
```
`RecordingSentinelTests`: round trip of the two new fields; a JSON without them decodes with nil. `BootSession.currentUUID()` returns a non-empty string on this machine.
`RecordingCoordinatorTests` (new suite `RecordingCoordinatorRelaunchTests`, using the harness with `engineFactory: { _ in (FakeEngine(), FakeDiarizer()) }`):
- fresh sentinel + `client.statusSnapshot = nil` + `isCapturing` false → after `recoverAtLaunch()`: `client.startCalls.count == 1` with baseName `sess-1`, `appState.isRecording`, `appState.activeAlarms[.recordingResumedWithGap] != nil`, `criticals` contains "Parley crashed at" and "resumed at", `client.retryEvents` contains a `launchRecovery` (via a new `recordLaunchRecovery` on the protocol — add it: `func recordLaunchRecovery(_ detail: [String: String])`).
- old sentinel → no start, `appState.isIdle`, alarm `.recordingStopped`, sentinel deleted only AFTER the salvage ran (`finalizeCalls.count == 1`).
- `refreshSentinelLiveness(now:)` rewrites `lastAliveAt`.

- [ ] **Step 2: Run to verify they fail** → compile errors.

- [ ] **Step 3: Implement**

`BootSession.swift`: `sysctlbyname("kern.bootsessionuuid", …)` → String (nil on failure).
`RecordingSentinel`: two optional fields, `decodeIfPresent`, written by `startRecording` (`bootSessionUUID: BootSession.currentUUID(), lastAliveAt: Date()`).
`RelaunchDecision.decide`: `helperCapturing → .reattach`; `!folderReachable → .waitForFolder`; `sentinel.bootSessionUUID != nil && current != nil && differ → .salvageStale`; `lastAliveAt == nil → .salvageAndStop(.noLiveness)`; `now − lastAliveAt ≤ 180 → .resumeSameSession(gapStart: lastAliveAt)`; else `.salvageAndStop(.tooOld(seconds:))`.
`RecordingCoordinator.recoverAtLaunch`: replace the `systemUptime` block and the Flow A/B branches with `switch RelaunchDecision.decide(...)`:
- `.reattach` → existing Flow A + `startStatusPoll()` + alive timer.
- `.resumeSameSession(gapStart)` → `let plan = CrashRecoveryPlanner.planRestart(sentinel:outputDirectory:)`; `try await captureClient.start(...)` with the plan's base name; write `plan.newSentinel` (with fresh `lastAliveAt`/boot uuid); `transcriptionRunner.setupChunkedPipeline(... seededState: SessionState.read(directory:sessionId:))` (new optional parameter that seeds `ChunkProcessor` with the persisted state) and `startChunkRotation()`; re-ingest orphans via `CrashRecoveryPlanner.orphanChunks` → `processor.processChunk(...)`; `appState.phase = .recording(since: sentinel.startedAt)`; record `.launchRecovery` + `.captureGap ["start": gapStart, "end": now, "reason": "app relaunch"]`; `appState.raiseAppAlarm(.recordingResumedWithGap, message: "Parley crashed at \(hh:mm:ss) and resumed at \(hh:mm:ss) — \(Int(gap)) s not recorded.")` + `notifyCritical`; `awaitingRecoveryFrames = true`; wire callbacks; start the poll and the alive timer. On `start` failure → `.salvageAndStop(.noLiveness)` path.
- `.salvageAndStop(reason)` / `.salvageStale` → existing chunked salvage (P2.5's presentation) + `recordingStopped` alarm; delete the sentinel after salvage.
- `.waitForFolder` → `raiseAppAlarm(.recordingFolderUnavailable, …)`, leave the sentinel, retry `recoverAtLaunch` every 30 s.
Alive timer: while recording, every `aliveRefreshInterval` call `refreshSentinelLiveness(now:)` (reads, sets `lastAliveAt`, writes). Also at every rotation (`ChunkRotator.onChunkFinalized` → coordinator hook).
Event kind `.captureGap` (anomaly, in `qualityCompromising`).

- [ ] **Step 4: Run, build, full suite, commit**

```bash
git add -A TranscriberCore SwiftTests
git commit -m "feat(relaunch): resume the same session after an app crash, honest STOPPED otherwise, boot-session stale check, never delete before salvage (L1, L3)"
```

---

### Task P3.2: Stop vs crash, orphan dedup, double start, post-start failure

**Files:**
- Modify: `TranscriberCore/RecordingCoordinator.swift:184-309, 411-559, 564-680`, `TranscriberCore/ChunkProcessor.swift:63-79` (ignore an index already present/in flight), `TranscriberApp/Views/MenuView.swift:306-327` (disable Record while `startInFlight`)
- Test: `RecordingCoordinatorTests.swift` (add), `ChunkProcessorTests.swift` (add) — red-first

- [ ] **Step 1: Tests**
```swift
    // RecordingCoordinatorTests
    @Test func aCrashDuringStopIsIgnoredByTheCrashHandler() async throws {
        let h = try Harness(); _ = try h.writeSentinel(); h.appState.phase = .recording(since: Date())
        h.client.stopError = FakeCaptureError()
        h.client.onStop = { await h.coordinator.handleXPCCrash() }   // the trailing invalidation lands mid-stop
        await h.coordinator.stopRecording()
        #expect(h.client.startCalls.isEmpty, "the stop path owns the teardown; no restart")
        #expect(h.appState.isIdle)
    }
    @Test func aSecondStartWhileOneIsInFlightIsIgnored() async throws {
        let h = try Harness()
        h.client.onStart = { Task { await h.coordinator.startRecording(sessionName: "b", microphoneDeviceId: nil) } }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.client.startCalls.count == 1)
        #expect(RecordingSentinel.read(directory: h.tmp)?.sessionName == "a")
    }
    @Test func aFailureAfterAStartedHelperStopsTheHelper() async throws {
        let h = try Harness()
        h.runner.failSetupForTesting = true   // new test seam: setupChunkedPipeline throws
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.stopCalls == 1)
        #expect(h.appState.isIdle)
    }
    // ChunkProcessorTests
    @Test func processingTheSameChunkIndexTwiceAppendsOnce() async throws { /* processLastChunk(index 0) twice → state.chunks.count == 1 */ }
```

- [ ] **Step 2: Implement** — `handleXPCCrash`: `guard !stopInFlight else { Logger…; return }` at the top and `guard appState.isRecording, !stopInFlight` after every `await`; `stopRecording` catch: `finalizeAbandonedSession(sentinel:, reingestOrphan: true)`; `RecoveryMessages.stopFailed(after:)` for the message. `ChunkProcessor.processChunk`/`processLastChunk`: skip when `stateStore` already holds the index or `inFlightIndices` contains it. `startInFlight` flag set at the top of `startRecording`, cleared in a `defer`; `guard appState.isIdle, !startInFlight`; `public var isStartInFlight`. Post-start failure: in `startRecording`'s catch, if `captureStarted` (set true after `start()` returned) → `try? await withDeadline(20 s) { captureClient.stop() }` before reporting; `clearHelperMic()` only after that. `TranscriptionRunner.failSetupForTesting` internal Bool.
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "fix(lifecycle): crash handler yields to a stop in flight, orphan re-ingested once, double start ignored, post-start failure stops the helper (L6, L7, L8)"`

---

### Task P3.3: Disk — check before start and at every rotation; rotation failures become alarms

**Files:**
- Create: `TranscriberCore/DiskSpaceCheck.swift`
- Modify: `TranscriberCore/RecordingCoordinator.swift` (start refusal; rotation hook), `TranscriberCore/ChunkRotator.swift:93-120` (`onRotationFailed`), `TranscriberCore/ChunkProcessor.swift` (session write failure → coordinator alarm via `onIssue` closure), `TranscriberCore/CaptureDiagnostics.swift` (`.rotationFailed`, `.sessionWriteFailed`, `.diskLow`)
- Test: `DiskSpaceCheckTests.swift` (new), `RecordingCoordinatorTests.swift` (refuses to start when the fake reports no space), `ChunkRotatorTests.swift` (a throwing client invokes `onRotationFailed`) — red-first

- [ ] **Step 1: Tests**
```swift
@Suite struct DiskSpaceCheckTests {
    @Test func bytesPerChunkIsTwoTracksAt96KBps() {
        #expect(DiskSpaceCheck.bytesPerChunk(chunkMinutes: 10) == 10 * 60 * 2 * 96_000)
    }
    @Test func startNeedsTwoChunksPlusHeadroom() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.canStart(freeBytes: 2 * one + 200_000_000, chunkMinutes: 30))
        #expect(!DiskSpaceCheck.canStart(freeBytes: 2 * one + 199_000_000, chunkMinutes: 30))
    }
    @Test func rotationWarnsBelowOneChunk() {
        let one = DiskSpaceCheck.bytesPerChunk(chunkMinutes: 30)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: one - 1, chunkMinutes: 30) == .low)
        #expect(DiskSpaceCheck.rotationVerdict(freeBytes: 2 * one, chunkMinutes: 30) == .ok)
    }
}
```
- [ ] **Step 2: Implement** — `DiskSpaceCheck { static func bytesPerChunk(chunkMinutes:) -> Int; static let headroomBytes = 200_000_000; static func canStart(freeBytes:chunkMinutes:) -> Bool; enum RotationVerdict { case ok, low }; static func rotationVerdict(freeBytes:chunkMinutes:) -> RotationVerdict; static func freeBytes(at: URL) -> Int? }` (`volumeAvailableCapacityForImportantUsage`). Coordinator: before `start()`, `guard DiskSpaceCheck.canStart(...)` else `notify("Recording not started", "Only N MB free — Parley needs at least M MB for a \(chunk)-minute chunk.")` and return; `ChunkRotator` gains `onChunkFinalized` companion `onRotationFailed: (Error) -> Void` and, before rotating, calls an injected `freeBytes` check → coordinator raises/clears `.diskLow`; rotation failure → `raiseAppAlarm(.rotationFailed, …)` + `.rotationFailed` event; if the error message contains `"No capture in progress"` → `handleXPCCrash()` (the capture is dead). `ChunkProcessor.onSessionWriteFailure: ((Int) -> Void)?` (new) → coordinator `raiseAppAlarm(.sessionWriteFailed, message: "Parley could not save its progress file — if it is interrupted now, the last chunk may not be recovered.")` (the kind exists since P0.4, app-owned, track nil) and records `.sessionWriteFailed`.
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "fix(disk): free-space check before start and at rotation; rotation and session-write failures are alarms, a dead capture on rotate is a crash (L10)"`

---

### Task P3.4: Deadlines on every helper call; sentinel outlives finalize

**Files:**
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:206-310, 351-373` (a `withDeadline` helper around every continuation), `TranscriberCore/RecordingCoordinator.swift:427-465` (sentinel deleted after `finalize`/salvage)
- Test: `RecordingCoordinatorTests.swift` (`stopKeepsTheSentinelUntilTheTranscriptExists` — red-first)

- [ ] **Step 1: Test** — with a fake `stopResult` and a runner whose `finalize` is slow (`onStop` cannot express it; add `runner.finalizeDelayForTesting`), assert `RecordingSentinel.read(directory: h.tmp) != nil` while `stopRecording()` is suspended and nil afterwards.
- [ ] **Step 2: Implement** — `AudioCaptureClient.withDeadline(_ seconds: Double, _ body: (ResumeOnce<Result>) -> Void)` used by `start` (15 s), `stop` (20 s), `rotateChunk` (10 s), `updateMicrophone` (10 s), `drainHelperDiagnostics` (3 s), `pingStatus` (3 s), `captureStatus` (3 s); a deadline hit throws `CaptureError.timedOut(call)` (new case) and records `.helperUnresponsive`-worthy anomaly `xpcTimeout` (new kind). Coordinator: move `RecordingSentinel.delete` from line 431 to after `presentCompletedTranscription` (and after salvage in the error paths).
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "fix(xpc): deadlines on every helper call; the sentinel is deleted only once the transcript exists (L13, #194, #195)"`

---

### Task P3.5: Sleep, wake, logout, quit-while-recording; gaps in the record

**Files:**
- Create: `TranscriberApp/Services/SystemEventObserver.swift`
- Modify: `TranscriberCore/RecordingCoordinator.swift` (`systemWillSleep/didWake/sessionResigned/willPowerOff`; idle-sleep assertion; wake rotation), `AudioCaptureProtocol/AudioCaptureProtocol.swift` (`systemPowerEvent(kind:reply:)`), `AudioCaptureHelper/XPC/AudioCaptureService.swift` (pause/re-arm monitors, heal on wake), `TranscriberCore/CaptureDiagnostics.swift` (`.systemSleep`, `.systemWake` info), `TranscriberCore/TranscriptAssembler.swift` (`metadata.capture.gaps`), `TranscriberApp/Views/MenuView.swift:17-31` (Quit while recording: confirm + bounded stop)
- Test: `RecordingCoordinatorTests.swift` (`sleepAndWakeAreRecordedAsAGapAndForceARotation`; `quitWhileRecordingStopsFirst` via an injected `confirmQuit` closure) — red-first

- [ ] **Step 1: Tests** — after `systemWillSleep(at: t0)` and `systemDidWake(at: t0 + 120)`: `client.retryEvents` is untouched, the app ring (spy through `finalizeSessionDiagnostics` calls is not enough — add `FakeCaptureClient.recordedEvents` via a new protocol method `record(_ kind: CaptureEventKind, _ severity:, _ detail:)`) contains `.systemSleep` and `.systemWake`, and `rotateNowForTesting` was requested; `metadata.capture.gaps` in a finalized transcript lists `{start, end, seconds: 120, reason: "sleep"}`.
- [ ] **Step 2: Implement** — `SystemEventObserver` (app): `NSWorkspace.shared.notificationCenter` observers for `willSleepNotification`, `didWakeNotification`, `sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification`, `willPowerOffNotification` → coordinator methods. Coordinator: `systemWillSleep` records `.systemSleep`, pauses the poll, calls `captureClient.systemPowerEvent("sleep")`; `systemDidWake` records `.systemWake` with the interval, appends to `captureGaps`, calls `systemPowerEvent("wake")`, forces `transcriptionRunner.chunkRotator?.rotateNow()` (new public method), resets `awaitingRecoveryFrames = true` so "Resumed" waits for frames; `willPowerOff` → bounded `stopRecording()`; `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Recording")` held from `.recording` to idle. Helper `systemPowerEvent`: `"sleep"` → `livenessWatchdog.pause()`; `"wake"` → `livenessWatchdog.arm("mic"); arm("system"); tapHealer.trigger(.wake); micSession.heal()`. `finalize` passes `sessionState.gaps` (persisted in `SessionState.gaps: [CaptureGap]`, written on wake) into `assemble(... captureGaps:)`. Quit: `quitAfterUninstallingLaunchAgent()` gains `if coordinator.appState.isRecording { confirm → await coordinator.stopRecording() (bounded 30 s) }`.
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "feat(lifecycle): sleep/wake/logout observed, recorded as gaps, monitors re-armed on wake; quit while recording stops first (L12)"`

---

### Task P3.6: Evidence survives restarts; counters outside the ring; monotonic chunk clock

**Files:**
- Create: `TranscriberCore/LiveDiagnosticsLog.swift`, `TranscriberCore/MonotonicWallClock.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift:206-218` (`start(sessionId:)` clears only on a new id; drains the helper first), `TranscriberCore/RecordingCaptureClient.swift`, `TranscriberCore/CaptureDiagnostics.swift` (`retryCount`/`launchRecoveries`/`eventsDropped` counters; provenance `events_dropped`), `TranscriberCore/ChunkRotator.swift:101-115` (`MonotonicWallClock`), `TranscriberCore/RecordingCoordinator.swift` (live log wiring)
- Test: `LiveDiagnosticsLogTests.swift` (new), `CaptureDiagnosticsTests.swift` (counters survive `clear()`; `events_dropped`), `MonotonicWallClockTests.swift` (new), `RecordingCoordinatorTests.swift` (a restart within a session keeps the retry event) — red-first

- [ ] **Step 1: Tests**
```swift
@Suite struct LiveDiagnosticsLogTests {
    @Test func appendsAnomaliesAsTheyHappenAndMergesWithoutDuplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = LiveDiagnosticsLog(directory: dir, sessionId: "s")
        let e = CaptureEvent(timestamp: Date(timeIntervalSince1970: 1), origin: .app, kind: .retry, severity: .warning, detail: ["attempt": "1"])
        log.append(e)
        var ring = CaptureDiagnostics(); ring.record(e)
        let merged = log.merged(into: ring)
        #expect(merged.events.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("s.diag.live.jsonl").path))
    }
}
@Suite struct MonotonicWallClockTests {
    @Test func advancesWithTheMonotonicClockNotTheWallClock() {
        let c = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: .init(secondsSinceEpoch: 100))
        #expect(c.now(monotonic: .init(secondsSinceEpoch: 160)) == Date(timeIntervalSince1970: 60))
    }
}
// CaptureDiagnosticsTests
@Test func countersSurviveEvictionAndClear() { var d = CaptureDiagnostics(maxEvents: 2); record 3 retries; #expect(d.retryCount == 3); d.clear(); #expect(d.retryCount == 3) }
```
- [ ] **Step 2: Implement** — `LiveDiagnosticsLog` (append JSONL line per `.anomaly`/`.warning` event; `merged(into:)` dedupes by `(timestamp, origin, kind, detail)`; `delete()`). `CaptureDiagnostics`: `retryCount`, `launchRecoveries`, `eventsDropped` as stored counters incremented in `record`/`evict`, never cleared by `clear()` (`resetSession()` clears them; called only by `start` on a new session id); provenance `retries` from the counter, new `events_dropped`. `AudioCaptureClient.start(sessionId:…)`: `if sessionId != currentSessionId { await drainHelperDiagnostics(); diagnostics.resetSession(); liveLog = LiveDiagnosticsLog(...) }` else `await drainHelperDiagnostics()` (bounded) before `startCapture`; `record()` also appends to `liveLog`. `finalizeSessionDiagnostics` merges the live log, writes `<session>.diag.jsonl` if anomalous, deletes the live file. `recoverAtLaunch` merges an existing live log for the sentinel's session. `MonotonicWallClock { init(anchorWall: Date, anchorMonotonic: ContinuousClock.Instant); func now(monotonic:) -> Date; static func start() }`; `ChunkRotator` stamps `currentChunkStartTime = clock.now()`.
- [ ] **Step 3: Run, build, full suite, commit** — `git commit -m "fix(evidence): rings survive in-session restarts, anomalies are written as they happen, counters live outside the ring, chunk clock is monotonic (L4, L14, L15, H7)"`

---

### P3 checkpoint

- [ ] Full suite green; build clean; council over the P3 diff (lens: every relaunch branch ends in an alarm or a notice; no path deletes the sentinel before salvage; every `await` in the crash handler re-checks state).
- [ ] CI green.
- [ ] Device (P4.1): D-30 M-L1 (SIGKILL the app: helper survival, WAV headers), D-31 M-L2 (LaunchAgent after crash), D-32 M-L3 (first-sample crash cap), D-33 M-L4 (sleep 2 min), D-34 M-L5 (disk full), D-35 (stale-by-boot after a reboot mid-recording).

---

# Phase 4 — device-test protocol, docs, threshold decisions

### Task P4.1: `scripts/test-checklist.md` — the overhaul's checklist (Regression section preserved verbatim)

**Files:**
- Modify: `scripts/test-checklist.md` — replace everything ABOVE `## Regression (always — do not trim; …)` with the section below; keep the Regression section and everything after it byte-for-byte (it is the standing gate; `git diff` must show no change from line `## Regression` onward).

- [ ] **Step 1: Replace the head of the checklist with this content**

```markdown
# Test Checklist — capture reliability overhaul (spec: docs/superpowers/specs/2026-09-24-capture-reliability-design.md)

Build and install this tree: `python3 scripts/dev.py`. Settings → Audio → Capture Method → **Core Audio Tap**.
"Remote" audio: a real call where stated, otherwise `afplay <file>`. Watch the helper with
`log stream --predicate 'subsystem == "eu.fmasi.parley"' --level debug` and read `<session>.diag.jsonl` after Stop.

The promise under test: for each side, **captured / healed within seconds / told loudly and persistently — never neither**.
Every mid-call item ends with the same check: after Stop the `.m4a` channel has the audio, or an alarm persisted, and
`metadata.capture.<side>.status` says which. Right channel: `ffmpeg -i <file>.m4a -af "pan=mono|c0=c1,volumedetect" -f null -`.

## P0 — live safety
- [ ] **D-01 Idle-exit does not disarm crash detection.** Launch, wait 12 min without recording (helper idle-exits: `log stream` shows "service inactive"), start a recording, `pkill -9 -f audio-capture-helper-xpc`. Expect: "Recording restarted — waiting for audio…" then "Recording Resumed" only after frames; `.diag.jsonl` has `helperIdleExit` (info) then `xpcInterruption`/`retry`.
- [ ] **D-02 LaunchAgent verified.** After launch: `launchctl print gui/$(id -u)/eu.fmasi.parley` exits 0. Quit → exits non-zero AND `~/Library/LaunchAgents/eu.fmasi.parley.plist` is gone. Relaunch → loaded again, no "Crash protection is off" row. Move the app bundle, launch it from the new path → the row appears once, then repair rewrites the path (row gone on next launch).
- [ ] **D-03 Crash relaunch within 5 s.** While recording, `kill -SEGV $(pgrep -x Parley)`. Parley relaunches, resumes the same session (menu timer continues from the original start), shows the floating alert "Parley crashed at HH:MM:SS and resumed at HH:MM:SS — N s not recorded", and after Stop `metadata.capture.gaps` lists that gap.
- [ ] **D-04 Never-delivered alarm.** `tccutil reset AudioCapture eu.fmasi.parley`, deny the prompt, play audio, Record. Within ~10 s: floating window + sound + notification + red row "The other side …". Click Later: the row stays; after 2 min a second notification; after 3 min the window returns. Grant in System Settings → the row clears only once remote audio plays.
- [ ] **D-05 Wedged helper.** Record, `pkill -STOP -f audio-capture-helper-xpc`. Within ~15 s the row "The capture helper stopped answering" appears; `pkill -CONT` → it clears within ~10 s and the recording continues.
- [ ] **D-06 Muted remote, no alarm (M-A).** See the measurement matrix below; the acceptance is no alarm for 5 min of muted remote on every app/route pair.

## P1 — tap healing
- [ ] **D-10 Incident-B reproduction (M-C).** Mic = AirPods (HFP), default output = AirPods, anchor = built-in speaker, Safari playing to the AirPods. Record; wait 15 s past mic start. If callbacks stop (`log stream` shows `PauseIO` with no `ResumeIO`): expect `tapRecoveryRung` events in order, frames back within 10 s, no alarm. Record which rung restored callbacks and `AudioDeviceStop` latency. Control: wired mic.
- [ ] **D-11 Aggregate listeners (M-E).** During D-10, `.diag.jsonl` shows `aggregateIOStopped` with `selector` `goin`/`stpd`/`diff` — note which fired.
- [ ] **D-12 TapAutoStart A/B (M-B).** `tap_auto_start: false` in config.json vs `true`: record 3 min with nothing playing, then 30 s of playback, then 2 min idle. Read callbacks/s from `remote_heartbeat_callbacks` in provenance (÷ seconds). `sudo powermetrics --samplers cpu_power,tasks -i 10000 -n 60` during each; `pmset -g assertions` after Stop (no coreaudiod assertion). Listen for relay/amp noise. Pass for `false`: continuous callbacks, CPU delta ≤ 1 %, no artefact.
- [ ] **D-13 coreaudiod restart (M-D).** Test recording with `afplay` looping: `sudo killall coreaudiod`. Expect `serviceRestarted`, `tapRecoveryRung rebuildTap`, frames back ≤ 10 s, mic back, no alarm (or an alarm that clears).
- [ ] **D-14 Insurance rebuild dead window (M-G).** Remote muted 60 s under both autostart settings: `remote_rebuilds ≤ 1`, and the dead window (gap between the last and first buffer around `restartInPlace`) < 1 s.
- [ ] **D-15 First-frame latency (M-J).** From `captureStart`/`restartInPlace` to `firstFrames` in `.diag.jsonl`, 10 samples each under both settings → p99; thresholds are set to p99 + 2 s (see P4.3).

## P2 — honest record
- [ ] **D-20 Coverage on a real call.** 2-chunk call: `metadata.capture.remote.status healthy`, `expected_seconds ≈ delivered_seconds`, `processing_issues: []`, `dual_stream: true`.
- [ ] **D-21 Mic-empty chunk.** Unplug a USB mic for a whole chunk: that chunk archives system-only, the merged `.m4a` keeps R = remote, L silent for that stretch; no WAV left behind unless `preserve_source_wav`.
- [ ] **D-22 Re-detect timeline.** On a recording with a mic-only chunk, re-detect the remote channel: speaker turns land at the same timestamps as before.
- [ ] **D-23 Summary honesty.** Re-summarise `2026-09-24/160032-….json` after stamping `capture.remote.status: neverDelivered`: the summary opens by stating the remote side was not captured.

## P3 — lifecycle
- [ ] **D-30 App SIGKILL vs helper (M-L1).** Throwaway bundle: `kill -9` the app while the helper records; `launchctl print pid/<helper>` before/after; note survival time and whether the WAV headers were sealed. Decides whether a helper-side grace is worth a follow-up.
- [ ] **D-31 LaunchAgent after a crash (M-L2)** — covered by D-02/D-03; note the relaunch delay.
- [ ] **D-32 First-sample crash cap (M-L3).** `touch ~/Library/Application\ Support/Parley/CRASH_TEST` (gotcha #52); expect restart, restart, then "Recording Failed" with the salvage message naming what was written — never a loop.
- [ ] **D-33 Sleep 2 min mid-call (M-L4).** Close the lid on a call for 2 min: on wake a new chunk starts, frames resume, `capture.gaps` has a `sleep` entry, and "Resumed" appears only after frames.
- [ ] **D-34 Disk full (M-L5).** Fill the recordings volume with `mkfile` during a recording: the `diskLow` row within one rotation, then `diskWriteFailure`; after Stop the end message names what is on disk.
- [ ] **D-35 Reboot mid-recording.** `sudo reboot` while recording; after login: the salvage runs, a "Recording STOPPED at HH:MM" alert appears, the sentinel is gone only afterwards.

## Measurement matrix (M-A, fills the exact-zero census)
For each of Meet/Chrome, Meet/Safari, Zoom app, Teams, FaceTime, iPhone relay × AirPods, wired headphones:
- [ ] Record; join; remote mutes 5 min; unmutes; speaks. Log at 1 Hz (from `log stream --level debug`, the helper's per-tick line): the app's `piro`, `outDevs`, tap callbacks/s, exact-zero fraction. Pass: no alarm; `remote_rebuilds ≤ 1`.
- [ ] Fill in: app / route / `piro` while muted / callbacks per s / exact-zero fraction / first-audio latency after unmute / alarm? — this table decides `remote_exact_zero_soft_alarm_seconds` (§10 M-A).
```

- [ ] **Step 2: Verify the Regression section is untouched**

Run: `git diff -U0 scripts/test-checklist.md | grep -n '^[-+]' | grep -v '^[-+][-+]' | awk -F: '$1 > 0' | tail -5` and confirm the last changed line is above `## Regression`. Commit: `git commit -am "docs(checklist): capture reliability device protocol; Regression section preserved"`.

---

### Task P4.2: Gotchas, CLAUDE.md, pipeline/parameters docs, README badge

**Files:** `docs/gotchas.md` (append #71–#78), `CLAUDE.md` (file list: new Core files, helper files, removed `LivenessGapDetector`; test count), `docs/pipeline.md` (a "Capture provenance and metadata" subsection listing `capture_provenance.{local,remote}_coverage`, `metadata.capture`, `metadata.processing_issues`, `metadata.merged_audio`, the `.diag.live.jsonl` file), `docs/parameters.md` (`tap_auto_start`, `remote_exact_zero_soft_alarm_seconds`), `README.md:10` (badge count), `docs/app-store-blockers.md` (no new row; add a one-line note under the table: "Process-object properties (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningOutput`) are public AudioHardware.h API and add no blocker").

- [ ] **Step 1: Append to `docs/gotchas.md`** (numbered, never renumber):
```
71. **A track that never delivers looks exactly like one that has not started yet (Incident B, 2026-09-24):** every detector was either driven from inside the audio callback (rate drift, pad ratio) or refused to judge `lastArrival == 0`. Stamp a heartbeat at the TOP of the callback and judge "expected but silent" from the moment capture/rebuild/wake armed the monitor — `TrackLivenessMonitor`. "Expected" for the tap means "some OTHER process is running output", never "the default output device is busy".
72. **`kAudioProcessPropertyIsRunningOutput` is IO state, not content, and includes us:** a process rendering exact digital zeros reads 1 until it exits, and the helper's own capture aggregate reports itself as running output on its anchor device. Exclude `getpid()`, or the gate holds itself open forever. Fail OPEN on a read failure.
73. **The HAL can pause an aggregate's IO after a successful `AudioDeviceStart` and never resume it, with no callback:** Incident B's context was started/stopped three times by a config-change sweep on the anchor (triggered by the helper's own mic opening on AirPods HFP, not by the call app), ended in `PauseIO` count 1, and `StartAndWaitForState` failed with EAGAIN inside the HAL client. `AudioDeviceStart` had returned `noErr`. `stpd`/`goin` listeners are accelerators; the heartbeat decides; the fix is a new IO context (aggregate rebuild), then a new tap.
74. **launchd idle-exits the embedded XPC helper ~10 min after its last message, and that interruption is not a crash:** the old `crashHandlerFired` latch treated it as "handled" and was reset only in `connect()`, so every real crash after that ran no recovery. Arm crash detection per capture generation (`XPCInterruptionPolicy`); never ping the helper while idle (the ping spawns a throwaway helper).
75. **`launchctl unload` from a launchd-spawned instance SIGTERMs the process before the plist removal runs — the plist survives and `isInstalled()` lies:** remove the plist FIRST, then `bootout`. A plist on disk proves nothing; `launchctl print gui/<uid>/<label>` does. Verify and repair at every launch, and say so when repair fails.
76. **`ProcessInfo.systemUptime` excludes sleep:** measured 7.2 h short after four days, so a sentinel from a recording that started during that window was "from before the last boot" and deleted. Compare `kern.bootsessionuuid` instead.
77. **`AudioConcatenator` given a mono WAV among stereo AACs re-encodes the mono into BOTH channels and deletes it (probe-proven):** the remote voice lands in the local slot for every channel-splitting consumer, and the only lossless copy is gone. Refuse mixed sources, never delete a non-`.m4a`, verify duration before deleting, honour `preserve_source_wav`.
78. **`kAudioAggregateDeviceTapAutoStartKey = true` defers `AudioDeviceStart` until a tapped process receives its first audio, and the HAL re-arms the autostart context after every IO stop.** Gotcha #66's leading silence is this key. Under `true`, "no callbacks" is ambiguous (idle or broken); under `false` the IOProc runs continuously and delivers zeros when idle. Which one ships is decided by measurement M-B (device checklist D-12); the setting is `tap_auto_start` and is stamped into `captureStart` provenance.
```
- [ ] **Step 2: Update the other docs; commit** — `git commit -am "docs: gotchas #71–#78, provenance/metadata reference, parameters, file map, badge"`

---

### Task P4.3: Measurement-driven decisions (owner + device)

- [ ] After D-12/D-15: set `CaptureOptions.tapAutoStart`'s default and `TrackLivenessMonitor` thresholds; commit with the numbers ("p99 first-frame 1.3 s under false → firstFrame 5 s, stall 3 s kept").
- [ ] After M-A: `remote_exact_zero_soft_alarm_seconds` stays nil unless NO app rendered exact zeros while muted; record the table in `docs/benchmarks/2026-09-capture-reliability.md`.
- [ ] After D-10: reorder or drop ladder rungs per which one cleared the stall; if `AudioDeviceStop` blocked, move rung execution to a throwaway queue.
- [ ] After D-30: if the helper survives the app's death, open a follow-up issue for a bounded helper-side grace (never a replacement for the resume path).
- [ ] Owner answers on §11 (SCK default, SpeechAnalyzer default, quota scope) → one-line commits each, or issues.
- [ ] Version: MINOR; release notes lead with the transcript changes (§14).

---

## Self-Review Notes (author)

- **Spec coverage:** §4 → P0.3; §5 → P1.1–P1.5; §6 → P0.4 (+P3.3 `sessionWriteFailed`); §7.1–7.3 → P2.1, P2.2; §7.4 → P2.3–P2.9; §8.1 → P0.1; §8.2 → P0.2; §8.3/8.9 → P3.1; §8.4 → P0.3/P0.4; §8.5 → P0.5; §8.6 → P3.2; §8.7 → P3.3; §8.8 → P3.4; §8.10 → P3.5; §8.11/8.12 → P3.6; §8.13 → P0.4 (`helperUnresponsive`); §9 scenarios → pinned by `TrackLivenessMonitorTests`, `OutputActivityTests`, `TapPermissionGuardSoftAlarmTests` and D-06; §10 → P4.1/P4.3; §11 → P2.9 + owner; §12 table rows all map to a task or a documented non-goal.
- **Placeholder scan:** P3.2 (`processingTheSameChunkIndexTwiceAppendsOnce`), P3.4 and P3.5 test bodies are described by their assertions and the test seams they need (`failSetupForTesting`, `finalizeDelayForTesting`, `recordedEvents`, `rotateNowForTesting`) rather than full code — each names the seam, the input and the expected value; none says "TBD". P2.6's tests are written out against the real fixture style. P2.8 is marked deferrable, not incomplete.
- **Type consistency:** `TrackLivenessMonitor.Verdict` cases used identically in P0.3, P1.3 (`MicHealPolicy`), P0.4; `TapRecoveryLadder.Trigger/Rung/Action` in P1.1–P1.3; `AlarmKind` cases in P0.4, P1.3, P3.1, P3.3 (`sessionWriteFailed` added there — the enum must add it with `isHelperOwned == false`); `TrackAccounting.asDetail(prefix:)` prefixes `"remote"`/`"local"` in P2.1 and read back in `makeProvenance`; `CaptureOptions` threaded through `RecordingCaptureClient.start(... options:)` in P1.4 and every later fake; `RecordingCaptureClient` grows `onFirstFrames` (P0.3), `captureStatus`/`onAlarmsChanged` (P0.4), `start(options:)` (P1.4), `recordLaunchRecovery` (P3.1), `systemPowerEvent` and `record` (P3.5) — `FakeCaptureClient` is updated in each of those tasks.
- **Review Focus:** all five pinned (P0.3 ×2, P0.4, P1.1, P2.1).
- **Tests that enshrined bugs and change red-first:** `RecordingCoordinatorTests.swift:795` (streak reset on `start()`), `crashRestartClearsTheStickyState` (:415), `PadRatioMonitorDeadTrackTests` (deleted: impossible input), `LivenessGapDetectorTests` (deleted with its type), `SpeakerAssignmentTests` dedup cases (far-apart repeat now survives), `EchoDeduplicatorTests`/`SpeakerAssignmentVadTests` (P2.8, flagged not removed), `TapPermissionGuardTests` (`.rebuildTap` gains a reason; `deliveryGap` tests removed).
- **Unit-test blind spots (helper/app targets):** `SystemTapSession` listeners and rungs, `TapHealer` timers, `OutputActivityProbe`, `AudioCaptureClient` deadlines, the alarm window — all thin executors of tested cores; each has a device item in P4.1.
