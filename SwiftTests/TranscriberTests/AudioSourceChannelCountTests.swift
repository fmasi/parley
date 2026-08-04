import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// `channelCount(of:)` is what the CLI's mono-`--split` guard rests on: splitting a mono file
/// upmixes it to L=R, so the speaker is transcribed as BOTH sides of the conversation and echo
/// dedup then fights itself over the duplicate. It also reaches
/// `CMAudioFormatDescriptionGetStreamBasicDescription`, and this codebase's history with format
/// descriptions is exactly why gotcha #59 exists — assumptions about them do not survive contact.
@Suite struct AudioSourceChannelCountTests {

    private static func writeAac(at url: URL, channels: AVAudioChannelCount) throws {
        let sampleRate: Double = 48000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)
        else { throw ChannelCountTestError.cannotCreateBuffer }
        buffer.frameLength = 48000
        for channel in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![channel]
            for i in 0..<48000 {
                ptr[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }

    enum ChannelCountTestError: Error { case cannotCreateBuffer }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chancount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// THE GUARD'S PREMISE: a mono file must be reported as mono so `--split` can refuse it.
    @Test func monoAacReportsOneChannel() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mono.m4a")
        try Self.writeAac(at: url, channels: 1)

        let count = try await AudioSourceResolver.channelCount(of: url)
        #expect(count == 1)
    }

    /// A genuine dual-stream archive must NOT be refused — the guard has to be precise, not cautious.
    @Test func stereoAacReportsTwoChannels() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stereo.m4a")
        try Self.writeAac(at: url, channels: 2)

        let count = try await AudioSourceResolver.channelCount(of: url)
        #expect(count == 2)
    }

    /// Fails open: the CLI treats a nil count as "can't tell, proceed", so an unreadable file must
    /// not throw its way out of the guard and abort an otherwise valid transcription.
    @Test func missingFileYieldsNilOrThrows() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).m4a")
        let count = try? await AudioSourceResolver.channelCount(of: missing)
        // Either nil, or a thrown error swallowed by `try?` — both leave the caller free to proceed.
        #expect(count == nil || count == .some(nil))
    }
}
