import Testing
import Foundation
import AVFoundation
@testable import TranscriberCore

/// `.serialized`: these tests drive AVAssetWriter/AVAssetReader, which are clients of shared media XPC
/// daemons. A timed-out CI run on 2026-09-04 showed 27 such tests starting within six
/// seconds and none ever finishing — a wedged daemon blocks every client forever. Running
/// this suite's cases one at a time reduces how many are ever in flight together.
///
/// NOTE: CI currently also runs the whole suite with `--no-parallel`, because serialising
/// these suites alone cut the frozen set from 27 tests to 15 and did not stop the stall —
/// it is cross-suite. These traits are kept because they document which suites are
/// implicated, and they keep the constraint if parallelism is ever restored.
@Suite(.serialized)
struct AudioArchiverTests {

    /// Helper: create a mono WAV file with a sine wave (48 kHz unless overridden).
    private static func createTestWav(
        at url: URL,
        frequency: Double = 440.0,
        durationSeconds: Double = 1.0,
        sampleRate: Double = 48000
    ) throws {
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

    /// The archiver takes its encode rate from the MIC file and never consulted the system file's.
    /// `AVAudioFile.read(into:)` does not resample when the buffer's rate differs from the file's —
    /// it raw-copies frames — so a rate-divergent pair encoded "successfully" into a structurally
    /// perfect .m4a whose system channel was pitch-shifted and half-length, passed the (weak)
    /// verification, and then BOTH source WAVs were deleted. That is irreversible: the lossless
    /// header-rewrite rescue that gotcha #58 depends on needs the original WAV.
    ///
    /// A rate mismatch means we do not understand the inputs. Refuse, and keep the sources.
    @Test func archiveRefusesRateMismatchAndKeepsSourceWavs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-ratemismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("meeting.wav")
        let micWav = dir.appendingPathComponent("meeting_mic.wav")
        // Exactly the 2026-08-04 shape: system captured at 24 kHz, mic healthy at 48 kHz.
        try Self.createTestWav(at: systemWav, frequency: 880, sampleRate: 24000)
        try Self.createTestWav(at: micWav, frequency: 440, sampleRate: 48000)

        await #expect(throws: (any Error).self) {
            _ = try await AudioArchiver.archive(
                systemAudio: systemWav,
                micAudio: micWav,
                outputDirectory: dir,
                bitrateKbps: 64
            )
        }

        // The whole point: the originals must survive so the recording stays recoverable.
        #expect(FileManager.default.fileExists(atPath: systemWav.path))
        #expect(FileManager.default.fileExists(atPath: micWav.path))
    }

    // MARK: - The duration guard that licenses deleting the only lossless copy

    /// `verify` is what permits step 5 to delete the source WAVs. "Non-empty with a track" was far
    /// too weak a bar — a truncated or half-encoded archive satisfies it perfectly — so the duration
    /// comparison is the part that makes "verified" mean something. Test it directly on both paths.
    @Test func verifyRejectsAnArchiveShorterThanItsSource() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-short-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Produce a real, structurally valid 1-second archive...
        let systemWav = dir.appendingPathComponent("sysonly.wav")
        try Self.createTestWav(at: systemWav, frequency: 660, durationSeconds: 1.0)
        let result = try await AudioArchiver.archiveSystemOnly(
            systemAudio: systemWav, outputDirectory: dir, bitrateKbps: 64)

        // ...then verify it while CLAIMING the source was 30 seconds long: exactly the shape of a
        // truncated encode. It must be rejected rather than blessed.
        await #expect(throws: (any Error).self) {
            try await AudioArchiver.verify(outputURL: result.archivePath, expectedSeconds: 30.0)
        }
    }

    /// The same archive must PASS against its true duration — the guard has to be precise, or it
    /// would strand every recording as an un-archivable WAV.
    @Test func verifyAcceptsAnArchiveMatchingItsSource() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let systemWav = dir.appendingPathComponent("sysonly.wav")
        try Self.createTestWav(at: systemWav, frequency: 660, durationSeconds: 1.0)
        let result = try await AudioArchiver.archiveSystemOnly(
            systemAudio: systemWav, outputDirectory: dir, bitrateKbps: 64)

        try await AudioArchiver.verify(outputURL: result.archivePath, expectedSeconds: 1.0)
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

    @Test func archiveAllEncodesSystemOnlySegmentToM4a() async throws {
        // #105: a system-only segment (no mic) on the archiveAll batch path must still flush to .m4a
        // via archiveSystemOnly — it used to be returned as a raw .wav, leaking a lossless file.
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

        #expect(out.count == 1)
        #expect(out[0].lastPathComponent == "seg-0.m4a")          // encoded, not the raw WAV
        #expect(FileManager.default.fileExists(atPath: out[0].path))
        #expect(!FileManager.default.fileExists(atPath: s0.path)) // source WAV flushed, not left behind
        let file = try AVAudioFile(forReading: out[0])
        #expect(file.processingFormat.channelCount == 2)          // stereo layout, mic channel silent
    }

    @Test func archiveAllKeepsSystemOnlyWavWhenEncodingFails() async throws {
        // The #93 per-segment isolation must still hold for the new system-only branch: a corrupt
        // system WAV keeps its .wav and never throws.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bad = dir.appendingPathComponent("bad-0.wav")
        try Data([0, 1, 2]).write(to: bad)  // not a valid WAV

        let out = await AudioArchiver.archiveAll(
            pairs: [.init(system: bad, mic: nil)],
            outputDirectory: dir,
            bitrateKbps: 64
        )

        #expect(out == [bad])
        #expect(FileManager.default.fileExists(atPath: bad.path))  // kept on failure
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
