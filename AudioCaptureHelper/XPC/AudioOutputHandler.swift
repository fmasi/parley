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

        return (oldSystemPath, oldMicPath)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .audio {
            handleSystemAudio(sampleBuffer)
        } else if type == .microphone {
            handleMicAudio(sampleBuffer)
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

    private func handleMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let rate = asbd.pointee.mSampleRate

        // macOS built-in mic arrays present 3+ interleaved channels, which
        // AVAudioFormat(streamDescription:) rejects (returns nil) — the likely root cause of the
        // "it used the wrong microphone, my voice was missing" reports when a route change falls
        // back to the built-in mic. Down-pick channel 0 (the primary capsule) into a mono buffer the
        // converter can normalize, instead of dropping every buffer.
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
            result.samples.withUnsafeBufferPointer { micWriter.appendInt16($0) }
        } catch {
            Logger.audio.error("Mic audio conversion failed: \(error, privacy: .public)")
        }
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

    /// Capture a multichannel (3+) mic by extracting channel 0 (the primary capsule) into a mono
    /// buffer the AudioConverter can normalize. The built-in mic array delivers interleaved float
    /// here; a non-float multichannel layout (not observed in practice) is dropped with a clear log.
    private func handleMultichannelMic(
        _ sampleBuffer: CMSampleBuffer, channels: Int, rate: Double,
        asbd: UnsafePointer<AudioStreamBasicDescription>
    ) {
        guard asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            Logger.audio.error("Mic audio: unhandled non-float \(channels)ch format — dropping")
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

        let srcCount = totalLength / MemoryLayout<Float32>.size
        ptr.withMemoryRebound(to: Float32.self, capacity: srcCount) { src in
            // De-interleave channel 0: samples at indices 0, channels, 2*channels, …
            var f = 0, i = 0
            while f < frameCount && i < srcCount {
                dst[f] = src[i]
                f += 1
                i += channels
            }
        }

        do {
            let result = try micConverter.convert(monoBuffer)
            result.samples.withUnsafeBufferPointer { micWriter.appendInt16($0) }
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
