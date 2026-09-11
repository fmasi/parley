import AVFoundation
import Observation

/// The two blocking lifecycle calls the level meter makes on a capture session. A seam so tests can
/// substitute a session whose `startRunning()` never returns — the 2026-09-10 freeze (#192), where
/// `AVCaptureSession.startRunning()` waited forever on a CoreAudio HAL lock because the capture helper
/// already had the same microphone's IO running.
public protocol LevelMeterSession: AnyObject {
    func startRunning()
    func stopRunning()
}

/// Physical devices whose level-meter `startRunning()` has not returned yet, process-wide. A new picker
/// (the switcher reopened, or flipped back to the dead mic) must not open such a device again: that
/// only parks another thread in the same HAL wait, every time, for the life of the app. Injectable so
/// tests don't share state; production uses `.shared`. Internal: only `InputLevelMonitor` uses it.
final class PendingStartRegistry: @unchecked Sendable {
    static let shared = PendingStartRegistry()
    private let lock = NSLock()
    private var keys: Set<String> = []
    init() {}
    /// Claims `key`; false if a start on it is already in flight.
    func claim(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.insert(key).inserted }
    func release(_ key: String) { lock.lock(); defer { lock.unlock() }; keys.remove(key) }
    func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.contains(key) }
}

/// Told about every change to a `RecordingMicrophone`, on the main actor.
@MainActor
public protocol RecordingMicrophoneObserver: AnyObject {
    func recordingMicrophoneChanged(to device: String??)
}

/// The microphone the recording is capturing from, process-wide, so no level meter opens it while the
/// capture helper holds it: opening a mic the helper has running is the exact `startRunning()` that
/// hung on 2026-09-10 (#192).
///
/// Design boundary: it stops meters OPENING the recording's mic, not one already running on it — e.g.
/// Settings metering mic A when a recording starts on A. That is the meter/helper coexistence that
/// worked for months on healthy mics; the hazard is a wedged one (a lid-closed built-in, #193), where
/// the meter already reads "Not responding". Revisit before adding a third picker.
///
/// Set by `RecordingCoordinator` and by the relaunch re-attach paths; the
/// coordinator mirrors it for the menu's mic label, so every writer keeps that label right too.
public final class RecordingMicrophone: @unchecked Sendable {
    public static let shared = RecordingMicrophone()
    private let lock = NSLock()
    private var device: String?? = .none
    /// Touched only on the main actor — protected by that isolation (addObserver/update are
    /// @MainActor), NOT by `lock`. Any future off-main path to it must hop to the main actor first.
    private let observers = NSHashTable<AnyObject>.weakObjects()
    public init() {}
    /// The recording is capturing from `deviceId` (`nil` = the system default).
    @MainActor public func set(_ deviceId: String?) { update(.some(deviceId)) }
    /// Nothing is recording.
    @MainActor public func clear() { update(.none) }
    /// `.none` when nothing is recording; `.some(nil)` when recording on the system default. Readable
    /// from any thread (level meters check it on their session queues); written only on the main actor.
    public var current: String?? { lock.lock(); defer { lock.unlock() }; return device }

    /// Tell `observer` (held weakly) about every change from now on.
    @MainActor public func addObserver(_ observer: RecordingMicrophoneObserver) {
        observers.add(observer)   // main-actor only, like update(): no lock needed
    }

    /// Main-actor only, so observers are told synchronously and stay exactly in step with `current`.
    /// The lock guards `device` alone — the one piece of state read from other threads.
    @MainActor private func update(_ value: String??) {
        lock.lock()
        device = value
        lock.unlock()
        for case let observer as RecordingMicrophoneObserver in observers.allObjects {
            observer.recordingMicrophoneChanged(to: value)
        }
    }
}

/// What the meter is doing, so the picker can say why it is flat.
public enum LevelMeterStatus: Equatable, Sendable {
    case off
    case starting
    case live
    /// The recording is capturing this mic; metering it too is what froze the app (#192).
    case inUseByRecording
    /// The device has not started in time — or another start on it (stuck, possibly for good, or just
    /// another picker opening it) has kept it busy for too long. Clears by itself if that start finishes.
    case notResponding
    /// No such device, or it could not be opened.
    case unavailable
}

/// Monitors audio input level from a specified device (or system default).
/// Uses AVCaptureSession which handles all device types including USB webcams.
/// Publishes `level` (0.0–1.0) suitable for driving a level meter UI.
///
/// Nothing here may block its caller, which is the main thread (SwiftUI `.onAppear`/`.onChange`/
/// `.onDisappear`). Every call that touches the device — lookup, `AVCaptureDeviceInput`,
/// `startRunning()`, `stopRunning()` — runs on a serial queue owned by that one session (#192,
/// gotcha #68). Public API is main-thread only.
@Observable
public final class InputLevelMonitor: NSObject {
    public var level: Float = 0.0
    public private(set) var status: LevelMeterStatus = .off
    public var isMonitoring: Bool { status == .live }

    /// Where every session of this monitor delivers its buffers. Deliberately ONE queue: only the
    /// lifecycle calls (which can block) need a queue per session. During an A→B switch both sessions
    /// may deliver here briefly; receiveLevel's generation check drops the old one's levels.
    private let processingQueue = DispatchQueue(label: "input-level-monitor")
    private let makeSession: (String?, UInt64, InputLevelMonitor) -> LevelMeterSession?
    /// The physical device a selection means (`nil` → whatever the default is now). Runs on the
    /// session's queue. Pending starts and the recording's mic are compared by this, so "System
    /// Default" and the default device's own entry count as the one device they are.
    private let physicalDevice: (String?) -> String?
    /// Where observable state changes are published. Main in production (SwiftUI reads these);
    /// injectable so tests can observe them without depending on the main run loop.
    private let publish: (@escaping () -> Void) -> Void
    private let pendingStarts: PendingStartRegistry
    private let recordingMicrophone: RecordingMicrophone
    /// How long a start may take before the picker says the device is not responding.
    private let unresponsiveAfter: TimeInterval

    /// Guards `current` and `generation`. A leaf lock: never held across a device call, so it cannot
    /// deadlock with a `startRunning()` that never returns.
    private let lock = NSLock()
    @ObservationIgnored private var current: Slot?
    /// Bumped by every start/stop, so work finishing after being superseded can tell it lost.
    @ObservationIgnored private var generation: UInt64 = 0

    /// One session's lifecycle. One queue PER SESSION: a session whose `startRunning()` never returns
    /// wedges only its own queue, so the user can still pick another mic and have it start.
    private final class Slot: @unchecked Sendable {
        let queue: DispatchQueue
        let generation: UInt64
        /// Confined to `queue`.
        var session: LevelMeterSession?
        private let lock = NSLock()
        private var settled = false
        init(generation: UInt64) {
            self.generation = generation
            // Numbered, so several pickers' sessions are told apart in a sample or crash report.
            self.queue = DispatchQueue(label: "input-level-monitor.session.\(generation)")
        }
        /// The slot reached a final status (live, in use, unavailable): the watchdog leaves it alone.
        var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return settled }
        func markSettled() { lock.lock(); defer { lock.unlock() }; settled = true }
    }

    public override init() {
        self.makeSession = { deviceId, generation, monitor in
            monitor.makeCaptureSession(deviceId: deviceId, generation: generation)
        }
        // Deliberately on the session queue, not main: the default-device lookup reads the HAL too. The
        // capture helper's MicCaptureSession resolves devices the same way, on its configQueue.
        self.physicalDevice = { deviceId in deviceId ?? AVCaptureDevice.default(for: .audio)?.uniqueID }
        self.publish = { DispatchQueue.main.async(execute: $0) }
        self.pendingStarts = .shared
        self.recordingMicrophone = .shared
        self.unresponsiveAfter = 2
        super.init()
    }

    /// Test seam: substitute every dependency. `physicalDevice` defaults to "nil means `default`".
    init(
        makeSession: @escaping (String?, UInt64, InputLevelMonitor) -> LevelMeterSession?,
        physicalDevice: @escaping (String?) -> String? = { $0 ?? "default" },
        publish: @escaping (@escaping () -> Void) -> Void,
        pendingStarts: PendingStartRegistry,
        recordingMicrophone: RecordingMicrophone = RecordingMicrophone(),
        unresponsiveAfter: TimeInterval = 2
    ) {
        self.makeSession = makeSession
        self.physicalDevice = physicalDevice
        self.publish = publish
        self.pendingStarts = pendingStarts
        self.recordingMicrophone = recordingMicrophone
        self.unresponsiveAfter = unresponsiveAfter
        super.init()
    }

    /// Start monitoring the given device. Pass `nil` for system default.
    /// If already monitoring, stops the previous session first. Returns immediately; `status` becomes
    /// `.live` only once the new session is actually running.
    @MainActor
    public func start(deviceId: String?) {
        let slot: Slot
        let old: Slot?
        lock.lock()                       // supersede and install in ONE critical section
        generation &+= 1
        slot = Slot(generation: generation)
        old = current
        current = slot
        lock.unlock()
        retire(old)
        status = .starting
        level = 0.0

        let makeSession = self.makeSession
        let physicalDevice = self.physicalDevice
        let publish = self.publish
        let pending = pendingStarts
        let recording = recordingMicrophone
        let unresponsiveAfter = self.unresponsiveAfter
        slot.queue.async { [weak self] in
            // `self` is only ever held briefly below — never across a wait or a blocking device call — so
            // a monitor dropped meanwhile can still deinit and retire the session.

            // Say so if getting this mic going is slow. Armed NOW, so it covers every device read below —
            // the default-device lookup, building the input, waiting for another start, the start itself —
            // each of which can hang on a wedged device. Decided ON the publish executor and only while
            // the slot hasn't settled, so a quick "In use"/"Unavailable" is never overwritten, and a start
            // that finishes as this fires is never LEFT showing "not responding" (it can flash it for one
            // frame; `.live` follows).
            weak var monitor = self
            DispatchQueue.global().asyncAfter(deadline: .now() + unresponsiveAfter) {
                publish {
                    guard let monitor, monitor.isCurrent(slot.generation), !slot.isSettled else { return }
                    monitor.status = .notResponding
                }
            }

            /// Whether the recording is capturing this physical device right now.
            func isRecordingMic(_ key: String) -> Bool {
                guard case .some(let recordingDevice) = recording.current,
                      let recordingPhysical = physicalDevice(recordingDevice) else { return false }
                return recordingPhysical == key
            }

            /// Report a final status — the watchdog will not override it.
            func settle(_ final: LevelMeterStatus, _ m: InputLevelMonitor) {
                slot.markSettled()
                m.report(final, for: slot.generation)
            }

            // 1. Which physical device, and may we meter it at all?
            let key: String? = {
                guard let m = self, m.isCurrent(slot.generation) else { return nil }   // superseded
                guard let key = physicalDevice(deviceId) else { settle(.unavailable, m); return nil }
                if isRecordingMic(key) { settle(.inUseByRecording, m); return nil }
                return key
            }()
            guard let key else { return }

            // 2. Another start on this device still in flight — stuck, or just another picker opening it:
            // wait for it rather than open the device a second time. Sleeping, never parked in the HAL;
            // the watchdog above says "not responding" if the wait runs long. The loop exits only when
            // the claim succeeds, this slot is superseded (a new start, or stop() — which the picker's
            // onDisappear calls), or the monitor is gone; so behind a start stuck for good it polls for as
            // long as its picker is showing that mic, and at most ~50 ms after it stops.
            // THREAD BUDGET: one sleeping GCD thread per picker showing a stuck mic — in practice at most
            // two pickers are ever open (Settings plus one dialog). See CLAUDE.md (InputLevelMonitor) and
            // #192 before adding another picker.
            while !pending.claim(key) {
                // The exit that bounds this. No release on it: nothing was claimed — claim() has returned
                // false every time so far.
                guard self?.isCurrent(slot.generation) == true else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }

            // 3. Build it — on this queue, never the caller's.
            let session: LevelMeterSession? = {
                guard let m = self, m.isCurrent(slot.generation) else { return nil }
                // Again: the recording may have switched to this very mic while step 2 waited.
                if isRecordingMic(key) { settle(.inUseByRecording, m); return nil }
                guard let made = makeSession(deviceId, slot.generation, m) else { settle(.unavailable, m); return nil }
                return m.isCurrent(slot.generation) ? made : nil               // superseded while building
            }()
            // EVERY nil from step 3 — superseded, "In use" on the re-check, "Unavailable" — lands here, so
            // the claim taken in step 2 is always given back. A new early return inside that closure must
            // return nil, never exit the block, or the device stays claimed.
            guard let session else { pending.release(key); return }
            slot.session = session

            // 4. Start it.
            session.startRunning()   // may block for a long time, or forever — only this queue waits
            slot.markSettled()
            // The registry tracks starts IN FLIGHT, not sessions: once this start has returned, another
            // picker may open the same mic — two live meters on one device are normal (Settings plus a
            // dialog). So a new slot can start before a superseded one's queued stopRunning() has run;
            // that brief overlap is the same harmless case. The hazard (#192) is the recording's mic,
            // which RecordingMicrophone keeps every meter off.
            pending.release(key)
            // Superseded while starting: retire() already queued this session's stop behind us.
            guard let m = self, m.isCurrent(slot.generation) else { return }
            m.report(.live, for: slot.generation)
        }
    }

    /// Stop monitoring and reset level to zero. Returns immediately: the blocking `stopRunning()` is
    /// queued behind the session's own start, on that session's queue.
    @MainActor
    public func stop() {
        retire(detach())
        status = .off
        level = 0.0
    }

    /// Stop, then wait until the device is actually let go — its `stopRunning()` has returned — so
    /// another client can open it without contending with this session: the capture helper opening
    /// the mic this meter was showing (#192). Bounded: returns false if the release took longer than
    /// `timeout`. The budget runs from THIS call, so a start still stuck in `startRunning()` uses it up —
    /// the stop can only run once that start returns, and it still does, later. The caller goes ahead
    /// either way; it just never waits forever.
    @MainActor
    public func stopAndRelease(timeout: TimeInterval) async -> Bool {
        let old = detach()
        status = .off
        level = 0.0
        guard let old else { return true }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            retire(old) { once.resume(true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }

    deinit {
        // No observable writes during teardown — only make sure the device is released.
        retire(detach())
    }

    /// Supersede whatever is running: bump the generation and hand back the slot to retire.
    private func detach() -> Slot? {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        let old = current
        current = nil
        return old
    }

    /// Queue a slot's stop behind its own start, then call `released`. Serial per-slot queue, so this
    /// runs after `startRunning()` returns, however long that takes — on that queue, never the caller's.
    private func retire(_ slot: Slot?, then released: (@Sendable () -> Void)? = nil) {
        guard let slot else { released?(); return }
        slot.queue.async {
            slot.session?.stopRunning()
            slot.session = nil
            released?()
        }
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    /// Publish `newStatus` unless the session it describes has been superseded by then.
    private func report(_ newStatus: LevelMeterStatus, for gen: UInt64) {
        publish { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.status = newStatus
        }
    }

    /// Publish a level measured by the session of `generation`. Levels from any other session — one the
    /// user switched away from, whose async stop has not landed yet — are dropped, so the old mic can
    /// never show on the new mic's meter.
    /// Internal, not fileprivate: `levelFromSupersededSessionIsDropped` drives it directly (test seam).
    func receiveLevel(_ normalized: Float, generation gen: UInt64) {
        publish { [weak self] in
            guard let self, self.isCurrent(gen), self.status == .live else { return }
            self.level = normalized
        }
    }

    // MARK: - Production session

    /// Build — but do not start — a capture session feeding this monitor. Runs on the session's queue.
    private func makeCaptureSession(deviceId: String?, generation: UInt64) -> LevelMeterSession? {
        let device: AVCaptureDevice?
        if let deviceId {
            device = AVCaptureDevice(uniqueID: deviceId)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { return nil }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return nil }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { return nil }
            let proxy = LevelDelegateProxy(monitor: self, generation: generation)
            output.setSampleBufferDelegate(proxy, queue: processingQueue)
            session.addOutput(output)
            return CaptureLevelSession(session: session, proxy: proxy)
        } catch {
            // Device unavailable or permission denied
            return nil
        }
    }

    /// Normalized level (0–1) of one buffer, or nil if it cannot be read.
    fileprivate func normalizedLevel(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        // Determine format to compute RMS correctly
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return nil }

        let rawRMS: Float
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 samples
            let sampleCount = lengthAtOffset / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)
            rawRMS = computeRMSFloat(floatPtr, count: sampleCount)
        } else {
            // Int16 samples (common for USB devices)
            let sampleCount = lengthAtOffset / MemoryLayout<Int16>.size
            let int16Ptr = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: sampleCount)
            rawRMS = computeRMSInt16(int16Ptr, count: sampleCount)
        }
        return dBNormalize(rawRMS)
    }

    // MARK: - Private

    func computeRMSFloat(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<count {
            let s = samples[i]
            sum += s * s
        }
        return sqrt(sum / Float(count))
    }

    func computeRMSInt16(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<count {
            let s = Float(samples[i]) / 32768.0
            sum += s * s
        }
        return sqrt(sum / Float(count))
    }

    func dBNormalize(_ rawRMS: Float) -> Float {
        guard rawRMS > 0 else { return 0.0 }
        let db = 20.0 * log10(rawRMS)
        let minDb: Float = -50.0
        let normalized = (db - minDb) / (0.0 - minDb)
        return min(max(normalized, 0.0), 1.0)
    }
}

/// Receives buffers for ONE session and forwards them tagged with that session's generation. Holds the
/// monitor weakly: an output keeps its delegate alive, so a strong reference would form the cycle
/// monitor → session → output → delegate → monitor, and the monitor could never deinit.
private final class LevelDelegateProxy: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var monitor: InputLevelMonitor?
    let generation: UInt64

    init(monitor: InputLevelMonitor, generation: UInt64) {
        self.monitor = monitor
        self.generation = generation
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let monitor, let level = monitor.normalizedLevel(of: sampleBuffer) else { return }
        monitor.receiveLevel(level, generation: generation)
    }
}

/// The production session: an AVCaptureSession plus the delegate proxy it must keep alive. Owned here
/// as well as by the output, because whether an output retains its delegate is not documented.
private final class CaptureLevelSession: LevelMeterSession {
    let session: AVCaptureSession
    let proxy: LevelDelegateProxy

    init(session: AVCaptureSession, proxy: LevelDelegateProxy) {
        self.session = session
        self.proxy = proxy
    }

    func startRunning() { session.startRunning() }
    func stopRunning() { session.stopRunning() }
}
