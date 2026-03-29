import Foundation
import ScreenCaptureKit

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
                if let rate = sampleRate(from: sampleBuffer) {
                    systemWriter.setSampleRate(UInt32(rate))
                }
            }
            writer = systemWriter
        } else if type == .microphone {
            if !detectedMicRate {
                detectedMicRate = true
                if let rate = sampleRate(from: sampleBuffer) {
                    micWriter.setSampleRate(UInt32(rate))
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

        let count = totalLength / MemoryLayout<Float32>.size
        ptr.withMemoryRebound(to: Float32.self, capacity: count) { floatPtr in
            writer.append(UnsafeBufferPointer(start: floatPtr, count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Log or propagate error
    }

    private func sampleRate(from buf: CMSampleBuffer) -> Double? {
        guard let fmt = CMSampleBufferGetFormatDescription(buf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        return asbd.pointee.mSampleRate
    }
}
