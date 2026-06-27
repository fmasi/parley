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

    // MARK: - archiveSystemOnly (single-stream chunks flush to m4a too, #59)

    @Test func archiveSystemOnlyCreatesM4aAndDeletesWav() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("solo-0.wav")
        try Self.createTestWav(at: systemWav, frequency: 660)

        let result = try await AudioArchiver.archiveSystemOnly(
            systemAudio: systemWav,
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(result.archivePath.lastPathComponent == "solo-0.m4a")
        #expect(FileManager.default.fileExists(atPath: result.archivePath.path))
        // Source WAV is deleted — no lossless WAV left behind.
        #expect(!FileManager.default.fileExists(atPath: systemWav.path))

        // Keeps the standard stereo (L=mic silent, R=system) layout for re-ingestion.
        let file = try AVAudioFile(forReading: result.archivePath)
        #expect(file.processingFormat.channelCount == 2)
    }

    @Test func archiveSystemOnlyKeepsWavOnFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("solo.wav")
        try Data([0, 1, 2]).write(to: systemWav)  // invalid WAV

        do {
            _ = try await AudioArchiver.archiveSystemOnly(
                systemAudio: systemWav,
                outputDirectory: dir,
                bitrateKbps: 64
            )
            Issue.record("Expected archiveSystemOnly to throw on invalid input")
        } catch {
            #expect(FileManager.default.fileExists(atPath: systemWav.path))
        }
    }

    // MARK: - archiveAll (recovery: archive every contributing segment)

    @Test func archiveAllArchivesEverySegment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s0 = dir.appendingPathComponent("meeting-0.wav")
        let m0 = dir.appendingPathComponent("meeting-0_mic.wav")
        let s1 = dir.appendingPathComponent("meeting-1.wav")
        let m1 = dir.appendingPathComponent("meeting-1_mic.wav")
        for url in [s0, m0, s1, m1] { try Self.createTestWav(at: url) }

        let out = await AudioArchiver.archiveAll(
            pairs: [.init(system: s0, mic: m0), .init(system: s1, mic: m1)],
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.pathExtension == "m4a" })
        #expect(out.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // Every source WAV consumed.
        for w in [s0, m0, s1, m1] { #expect(!FileManager.default.fileExists(atPath: w.path)) }
    }

    @Test func archiveAllKeepsSystemWavWhenMicMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s0 = dir.appendingPathComponent("seg-0.wav")
        try Self.createTestWav(at: s0)

        let out = await AudioArchiver.archiveAll(
            pairs: [.init(system: s0, mic: nil)],
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(out == [s0])
        #expect(FileManager.default.fileExists(atPath: s0.path))  // kept, not deleted
    }

    @Test func archiveAllIsolatesPerSegmentFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let goodSys = dir.appendingPathComponent("good-0.wav")
        let goodMic = dir.appendingPathComponent("good-0_mic.wav")
        try Self.createTestWav(at: goodSys)
        try Self.createTestWav(at: goodMic)
        let badSys = dir.appendingPathComponent("bad-1.wav")
        let badMic = dir.appendingPathComponent("bad-1_mic.wav")
        try Data([0, 1, 2]).write(to: badSys)
        try Data([0, 1, 2]).write(to: badMic)

        let out = await AudioArchiver.archiveAll(
            pairs: [.init(system: goodSys, mic: goodMic), .init(system: badSys, mic: badMic)],
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(out.count == 2)
        #expect(out[0].pathExtension == "m4a")           // good segment archived
        #expect(out[1] == badSys)                          // bad segment kept as WAV
        #expect(FileManager.default.fileExists(atPath: badSys.path))
    }
}
