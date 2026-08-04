import Foundation

/// Frame arithmetic for copying raw PCM bytes into an `AVAudioPCMBuffer`.
///
/// Extracted because getting it wrong is silent. The mic path clamped every copy to
/// `frameLength * sizeof(sample)` with no channel count; interleaved stereo does not have nil
/// `floatChannelData` (it exposes a single interleaved plane), so a stereo mic took that branch and
/// lost half of every buffer — the destination's tail stayed zero. Correct duration, choppy content,
/// no error: the same failure shape as the chipmunk.
///
/// The COPY clamp no longer lives here: `AudioOutputHandler` bounds each memcpy by the destination
/// buffer's real `mDataByteSize`, which is inherently right for both layouts and cannot drift from
/// the format the way a recomputed capacity can. What remains is the one calculation that still has
/// to be derived — how many whole frames the bytes that actually arrived represent.
public enum PCMCopyPlan {

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
