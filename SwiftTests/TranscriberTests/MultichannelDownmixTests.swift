import Testing
@testable import TranscriberCore

@Suite("MultichannelDownmix")
struct MultichannelDownmixTests {
    /// Run the pointer-based downmix over Swift arrays and return only the frames actually written.
    private func downmix(_ src: [Float], channels: Int, frameCount: Int) -> [Float] {
        var dst = [Float](repeating: -999, count: max(frameCount, 0))
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                MultichannelDownmix.averageInterleavedToMono(
                    s.baseAddress!, srcCount: s.count, channels: channels,
                    into: d.baseAddress!, frameCount: frameCount
                )
            }
        }
        return Array(dst.prefix(written))
    }

    @Test("averages each 3-channel frame to its mean (built-in mic array)")
    func averagesThreeChannels() {
        // 2 frames, 3 ch: (1+2+3)/3 = 2, (4+5+6)/3 = 5
        #expect(downmix([1, 2, 3, 4, 5, 6], channels: 3, frameCount: 2) == [2, 5])
    }

    @Test("passes mono through unchanged")
    func monoPassthrough() {
        #expect(downmix([0.25, -0.5, 1.0], channels: 1, frameCount: 3) == [0.25, -0.5, 1.0])
    }

    @Test("averages stereo to mid")
    func stereoToMid() {
        // (1 + -1)/2 = 0, (0.5 + 0.5)/2 = 0.5
        #expect(downmix([1, -1, 0.5, 0.5], channels: 2, frameCount: 2) == [0, 0.5])
    }

    @Test("averaging cancels equal-and-opposite capsules without clipping")
    func averageNotSum() {
        // Summing would give 2.0 (clips beyond ±1); averaging keeps it at 1.0.
        #expect(downmix([1, 1, 1, -1, -1, -1], channels: 3, frameCount: 2) == [1, -1])
    }

    @Test("stops at the last whole frame when the source runs short")
    func truncatedFinalFrame() {
        // 3 ch, but only 1⅔ frames of data — only the first whole frame is emitted, no OOB read.
        #expect(downmix([3, 3, 3, 9, 9], channels: 3, frameCount: 2) == [3])
    }

    @Test("never writes more than frameCount frames")
    func respectsFrameCount() {
        // 4 frames of stereo data, but the caller only wants 2.
        #expect(downmix([1, 1, 2, 2, 3, 3, 4, 4], channels: 2, frameCount: 2) == [1, 2])
    }

    @Test("zero channels is a guarded no-op, not a divide-by-zero")
    func zeroChannelsNoOp() {
        #expect(downmix([1, 2, 3], channels: 0, frameCount: 3) == [])
    }
}
