import AVFoundation
import Foundation
import Testing
@testable import TranscriberCore

/// `SpeakerSamplePreview` is the single shared extraction path for both rename flows (GUI and CLI).
/// Its correctness properties are exactly the ones that produced #132: which CHANNEL is read, and
/// whether the offset lands where the transcript said. Getting either wrong plays the wrong person's
/// voice under a confident label — and the user then names a speaker from it.
@Suite struct SpeakerSamplePreviewTests {

    /// Write a stereo WAV whose two channels are trivially distinguishable: L is a constant +0.5,
    /// R a constant -0.5. Whichever channel the preview extracted is then unambiguous.
    private func makeStereoFixture(seconds: Double = 4, sampleRate: Double = 48000) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = 0.5    // L = mic / local
            buf.floatChannelData![1][i] = -0.5   // R = system / remote
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-fixture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        return url
    }

    private func makeMonoFixture(seconds: Double = 4, sampleRate: Double = 48000) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.25 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-mono-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        return url
    }

    /// Read back the first sample of a rendered preview, so we can tell which channel it came from.
    private func firstSample(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
        try file.read(into: buf, frameCount: 1024)
        return buf.floatChannelData![0][0]
    }

    /// The #132 property: a LOCAL speaker must be read from L, never R. Reading the wrong channel
    /// means the user auditions "Local Speaker 1" and hears the remote participants.
    @Test func localSampleReadsLeftChannel() throws {
        let src = try makeStereoFixture()
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 1, to: 2, isLocal: true)
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(try firstSample(of: out) > 0, "local must come from L (+0.5), not R (-0.5)")
    }

    @Test func remoteSampleReadsRightChannel() throws {
        let src = try makeStereoFixture()
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 1, to: 2, isLocal: false)
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(try firstSample(of: out) < 0, "remote must come from R (-0.5), not L (+0.5)")
    }

    /// A mono source carries a single stream already — `isLocal` must not push the read off the end.
    @Test func monoSourceIgnoresChannelSelection() throws {
        let src = try makeMonoFixture()
        defer { try? FileManager.default.removeItem(at: src) }

        for isLocal in [true, false] {
            let out = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 1, to: 2, isLocal: isLocal)
            defer { try? FileManager.default.removeItem(at: out) }
            #expect(try firstSample(of: out) > 0)
        }
    }

    @Test func previewHasTheRequestedDuration() throws {
        let src = try makeStereoFixture(seconds: 4)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 1, to: 2.5, isLocal: false)
        defer { try? FileManager.default.removeItem(at: out) }

        let file = try AVAudioFile(forReading: out)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 1.5) < 0.01)
        #expect(file.processingFormat.channelCount == 1)
    }

    /// Clamped at EOF rather than reading past it — the pre-#132 behaviour was to seek past the end
    /// and silently produce zero frames, so the play button did nothing at all.
    @Test func rangeExtendingPastEndIsClampedToTheFile() throws {
        let src = try makeStereoFixture(seconds: 4)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 3, to: 99, isLocal: false)
        defer { try? FileManager.default.removeItem(at: out) }

        let file = try AVAudioFile(forReading: out)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 1.0) < 0.01, "should yield the 1s that actually exists, not 96s")
    }

    /// A window with no frames must THROW, so the caller can disable the control — rather than
    /// hand back a silent file and a play button that appears to work.
    @Test func startAtOrPastEndThrows() throws {
        let src = try makeStereoFixture(seconds: 4)
        defer { try? FileManager.default.removeItem(at: src) }

        #expect(throws: SpeakerSamplePreview.PreviewError.self) {
            _ = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 10, to: 12, isLocal: false)
        }
    }

    @Test func zeroLengthRangeThrows() throws {
        let src = try makeStereoFixture()
        defer { try? FileManager.default.removeItem(at: src) }

        #expect(throws: SpeakerSamplePreview.PreviewError.self) {
            _ = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 2, to: 2, isLocal: false)
        }
    }

    @Test func unreadableFileThrows() {
        let missing = URL(fileURLWithPath: "/nope/not-audio.wav")
        #expect(throws: SpeakerSamplePreview.PreviewError.self) {
            _ = try SpeakerSamplePreview.makeMonoPreview(of: missing, from: 0, to: 1, isLocal: false)
        }
    }

    /// Each preview gets its own filename: a fixed name rewritten in place races a player still
    /// reading the previous clip.
    @Test func previewsDoNotCollide() throws {
        let src = try makeStereoFixture()
        defer { try? FileManager.default.removeItem(at: src) }

        let a = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 0, to: 1, isLocal: true)
        let b = try SpeakerSamplePreview.makeMonoPreview(of: src, from: 1, to: 2, isLocal: true)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a != b)
    }
}
