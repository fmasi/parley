import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import TranscriberCore

/// Captures **system output audio** via a Core Audio *global output* process tap
/// (`AudioHardwareCreateProcessTap` + a private aggregate device + an `AudioDeviceIOProc`), as the
/// selectable alternative to the ScreenCaptureKit system stream (#103, phase 2).
///
/// Why this exists: SCK captures only *shareable content* audio, so it returns silence for
/// Continuity / iPhone-relay telephony and some VoIP — validated on-device (the phase-1 spike measured
/// the tap 15–45 dB above SCK's noise floor for a real relayed call). A global output tap captures a
/// **strict superset** of SCK: all system output regardless of which process or output device produced
/// it. The phase-1 spike also confirmed the tap is **route-independent for content** — the aggregate's
/// main sub-device only supplies a clock; the captured audio is the whole system mix.
///
/// Pipeline fit: this is a drop-in for the SCK system source. Each tap buffer (float32 @ the output
/// device's rate, usually stereo) is normalized to Parley's canonical **48 kHz mono Int16** via the
/// same `AudioConverter` the mic path uses, then handed to `AudioOutputHandler.appendSystemSamples`
/// exactly as SCK buffers feed `handleSystemAudio`. Everything downstream (timeline anchor, chunk
/// rotation, stereo-AAC archive, VAD, diarization, echo-dedup) is unchanged. The mic path (#96,
/// `MicCaptureSession`) is untouched.
///
/// Concurrency: the IOProc block is dispatched on the capture service's single persistent `audioQueue`
/// (the `deliveryQueue`), so tap appends serialize with mic appends, chunk-rotation writer swaps, and
/// finalization on ONE serial queue — preserving the single-writer-queue invariant. Running file I/O on
/// this queue cannot glitch playback: the tap only receives *copies* of the output mix; it does not
/// drive the real output device.
final class SystemTapSession {
    private let deliveryQueue: DispatchQueue
    /// Delivers normalized 48 kHz mono Int16 system samples + a host-clock PTS (aligned with the mic's
    /// AVCapture PTS — both are mach host time) on the `deliveryQueue`.
    private let onSamples: ([Int16], CMTime) -> Void
    /// Records a diagnostic event (build, rebuild, error) into the helper's anomaly ring.
    var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?
    /// Invoked if the tap cannot be (re)built — e.g. the System Audio Recording TCC grant is missing,
    /// or an output-switch rebuild fails. The caller decides how to surface it.
    var onUnavailable: ((String) -> Void)?

    /// Converts each tap buffer (float32 @ output rate, stereo) → 48 kHz mono Int16. Reused across
    /// IOProc invocations; only ever touched on `deliveryQueue` (serial), so no lock needed.
    private let converter = AudioConverter()

    /// Serializes every build / output-switch rebuild / stop so a HAL output-change rebuild can't race
    /// a user stop into two aggregate devices. `AudioDeviceStart`/destroy happen here, never under
    /// `stateLock`.
    private let configQueue = DispatchQueue(label: "system-tap.config")
    /// Guards the CoreAudio object ids + the listener block + stopping flag. A leaf lock — its critical
    /// sections never call CoreAudio — so it can't deadlock with `configQueue`.
    private let stateLock = DispatchQueue(label: "system-tap.state")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID: String?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var bytesPerFrame: UInt32 = 0
    private var isStopping = false

    /// Serial queue the HAL property-listener block runs on (never the audio/main queue).
    private let monitorQueue = DispatchQueue(label: "system-tap.device-monitor")
    /// Retained so the SAME reference can be passed to remove it (Swift boxes a fresh block per call).
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Private aggregate UID prefix — also used to sweep orphans from a prior crash on startup.
    private static let aggregateUIDPrefix = "eu.fmasi.parley.system-tap."

    init(deliveryQueue: DispatchQueue, onSamples: @escaping ([Int16], CMTime) -> Void) {
        self.deliveryQueue = deliveryQueue
        self.onSamples = onSamples
    }

    // stop() (not just stopDeviceMonitoring) so a partial start() failure — createTap() succeeds but
    // buildAggregateAndStart() throws — doesn't leak the HAL-level process tap. The caller (startSystemTap)
    // never retains the session on a throw, so this is the only place that cleanup runs. Idempotent.
    deinit { stop() }

    // MARK: - Lifecycle

    /// Create the tap + aggregate + IOProc and start capture. Throws (failing the whole start) if the
    /// tap or aggregate can't be created — most likely a missing System Audio Recording TCC grant.
    func start() throws {
        stateLock.sync { isStopping = false }
        Self.sweepOrphanedAggregates()
        try configQueue.sync {
            try createTap()
            try buildAggregateAndStart()
        }
        startDeviceMonitoring()
    }

    /// Stop capture and destroy all CoreAudio objects. Idempotent.
    func stop() {
        stateLock.sync { isStopping = true }
        stopDeviceMonitoring()
        configQueue.sync { teardownIO(); destroyTap() }
    }

    // MARK: - Tap + aggregate construction (on configQueue)

    private func createTap() throws {
        // Global tap, exclude nothing — this helper renders no audio of its own.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Parley System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // keep the call/meeting audible while we capture it

        var id = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &id)
        guard st == noErr, id != kAudioObjectUnknown else {
            throw SystemTapError.tapCreateFailed(st)
        }
        stateLock.sync {
            tapID = id
            tapUUID = desc.uuid.uuidString
        }
        Logger.audio.info("System tap created — id \(id), uuid \(desc.uuid.uuidString, privacy: .public)")
    }

    /// Build a private aggregate device around the CURRENT default output + the tap, read the tap
    /// format, install the IOProc on `deliveryQueue`, and start. Called on initial start and on each
    /// output-switch rebuild. Must run on `configQueue`.
    private func buildAggregateAndStart() throws {
        let (tap, uuid) = stateLock.sync { (tapID, tapUUID) }
        guard tap != kAudioObjectUnknown, let uuid else { throw SystemTapError.noTap }

        let output = Self.defaultOutputDevice()
        guard output != kAudioObjectUnknown, let outUID = Self.deviceUID(output) else {
            throw SystemTapError.noDefaultOutput
        }

        let aggUID = Self.aggregateUIDPrefix + uuid
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Parley System Tap Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: uuid,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggSt = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aggSt == noErr, agg != kAudioObjectUnknown else {
            throw SystemTapError.aggregateCreateFailed(aggSt)
        }

        // The format the IOProc actually delivers is the AGGREGATE's input-stream format, which follows
        // the output device's rate — e.g. it drops to 24 kHz when AirPods switch to call/hands-free mode.
        // The tap's own `kAudioTapPropertyFormat` can report a DIFFERENT (higher) rate; trusting it made
        // the AudioConverter think the input was already 48 kHz, skip resampling, and write low-rate
        // samples under a 48 kHz header → chipmunk playback of the remote. So read the aggregate input
        // stream's virtual format as the source of truth, and fall back to the tap format only if that
        // read fails.
        var asbd = AudioStreamBasicDescription()
        var tapFmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let tapFmtOK = AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &tapFmt) == noErr
        if let aggFmt = Self.aggregateInputFormat(agg), aggFmt.mSampleRate > 0 {
            asbd = aggFmt
            if tapFmtOK, tapFmt.mSampleRate != aggFmt.mSampleRate {
                Logger.audio.warning("System tap: aggregate delivers \(aggFmt.mSampleRate)Hz but tap reports \(tapFmt.mSampleRate)Hz — using aggregate rate (avoids chipmunk)")
            }
        } else if tapFmtOK {
            Logger.audio.warning("System tap: aggregate input stream not yet readable — falling back to tap-reported format (\(tapFmt.mSampleRate)Hz), which can be the wrong rate (chipmunk risk)")
            asbd = tapFmt
        } else {
            AudioHardwareDestroyAggregateDevice(agg)
            throw SystemTapError.formatReadFailed
        }
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(agg)
            throw SystemTapError.formatReadFailed
        }

        // Install the IOProc on the SHARED audio queue so its appends serialize with the mic + writer
        // swaps + finalize. The block is `@Sendable`-safe: it only reads immutable captured state
        // (format, converter on this serial queue) and calls onSamples on the same queue.
        var proc: AudioDeviceIOProcID?
        let ioSt = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, deliveryQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleTapBuffers(inInputData, inInputTime)
        }
        guard ioSt == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(agg)
            throw SystemTapError.ioProcCreateFailed(ioSt)
        }

        let startSt = AudioDeviceStart(agg, proc)
        guard startSt == noErr else {
            AudioDeviceDestroyIOProcID(agg, proc)
            AudioHardwareDestroyAggregateDevice(agg)
            throw SystemTapError.deviceStartFailed(startSt)
        }

        stateLock.sync {
            aggregateID = agg
            procID = proc
            tapFormat = avFormat
            bytesPerFrame = asbd.mBytesPerFrame
        }
        Logger.audio.info("System tap aggregate started — output \(Self.deviceName(output), privacy: .public), delivery format \(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch (converter → 48000Hz 1ch)")
        // Surface the REAL tap delivery format for provenance/diagnostics — the WAV is always the
        // normalized 48 kHz mono, but the source rate is what reveals a chipmunk-class mismatch.
        // Use the standard "rate"/"channels" keys the app's provenance formatter reads, so
        // system_format shows the REAL device delivery rate (e.g. "24000Hz/2ch") — the value that
        // reveals a chipmunk-class mismatch. The WAV itself is still normalized 48 kHz mono.
        onEvent?(.systemFormatDetected, .info, [
            "source": "tap",
            "rate": "\(Int(asbd.mSampleRate))",
            "channels": "\(asbd.mChannelsPerFrame)",
            "normalized": "48000Hz/1ch",
        ])
    }

    /// The `AudioStreamBasicDescription` the aggregate device's input stream will actually deliver to
    /// the IOProc. This is the authoritative delivery format (it tracks the output device's current
    /// rate); the tap's own `kAudioTapPropertyFormat` can disagree. Returns nil if the aggregate has no
    /// readable input stream yet, in which case the caller falls back to the tap format.
    private static func aggregateInputFormat(_ agg: AudioObjectID) -> AudioStreamBasicDescription? {
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(agg, &streamsAddr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(agg, &streamsAddr, 0, nil, &size, &streams) == noErr,
              let stream = streams.first else { return nil }
        var fmt = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fsize, &fmt) == noErr else { return nil }
        return fmt
    }

    /// Stop + destroy the IOProc and aggregate (NOT the tap). Used by stop() and by an output-switch
    /// rebuild. Must run on `configQueue`. Idempotent.
    private func teardownIO() {
        let (agg, proc) = stateLock.sync { () -> (AudioObjectID, AudioDeviceIOProcID?) in
            let a = aggregateID, p = procID
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
            // Clear so mid-rebuild IOProc callbacks hit the same nil-format guard as initial start,
            // instead of converting against the stale pre-rebuild format (wrong rate/channel count
            // if the new output device differs, e.g. speakers -> AirPods).
            tapFormat = nil
            bytesPerFrame = 0
            return (a, p)
        }
        if agg != kAudioObjectUnknown, let proc {
            AudioDeviceStop(agg, proc)
            AudioDeviceDestroyIOProcID(agg, proc)
        }
        if agg != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(agg)
        }
    }

    private func destroyTap() {
        let tap = stateLock.sync { () -> AudioObjectID in
            let t = tapID
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapUUID = nil
            return t
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - IOProc (runs on deliveryQueue)

    /// Wrap the tap's pulled buffers into an AVAudioPCMBuffer matching the tap format, normalize to
    /// 48 kHz mono Int16 via the shared converter, and deliver with a host-clock PTS. Runs on the
    /// capture service's audio queue.
    private func handleTapBuffers(
        _ inInputData: UnsafePointer<AudioBufferList>, _ inInputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let (format, bpf, stopping) = stateLock.sync { (tapFormat, bytesPerFrame, isStopping) }
        guard !stopping, let format, bpf > 0 else { return }

        let srcABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard srcABL.count > 0 else { return }
        let frames = Int(srcABL[0].mDataByteSize) / Int(bpf)
        guard frames > 0 else { return }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        // The PCM buffer was created with the SAME format as the tap, so its AudioBufferList layout
        // matches `srcABL` buffer-for-buffer (interleaved or not) — copy each buffer's bytes directly.
        let dstABL = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<min(dstABL.count, srcABL.count) {
            guard let dst = dstABL[i].mData, let src = srcABL[i].mData else { continue }
            memcpy(dst, src, min(Int(dstABL[i].mDataByteSize), Int(srcABL[i].mDataByteSize)))
        }

        let samples: [Int16]
        do {
            samples = try converter.convert(pcm).samples
        } catch {
            Logger.audio.error("System tap conversion failed: \(error, privacy: .public)")
            return
        }
        guard !samples.isEmpty else { return }

        // PTS on the mach host clock — same epoch as the mic's AVCapture sample PTS, so the shared
        // timeline anchor in AudioOutputHandler aligns the two sources. Fall back to "now" if the IO
        // timestamp lacks a valid host time.
        let host = inInputTime.pointee.mHostTime
        let nanos = host != 0 ? AudioConvertHostTimeToNanos(host)
                              : AudioConvertHostTimeToNanos(mach_absolute_time())
        let pts = CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000)
        onSamples(samples, pts)
    }

    // MARK: - Default-output monitoring (HAL) — clock continuity across output switches

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Watch the default OUTPUT device. The global tap captures system-wide content regardless of route
    /// (validated in the phase-1 spike), so this is NOT about content — it keeps the aggregate's CLOCK
    /// alive: the aggregate's main sub-device is the default output at build time, and if that device
    /// goes away (speakers → AirPods, or unplug) the IOProc stalls until we rebuild the aggregate around
    /// the new default. Mirrors MicCaptureSession's HAL input listener (gotcha #55).
    private func startDeviceMonitoring() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleOutputReevaluation()
        }
        let shouldRegister: Bool = stateLock.sync {
            guard outputListenerBlock == nil else { return false }
            outputListenerBlock = block
            return true
        }
        guard shouldRegister else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.defaultOutputAddress
        let st = AudioObjectAddPropertyListenerBlock(system, &addr, monitorQueue, block)
        if st != noErr {
            Logger.audio.error("System tap: default-output HAL listener registration failed (\(st))")
            onEvent?(.streamStopError, .anomaly, ["source": "system-tap", "reason": "output monitor unavailable", "status": "\(st)"])
        }
    }

    private func stopDeviceMonitoring() {
        let block: AudioObjectPropertyListenerBlock? = stateLock.sync {
            let b = outputListenerBlock
            outputListenerBlock = nil
            return b
        }
        guard let block else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.defaultOutputAddress
        _ = AudioObjectRemovePropertyListenerBlock(system, &addr, monitorQueue, block)
    }

    /// Cancellable pending rebuild, so a burst of HAL notifications from one output switch collapses
    /// into a single rebuild instead of one per notification. Only touched on `monitorQueue`.
    private var reevaluationItem: DispatchWorkItem?

    /// Debounce a burst of HAL notifications (a single output switch fires several) and let the new
    /// route settle before rebuilding. Runs on `monitorQueue`.
    private func scheduleOutputReevaluation() {
        reevaluationItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rebuildForOutputChange() }
        reevaluationItem = item
        monitorQueue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Rebuild the aggregate + IOProc around the new default output, keeping the same global tap. Runs
    /// the actual rebuild on `configQueue` (serialized against stop and other rebuilds).
    private func rebuildForOutputChange() {
        if stateLock.sync(execute: { isStopping }) { return }
        configQueue.async { [weak self] in
            guard let self else { return }
            if self.stateLock.sync(execute: { self.isStopping }) { return }
            self.teardownIO()
            do {
                try self.buildAggregateAndStart()
                Logger.audio.info("System tap rebuilt around new default output")
                self.onEvent?(.restartInPlace, .warning, ["source": "system-tap", "reason": "output device changed"])
            } catch {
                Logger.audio.error("System tap rebuild after output change failed: \(error, privacy: .public)")
                self.onEvent?(.restartFailed, .anomaly, ["source": "system-tap", "reason": "output rebuild failed", "error": "\(error)"])
                self.onUnavailable?("System audio tap could not follow the output device change")
            }
        }
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (uid as String) : nil
    }

    private static func deviceName(_ device: AudioObjectID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (name as String) : "?"
    }

    /// Destroy any private aggregate devices left over from a prior helper crash (their tap is already
    /// gone). Mirrors the spike's startup sweep; safe because the UID prefix is Parley-specific.
    private static func sweepOrphanedAggregates() {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return }
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return }
        for dev in devices {
            guard let uid = deviceUID(dev), uid.hasPrefix(aggregateUIDPrefix) else { continue }
            let st = AudioHardwareDestroyAggregateDevice(dev)
            Logger.audio.info("System tap swept orphaned aggregate \(uid, privacy: .public): \(st == noErr ? "ok" : "\(st)", privacy: .public)")
        }
    }
}

enum SystemTapError: LocalizedError {
    case tapCreateFailed(OSStatus)
    case noTap
    case noDefaultOutput
    case aggregateCreateFailed(OSStatus)
    case formatReadFailed
    case ioProcCreateFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreateFailed(let st):
            return "Could not create the system-audio tap (\(st)) — grant System Audio Recording in System Settings › Privacy & Security"
        case .noTap:
            return "System-audio tap missing"
        case .noDefaultOutput:
            return "No default output device to tap"
        case .aggregateCreateFailed(let st):
            return "Could not create the tap aggregate device (\(st))"
        case .formatReadFailed:
            return "Could not read the system-audio tap format"
        case .ioProcCreateFailed(let st):
            return "Could not install the system-audio IO callback (\(st))"
        case .deviceStartFailed(let st):
            return "Could not start the system-audio tap device (\(st))"
        }
    }
}
