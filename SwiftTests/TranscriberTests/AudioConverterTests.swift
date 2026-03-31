import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioConverterTests {

    // MARK: - Helpers

    /// Create an AVAudioPCMBuffer with Float32 samples at a given rate/channels.
    private func makeFloat32Buffer(
        samples: [Float],
        sampleRate: Double,
        channels: UInt32
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: channels > 1
        )!
        let frameCount = UInt32(samples.count) / channels
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if channels > 1 {
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        } else {
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        }
        return buffer
    }

    // MARK: - Conversion output format

    @Test func outputIsAlways48kHzMonoInt16() throws {
        let converter = AudioConverter()
        // Use enough samples for AVAudioConverter's resampler to produce output
        let input = makeFloat32Buffer(
            samples: Array(repeating: Float(0.5), count: 160),
            sampleRate: 16000,
            channels: 1
        )
        let result = try converter.convert(input)
        #expect(result.sampleRate == 48000)
        #expect(result.channelCount == 1)
        #expect(!result.samples.isEmpty)
    }

    @Test func convertsFrom48kHzStereoToMono() throws {
        let converter = AudioConverter()
        let input = makeFloat32Buffer(
            samples: [0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3],
            sampleRate: 48000,
            channels: 2
        )
        let result = try converter.convert(input)
        #expect(result.sampleRate == 48000)
        #expect(result.channelCount == 1)
        #expect(result.samples.count == 4)
    }

    @Test func handlesFormatChange() throws {
        let converter = AudioConverter()
        // Use enough samples for resampler to produce output at 16kHz→48kHz
        let input1 = makeFloat32Buffer(
            samples: Array(repeating: Float(0.1), count: 160),
            sampleRate: 16000,
            channels: 1
        )
        let result1 = try converter.convert(input1)
        #expect(result1.sampleRate == 48000)

        let input2 = makeFloat32Buffer(
            samples: [0.5, 0.3, 0.5, 0.3],
            sampleRate: 48000,
            channels: 2
        )
        let result2 = try converter.convert(input2)
        #expect(result2.sampleRate == 48000)
        #expect(result2.channelCount == 1)
    }

    @Test func outputSamplesAreReasonable() throws {
        let converter = AudioConverter()
        let input = makeFloat32Buffer(
            samples: [0.5, 0.5, 0.5, 0.5],
            sampleRate: 48000,
            channels: 1
        )
        let result = try converter.convert(input)
        for sample in result.samples {
            #expect(abs(Int32(sample) - 16383) < 100)
        }
    }

    @Test func sameSampleRatePassthrough() throws {
        let converter = AudioConverter()
        let input = makeFloat32Buffer(
            samples: [0.0, 1.0, -1.0, 0.5],
            sampleRate: 48000,
            channels: 1
        )
        let result = try converter.convert(input)
        #expect(result.samples.count == 4)
    }
}
