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

    /// Rates that only ever appear because a Bluetooth link dropped to a hands-free profile
    /// (A2DP -> HFP). A 44.1 kHz output is perfectly healthy and must NOT trigger re-anchoring:
    /// substituting the clock for a device that is fine is a risk with no upside.
    private static let handsFreeRates: Set<Int> = [8000, 16000, 24000, 32000]

    /// Rate-drift watchdog. If the device silently changes rate underneath us (Bluetooth A2DP -> HFP
    /// is NOT a device change, so no output-switch listener fires), the IOProc keeps delivering
    /// against a stale format: fewer frames arrive than the declared rate implies, the writer pads
    /// silence to hold the wall clock, and the result is 2x-fast speech interleaved with gaps —
    /// correct duration, corrupt content. Nothing in the pipeline noticed. Compare delivered frames
    /// against elapsed host time and surface it.
    ///
    /// Rate-drift state machine (extracted + unit-tested in `RateDriftMonitor`). Scoped to an
    /// aggregate GENERATION, not the session: a rebuild has a dead window with no frames while the
    /// host clock runs, which reads as a frame deficit — so it must be `reset()` on every teardown,
    /// or it false-fires on the rebuild and then latches itself off for the rest of the meeting.
    /// Mutated only under `stateLock`.
    private var driftMonitor = RateDriftMonitor()

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
        guard output != kAudioObjectUnknown, Self.deviceUID(output) != nil else {
            throw SystemTapError.noDefaultOutput
        }

        // Choose the device that CLOCKS the capture aggregate.
        //
        // The tap is a global PROCESS tap: it carries the source audio at full rate (its own
        // kAudioTapPropertyFormat reports 48 kHz) no matter what the user is listening on. But the
        // aggregate is clocked by its main sub-device, and if that is a Bluetooth headset in HFP
        // call mode the IOProc fires at the headset's 24 kHz cadence — so only half the frames ever
        // arrive and the writer pads silence to hold the wall clock. Pinning the aggregate's nominal
        // rate does NOT fix this (measured: it reports 48 kHz and still delivers 24 kHz).
        //
        // So when the default output is degraded, clock the aggregate off a full-rate device
        // instead. The tap still captures everything (it is not bound to a device), it just gets
        // carried on an undegraded clock. The user keeps listening on their headset; we simply stop
        // letting their headset's limitations dictate what we record.
        var anchor = output
        let outputRate = Int(Self.deviceNominalRate(output).rounded())
        if Self.handsFreeRates.contains(outputRate) {
            if let fullRate = Self.fullRateOutputDevice(minimum: 44100), fullRate != output {
                Logger.audio.info(
                    "System tap: output device \(Self.deviceName(output), privacy: .public) is at \(outputRate, privacy: .public)Hz (degraded) — clocking capture off \(Self.deviceName(fullRate), privacy: .public) at \(Self.deviceNominalRate(fullRate), privacy: .public)Hz instead"
                )
                anchor = fullRate
            } else {
                // Degraded output and NO full-rate device to clock off (a Mac with no built-in
                // output, headset as the only device). We are about to capture the remote side at
                // the headset's hands-free rate. Say so at setup rather than leaving it to the
                // watchdog, which only fires 5+ seconds in.
                Logger.audio.error(
                    "System tap: output device is at \(outputRate, privacy: .public)Hz (hands-free) and no full-rate device is available to clock the capture — remote audio will be captured at reduced quality"
                )
                onEvent?(.rateDrift, .anomaly, [
                    "source": "system-tap",
                    "reason": "degraded output rate, no full-rate anchor available",
                    "outputRate": "\(outputRate)",
                ])
            }
        }
        guard let outUID = Self.deviceUID(anchor) else {
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
        // On a rebuild the just-created aggregate's input stream can be briefly unreadable, so poll it
        // for a short bounded window before falling back to the tap-reported rate (which may be the
        // wrong rate → chipmunk). Runs on configQueue (the build path), never the audio path, so a
        // short sleep is acceptable; ≤~105ms worst case and only when the stream is slow to appear (#111).
        var aggFmt: AudioStreamBasicDescription?
        for attempt in 0..<8 {
            if let f = Self.aggregateInputFormat(agg), f.mSampleRate > 0 { aggFmt = f; break }
            if attempt < 7 { Thread.sleep(forTimeInterval: 0.015) }
        }
        if let aggFmt {
            asbd = aggFmt
            // Diagnostic: the rate story in one line. `tap` is the source's own rate; `aggregate`
            // is what we will actually receive. They diverge exactly when the output device is
            // degraded (AirPods HFP), which is the quality loss we are trying to eliminate.
            Logger.audio.info(
                "System tap rates — tap: \(tapFmtOK ? tapFmt.mSampleRate : 0, privacy: .public)Hz, aggregate(delivered): \(aggFmt.mSampleRate, privacy: .public)Hz, output device: \(Self.deviceNominalRate(output), privacy: .public)Hz"
            )
            if tapFmtOK, tapFmt.mSampleRate != aggFmt.mSampleRate {
                Logger.audio.warning("System tap: aggregate delivers \(aggFmt.mSampleRate)Hz but tap reports \(tapFmt.mSampleRate)Hz — using aggregate rate (avoids chipmunk)")
            }
        } else if tapFmtOK {
            Logger.audio.warning("System tap: aggregate input stream not readable after retries — falling back to tap-reported format (\(tapFmt.mSampleRate)Hz), which can be the wrong rate (chipmunk risk)")
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

        // Publish the delivery format BEFORE starting the device (#111). AudioDeviceStart delivers on
        // deliveryQueue — a different queue from this configQueue build — so a callback can fire the
        // instant Start returns. Committing tapFormat/bytesPerFrame first means those first frames pass
        // the handleTapBuffers guard with the correct format, instead of reading a nil format and being
        // dropped (then silence-padded). Previously the commit happened after Start, so the leading
        // frames after every start AND every output-switch rebuild were lost to silence.
        // aggregateID/procID stay unset until Start succeeds so teardown never targets a dead aggregate;
        // handleTapBuffers doesn't read those, only tapFormat/bytesPerFrame/isStopping.
        stateLock.sync {
            tapFormat = avFormat
            bytesPerFrame = asbd.mBytesPerFrame
        }

        let startSt = AudioDeviceStart(agg, proc)
        guard startSt == noErr else {
            // Roll back the just-published format so a failed start leaves no stale state behind.
            stateLock.sync { tapFormat = nil; bytesPerFrame = 0 }
            AudioDeviceDestroyIOProcID(agg, proc)
            AudioHardwareDestroyAggregateDevice(agg)
            throw SystemTapError.deviceStartFailed(startSt)
        }

        stateLock.sync {
            aggregateID = agg
            procID = proc
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
            // Reset the monitor under the same lock: the next generation must not be judged against
            // frames delivered by the previous one, across a dead rebuild window.
            driftMonitor.reset()
            return (a, p)
        }
        // Concurrency note (#112): the IOProc block runs on `deliveryQueue`, a different queue from
        // this `configQueue` teardown, so a callback can be in flight here. We rely on CoreAudio's
        // documented contract that `AudioDeviceStop` blocks until any executing IOProc has returned
        // before it completes — so once Stop returns, no callback is running and the subsequent
        // DestroyIOProcID/DestroyAggregateDevice cannot race a live `srcABL` read in handleTapBuffers.
        // (The nil-format guard set above is a second layer: a callback that already passed the guard
        // finishes under Stop's barrier; one that hasn't yet reads the nil format and bails.)
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

        // Watchdog: delivered frames vs wall clock. A sustained shortfall means the declared format
        // no longer matches what the device is really producing.
        checkRateDrift(frames: frames, declaredRate: format.sampleRate, hostNanos: {
            let h = inInputTime.pointee.mHostTime
            return h != 0 ? AudioConvertHostTimeToNanos(h) : AudioConvertHostTimeToNanos(mach_absolute_time())
        }())

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
        if let block {
            let system = AudioObjectID(kAudioObjectSystemObject)
            var addr = Self.defaultOutputAddress
            _ = AudioObjectRemovePropertyListenerBlock(system, &addr, monitorQueue, block)
        }
        // Listener removed first (so no new rebuild can be scheduled), then cancel any already-pending
        // debounced rebuild so it doesn't fire after stop() or keep a [weak self] closure alive (#112).
        // reevaluationItem is monitorQueue-confined; the sync also serializes AFTER any in-flight
        // listener block, so an item that block just scheduled is cancelled too.
        monitorQueue.sync {
            reevaluationItem?.cancel()
            reevaluationItem = nil
        }
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

    /// Compare frames actually delivered against elapsed wall time. Runs on the audio queue, so it
    /// does only integer arithmetic. Reports once per session — this is a persistent condition, not
    /// a transient glitch, and the recording is already compromised by the time we can tell.
    private func checkRateDrift(frames: Int, declaredRate: Double, hostNanos: UInt64) {
        guard declaredRate > 0 else { return }

        // ONE lock acquisition for the WHOLE decision — the monitor's accumulate/judge/latch must
        // advance atomically, or a teardown landing mid-decision reopens the exact race this closes.
        let verdict = stateLock.sync {
            driftMonitor.record(frames: frames, declaredRate: declaredRate, hostNanos: hostNanos)
        }

        guard case .drift(let effectiveRate, let ratio) = verdict else { return }

        Logger.audio.error(
            """
            System tap RATE DRIFT: declared \(declaredRate, privacy: .public)Hz but the device is delivering \
            ~\(Int(effectiveRate), privacy: .public)Hz (\(Int(ratio * 100), privacy: .public)%). The output \
            device changed rate underneath the tap — remote audio is being captured at the wrong rate and \
            padded to fit. Output device now reports \
            \(Self.deviceNominalRate(Self.defaultOutputDevice()), privacy: .public)Hz.
            """
        )
        onEvent?(.rateDrift, .anomaly, [
            "source": "system-tap",
            "reason": "rate drift — output device changed rate under the tap",
            "declared": "\(Int(declaredRate))",
            "actual": "\(Int(effectiveRate))",
        ])
    }

    /// An output device running at or above `minimum` Hz, preferring the built-in one.
    /// Used to clock the capture aggregate when the user's actual output device is degraded
    /// (Bluetooth HFP), so a headset's bandwidth limit cannot dictate our recording quality.
    static func fullRateOutputDevice(minimum: Double) -> AudioObjectID? {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return nil }

        // Built-in first, unconditionally: it cannot be unplugged, so it can't strand the aggregate.
        // We only listen for changes to the DEFAULT output device — if our anchor is something else
        // and it disappears, the IOProc stalls with no notification and nothing notices.
        for device in devices where hasOutputStreams(device) && isBuiltIn(device) {
            if deviceNominalRate(device) >= minimum { return device }
        }
        // Fallback: a physical, non-virtual device. Virtual/aggregate devices (ZoomAudioDevice,
        // BlackHole, Krisp) are exactly the ones that appear and vanish under us.
        for device in devices
        where hasOutputStreams(device) && deviceNominalRate(device) >= minimum && !isVirtual(device) {
            return device
        }
        return nil
    }

    /// Virtual and aggregate devices come and go with the apps that install them — never a safe clock.
    private static func isVirtual(_ device: AudioObjectID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return true }   // unknown transport: treat as unsafe
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func isBuiltIn(_ device: AudioObjectID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    /// Current nominal sample rate of a device — diagnostic only. Reveals when the output device
    /// has dropped to a hands-free rate underneath us.
    static func deviceNominalRate(_ device: AudioObjectID) -> Double {
        guard device != kAudioObjectUnknown else { return 0 }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return st == noErr ? Double(rate) : 0
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
