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
/// The scan reads live state, so listener storms are harmless, and a wake that arrives after a scan has
/// begun schedules the next one — the final wake of a burst is never dropped. Output: a
/// `CaptureSnapshot` of raw bundle IDs running input IO, delivered **on the sensor queue**. No
/// classification, no policy — that is the engine's.
///
/// Cost when idle: zero timers and zero periodic wakeups. The only timers are one-shots — the coalescing
/// delay, and the engine's `scheduleScan(after:)` stop debounce. Nothing here ever arms a repeating timer.
final class MeetingSensor {
    private let queue = DispatchQueue(label: "eu.fmasi.parley.meeting-sensor", qos: .utility)
    private let onSnapshot: @Sendable (CaptureSnapshot) -> Void
    private let signposter = OSSignposter(subsystem: "eu.fmasi.parley", category: "meeting-sensor")

    // All state below is touched only on `queue` (deinit excepted — see there).
    private var running = false
    private var scanPending = false
    private var oneShot: DispatchWorkItem?
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenedDevices: Set<AudioObjectID> = []
    private var listenedProcesses: Set<AudioObjectID> = []
    private var watchedBundleIDs: Set<String> = []
    /// Process object → bundle ID from the last scan (only for capturing or watched processes).
    private var processBundleIDs: [AudioObjectID: String] = [:]
    /// Which classes of listener-add failure have already been reported. Per class, so one failing device
    /// cannot silence every future process failure; cleared by `stopOnQueue` so a later session reports
    /// afresh.
    private enum AddFailure { case device, process }
    private var loggedAddFailures: Set<AddFailure> = []

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// How long wakes fold together before one scan runs.
    private static let coalesceWindow: TimeInterval = 0.25
    /// Release fallback: how long between re-reads of the watched apps' `IsRunningInput` while a watch is
    /// armed (i.e. only during a recording with a meeting app in it). See the arming site in `scan()`.
    private static let releaseRecheck: TimeInterval = 10

    init(onSnapshot: @escaping @Sendable (CaptureSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    deinit {
        // Deliberately NOT `queue.sync`: the last strong reference can be held by a block already on
        // `queue` (the one `stop()` enqueues), in which case deinit runs ON `queue` and a sync would
        // deadlock; deinit can equally land on main, where a blocking HAL call is what gotcha #68
        // forbids. Reading the queue-confined state here is safe precisely because it is deinit — no
        // other reference to `self` exists any more (Swift zeroes weak references before deinit runs),
        // so the listener blocks that would race this can no longer resolve `self`. The registrations
        // are handed to the queue as plain values, so the HAL Removes still happen off main and off
        // whatever thread dropped the last reference.
        Self.removeListeners(block: listener, devices: listenedDevices, processes: listenedProcesses,
                             queue: queue, synchronously: false)
    }

    // MARK: - Public (thread-safe; every call hops to the queue)

    func start() { queue.async { self.startOnQueue() } }
    func stop() { queue.async { self.stopOnQueue() } }

    /// The engine's `.watch(bundleIDs:)`: hold per-process listeners on exactly these bundle IDs.
    func setWatched(bundleIDs: Set<String>) {
        queue.async {
            self.watchedBundleIDs = bundleIDs
            guard self.running else { return }
            guard !bundleIDs.isEmpty else {
                self.reconcileProcessListeners()   // removes everything; no need to re-read the HAL
                return
            }
            // A full scan, not a bare reconcile: while the watch set was empty, the last scan recorded
            // bundle IDs only for *capturing* processes, so reconciling against that map would arm
            // listeners on the watched app's capturing process alone and miss the non-capturing helpers
            // that also connect to the HAL. And during a recording Parley's own helper masks the device
            // signal, so no wake is guaranteed to arrive later to repair the map.
            self.scan()
        }
    }

    /// The engine's `.scheduleScan(after:)`: a one-shot that runs an ordinary scan. Replaces any pending one.
    ///
    /// It fires `wake()`, not `scan()`, so the scan lands one coalescing window later: the engine's 30 s
    /// stop debounce is 30.25 s in practice (and the 10 s release re-read below, 10.25 s). Deliberate —
    /// the deadline is a floor, not a promise, and routing every scan through `wake()` keeps a timer and a
    /// HAL wake that land together from running two scans.
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
            // Losing these means losing every start-of-call wake — the sensor would be silently inert.
            Logger.audio.error("Meeting sensor: system HAL listener registration failed (\(s1), \(s2))")
        }
        // TODO(Task 0): confirm WHICH of these wake signals actually fires when a call starts, per app
        // (device `IsRunningSomewhere`, system `ProcessObjectList`, or both) and the start→wake latency.
        // The spike's table answers it. If neither fires for a browser tab that joins a call while the
        // input device is already open by something else, the start offer is missed entirely and another
        // signal is needed here — so nothing in this registration set may be dropped as redundant until
        // the spike has spoken.
        scan()   // first scan: one-time HAL client init (~50 ms measured) — here, never on main
        Logger.audio.info("Meeting sensor started — \(self.listenedDevices.count) input device listener(s)")
    }

    /// Releases EVERY listener this sensor registered. Deliberately independent of any engine action:
    /// with the mode `.off` while recording the engine emits no `.watch` at all, so the per-process
    /// listeners must be cleared here rather than by an instruction that may never arrive.
    private func stopOnQueue() {
        guard running, let block = listener else { return }
        running = false
        oneShot?.cancel()
        oneShot = nil
        scanPending = false
        Self.removeListeners(block: block, devices: listenedDevices, processes: listenedProcesses,
                             queue: queue, synchronously: true)
        listenedDevices = []
        listenedProcesses = []
        // Stale AudioObjectIDs must not survive a restart; `watchedBundleIDs` does survive on purpose —
        // it is the engine's last standing instruction, and the first scan after a restart re-arms from
        // it without waiting for the engine to repeat itself.
        processBundleIDs = [:]
        loggedAddFailures = []
        listener = nil
        Logger.audio.info("Meeting sensor stopped")
    }

    // MARK: - Wake + scan (on queue)

    private func wake() {
        guard running, !scanPending else { return }
        scanPending = true
        queue.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in self?.scan() }
    }

    private func scan() {
        // Cleared FIRST so a wake that lands while this scan is queued behind us schedules the next one
        // — the last event of a burst always gets a scan after it.
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
        // The COUNT stays public so the log is usable for triage; the bundle IDs are `.private` because
        // "which apps are using your microphone" is exactly the kind of thing an airgapped product must
        // not write into the unified log in the clear (gotcha #56 territory).
        Logger.audio.debug("""
            Meeting sensor scan: \(processes.count) processes, \
            \(capturing.count, privacy: .public) capturing \
            [\(capturing.sorted().joined(separator: ", "), privacy: .private)]
            """)
        onSnapshot(CaptureSnapshot(capturingBundleIDs: capturing))
        // Release fallback. The per-process `IsRunningInput` listeners are the intended release signal,
        // but nothing proves they fire on release in a release build, and during a recording Parley's own
        // helper holds the device, so the device-level signal cannot see the call app let go either. With
        // no wake, the stop offer could never come — so while, and ONLY while, a watch is armed (which is
        // only ever during a recording with a meeting app in it) re-read on a 10 s one-shot.
        //
        // Why this can never cost anything when idle: an empty watch set arms nothing, and the watch set
        // is empty except between the engine's `.watch(ids)` and its `.watch([])` on leaving `.recording`.
        // `scheduleScan` REPLACES the pending one-shot rather than adding one, so timers never accumulate;
        // when the recording ends, the last armed one-shot fires once more, finds the watch empty and
        // re-arms nothing. (`running` is already guarded at the top of this scan, and `stop()` cancels the
        // one-shot outright.) Delete this block if the device test shows the listeners do fire.
        if !watchedBundleIDs.isEmpty { scheduleScan(after: Self.releaseRecheck) }
    }

    // MARK: - Listener reconciliation (on queue)

    private func reconcileDeviceListeners() {
        guard let block = listener else { return }
        let allDevices = Set(Self.objectList(Self.system, kAudioHardwarePropertyDevices))
        let inputDevices = allDevices.filter(Self.hasInput)
        let plan = ListenerReconcile.plan(current: listenedDevices, desired: inputDevices)
        guard !plan.isEmpty else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for device in plan.add {
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
            if status == noErr {
                listenedDevices.insert(device)
            } else {
                logOnce(.device, "device listener add failed: \(status)")
            }
        }
        for device in plan.remove {
            let status = AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            // A device that has vanished is the normal case and its Remove is best-effort. A failure on a
            // device the HAL still lists is different: the registration probably still exists, so keep the
            // entry and let the next reconcile (or `stop()`) try again, rather than forgetting a listener
            // the HAL is still holding.
            if status != noErr, allDevices.contains(device) {
                Logger.audio.debug("Meeting sensor: remove listener on live device \(device) → \(status)")
                continue
            }
            listenedDevices.remove(device)
        }
    }

    private func reconcileProcessListeners() {
        guard let block = listener else { return }
        let targets = ListenerReconcile.watchTargets(processBundleIDs: processBundleIDs,
                                                     watched: watchedBundleIDs)
        let plan = ListenerReconcile.plan(current: listenedProcesses, desired: targets)
        guard !plan.isEmpty else { return }
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        for process in plan.add {
            let status = AudioObjectAddPropertyListenerBlock(process, &address, queue, block)
            if status == noErr {
                listenedProcesses.insert(process)
            } else {
                logOnce(.process, "process listener add failed: \(status)")
            }
        }
        for process in plan.remove {
            // TODO(Task 0): a Remove on a Process object that has already died is expected to return a
            // non-zero OSStatus while leaking nothing — the spike's `--churn` run (100 process
            // births/deaths) confirms it by a flat RSS and a listener count that returns to its start.
            // If it DOES leak, the watch set must be bounded and re-registered from scratch instead.
            // Debug level on purpose: a vanished object is the normal case, not a fault.
            let status = AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            if status != noErr {
                // A failure on a process the HAL still lists probably means the registration survives, so
                // keep the entry rather than forgetting a listener `stop()` would then never release.
                // Checked only on failure, so the extra HAL read costs nothing in the normal path.
                let stillLive = Self.objectList(Self.system, kAudioHardwarePropertyProcessObjectList)
                    .contains(process)
                Logger.audio.debug("Meeting sensor: remove listener on process \(process) → \(status), still listed: \(stillLive)")
                if stillLive { continue }
            }
            listenedProcesses.remove(process)
        }
    }

    private func logOnce(_ kind: AddFailure, _ message: String) {
        guard loggedAddFailures.insert(kind).inserted else { return }
        Logger.audio.error("Meeting sensor: \(message, privacy: .public)")
    }

    /// Unregisters every listener held on `devices`, `processes` and the system object. MUST be reached
    /// on `queue` — either already there (`synchronously: true`) or via the hop this takes for deinit,
    /// which cannot touch `self`.
    private static func removeListeners(
        block: AudioObjectPropertyListenerBlock?,
        devices: Set<AudioObjectID>,
        processes: Set<AudioObjectID>,
        queue: DispatchQueue,
        synchronously: Bool
    ) {
        guard let block else { return }
        let work = {
            var deviceList = address(kAudioHardwarePropertyDevices)
            var processList = address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(system, &deviceList, queue, block)
            _ = AudioObjectRemovePropertyListenerBlock(system, &processList, queue, block)
            var deviceRunning = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            for device in devices {
                _ = AudioObjectRemovePropertyListenerBlock(device, &deviceRunning, queue, block)
            }
            var processInput = address(kAudioProcessPropertyIsRunningInput)
            for process in processes {
                _ = AudioObjectRemovePropertyListenerBlock(process, &processInput, queue, block)
            }
        }
        if synchronously { work() } else { queue.async(execute: work) }
    }

    // MARK: - Core Audio property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &list) == noErr else { return [] }
        // The second call reports how much it ACTUALLY wrote. If the population shrank between the size
        // probe and the read, the tail is still zeroes (`kAudioObjectUnknown`) and must not come back as
        // real objects.
        let returned = Int(size) / MemoryLayout<AudioObjectID>.stride
        if returned < list.count { list.removeLast(list.count - returned) }
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
