import Foundation
import Testing
@testable import TranscriberCore

@MainActor
struct InputLevelMonitorTests {

    @Test func initialLevelIsZero() {
        let monitor = InputLevelMonitor()
        #expect(monitor.level == 0.0)
    }

    @Test func isNotMonitoringInitially() {
        let monitor = InputLevelMonitor()
        #expect(monitor.isMonitoring == false)
    }

    @Test func stopWhenNotMonitoringIsNoOp() {
        let monitor = InputLevelMonitor()
        monitor.stop()
        #expect(monitor.isMonitoring == false)
        #expect(monitor.level == 0.0)
    }

    @Test func stopResetsLevel() {
        let monitor = InputLevelMonitor()
        // Simulate that level was set (in real use, the audio tap sets it)
        monitor.level = 0.75
        monitor.stop()
        #expect(monitor.level == 0.0)
        #expect(monitor.isMonitoring == false)
    }

    // MARK: - RMS Float32

    @Test func rmsFloatSilenceIsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = [0.0, 0.0, 0.0, 0.0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(rms == 0.0)
    }

    @Test func rmsFloatFullScaleSine() {
        let monitor = InputLevelMonitor()
        // A full-scale sine wave has RMS = 1/√2 ≈ 0.707
        // Approximate with +1, -1 alternating
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(rms == 1.0)  // sqrt(mean of 1s) = 1.0
    }

    @Test func rmsFloatHalfAmplitude() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test func rmsFloatEmptyReturnsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = []
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: 0) }
        #expect(rms == 0.0)
    }

    // MARK: - RMS Int16

    @Test func rmsInt16SilenceIsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [0, 0, 0, 0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        #expect(rms == 0.0)
    }

    @Test func rmsInt16FullScale() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [32767, -32767, 32767, -32767]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        // 32767/32768 ≈ 0.99997
        #expect(abs(rms - 1.0) < 0.001)
    }

    @Test func rmsInt16HalfAmplitude() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [16384, -16384, 16384, -16384]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test func rmsInt16EmptyReturnsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = []
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: 0) }
        #expect(rms == 0.0)
    }

    // MARK: - dB normalization

    @Test func dBNormalizeZeroReturnsZero() {
        let monitor = InputLevelMonitor()
        #expect(monitor.dBNormalize(0.0) == 0.0)
    }

    @Test func dBNormalizeFullScaleReturnsOne() {
        let monitor = InputLevelMonitor()
        // RMS of 1.0 = 0 dB, normalized to 1.0
        #expect(monitor.dBNormalize(1.0) == 1.0)
    }

    @Test func dBNormalizeVeryQuietClampsToZero() {
        let monitor = InputLevelMonitor()
        // RMS of 0.00001 ≈ -100 dB, well below -50 dB floor
        #expect(monitor.dBNormalize(0.00001) == 0.0)
    }

    @Test func dBNormalizeMidRange() {
        let monitor = InputLevelMonitor()
        // RMS of ~0.00316 = -50 dB, should map to 0.0 (the floor)
        let atFloor = monitor.dBNormalize(0.00316)
        #expect(abs(atFloor) < 0.02)
    }

    @Test func dBNormalizeMonotonicallyIncreasing() {
        let monitor = InputLevelMonitor()
        let low = monitor.dBNormalize(0.01)
        let mid = monitor.dBNormalize(0.1)
        let high = monitor.dBNormalize(0.5)
        #expect(low < mid)
        #expect(mid < high)
    }
}

// MARK: - Never block the caller (#192)
//
// 2026-09-10: opening the mic switcher mid-recording froze the app permanently. `MicrophonePicker`
// calls `InputLevelMonitor.start` from `.onAppear` — on the main thread — and `start` called
// `AVCaptureSession.startRunning()` synchronously. With the capture helper already running the same
// mic's IO, that call waited forever on a CoreAudio HAL lock (`HALB_Guard::WaitFor` →
// `__psynch_mutexwait`), so the UI never came back. The fakes below reproduce that hang exactly: a
// lifecycle call that simply does not return.


/// Carries a non-Sendable value across a thread boundary in a test.
private final class Carry<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// `startRunning()` blocks until released — the 2026-09-10 CoreAudio HAL wait. `entered` fires once
/// the call is actually in progress, so a test can pin WHICH path it exercises.
private final class HangingStartSession: LevelMeterSession, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _starts = 0, _stops = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    func startRunning() {
        lock.lock(); _starts += 1; lock.unlock()
        entered.signal()
        release.wait()
    }
    func stopRunning() { lock.lock(); _stops += 1; lock.unlock() }
}

/// `stopRunning()` blocks until released.
private final class HangingStopSession: LevelMeterSession, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func startRunning() { started.signal() }
    func stopRunning() { release.wait() }
}

/// Starts and stops instantly; counts calls.
private final class InstantSession: LevelMeterSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    func startRunning() { lock.lock(); _starts += 1; lock.unlock() }
    func stopRunning() { lock.lock(); _stops += 1; lock.unlock() }
}

/// Hands out the given sessions in order, one per build.
private final class SessionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [LevelMeterSession]
    private var _handedOut = 0
    init(_ sessions: [LevelMeterSession]) { remaining = sessions }
    var handedOut: Int { lock.lock(); defer { lock.unlock() }; return _handedOut }
    func next() -> LevelMeterSession? {
        lock.lock(); defer { lock.unlock() }
        guard !remaining.isEmpty else { return nil }
        _handedOut += 1
        return remaining.removeFirst()
    }
}

/// A session factory keyed by device id that records how, where and with which generation it was called.
private final class RecordingFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let byDevice: [String: LevelMeterSession]
    private var _calls: [String: Int] = [:]
    private var _generations: [String: UInt64] = [:]
    private var _threads: [Thread] = []
    init(_ byDevice: [String: LevelMeterSession]) { self.byDevice = byDevice }
    func make(_ deviceId: String?, _ generation: UInt64) -> LevelMeterSession? {
        let key = deviceId ?? "default"
        lock.lock(); defer { lock.unlock() }
        _calls[key, default: 0] += 1
        _generations[key] = generation
        _threads.append(Thread.current)
        return byDevice[key]
    }
    func calls(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return _calls[key, default: 0] }
    func generation(_ key: String) -> UInt64? { lock.lock(); defer { lock.unlock() }; return _generations[key] }
    var threads: [Thread] { lock.lock(); defer { lock.unlock() }; return _threads }
}

/// `start()`/`stop()` are main-actor API, called from SwiftUI — so the suite runs on the main actor.
/// Whether they return promptly is tested separately, off the main actor (below).
@MainActor
@Suite("InputLevelMonitor never blocks its caller (#192)")
struct InputLevelMonitorNonBlockingTests {

    /// Polls `condition` for up to `seconds`.
    private nonisolated func eventually(within seconds: Double = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private nonisolated func monitor(_ factory: RecordingFactory, publish q: DispatchQueue? = nil) -> InputLevelMonitor {
        let publish: (@escaping () -> Void) -> Void
        if let q {
            publish = { q.async(execute: $0) }
        } else {
            publish = { _ in }
        }
        return InputLevelMonitor(
            makeSession: { id, gen, _ in factory.make(id, gen) },
            publish: publish,
            pendingStarts: PendingStartRegistry()
        )
    }

    @Test("the session is built off the calling thread, not just started off it")
    func sessionIsBuiltOffTheCallingThread() {
        // AVCaptureDevice lookup and AVCaptureDeviceInput creation touch the device too. Building on the
        // caller left them on main, where a device wedged by an earlier hung start could still freeze
        // the UI — the capture helper builds on its configQueue for exactly this reason.
        let factory = RecordingFactory(["default": InstantSession()])
        let m = monitor(factory)
        let caller = Thread.current
        m.start(deviceId: nil)
        #expect(eventually { !factory.threads.isEmpty })
        #expect(factory.threads.allSatisfy { $0 !== caller }, "the session was constructed on the caller's thread")
    }

    @Test("a new mic goes live WHILE the old one is still hung — the user can always switch away")
    func newMicGoesLiveWhileOldStartIsStillHung() {
        // Asserted before the dead mic is released: that is what proves one hung session cannot hold
        // up the next. A single shared queue would pass a version of this test that released first.
        let dead = HangingStartSession()
        let good = InstantSession()
        let factory = RecordingFactory(["dead": dead, "working": good])
        let q = DispatchQueue(label: "test.publish")
        let m = monitor(factory, publish: q)

        m.start(deviceId: "dead")
        guard dead.entered.wait(timeout: .now() + 2) == .success else {
            dead.release.signal(); Issue.record("the dead mic's start never began"); return
        }
        m.start(deviceId: "working")

        #expect(eventually { good.starts == 1 }, "the working mic waited behind the hung one")
        #expect(eventually { q.sync { m.isMonitoring } }, "the working mic never went live")

        dead.release.signal()
        #expect(eventually { dead.stops == 1 }, "the superseded session was left running")
        #expect(good.stops == 0, "the live session was stopped by the stale one")
        #expect(q.sync { m.isMonitoring })
    }

    @Test("a start that finishes after stop() cannot turn monitoring back on")
    func staleStartCannotTurnMonitoringOn() {
        let dead = HangingStartSession()
        let q = DispatchQueue(label: "test.publish")
        let m = monitor(RecordingFactory(["dead": dead]), publish: q)

        m.start(deviceId: "dead")
        guard dead.entered.wait(timeout: .now() + 2) == .success else {
            dead.release.signal(); Issue.record("start never began"); return
        }
        m.stop()                    // the user closed the picker while it was still hanging
        dead.release.signal()       // ...and only now does the start come back
        #expect(eventually { dead.stops == 1 })
        q.sync {}                   // flush anything the stale start tried to publish
        #expect(!q.sync { m.isMonitoring }, "a start superseded by stop() still flipped isMonitoring on")
    }

    @Test("a device whose start is still hung is not opened a second time")
    func hungDeviceIsNotOpenedAgain() {
        // Reopening the switcher (a new picker, a new monitor) or flipping back to the dead mic would
        // otherwise pile up another thread blocked in the same HAL wait, every time, forever.
        let dead = HangingStartSession()
        let factory = RecordingFactory(["dead": dead])
        let registry = PendingStartRegistry()
        let q = DispatchQueue(label: "test.publish")
        let first = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, publish: { _ in }, pendingStarts: registry)
        let second = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, publish: { q.async(execute: $0) },
                                       pendingStarts: registry, unresponsiveAfter: 0.1)

        first.start(deviceId: "dead")
        guard dead.entered.wait(timeout: .now() + 2) == .success else {
            dead.release.signal(); Issue.record("start never began"); return
        }
        second.start(deviceId: "dead")
        #expect(eventually { q.sync { second.status } == .notResponding }, "the second picker was not told the mic is stuck")
        #expect(dead.starts == 1, "a second startRunning() was issued on a device already hung in one")
        #expect(factory.calls("dead") == 1, "a second session was built on a device already hung in one")
        second.stop()   // it would otherwise take its turn on the (fake, single-use) session once released
        dead.release.signal()
    }

    @Test("a monitor dropped while its start hangs still stops that session afterwards")
    func droppedMonitorStillStopsHungSession() {
        // The picker can go away (dialog closed, view torn down) while its start is stuck. The session
        // must still be stopped once the start returns, or the mic stays open for the life of the app.
        let dead = HangingStartSession()
        var m: InputLevelMonitor? = monitor(RecordingFactory(["dead": dead]))
        weak var weakM = m
        m!.start(deviceId: "dead")
        guard dead.entered.wait(timeout: .now() + 2) == .success else {
            dead.release.signal(); Issue.record("start never began"); return
        }
        m = nil
        #expect(eventually { weakM == nil }, "the hung start kept the monitor alive — its teardown can never run")
        dead.release.signal()
        #expect(eventually { dead.stops == 1 }, "nobody stopped the session after its start returned")
    }

    @Test("a level from a superseded session never reaches the meter")
    func levelFromSupersededSessionIsDropped() {
        let factory = RecordingFactory(["A": InstantSession(), "B": InstantSession()])
        let q = DispatchQueue(label: "test.publish")
        let m = monitor(factory, publish: q)

        m.start(deviceId: "A")
        #expect(eventually { q.sync { m.isMonitoring } })
        m.start(deviceId: "B")
        #expect(eventually { factory.calls("B") == 1 && q.sync { m.isMonitoring } })

        guard let genA = factory.generation("A"), let genB = factory.generation("B") else {
            Issue.record("sessions were not built"); return
        }
        m.receiveLevel(0.9, generation: genA)   // a late buffer from the mic the user left
        q.sync {}
        #expect(q.sync { m.level } == 0, "the old mic's level showed on the new mic's meter")
        m.receiveLevel(0.5, generation: genB)
        q.sync {}
        #expect(q.sync { m.level } == 0.5)
    }

    @Test("isMonitoring turns on once the session is actually running")
    func isMonitoringReflectsRunningSession() {
        let session = InstantSession()
        let q = DispatchQueue(label: "test.publish")
        let m = monitor(RecordingFactory(["default": session]), publish: q)
        m.start(deviceId: nil)
        #expect(eventually { q.sync { m.isMonitoring } })
        #expect(session.starts == 1)
    }

    @Test("stopAndRelease() returns once stopRunning() has actually let the device go")
    func stopAndReleaseWaitsForTheDevice() async {
        let session = InstantSession()
        let m = monitor(RecordingFactory(["default": session]))
        m.start(deviceId: nil)
        #expect(eventually { session.starts == 1 })
        let released = await m.stopAndRelease(timeout: 2)
        #expect(released)
        #expect(session.stops == 1, "reported the device released before stopRunning() ran")
    }

    @Test("stopAndRelease() gives up after its timeout instead of waiting on a wedged device")
    func stopAndReleaseIsBounded() async {
        let hang = HangingStopSession()
        let m = monitor(RecordingFactory(["default": hang]))
        m.start(deviceId: nil)
        guard hang.started.wait(timeout: .now() + 2) == .success else {
            Issue.record("start never began"); return
        }
        let began = Date()
        let released = await m.stopAndRelease(timeout: 0.2)
        let waited = Date().timeIntervalSince(began)
        hang.release.signal()
        #expect(!released)
        #expect(waited < 5, "waited \(waited)s — the mic switch would hang behind a wedged meter")
    }

    @Test("stopAndRelease() during a stuck start gives up in time, and the session is still stopped later")
    func stopAndReleaseDuringAStuckStart() async {
        // The user clicks Start Recording while the meter's start is still stuck: the dialog must not
        // wait past its budget, and the meter must still let go of the mic once the start returns.
        let stuck = HangingStartSession()
        let m = monitor(RecordingFactory(["default": stuck]))
        m.start(deviceId: nil)
        guard stuck.entered.wait(timeout: .now() + 2) == .success else {
            stuck.release.signal(); Issue.record("start never began"); return
        }
        let began = Date()
        let released = await m.stopAndRelease(timeout: 0.2)
        let waited = Date().timeIntervalSince(began)
        #expect(!released, "reported the mic released while its start was still stuck")
        #expect(waited < 5, "waited \(waited)s behind a stuck start")
        stuck.release.signal()
        #expect(eventually { stuck.stops == 1 }, "the session was never stopped after its stuck start returned")
    }

    @Test("stopAndRelease() with nothing running returns at once")
    func stopAndReleaseWhenIdle() async {
        let m = monitor(RecordingFactory([:]))
        #expect(await m.stopAndRelease(timeout: 2))
    }

    // MARK: - Review round 1 (#192): the recording's own mic, one physical device, slow starts

    @Test("the mic the recording is capturing is never metered")
    func recordingMicIsNeverMetered() {
        // Metering the helper's own mic is the exact startRunning() that hung (#192): the switcher opens
        // with the current mic selected, and Settings shows the configured one.
        let factory = RecordingFactory(["A": InstantSession()])
        let recording = RecordingMicrophone()
        recording.set("A")
        let q = DispatchQueue(label: "test.publish")
        let m = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, publish: { q.async(execute: $0) },
                                  pendingStarts: PendingStartRegistry(), recordingMicrophone: recording)
        m.start(deviceId: "A")
        #expect(eventually { q.sync { m.status } == .inUseByRecording })
        #expect(factory.calls("A") == 0, "a session was built on the mic the recording holds")

        recording.clear()   // recording over: the same mic meters normally again
        m.start(deviceId: "A")
        #expect(eventually { q.sync { m.status } == .live })
    }

    @Test("System Default and the default mic's own entry are one device")
    func systemDefaultAndItsExplicitIdAreOneDevice() {
        // Recording on "System Default" while the picker shows the built-in mic by name (or the other
        // way round) is still the same physical mic, for both the in-use check and pending starts.
        let dead = HangingStartSession()
        let factory = RecordingFactory(["default": dead, "builtin": InstantSession()])
        let toPhysical: (String?) -> String? = { $0 ?? "builtin" }
        let recording = RecordingMicrophone()
        recording.set(nil)
        let q = DispatchQueue(label: "test.publish")
        let m = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, physicalDevice: toPhysical,
                                  publish: { q.async(execute: $0) }, pendingStarts: PendingStartRegistry(),
                                  recordingMicrophone: recording)
        m.start(deviceId: "builtin")
        #expect(eventually { q.sync { m.status } == .inUseByRecording })

        recording.clear()
        let registry = PendingStartRegistry()
        let first = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, physicalDevice: toPhysical,
                                      publish: { _ in }, pendingStarts: registry)
        let second = InputLevelMonitor(makeSession: { id, g, _ in factory.make(id, g) }, physicalDevice: toPhysical,
                                       publish: { q.async(execute: $0) }, pendingStarts: registry,
                                       unresponsiveAfter: 0.1)
        first.start(deviceId: nil)   // hangs on the built-in mic
        guard dead.entered.wait(timeout: .now() + 2) == .success else {
            dead.release.signal(); Issue.record("start never began"); return
        }
        second.start(deviceId: "builtin")
        #expect(eventually { q.sync { second.status } == .notResponding })
        #expect(factory.calls("builtin") == 0, "opened the stuck mic again under its other name")
        second.stop()
        dead.release.signal()
    }

    @Test("a second picker on a mic another is still starting waits for it, then goes live")
    func secondPickerWaitsForTheFirstStartThenGoesLive() {
        // Two pickers opening the same mic at once (Settings plus a dialog) — or the switcher reopened
        // while the first start is slow: the second must not open the device again, and must not be
        // left saying "not responding" for good once the first start finishes.
        let slow = HangingStartSession()
        let fast = InstantSession()
        let sessions = SessionSequence([slow, fast])
        let registry = PendingStartRegistry()
        let q = DispatchQueue(label: "test.publish")
        let first = InputLevelMonitor(makeSession: { _, _, _ in sessions.next() }, publish: { _ in }, pendingStarts: registry)
        let second = InputLevelMonitor(makeSession: { _, _, _ in sessions.next() }, publish: { q.async(execute: $0) },
                                       pendingStarts: registry, unresponsiveAfter: 0.1)
        first.start(deviceId: "A")
        guard slow.entered.wait(timeout: .now() + 2) == .success else {
            slow.release.signal(); Issue.record("first start never began"); return
        }
        second.start(deviceId: "A")
        #expect(eventually { q.sync { second.status } == .notResponding })
        #expect(sessions.handedOut == 1, "the second picker opened the mic while another start on it was in flight")

        slow.release.signal()
        #expect(eventually { q.sync { second.status } == .live }, "the second picker never recovered once the first start finished")
        #expect(fast.starts == 1)
    }

    @Test("a start that has not returned in time says the mic is not responding, then recovers")
    func slowStartReportsNotResponding() {
        let slow = HangingStartSession()
        let q = DispatchQueue(label: "test.publish")
        let m = InputLevelMonitor(makeSession: { id, g, _ in RecordingFactory(["default": slow]).make(id, g) },
                                  publish: { q.async(execute: $0) }, pendingStarts: PendingStartRegistry(),
                                  unresponsiveAfter: 0.1)
        m.start(deviceId: nil)
        #expect(eventually { q.sync { m.status } == .notResponding }, "a stuck mic showed a silent meter with no explanation")
        slow.release.signal()
        #expect(eventually { q.sync { m.status } == .live }, "the meter never came back once the start returned")
    }

    @Test("a mic superseded while its session is being built is never started")
    func supersededWhileBuildingNeverStarts() {
        // The user flips A→B while A's device input is still being created: A must not start afterwards.
        let a = InstantSession()
        let building = DispatchSemaphore(value: 0)
        let finishBuilding = DispatchSemaphore(value: 0)
        let registry = PendingStartRegistry()
        let q = DispatchQueue(label: "test.publish")
        let m = InputLevelMonitor(
            makeSession: { id, _, _ in
                if id == "A" { building.signal(); finishBuilding.wait(); return a }
                return InstantSession()
            },
            publish: { q.async(execute: $0) }, pendingStarts: registry
        )
        m.start(deviceId: "A")
        guard building.wait(timeout: .now() + 2) == .success else {
            finishBuilding.signal(); Issue.record("A was never built"); return
        }
        m.start(deviceId: "B")
        #expect(eventually { q.sync { m.status } == .live })
        finishBuilding.signal()
        #expect(eventually { !registry.contains("A") }, "A's slot never finished")
        #expect(a.starts == 0, "the superseded mic was started anyway")
    }

    @Test("a mic that cannot be opened says so")
    func unopenableMicSaysUnavailable() {
        let q = DispatchQueue(label: "test.publish")
        let m = monitor(RecordingFactory([:]), publish: q)
        m.start(deviceId: "gone")
        #expect(eventually { q.sync { m.status } == .unavailable })
    }
}

/// The two "returns promptly" tests, kept OFF the main actor. They hand `start()`/`stop()` to the main
/// actor — where production calls them — and AWAIT the result, never blocking the main thread
/// themselves. A call that never returns fails after a bounded wait instead of hanging the suite, and
/// time spent queued behind other main-actor tests doesn't count, so a busy parallel run can't flake it.
@Suite("InputLevelMonitor's main-actor API returns promptly (#192)")
struct InputLevelMonitorPromptnessTests {

    /// How long `body` took once it ran on the main actor, or nil if it had not finished within `seconds`.
    private func durationOnMain(
        within seconds: Double = 30, _ body: @escaping @MainActor () -> Void
    ) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<TimeInterval?>(continuation)
            Task { @MainActor in
                let began = Date()
                body()
                once.resume(Date().timeIntervalSince(began))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    private func monitor(_ factory: RecordingFactory) -> InputLevelMonitor {
        InputLevelMonitor(
            makeSession: { id, gen, _ in factory.make(id, gen) },
            publish: { _ in },
            pendingStarts: PendingStartRegistry()
        )
    }

    @Test("start() returns even when startRunning() never does")
    func startDoesNotBlockWhenStartRunningHangs() async {
        let hang = HangingStartSession()
        let m = Carry(monitor(RecordingFactory(["default": hang])))
        let took = await durationOnMain { m.value.start(deviceId: nil) }
        hang.release.signal()   // let the hung call finish so no thread outlives the test
        #expect(took.map { $0 < 1 } == true, "start() blocked its caller — on the main thread this is the 2026-09-10 UI freeze")
    }

    @Test("stop() returns even when stopRunning() never does")
    func stopDoesNotBlockWhenStopRunningHangs() async {
        let hang = HangingStopSession()
        let m = Carry(monitor(RecordingFactory(["default": hang])))
        _ = await durationOnMain { m.value.start(deviceId: nil) }
        guard hang.started.wait(timeout: .now() + 5) == .success else {
            Issue.record("start never began — stop() would have nothing to stop"); return
        }
        let took = await durationOnMain { m.value.stop() }
        hang.release.signal()
        #expect(took.map { $0 < 1 } == true, "stop() blocked its caller — closing the picker would freeze the app")
    }
}
