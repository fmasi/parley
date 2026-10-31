import AVFoundation
import Foundation

/// Reads an audio file as mono Float32 at 16 kHz a block at a time (#342): what `AudioDecode.mono16kHzFloat`
/// does for a whole file, without holding the file. One `AVAudioConverter` keeps its resampling state across
/// blocks, so the stream is continuous.
final class Mono16kReader {
    static let sampleRate: Double = 16_000

    private let file: AVAudioFile
    private let nativeMono: AVAudioFormat
    private let resampler: AVAudioConverter?
    private let nativeBlock: AVAudioFrameCount
    private var fileDone = false
    private var finished = false
    /// A compressed file (AAC) whose stated length is only an estimate: a read that throws after real
    /// audio is its padded tail. Never true for PCM (WAV), whose length is exact: there a throw is a real
    /// read error and is reported.
    let lengthIsEstimate: Bool

    /// The file's length as 16 kHz samples (its stated length, converted): what a complete read returns,
    /// give or take the resampler's rounding.
    var expectedFrames: Int {
        Int((Double(file.length) * Self.sampleRate / file.processingFormat.sampleRate).rounded())
    }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        lengthIsEstimate = file.fileFormat.streamDescription.pointee.mFormatID != kAudioFormatLinearPCM
        let rate = file.processingFormat.sampleRate
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                                         interleaved: false)
        else { throw AudioDecode.DecodeError.formatCreationFailed }
        nativeMono = mono
        nativeBlock = AVAudioFrameCount(max(4096, Int(rate)))
        if rate == Self.sampleRate {
            resampler = nil
        } else {
            guard let converter = AVAudioConverter(from: mono, to: target) else {
                throw AudioDecode.DecodeError.converterCreationFailed
            }
            resampler = converter
        }
    }

    /// Up to `maxFrames` samples; empty once the file is exhausted.
    func read(maxFrames: Int) throws -> [Float] {
        guard !finished, maxFrames > 0 else { return [] }
        guard let resampler else {
            let block = try nextNativeMono(maxFrames: AVAudioFrameCount(maxFrames))
            if block == nil { finished = true }
            return block.map { Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) } ?? []
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                                         interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(maxFrames))
        else { throw AudioDecode.DecodeError.bufferAllocationFailed }
        var pullError: Error?
        var error: NSError?
        let status = resampler.convert(to: out, error: &error) { [self] _, status in
            do {
                guard let block = try nextNativeMono(maxFrames: nativeBlock) else {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return block
            } catch {
                pullError = error
                status.pointee = .endOfStream
                return nil
            }
        }
        if let pullError { throw pullError }
        guard status != .error else { throw AudioDecode.DecodeError.conversionFailed(error) }
        if status == .endOfStream || (status == .inputRanDry && out.frameLength == 0) { finished = true }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// The next block of the file at its own rate, mixed to mono; nil at the end.
    private func nextNativeMono(maxFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard !fileDone else { return nil }
        let remaining = AVAudioFrameCount(max(0, file.length - file.framePosition))
        guard remaining > 0,
              let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(maxFrames, remaining))
        else { fileDone = true; return nil }
        do {
            try file.read(into: raw)
        } catch where lengthIsEstimate && file.framePosition > 0 {
            // Only a compressed file's padded tail (its length is an estimate), past real audio, as
            // FluidAudio's own reader treats it. A PCM read error propagates.
            fileDone = true
            return nil
        }
        guard raw.frameLength > 0 else { fileDone = true; return nil }
        let format = raw.format
        if format.channelCount == 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved { return raw }
        let samples = try AudioDecode.monoFloat32(from: raw)
        guard let mono = AVAudioPCMBuffer(pcmFormat: nativeMono, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioDecode.DecodeError.bufferAllocationFailed
        }
        mono.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { mono.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return mono
    }
}

/// Writes a mono Float32 WAV a block at a time.
final class MonoWavWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    init(url: URL, sampleRate: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
                                         interleaved: false)
        else { throw AudioDecode.DecodeError.formatCreationFailed }
        self.format = format
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard samples.count > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioDecode.DecodeError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        try file.write(from: buffer)
    }

    func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try write($0) }
    }
}
