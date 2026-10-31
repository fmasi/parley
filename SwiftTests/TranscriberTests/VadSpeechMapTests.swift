import AVFoundation
import Testing
import Foundation
@testable import TranscriberCore

struct VadSpeechMapTests {

    // MARK: - speechOverlap

    @Test func fullOverlapReturnsOne() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 1.0)
    }

    @Test func noOverlapReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 2.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 8.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func partialOverlapReturnsProportionalValue() {
        let regions = [SpeechRegion(start: 0.0, end: 3.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 6.0, threshold: 0.5)
        // 1s overlap out of 4s segment = 0.25
        #expect(abs(result - 0.25) < 0.001)
    }

    @Test func multipleRegionsSpanningOneSegment() {
        let regions = [
            SpeechRegion(start: 0.0, end: 2.0, probability: 0.9),
            SpeechRegion(start: 4.0, end: 6.0, probability: 0.9),
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 8.0, threshold: 0.5)
        // 4s overlap out of 8s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test func emptyRegionsReturnsZero() {
        let result = SpeechRegion.speechOverlap(regions: [], start: 0.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func zeroDurationSegmentReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func regionBelowThresholdIsIgnored() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.3)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func mixedProbabilityRegions() {
        let regions = [
            SpeechRegion(start: 0.0, end: 5.0, probability: 0.9),  // above threshold
            SpeechRegion(start: 5.0, end: 10.0, probability: 0.2), // below threshold
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 10.0, threshold: 0.5)
        // 5s overlap out of 10s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }
}

/// `analyze(samples:)` (#204): lets a caller that already decoded the audio for another consumer
/// (the diarizer, in `TranscriptRediarizer`) share that buffer instead of handing `analyze` a path
/// and paying for a second decode of identical audio.
@Suite("VadSpeechMap analyze(samples:)")
struct VadSpeechMapAnalyzeSamplesTests {

    /// CI (and most dev machines running this suite) has no cached VAD model, so this exercises
    /// the real graceful-degradation branch shared with `analyze(audioPath:)` — not a stub. If a
    /// machine DOES have the model cached, there is nothing to assert here (VAD would actually
    /// run), so the test is a no-op rather than a false failure.
    @Test("returns nil when the VAD model is not cached, matching analyze(audioPath:)")
    func returnsNilWhenModelNotCached() async throws {
        guard !VadSpeechMap.isModelCached() else { return }
        let samples = [Float](repeating: 0, count: 1600)
        let result = try await VadSpeechMap().analyze(samples: samples)
        #expect(result == nil)
    }
}

/// `analyze(audioPath:)` reads the file itself, a block at a time at 16 kHz, instead of FluidAudio's file
/// path, which decoded a whole chunk at 48 kHz first (2.0 GB and 20 s for 61 minutes). The samples it
/// hands the VAD are the ones the whole-file reader produces.
@Suite("VadSpeechMap block reading")
struct VadSpeechMapBlockReadingTests {
    private func wav(_ samples: [Float], rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vad-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if !samples.isEmpty {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        return url
    }

    private func tone(seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }
    }

    @Test func a48kHzFileReadsAsTheWholeFileReaderReadsIt() throws {
        let url = try wav(tone(seconds: 5.3, rate: 48_000), rate: 48_000); defer { try? FileManager.default.removeItem(at: url) }
        let blocks = try VadSpeechMap.samples16k(contentsOf: url)
        let whole = try AudioDecode.mono16kHzFloat(contentsOf: url)
        #expect(abs(blocks.count - whole.count) <= 1)
        let worst = zip(blocks, whole).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-3, "differs by \(worst)")
    }

    @Test func a16kHzFileIsReadUnchanged() throws {
        let samples = tone(seconds: 2, rate: 16_000)
        let url = try wav(samples, rate: 16_000); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try VadSpeechMap.samples16k(contentsOf: url) == samples)
    }

    @Test func anEmptyFileHasNoSamples() throws {
        let url = try wav([], rate: 48_000); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try VadSpeechMap.samples16k(contentsOf: url).isEmpty)
    }
}

extension VadSpeechMapBlockReadingTests {
    /// A file whose header claims more audio than it holds (a lagging writer, a truncated copy): the
    /// reader returns the audio that is there and stops, it does not throw the whole file away.
    @Test(arguments: [16_000.0, 48_000.0])
    func aHeaderThatOverReportsReadsTheAudioThatIsThere(rate: Double) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecoveryFixtures.writeFakeWav(at: url, seconds: 1, sampleRate: Int(rate))
        var data = try Data(contentsOf: url)
        let claimed = UInt32(2 * rate) * 2  // two seconds of 16-bit mono, against one written
        withUnsafeBytes(of: (36 + claimed).littleEndian) { data.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: claimed.littleEndian) { data.replaceSubrange(40..<44, with: $0) }
        try data.write(to: url)
        let samples = try VadSpeechMap.samples16k(contentsOf: url)
        #expect(abs(samples.count - 16_000) <= 64, "read \(samples.count) samples")
    }
}
