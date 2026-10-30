import Foundation

/// The safety net behind mic echo cancellation (#342): echo left in a transcript can be seen and
/// flagged, but a word the canceller removed is silent loss. So wherever the far end has been silent
/// (no echo can exist) and the raw mic has sound, the cleaned mic may not be much quieter than the
/// raw one. Each 100 ms frame that is gets the raw mic back, with short crossfades.
///
/// Pure: samples in, samples and a count out. Every threshold is in `Parameters`.
public enum NearEndGuard {
    public struct Parameters: Equatable, Sendable {
        public var frameSeconds = 0.1
        /// The reference counts as silent below this RMS (dBFS), in every frame within `silenceMarginSeconds`.
        public var farEndSilentDBFS = -55.0
        public var silenceMarginSeconds = 0.5
        /// The raw mic counts as having sound at or above this RMS (dBFS).
        public var micActiveDBFS = -45.0
        /// A frame is reverted when the cleaned mic is at least this much quieter than the raw mic.
        public var maxCutDB = 20.0
        public var crossfadeSeconds = 0.05
        public init() {}
    }

    public struct Result: Equatable, Sendable {
        public let samples: [Float]
        /// How many frames got the raw mic back.
        public let revertedFrames: Int
    }

    /// `microphone`, `cleaned` and `reference` are one stream each, same sample rate. `cleaned` must be
    /// as long as `microphone`; a shorter `reference` counts as silent past its end.
    public static func apply(microphone: [Float], cleaned: [Float], reference: [Float], sampleRate: Int,
                             parameters p: Parameters = Parameters()) -> Result {
        precondition(microphone.count == cleaned.count, "cleaned and raw mic must be the same length")
        let frame = max(1, Int((p.frameSeconds * Double(sampleRate)).rounded()))
        let frames = (microphone.count + frame - 1) / frame
        guard frames > 0 else { return Result(samples: cleaned, revertedFrames: 0) }

        let micDB = levels(microphone, frame: frame, frames: frames)
        let cleanDB = levels(cleaned, frame: frame, frames: frames)
        let refDB = levels(reference, frame: frame, frames: frames)
        let margin = Int((p.silenceMarginSeconds / p.frameSeconds).rounded())

        // Far end silent across the margin: a sliding count of loud reference frames.
        var loud = [Int](repeating: 0, count: frames + 1)
        for i in 0..<frames { loud[i + 1] = loud[i] + (refDB[i] >= p.farEndSilentDBFS ? 1 : 0) }
        var revert = [Bool](repeating: false, count: frames)
        var count = 0
        for i in 0..<frames {
            let lo = max(0, i - margin), hi = min(frames, i + margin + 1)
            let farSilent = loud[hi] - loud[lo] == 0
            if farSilent && micDB[i] >= p.micActiveDBFS && micDB[i] - cleanDB[i] >= p.maxCutDB {
                revert[i] = true
                count += 1
            }
        }
        guard count > 0 else { return Result(samples: cleaned, revertedFrames: 0) }

        // Gain toward the raw mic: 1 inside reverted frames, ramping to 0 over the crossfade outside
        // them (into frames whose far end is silent too, by the margin, so no echo comes back).
        let fade = max(1, Int((p.crossfadeSeconds * Double(sampleRate)).rounded()))
        var gain = [Float](repeating: 0, count: microphone.count)
        for i in 0..<frames where revert[i] {
            for s in (i * frame)..<min(microphone.count, (i + 1) * frame) { gain[s] = 1 }
        }
        var distance = Int.max / 2
        for s in 0..<gain.count {  // forward pass: distance since the last reverted sample
            distance = gain[s] == 1 ? 0 : distance + 1
            if distance > 0 && distance <= fade { gain[s] = max(gain[s], 1 - Float(distance) / Float(fade + 1)) }
        }
        distance = Int.max / 2
        for s in stride(from: gain.count - 1, through: 0, by: -1) {  // backward pass
            distance = gain[s] == 1 ? 0 : distance + 1
            if distance > 0 && distance <= fade { gain[s] = max(gain[s], 1 - Float(distance) / Float(fade + 1)) }
        }
        var out = cleaned
        for s in out.indices where gain[s] > 0 { out[s] = gain[s] * microphone[s] + (1 - gain[s]) * cleaned[s] }
        return Result(samples: out, revertedFrames: count)
    }

    /// RMS per frame in dBFS (silence is -200).
    static func levels(_ x: [Float], frame: Int, frames: Int) -> [Double] {
        (0..<frames).map { i in
            let lo = i * frame, hi = min(x.count, lo + frame)
            guard lo < hi else { return -200 }
            var sum = 0.0
            for s in lo..<hi { sum += Double(x[s]) * Double(x[s]) }
            let rms = (sum / Double(hi - lo)).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -200
        }
    }
}
