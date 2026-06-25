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
    private var micFormatDetected = false
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
        // `.changed` means a transient route anomaly — record it loudly rather than silently
        // writing mismatched samples under a stale header; the paired didStopWithError drives the
        // #86 in-place restart, which opens fresh writers that re-detect cleanly.
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
                Logger.audio.error("System format changed mid-stream: \(Int(from.sampleRate))Hz/\(from.channelCount)ch → \(Int(to.sampleRate))Hz/\(to.channelCount)ch")
                record(.formatChanged, .anomaly, [
                    "from": "\(Int(from.sampleRate))Hz/\(from.channelCount)ch",
                    "to": "\(Int(to.sampleRate))Hz/\(to.channelCount)ch",
                ])
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

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            Logger.audio.error("Mic audio: unsupported format — rate=\(asbd.pointee.mSampleRate) ch=\(asbd.pointee.mChannelsPerFrame) flags=\(asbd.pointee.mFormatFlags)")
            return
        }
        if !micFormatDetected {
            micFormatDetected = true
            record(.micFormatDetected, .info, [
                "rate": "\(Int(asbd.pointee.mSampleRate))",
                "channels": "\(asbd.pointee.mChannelsPerFrame)",
            ])
        }
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
