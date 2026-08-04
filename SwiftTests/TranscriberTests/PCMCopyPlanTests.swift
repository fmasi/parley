import Testing
@testable import TranscriberCore

/// Byte arithmetic for copying a `CMBlockBuffer`'s raw samples into an `AVAudioPCMBuffer`.
///
/// Regression cover for a confirmed bug: the mic copy clamped every write to
/// `frameLength * MemoryLayout<Float>.size`, omitting the channel count. Interleaved stereo does NOT
/// have nil `floatChannelData` (it exposes one interleaved plane), so a stereo mic took that branch
/// and had HALF of every buffer silently dropped — the destination's second half stayed zero. The
/// result is choppy audio at the correct duration with no error anywhere: the same bug class as the
/// chipmunk, arriving through the clamp that was added to fix a heap overrun (#94).
@Suite struct PCMCopyPlanTests {

    // MARK: - Interleaved

    /// THE REGRESSION: 1024 frames of interleaved stereo Float32 is 8192 bytes, not 4096.
    @Test func interleavedStereoFloatCapacityCountsBothChannels() {
        #expect(PCMCopyPlan.capacityBytes(frameLength: 1024, channelCount: 2,
                                          bytesPerSample: 4, isInterleaved: true) == 8192)
    }

    @Test func interleavedMonoIsUnchanged() {
        #expect(PCMCopyPlan.capacityBytes(frameLength: 1024, channelCount: 1,
                                          bytesPerSample: 4, isInterleaved: true) == 4096)
    }

    @Test func interleavedStereoInt16() {
        #expect(PCMCopyPlan.capacityBytes(frameLength: 512, channelCount: 2,
                                          bytesPerSample: 2, isInterleaved: true) == 2048)
    }

    // MARK: - Planar

    /// Non-interleaved buffers hold one plane PER channel, so a single plane's capacity is
    /// frames * bytesPerSample regardless of how many channels exist.
    @Test func planarCapacityIsPerChannel() {
        #expect(PCMCopyPlan.capacityBytes(frameLength: 1024, channelCount: 2,
                                          bytesPerSample: 4, isInterleaved: false) == 4096)
    }

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
        #expect(PCMCopyPlan.capacityBytes(frameLength: 1024, channelCount: 0,
                                          bytesPerSample: 4, isInterleaved: true) == 0)
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 0,
                                         bytesPerSample: 4, isInterleaved: true) == 0)
        #expect(PCMCopyPlan.usableFrames(copiedBytes: 4096, channelCount: 2,
                                         bytesPerSample: 0, isInterleaved: true) == 0)
    }
}
