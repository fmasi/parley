import Foundation

/// A snapshot of an audio stream's PCM format.
public struct AudioStreamFormat: Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let isFloat: Bool
    public let bitsPerChannel: Int

    public init(sampleRate: Double, channelCount: Int, isFloat: Bool, bitsPerChannel: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isFloat = isFloat
        self.bitsPerChannel = bitsPerChannel
    }

    /// Two formats are "writer-compatible" when the dimensions that define the WAV header
    /// match. Sample storage (float vs int, bit depth) is normalized to Int16 by the writer,
    /// so only sample rate + channel count gate a writer reconfiguration.
    public func isWriterCompatible(with other: AudioStreamFormat) -> Bool {
        sampleRate == other.sampleRate && channelCount == other.channelCount
    }
}

/// Tracks the system-audio format across sample buffers and reports transitions, so a
/// mid-stream route/format change (e.g. AirPods connect) can rotate the WAV writer instead of
/// appending mismatched samples into a header that no longer describes them (#94).
public final class SystemFormatTracker {
    public enum Observation: Equatable {
        case first(AudioStreamFormat)
        case unchanged
        case changed(from: AudioStreamFormat, to: AudioStreamFormat)
    }

    public private(set) var current: AudioStreamFormat?

    public init() {}

    public func observe(_ format: AudioStreamFormat) -> Observation {
        guard let existing = current else {
            current = format
            return .first(format)
        }
        if existing.isWriterCompatible(with: format) {
            return .unchanged
        }
        current = format
        return .changed(from: existing, to: format)
    }
}
