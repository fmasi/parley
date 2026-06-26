import Foundation

/// Equal-weight average of interleaved multichannel float audio into mono.
///
/// The macOS built-in microphone is a 3-capsule beamforming array. macOS normally fuses it into a
/// single clean mono channel, but ScreenCaptureKit's raw mic tap bypasses that fusion and delivers
/// the raw interleaved capsules (3+ channels). Those capsules are undifferentiated — a positionless
/// "Discrete" layout with no "primary" channel — so the correct mixdown is an equal-weight average,
/// not picking one channel and discarding the rest. Averaging reduces the capsules' uncorrelated
/// self-noise (~4.8 dB for three capsules) and is safe in the speech band for a near-frontal talker,
/// where the first comb-filter notch from the cm-scale capsule spacing sits above ~5 kHz.
///
/// `AVAudioConverter`'s own downmix cannot do this (on a Discrete layout it applies surround
/// coefficients, not an equal average), so we average here before handing the mono buffer to the
/// converter. The durable fix is to capture the mic off ScreenCaptureKit via `AVAudioEngine`'s input
/// node, which hands us OS-fused mono directly — see issue #96.
public enum MultichannelDownmix {
    /// Average `channels` interleaved float samples per frame into a mono output.
    ///
    /// Frame `f` spans `src[f*channels ..< f*channels + channels]`; each output sample is the mean of
    /// that frame's channels. Reads stop at the last *whole* frame the source can supply, so a
    /// truncated final frame is never partially summed (no out-of-bounds read, no half-frame
    /// artifact) — mirroring the bounded-copy discipline on the rest of the mic path.
    ///
    /// - Parameters:
    ///   - src: interleaved source samples (all channels of frame 0, then all channels of frame 1, …).
    ///   - srcCount: number of valid `Float` elements readable at `src`.
    ///   - channels: interleave stride / channel count (must be > 0; otherwise a no-op).
    ///   - dst: mono output buffer with capacity for at least `frameCount` samples.
    ///   - frameCount: maximum number of mono frames to produce.
    /// - Returns: the number of mono frames actually written (may be < `frameCount` if the source ran
    ///   short). The caller should set the output buffer's `frameLength` to this value so no
    ///   uninitialized tail is ever played or transcribed.
    @discardableResult
    public static func averageInterleavedToMono(
        _ src: UnsafePointer<Float>, srcCount: Int, channels: Int,
        into dst: UnsafeMutablePointer<Float>, frameCount: Int
    ) -> Int {
        guard channels > 0 else { return 0 }
        let scale = 1.0 / Float(channels)
        var written = 0
        var i = 0
        while written < frameCount && i + channels <= srcCount {
            var sum: Float = 0
            for c in 0..<channels { sum += src[i + c] }
            dst[written] = sum * scale
            written += 1
            i += channels
        }
        return written
    }

    /// Average `channels` interleaved **Int16** samples per frame into mono **Float32** in [-1, 1).
    ///
    /// Same gap-safe contract as `averageInterleavedToMono`. The built-in mic array is float, but pro
    /// USB interfaces (Focusrite, Behringer, …) present >2 channels of packed Int16 — without this they
    /// would be dropped. Output is float so it feeds the same `AudioConverter` path as the float case.
    @discardableResult
    public static func averageInterleavedInt16ToMono(
        _ src: UnsafePointer<Int16>, srcCount: Int, channels: Int,
        into dst: UnsafeMutablePointer<Float>, frameCount: Int
    ) -> Int {
        guard channels > 0 else { return 0 }
        let scale = 1.0 / (Float(channels) * 32768.0)
        var written = 0
        var i = 0
        while written < frameCount && i + channels <= srcCount {
            var sum: Float = 0
            for c in 0..<channels { sum += Float(src[i + c]) }
            dst[written] = sum * scale
            written += 1
            i += channels
        }
        return written
    }
}
