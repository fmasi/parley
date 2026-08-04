import Testing
@testable import TranscriberCore

/// Frame arithmetic for copying a `CMBlockBuffer`'s raw samples into an `AVAudioPCMBuffer`.
///
/// Regression cover for a confirmed bug: the mic copy clamped every write to
/// `frameLength * MemoryLayout<Float>.size`, omitting the channel count. Interleaved stereo does NOT
/// have nil `floatChannelData` (it exposes one interleaved plane), so a stereo mic took that branch
/// and had HALF of every buffer silently dropped — the destination's second half stayed zero. The
/// result is choppy audio at the correct duration with no error anywhere: the same bug class as the
/// chipmunk, arriving through the clamp that was added to fix a heap overrun (#94).
///
/// The copy clamp itself now comes from the destination's real `mDataByteSize` rather than a
/// recomputed capacity, so the original miscalculation is structurally impossible. What still has to
/// be derived — and therefore still needs pinning — is the frame count for a SHORT buffer, which is
/// what stops an uninitialised tail being converted into a noise blip.
@Suite struct PCMCopyPlanTests {

    // MARK: - Short buffers

    /// The clamp exists because a route change can deliver fewer bytes than `frameLength` implies.
    /// Converting the uninitialised tail would emit a noise blip, so the frame count must follow the
    /// bytes that actually arrived — rounded DOWN to a whole frame.
    @Test func usableFramesFollowsBytesActuallyCopied() {
        // Only half the expected bytes arrived for 1024 interleaved stereo float frames.
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 2,
                                         bytesPerSample: 4, isInterleaved: true) == 512)
    }

    @Test func usableFramesRoundsDownOnPartialFrame() {
        // 4100 bytes is 512 whole stereo frames plus a 4-byte stub — the stub must be discarded.
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4100, channelCount: 2,
                                         bytesPerSample: 4, isInterleaved: true) == 512)
    }

    @Test func usableFramesPlanarCountsOnePlane() {
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 2,
                                         bytesPerSample: 4, isInterleaved: false) == 1024)
    }

    @Test func zeroBytesYieldsNoFrames() {
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 0, channelCount: 2,
                                         bytesPerSample: 4, isInterleaved: true) == 0)
    }

    // MARK: - Degenerate inputs must not trap the audio thread

    @Test func zeroChannelsOrSampleSizeIsSafe() {
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 0,
                                         bytesPerSample: 4, isInterleaved: true) == 0)
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 2,
                                         bytesPerSample: 0, isInterleaved: true) == 0)
    }
}
