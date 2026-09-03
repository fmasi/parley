import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// A recording with NO system audio (#183).
///
/// Device-observed twice: `2026-07-16/115126-Leaseholder Insurance first call` and
/// `2026-09-02/150633-Paul feedback` — a phone call answered and put on speaker. Everything comes
/// through the mic; the system capture writes a 44-byte header and nothing else.
///
/// The empty header declares 16000 Hz, the mic runs at 48000, so `archive()` hit its rate-mismatch
/// guard and refused. The guard is right in principle — a genuine rate divergence used to encode a
/// pitch-shifted system channel and then delete both lossless sources — but there is no divergence
/// here, because there is no system audio at all.
///
/// `archiveSystemOnly` cannot be reused for this: it fills the RIGHT channel, so feeding it mic
/// audio would put the local speaker in the remote slot and mislabel them everywhere downstream
/// (the #132 class of harm).
struct MicOnlyArchiveTests {

    private static func createTestWav(
        at url: URL, frequency: Double = 440.0, durationSeconds: Double = 1.0, sampleRate: Double = 48000
    ) throws {
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<frameCount { ptr[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// A WAV the capture layer opened and never wrote a frame to: a valid header, zero frames.
    private static func createEmptyWav(at url: URL, sampleRate: Double = 16000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        _ = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Peak magnitude per channel of a stereo file.
    private static func channelPeaks(_ url: URL) throws -> (left: Float, right: Float) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channels = buffer.floatChannelData!
        var peaks: [Float] = []
        for c in 0..<Int(file.processingFormat.channelCount) {
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i])) }
            peaks.append(peak)
        }
        return (peaks[0], peaks.count > 1 ? peaks[1] : 0)
    }

    // MARK: - archiveMicOnly

    @Test("mic-only archive puts the mic on the LEFT channel and leaves the right silent")
    func micOnlyUsesTheLocalChannel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let micWav = dir.appendingPathComponent("call_mic.wav")
        try Self.createTestWav(at: micWav, frequency: 440)

        let result = try await AudioArchiver.archiveMicOnly(
            micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)

        let file = try AVAudioFile(forReading: result.archivePath)
        #expect(file.processingFormat.channelCount == 2)
        let peaks = try Self.channelPeaks(result.archivePath)
        // L carries the voice, R is the (absent) system side. Reversing these would attribute
        // every local speaker to the remote channel downstream.
        #expect(peaks.left > 0.1)
        #expect(peaks.right < 0.01)
    }

    @Test("mic-only archive is named for the recording, not the mic file")
    func micOnlyDropsTheMicSuffixFromTheName() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let micWav = dir.appendingPathComponent("150633-Paul feedback-0_mic.wav")
        try Self.createTestWav(at: micWav)

        let result = try await AudioArchiver.archiveMicOnly(
            micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)
        // "…-0_mic.m4a" would not match the chunk naming every other path produces.
        #expect(result.archivePath.lastPathComponent == "150633-Paul feedback-0.m4a")
    }

    @Test("mic-only archive deletes its source once verified")
    func micOnlyDeletesTheSourceWav() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let micWav = dir.appendingPathComponent("call_mic.wav")
        try Self.createTestWav(at: micWav)
        _ = try await AudioArchiver.archiveMicOnly(micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)
        #expect(!FileManager.default.fileExists(atPath: micWav.path))
    }

    @Test("preserveSourceWAV keeps the mic WAV on the mic-only path too")
    func micOnlyHonoursPreserveFlag() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let micWav = dir.appendingPathComponent("call_mic.wav")
        try Self.createTestWav(at: micWav)
        _ = try await AudioArchiver.archiveMicOnly(
            micAudio: micWav, outputDirectory: dir, bitrateKbps: 64, preserveSourceWAV: true)
        #expect(FileManager.default.fileExists(atPath: micWav.path))
    }

    // MARK: - archive() routing

    @Test("an EMPTY system track routes to the mic-only path instead of tripping the rate guard")
    func emptySystemTrackArchivesAsMicOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("call.wav")
        let micWav = dir.appendingPathComponent("call_mic.wav")
        // The device shape: header-only system file declaring 16 kHz, healthy 48 kHz mic.
        try Self.createEmptyWav(at: systemWav, sampleRate: 16000)
        try Self.createTestWav(at: micWav, sampleRate: 48000)

        let result = try await AudioArchiver.archive(
            systemAudio: systemWav, micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)

        #expect(result.archivePath.lastPathComponent == "call.m4a")
        let peaks = try Self.channelPeaks(result.archivePath)
        #expect(peaks.left > 0.1)
        #expect(peaks.right < 0.01)
    }

    @Test("a real rate mismatch is still refused — the empty-file case must not weaken the guard")
    func genuineRateMismatchStillRefuses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        // Both tracks carry REAL audio at different rates: the 2026-08-04 chipmunk shape.
        try Self.createTestWav(at: systemWav, frequency: 880, sampleRate: 24000)
        try Self.createTestWav(at: micWav, frequency: 440, sampleRate: 48000)

        await #expect(throws: (any Error).self) {
            _ = try await AudioArchiver.archive(
                systemAudio: systemWav, micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)
        }
        #expect(FileManager.default.fileExists(atPath: systemWav.path))
        #expect(FileManager.default.fileExists(atPath: micWav.path))
    }

    @Test("both tracks empty is a failure, not a silent empty archive")
    func bothTracksEmptyThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("call.wav")
        let micWav = dir.appendingPathComponent("call_mic.wav")
        try Self.createEmptyWav(at: systemWav)
        try Self.createEmptyWav(at: micWav, sampleRate: 48000)

        await #expect(throws: (any Error).self) {
            _ = try await AudioArchiver.archive(
                systemAudio: systemWav, micAudio: micWav, outputDirectory: dir, bitrateKbps: 64)
        }
    }
}
