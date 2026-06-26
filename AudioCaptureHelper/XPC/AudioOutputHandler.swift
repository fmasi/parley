import AudioToolbox
import AVFoundation
import Foundation
import os
import ScreenCaptureKit
import TranscriberCore

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private var systemWriter: WavFileWriter
    private var micWriter: WavFileWriter
    private let systemFormatTracker = SystemFormatTracker()
    private var systemFormatInfo: FormatInfo?
    /// Last mic format seen ("<rate>Hz/<ch>ch[/unsupported]"); re-recorded on change so a mid-stream
    /// mic switch (and its format) is captured in diagnostics + provenance, not just the first one.
    private var lastMicFormatKey: String?
    private let micConverter = AudioConverter()

    /// Shared-timeline anchor for mic/system alignment (#96 / council HOL-1): the PTS of the first
    /// system-audio buffer (the continuous "spine"). The mic runs on an independent AVCaptureSession
    /// whose start latency and route-change recovery gaps would otherwise shift the mic track relative
    /// to system audio — breaking echo-dedup temporal overlap and skewing the stereo archive. The mic
    /// path inserts compensating silence so mic frame N lines up with system frame N. Reset per chunk.
    private var timelineAnchorPTS: CMTime?
    /// Mic frames (48 kHz mono) written to the current chunk, including inserted silence — the mic's
    /// position on the shared timeline. Reset to 0 on each chunk rotation.
    private var micFramesWritten: Int64 = 0

    /// Anomaly-gated diagnostic ring (set by the service). Records format detections/changes and
    /// stream stop errors so an anomalous session can be reconstructed after the fact (#95).
    var diagnostics: LockedDiagnostics?

    /// Invoked when the SCStream stops with an error, so the service can decide whether to restart
    /// in place (benign route change) or surface a fatal failure (#86). Set by the service.
    var onStreamStopped: ((Error) -> Void)?

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter

        // Mic writer always gets normalized 48kHz mono Int16
        micWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        micWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))
    }

    private func record(
        _ kind: CaptureEventKind,
        _ severity: CaptureEvent.Severity,
        _ detail: [String: String] = [:]
    ) {
        diagnostics?.record(CaptureEvent(
            timestamp: Date(), origin: .helper, kind: kind, severity: severity, detail: detail
        ))
    }

    func finalizeAll() {
        systemWriter.finalize()
        micWriter.finalize()
    }

    /// Swap writers for chunk rotation. MUST be called on the audio callback queue.
    /// Returns the old writers' file paths after finalizing them.
    func swapWriters(
        newSystemWriter: WavFileWriter,
        newMicWriter: WavFileWriter
    ) -> (systemPath: String, micPath: String) {
        // Finalize current writers
        systemWriter.finalize()
        micWriter.finalize()

        let oldSystemPath = systemWriter.path
        let oldMicPath = micWriter.path

        // Configure new writers with detected formats
        if let info = systemFormatInfo {
            newSystemWriter.setSampleRate(UInt32(info.rate))
            newSystemWriter.setChannelCount(UInt16(info.channels))
        }
        newMicWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        newMicWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))

        // Atomic swap
        systemWriter = newSystemWriter
        micWriter = newMicWriter

        // Re-anchor the shared timeline for the new chunk: the new writers start at frame 0, so the
        // next system buffer becomes the new spine t=0 and the mic re-aligns from there (#96 / HOL-1).
        timelineAnchorPTS = nil
        micFramesWritten = 0

        return (oldSystemPath, oldMicPath)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // The mic is captured separately via AVCaptureSession (#96); the SCStream delivers system
        // audio only. `.microphone` is no longer registered as an output, so only `.audio` arrives.
        if type == .audio {
            handleSystemAudio(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.audio.error("Stream stopped with error: \(error, privacy: .public)")
        // A benign audio-route change (e.g. AirPods HFP↔A2DP) stops the SCStream without a
        // process crash. Record it and hand off to the service's restart decision (#86) instead
        // of treating it as a terminal failure.
        record(.streamStopError, .anomaly, ["error": "\(error.localizedDescription)"])
        onStreamStopped?(error)
    }

    // MARK: - System audio

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        // Anchor the shared mic/system timeline to the first system buffer — the spine that defines
        // t=0 for this chunk. The mic aligns to it (#96 / council HOL-1).
        if timelineAnchorPTS == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid { timelineAnchorPTS = pts }
        }

        // Per-buffer format tracking (#94): system audio is pinned to 48kHz mono by the stream
        // config, so the steady state is `.first` once then `.unchanged`. A writer-incompatible
        // `.changed` means a transient route anomaly — record it and DROP the buffer rather than
        // appending mismatched samples under the stale WAV header (council F9). The in-place
        // restart reuses the SAME handler/writers/tracker (it does NOT reset them), so if true
        // mid-stream rotation is ever needed the tracker + writer config must be reset explicitly.
        if let info = formatInfo(from: sampleBuffer) {
            let fmt = AudioStreamFormat(
                sampleRate: info.rate, channelCount: Int(info.channels),
                isFloat: info.isFloat, bitsPerChannel: Int(info.bitsPerChannel)
            )
            switch systemFormatTracker.observe(fmt) {
            case .first(let f):
                systemFormatInfo = info
                systemWriter.setSampleRate(UInt32(f.sampleRate))
                systemWriter.setChannelCount(UInt16(f.channelCount))
                Logger.audio.info("System audio: \(Int(f.sampleRate))Hz, \(f.channelCount)ch, \(f.isFloat ? "Float32" : "Int16", privacy: .public)")
                record(.systemFormatDetected, .info, [
                    "rate": "\(Int(f.sampleRate))", "channels": "\(f.channelCount)",
                    "sample": f.isFloat ? "float32" : "int16",
                ])
            case .unchanged:
                break
            case .changed(let from, let to):
                // Log the transition once (observe() reports `.unchanged` for the buffers that
                // follow, since it advances `current`). The sticky gate below is what actually
                // drops them — not this one-shot branch (council FV3).
                Logger.audio.error("System format changed mid-stream: \(Int(from.sampleRate))Hz/\(from.channelCount)ch → \(Int(to.sampleRate))Hz/\(to.channelCount)ch")
                record(.formatChanged, .anomaly, [
                    "from": "\(Int(from.sampleRate))Hz/\(from.channelCount)ch",
                    "to": "\(Int(to.sampleRate))Hz/\(to.channelCount)ch",
                ])
            }

            // Sticky drop: skip ANY buffer whose format is writer-incompatible with the format the
            // writer is actually configured for (set once in `.first`), independent of observe()'s
            // transient/sustained distinction. A single dropped run is harmless — the paired
            // didStopWithError drives the #86 restart that resumes cleanly (council FV3, F9).
            if let cfg = systemFormatInfo {
                let configured = AudioStreamFormat(
                    sampleRate: cfg.rate, channelCount: Int(cfg.channels),
                    isFloat: cfg.isFloat, bitsPerChannel: Int(cfg.bitsPerChannel)
                )
                if !configured.isWriterCompatible(with: fmt) { return }
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let isFloat = isFloatFormat(from: sampleBuffer)
        if isFloat {
            let count = totalLength / MemoryLayout<Float32>.size
            ptr.withMemoryRebound(to: Float32.self, capacity: count) { floatPtr in
                systemWriter.append(UnsafeBufferPointer(start: floatPtr, count: count))
            }
        } else {
            let count = totalLength / MemoryLayout<Int16>.size
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { int16Ptr in
                systemWriter.appendInt16(UnsafeBufferPointer(start: int16Ptr, count: count))
            }
        }
    }

    // MARK: - Mic audio (normalized via AudioConverter)

    /// Append a microphone sample buffer captured by the decoupled `AVCaptureSession` (#96). MUST be
    /// called on the capture service's audio queue — the same serial queue as system-audio callbacks,
    /// writer swaps, and finalize — so all writer access stays single-threaded.
    func appendMicSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let rate = asbd.pointee.mSampleRate

        // The mic comes from a dedicated AVCaptureSession now (#96), which hands us the OS-fused MONO
        // for the built-in mic — so its raw 3-capsule beamforming array is no longer exposed here. A
        // multichannel format still arrives from pro USB interfaces (>2ch). Those channels are
        // undifferentiated, so we average them all into mono (see MultichannelDownmix) rather than
        // dropping the buffer or wastefully keeping one; <=2ch takes the normal converter path below.
        if channels > 2 {
            recordMicFormatIfChanged(rate: rate, channels: channels, supported: true)
            handleMultichannelMic(sampleBuffer, channels: channels, rate: rate, asbd: asbd)
            return
        }

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            recordMicFormatIfChanged(rate: rate, channels: channels, supported: false)
            Logger.audio.error("Mic audio: unsupported format — rate=\(rate) ch=\(channels) flags=\(asbd.pointee.mFormatFlags)")
            return
        }
        recordMicFormatIfChanged(rate: rate, channels: channels, supported: true)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        // Extract AVAudioPCMBuffer from CMSampleBuffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Logger.audio.error("Failed to create PCM buffer for mic audio")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy sample data from CMSampleBuffer into AVAudioPCMBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &rawPtr
        )
        guard status == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        // Copy raw bytes into the PCM buffer's channel data (non-interleaved) or AudioBufferList
        // (interleaved). Clamp every copy to the destination channel's capacity — a route change
        // can briefly deliver a buffer whose byte count exceeds frameLength*sampleSize, and an
        // unbounded memcpy would overrun the heap allocation (#94).
        if let channelData = pcmBuffer.floatChannelData {
            let capacity = Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size
            memcpy(channelData[0], ptr, min(totalLength, capacity))
        } else if let channelData = pcmBuffer.int16ChannelData {
            let capacity = Int(pcmBuffer.frameLength) * MemoryLayout<Int16>.size
            memcpy(channelData[0], ptr, min(totalLength, capacity))
        } else {
            // Interleaved format — copy via AudioBufferList
            let abl = pcmBuffer.mutableAudioBufferList
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count > 0, let dstPtr = buffers[0].mData else { return }
            memcpy(dstPtr, ptr, min(Int(buffers[0].mDataByteSize), totalLength))
        }

        do {
            let result = try micConverter.convert(pcmBuffer)
            appendAlignedMic(result.samples, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } catch {
            Logger.audio.error("Mic audio conversion failed: \(error, privacy: .public)")
        }
    }

    /// Append converted 48 kHz mono mic samples, first inserting compensating silence so the mic WAV
    /// stays aligned to the system-audio spine on a shared timeline (#96 / council HOL-1). One
    /// mechanism covers both the AVCaptureSession start latency (leading silence on the first buffer)
    /// and any route-change recovery gap (silence for the dead interval) — without it the mic track
    /// would drift earlier than system audio, breaking echo-dedup overlap and skewing the stereo
    /// archive. Never trims (we can't un-write); only catches the mic up when it is behind.
    private func appendAlignedMic(_ samples: [Int16], pts: CMTime) {
        if timelineAnchorPTS == nil, pts.isValid { timelineAnchorPTS = pts }
        if let anchor = timelineAnchorPTS, anchor.isValid, pts.isValid {
            let rate = AudioConverter.outputSampleRate  // 48000
            let targetFrame = Int64((CMTimeSubtract(pts, anchor).seconds * rate).rounded())
            var pad = targetFrame - micFramesWritten
            if pad > 0 {
                let maxPad = Int64(rate * 60)  // clamp a pathological gap at 60s of silence
                if pad > maxPad {
                    Logger.audio.error("Mic timeline gap \(Int(Double(pad) / rate))s exceeds 60s cap — clamping")
                    pad = maxPad
                }
                Logger.audio.info("Mic timeline: padding \(Int(Double(pad) / rate * 1000))ms silence to align mic to system spine")
                let silence = [Int16](repeating: 0, count: Int(pad))
                silence.withUnsafeBufferPointer { micWriter.appendInt16($0) }
                micFramesWritten += pad
            }
        }
        samples.withUnsafeBufferPointer { micWriter.appendInt16($0) }
        micFramesWritten += Int64(samples.count)
    }

    /// Record the mic input format, but only when it CHANGES — so a mid-stream mic switch (and an
    /// unsupported format) lands in diagnostics/provenance, not just the first format seen (#95).
    private func recordMicFormatIfChanged(rate: Double, channels: Int, supported: Bool) {
        let key = "\(Int(rate))Hz/\(channels)ch\(supported ? "" : "/unsupported")"
        guard key != lastMicFormatKey else { return }
        lastMicFormatKey = key
        let severity: CaptureEvent.Severity = supported ? (channels > 2 ? .warning : .info) : .anomaly
        record(.micFormatDetected, severity, [
            "rate": "\(Int(rate))", "channels": "\(channels)", "supported": "\(supported)",
        ])
    }

    /// Capture a multichannel (3+) mic by averaging its interleaved channels into a single mono buffer
    /// the AudioConverter can normalize. The channels are undifferentiated (positionless "Discrete"
    /// layout), so an equal-weight average is the correct mixdown and beats picking one channel on SNR.
    /// Handles both float and packed 16-bit-int interleaved input (pro USB interfaces are int); any
    /// other layout is recorded as an anomaly and dropped (council CONC-2).
    private func handleMultichannelMic(
        _ sampleBuffer: CMSampleBuffer, channels: Int, rate: Double,
        asbd: UnsafePointer<AudioStreamBasicDescription>
    ) {
        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.pointee.mBitsPerChannel)
        // Average float or packed 16-bit integer interleaved channels. Anything else (e.g. 24/32-bit
        // int) is genuinely unhandled — record it as an anomaly (not a silent loss) and drop.
        guard isFloat || bits == 16 else {
            recordMicFormatIfChanged(rate: rate, channels: channels, supported: false)
            Logger.audio.error("Mic audio: unhandled \(bits)-bit non-float \(channels)ch format — dropping")
            return
        }
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let dst = monoBuffer.floatChannelData?[0],
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frameCount)

        var lengthAtOffset = 0, totalLength = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &rawPtr
        ) == kCMBlockBufferNoErr, let ptr = rawPtr else { return }

        let written: Int
        if isFloat {
            let srcCount = totalLength / MemoryLayout<Float32>.size
            written = ptr.withMemoryRebound(to: Float32.self, capacity: srcCount) { src in
                MultichannelDownmix.averageInterleavedToMono(
                    src, srcCount: srcCount, channels: channels, into: dst, frameCount: frameCount
                )
            }
        } else {
            let srcCount = totalLength / MemoryLayout<Int16>.size
            written = ptr.withMemoryRebound(to: Int16.self, capacity: srcCount) { src in
                MultichannelDownmix.averageInterleavedInt16ToMono(
                    src, srcCount: srcCount, channels: channels, into: dst, frameCount: frameCount
                )
            }
        }
        guard written > 0 else { return }
        monoBuffer.frameLength = AVAudioFrameCount(written)

        do {
            let result = try micConverter.convert(monoBuffer)
            appendAlignedMic(result.samples, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } catch {
            Logger.audio.error("Mic audio conversion failed (multichannel): \(error, privacy: .public)")
        }
    }

    // MARK: - Format helpers (system audio only)

    private struct FormatInfo {
        let rate: Double
        let channels: UInt32
        let isFloat: Bool
        let bitsPerChannel: UInt32
    }

    private func formatInfo(from buf: CMSampleBuffer) -> FormatInfo? {
        guard let fmt = CMSampleBufferGetFormatDescription(buf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let p = asbd.pointee
        return FormatInfo(
            rate: p.mSampleRate,
            channels: p.mChannelsPerFrame,
            isFloat: p.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            bitsPerChannel: p.mBitsPerChannel
        )
    }

    private func isFloatFormat(from buf: CMSampleBuffer) -> Bool {
        return formatInfo(from: buf)?.isFloat ?? true
    }
}
