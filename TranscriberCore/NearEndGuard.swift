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
    /// as long as `microphone`; a shorter `reference` counts as silent past its end. A whole stream in
    /// memory: `Frames` + `revertMask` + `Blend` are the same rule a block at a time.
    public static func apply(microphone: [Float], cleaned: [Float], reference: [Float], sampleRate: Int,
                             parameters p: Parameters = Parameters()) -> Result {
        precondition(microphone.count == cleaned.count, "cleaned and raw mic must be the same length")
        let frame = frameLength(sampleRate: sampleRate, parameters: p)
        let frames = (microphone.count + frame - 1) / frame
        guard frames > 0 else { return Result(samples: cleaned, revertedFrames: 0) }
        let mask = revertMask(micDB: levels(microphone, frame: frame, frames: frames),
                              cleanDB: levels(cleaned, frame: frame, frames: frames),
                              refDB: levels(reference, frame: frame, frames: frames), parameters: p)
        let blend = Blend(mask: mask, frame: frame, count: microphone.count, sampleRate: sampleRate, parameters: p)
        guard blend.revertedFrames > 0 else { return Result(samples: cleaned, revertedFrames: 0) }
        var out = cleaned
        blend.apply(microphone: microphone[...], to: &out[...], from: 0)
        return Result(samples: out, revertedFrames: blend.revertedFrames)
    }

    static func frameLength(sampleRate: Int, parameters p: Parameters) -> Int {
        max(1, Int((p.frameSeconds * Double(sampleRate)).rounded()))
    }

    /// Which frames get the raw mic back, from each stream's RMS per frame (dBFS).
    static func revertMask(micDB: [Double], cleanDB: [Double], refDB: [Double], parameters p: Parameters) -> [Bool] {
        let frames = micDB.count
        let margin = Int((p.silenceMarginSeconds / p.frameSeconds).rounded())
        // Far end silent across the margin: a sliding count of loud reference frames.
        var loud = [Int](repeating: 0, count: frames + 1)
        for i in 0..<frames {
            let ref = i < refDB.count ? refDB[i] : -200
            loud[i + 1] = loud[i] + (ref >= p.farEndSilentDBFS ? 1 : 0)
        }
        return (0..<frames).map { i in
            let lo = max(0, i - margin), hi = min(frames, i + margin + 1)
            return loud[hi] - loud[lo] == 0 && micDB[i] >= p.micActiveDBFS && micDB[i] - cleanDB[i] >= p.maxCutDB
        }
    }

    /// Per-frame RMS accumulated a block at a time: feed every block of a stream in order, then `levels`.
    struct Frames {
        let frame: Int
        private var sums: [Double] = []
        private var counts: [Int] = []
        private var position = 0
        init(frame: Int) { self.frame = frame }

        mutating func add(_ block: UnsafeBufferPointer<Float>) {
            for x in block {
                let f = position / frame
                if f == sums.count { sums.append(0); counts.append(0) }
                sums[f] += Double(x) * Double(x)
                counts[f] += 1
                position += 1
            }
        }

        /// dBFS per frame, padded with silence (-200) to `frames`.
        func levels(frames: Int) -> [Double] {
            (0..<frames).map { f in
                guard f < sums.count, counts[f] > 0 else { return -200 }
                let rms = (sums[f] / Double(counts[f])).squareRoot()
                return rms > 0 ? 20 * log10(rms) : -200
            }
        }
    }

    /// The crossfaded mix toward the raw mic that a mask asks for, computed per sample: 1 inside a
    /// reverted frame, ramping to 0 over the crossfade outside it (into frames whose far end is silent
    /// too, by the margin, so no echo comes back).
    struct Blend {
        let mask: [Bool]
        let frame: Int
        let count: Int
        let fade: Int
        /// The nearest reverted frame at or before / at or after each frame.
        private let previous: [Int?], next: [Int?]
        var revertedFrames: Int { mask.lazy.filter { $0 }.count }

        init(mask: [Bool], frame: Int, count: Int, sampleRate: Int, parameters p: Parameters) {
            self.mask = mask
            self.frame = frame
            self.count = count
            fade = max(1, Int((p.crossfadeSeconds * Double(sampleRate)).rounded()))
            var previous = [Int?](repeating: nil, count: mask.count), next = previous
            var last: Int? = nil
            for f in mask.indices { if mask[f] { last = f }; previous[f] = last }
            last = nil
            for f in mask.indices.reversed() { if mask[f] { last = f }; next[f] = last }
            self.previous = previous
            self.next = next
        }

        func gain(at s: Int) -> Float {
            let f = s / frame
            if mask[f] { return 1 }
            var g: Float = 0
            if let p = previous[f] {  // samples since the last reverted sample
                let distance = s - (min(count, (p + 1) * frame) - 1)
                if distance <= fade { g = max(g, 1 - Float(distance) / Float(fade + 1)) }
            }
            if let n = next[f] {  // samples until the next reverted sample
                let distance = n * frame - s
                if distance <= fade { g = max(g, 1 - Float(distance) / Float(fade + 1)) }
            }
            return g
        }

        /// Mixes `microphone` into `cleaned` in place, both starting at stream sample `start`.
        func apply(microphone: ArraySlice<Float>, to cleaned: inout ArraySlice<Float>, from start: Int) {
            precondition(microphone.count == cleaned.count)
            var m = microphone.startIndex
            for c in cleaned.indices {
                let g = gain(at: start + (c - cleaned.startIndex))
                if g > 0 { cleaned[c] = g * microphone[m] + (1 - g) * cleaned[c] }
                m += 1
            }
        }
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
