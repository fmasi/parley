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
    func release(_ key: String) { lock.lock(); keys.remove(key); lock.unlock() }
    func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.contains(key) }
}

/// Told about every change to a `RecordingMicrophone`, on the main actor.
@MainActor
public protocol RecordingMicrophoneObserver: AnyObject {
    func recordingMicrophoneChanged(to device: String??)
}

/// The microphone the recording is capturing from, process-wide, so no level meter opens it while the
/// capture helper holds it: opening a mic the helper has running is the exact `startRunning()` that
/// hung on 2026-09-10 (#192). Set by `RecordingCoordinator` and by the relaunch re-attach paths; the
/// coordinator mirrors it for the menu's mic label, so every writer keeps that label right too.
public final class RecordingMicrophone: @unchecked Sendable {
    public static let shared = RecordingMicrophone()
    private let lock = NSLock()
    private var device: String?? = .none
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
        lock.lock(); observers.add(observer); lock.unlock()
    }

    /// Main-actor only, so observers are told synchronously and stay exactly in step with `current`.
    @MainActor private func update(_ value: String??) {
        lock.lock()
        device = value
        let targets = observers.allObjects
        lock.unlock()
        for case let observer as RecordingMicrophoneObserver in targets {
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
        private var started = false
        init(generation: UInt64) {
            self.generation = generation
            // Numbered, so several pickers' sessions are told apart in a sample or crash report.
            self.queue = DispatchQueue(label: "input-level-monitor.session.\(generation)")
        }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func markStarted() { lock.lock(); started = true; lock.unlock() }
    }

    public override init() {
        self.makeSession = { deviceId, generation, monitor in
            monitor.makeCaptureSession(deviceId: deviceId, generation: generation)
        }
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
            // `self` is only ever held briefly below — never across a wait or the blocking start — so a
            // monitor dropped meanwhile can still deinit and retire the session.

            // 1. Which physical device, and may we meter it at all?
            let key: String? = {
                guard let m = self, m.isCurrent(slot.generation) else { return nil }   // superseded
                guard let key = physicalDevice(deviceId) else {
                    m.report(.unavailable, for: slot.generation); return nil
                }
                if case .some(let recordingDevice) = recording.current, physicalDevice(recordingDevice) == key {
                    m.report(.inUseByRecording, for: slot.generation); return nil
                }
                return key
            }()
            guard let key else { return }

            // 2. Another start on this device still in flight — stuck, or just another picker opening it:
            // wait for it rather than open the device a second time. Sleeping, never parked in the HAL;
            // "not responding" once the wait runs long; given up the moment this start is superseded.
            let waitBegan = Date()
            var saidNotResponding = false
            while !pending.claim(key) {
                guard let m = self, m.isCurrent(slot.generation) else { return }
                if !saidNotResponding, Date().timeIntervalSince(waitBegan) >= unresponsiveAfter {
                    m.report(.notResponding, for: slot.generation)
                    saidNotResponding = true
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            // 3. Build it — on this queue, never the caller's.
            let session: LevelMeterSession? = {
                guard let m = self, m.isCurrent(slot.generation) else { return nil }
                guard let made = makeSession(deviceId, slot.generation, m) else {
                    m.report(.unavailable, for: slot.generation); return nil
                }
                return m.isCurrent(slot.generation) ? made : nil               // superseded while building
            }()
            guard let session else { pending.release(key); return }
            slot.session = session

            // 4. Start it. Say so if that is slow — decided ON the publish executor, where `.live` is also
            // set, so a start that finishes just as this fires can never be left showing "not responding".
            weak var monitor = self
            DispatchQueue.global().asyncAfter(deadline: .now() + unresponsiveAfter) {
                publish {
                    guard let monitor, monitor.isCurrent(slot.generation), !slot.hasStarted else { return }
                    monitor.status = .notResponding
                }
            }
            session.startRunning()   // may block for a long time, or forever — only this queue waits
            slot.markStarted()
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
