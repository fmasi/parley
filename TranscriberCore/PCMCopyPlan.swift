import Foundation

/// Byte arithmetic for copying raw PCM bytes into an `AVAudioPCMBuffer`.
///
/// Extracted because getting it wrong is silent. The mic path clamped every copy to
/// `frameLength * sizeof(sample)` with no channel count; interleaved stereo does not have nil
/// `floatChannelData` (it exposes a single interleaved plane), so a stereo mic took that branch and
/// lost half of every buffer — the destination's tail stayed zero. Correct duration, choppy content,
/// no error: the same failure shape as the chipmunk. Pure arithmetic belongs where it can be tested.
public enum PCMCopyPlan {

    /// Bytes the destination can accept.
    ///
    /// Interleaved buffers hold every channel in ONE plane, so capacity scales with channel count.
    /// Non-interleaved buffers hold one plane per channel, so a single plane's capacity does not.
    public static func capacityBytes(
        frameLength: Int,
        channelCount: Int,
        bytesPerSample: Int,
        isInterleaved: Bool
    ) -> Int {
        guard frameLength > 0, channelCount > 0, bytesPerSample > 0 else { return 0 }
        let perFrame = isInterleaved ? channelCount * bytesPerSample : bytesPerSample
        return frameLength * perFrame
    }

    /// How many whole frames the bytes that actually arrived represent.
    ///
    /// A route change can briefly deliver a short buffer. Declaring `frameLength` from the source's
    /// *expected* size would convert an uninitialised tail into a noise blip, so the frame count has
    /// to follow the bytes really copied, rounded DOWN — a partial frame is not a frame.
    public static func usableFrames(
        copiedBytes: Int,
        channelCount: Int,
        bytesPerSample: Int,
        isInterleaved: Bool
    ) -> Int {
        guard copiedBytes > 0, channelCount > 0, bytesPerSample > 0 else { return 0 }
        let perFrame = isInterleaved ? channelCount * bytesPerSample : bytesPerSample
        return copiedBytes / perFrame
    }
}
