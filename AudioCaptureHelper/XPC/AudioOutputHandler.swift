import AudioToolbox
import Foundation
import os
import ScreenCaptureKit
import TranscriberCore

final class AudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private let systemWriter: WavFileWriter
    private let micWriter: WavFileWriter
    private var detectedSystemRate = false
    private var detectedMicRate = false

    init(systemWriter: WavFileWriter, micWriter: WavFileWriter) {
        self.systemWriter = systemWriter
        self.micWriter = micWriter
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
        let writer: WavFileWriter
        if type == .audio {
            if !detectedSystemRate {
                detectedSystemRate = true
                if let info = formatInfo(from: sampleBuffer) {
                    systemWriter.setSampleRate(UInt32(info.rate))
                    systemWriter.setChannelCount(UInt16(info.channels))
                    Logger.audio.info("System audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
                }
            }
            writer = systemWriter
        } else if type == .microphone {
            if !detectedMicRate {
                detectedMicRate = true
                if let info = formatInfo(from: sampleBuffer) {
                    micWriter.setSampleRate(UInt32(info.rate))
                    micWriter.setChannelCount(UInt16(info.channels))
                    Logger.audio.info("Mic audio: \(Int(info.rate))Hz, \(info.channels)ch, \(info.isFloat ? "Float32" : "Int16", privacy: .public)")
                }
            }
            writer = micWriter
        } else {
            return
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
                writer.append(UnsafeBufferPointer(start: floatPtr, count: count))
            }
        } else {
            let count = totalLength / MemoryLayout<Int16>.size
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { int16Ptr in
                writer.appendInt16(UnsafeBufferPointer(start: int16Ptr, count: count))
            }
        }
        Logger.audio.debug("\(type == .audio ? "System" : "Mic", privacy: .public) frame: \(totalLength) bytes")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.audio.error("Stream stopped with error: \(error, privacy: .public)")
    }

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
