import AudioToolbox
import AVFoundation
import Foundation
import os
import ScreenCaptureKit
import TranscriberCore

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let systemWriter: WavFileWriter
    private let micWriter: WavFileWriter
    private var detectedSystemRate = false
    private let micConverter = AudioConverter()

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter

        // Mic writer always gets normalized 48kHz mono Int16
        micWriter.setSampleRate(UInt32(AudioConverter.outputSampleRate))
        micWriter.setChannelCount(UInt16(AudioConverter.outputChannelCount))
    }

    func finalizeAll() {
        systemWriter.finalize()
        micWriter.finalize()
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
    }

    // MARK: - System audio (unchanged — ScreenCaptureKit normalizes via config)

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        if !detectedSystemRate {
            detectedSystemRate = true
            if let info = formatInfo(from: sampleBuffer) {
                systemWriter.setSampleRate(UInt32(info.rate))
                systemWriter.setChannelCount(UInt16(info.channels))
                Logger.audio.info("System audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
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
        Logger.audio.debug("System frame: \(totalLength) bytes")
    }

    // MARK: - Mic audio (normalized via AudioConverter)

    private func handleMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let inputFormat = AVAudioFormat(streamDescription: asbd)!
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

        // Copy raw bytes into the PCM buffer's channel data (non-interleaved)
        // or AudioBufferList (interleaved)
        if let channelData = pcmBuffer.floatChannelData {
            memcpy(channelData[0], ptr, totalLength)
        } else if let channelData = pcmBuffer.int16ChannelData {
            memcpy(channelData[0], ptr, totalLength)
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
            Logger.audio.debug("Mic frame: \(frameCount) in → \(result.samples.count) out (48kHz mono)")
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
