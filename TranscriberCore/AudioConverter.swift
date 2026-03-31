import AVFoundation
import os

/// Converts arbitrary PCM audio buffers to a fixed 48kHz mono Int16 format.
/// Handles sample rate conversion, channel downmixing, and format normalization
/// via AVAudioConverter. Detects source format changes (e.g., after a mic switch)
/// and recreates the internal converter automatically.
public final class AudioConverter {
    public static let outputSampleRate: Double = 48000
    public static let outputChannelCount: UInt32 = 1

    /// The fixed output format: 48kHz mono Int16
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: outputSampleRate,
        channels: AVAudioChannelCount(outputChannelCount),
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    public struct Result {
        public let samples: [Int16]
        public let sampleRate: Double
        public let channelCount: UInt32

        public init(samples: [Int16], sampleRate: Double, channelCount: UInt32) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    public init() {}

    /// Convert an AVAudioPCMBuffer (any supported PCM format) to 48kHz mono Int16.
    /// Creates or replaces the internal AVAudioConverter when the input format changes.
    public func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> Result {
        let inputFormat = inputBuffer.format

        // Rebuild converter if input format changed
        if converter == nil || lastInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
                throw AudioConverterError.cannotCreateConverter(
                    from: inputFormat.description, to: Self.outputFormat.description
                )
            }
            newConverter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = newConverter
            lastInputFormat = inputFormat
            Logger.audio.info(
                "AudioConverter: new converter \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch \u{2192} 48000Hz 1ch"
            )
        }

        guard let converter else {
            throw AudioConverterError.converterNotAvailable
        }

        // Calculate output frame count
        let ratio = Self.outputSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioConverterError.cannotCreateOutputBuffer
        }

        var inputConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw AudioConverterError.conversionFailed(conversionError.localizedDescription)
        }
        if status == .error {
            throw AudioConverterError.conversionFailed("AVAudioConverter returned error status")
        }

        // Extract Int16 samples from output buffer
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            return Result(samples: [], sampleRate: Self.outputSampleRate, channelCount: Self.outputChannelCount)
        }

        let int16Ptr = outputBuffer.int16ChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: int16Ptr, count: frameCount))

        return Result(
            samples: samples,
            sampleRate: Self.outputSampleRate,
            channelCount: Self.outputChannelCount
        )
    }
}

public enum AudioConverterError: LocalizedError {
    case cannotCreateConverter(from: String, to: String)
    case converterNotAvailable
    case cannotCreateOutputBuffer
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateConverter(let from, let to):
            return "Cannot create audio converter from \(from) to \(to)"
        case .converterNotAvailable:
            return "Audio converter not available"
        case .cannotCreateOutputBuffer:
            return "Cannot create output buffer"
        case .conversionFailed(let msg):
            return "Audio conversion failed: \(msg)"
        }
    }
}
