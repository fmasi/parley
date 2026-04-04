import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

struct AudioArchiverTests {

    /// Helper: create a mono 48kHz WAV file with a sine wave.
    private static func createTestWav(at url: URL, frequency: Double = 440.0, durationSeconds: Double = 1.0) throws {
        let sampleRate: Double = 48000
        let frameCount = Int(sampleRate * durationSeconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw ArchiverTestError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            ptr[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    enum ArchiverTestError: Error {
        case cannotCreateBuffer
    }

    @Test func archiveCreatesStereoM4a() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        try Self.createTestWav(at: systemWav, frequency: 880)
        try Self.createTestWav(at: micWav, frequency: 440)

        let result = try await AudioArchiver.archive(
            systemAudio: systemWav,
            micAudio: micWav,
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(result.archivePath.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: result.archivePath.path))

        // Source WAVs are deleted
        #expect(!FileManager.default.fileExists(atPath: systemWav.path))
        #expect(!FileManager.default.fileExists(atPath: micWav.path))

        // Output is stereo
        let file = try AVAudioFile(forReading: result.archivePath)
        #expect(file.processingFormat.channelCount == 2)
    }

    @Test func archivePreservesBaseName() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("my-meeting-2026.wav")
        let micWav = dir.appendingPathComponent("my-meeting-2026_mic.wav")
        try Self.createTestWav(at: systemWav)
        try Self.createTestWav(at: micWav)

        let result = try await AudioArchiver.archive(
            systemAudio: systemWav,
            micAudio: micWav,
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(result.archivePath.lastPathComponent == "my-meeting-2026.m4a")
    }

    @Test func archiveKeepsWavsOnFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        // Write invalid WAV data
        try Data([0, 1, 2]).write(to: systemWav)
        try Data([0, 1, 2]).write(to: micWav)

        do {
            _ = try await AudioArchiver.archive(
                systemAudio: systemWav,
                micAudio: micWav,
                outputDirectory: dir,
                bitrateKbps: 64
            )
            Issue.record("Expected archive to throw on invalid input")
        } catch {
            #expect(FileManager.default.fileExists(atPath: systemWav.path))
            #expect(FileManager.default.fileExists(atPath: micWav.path))
        }
    }
}
