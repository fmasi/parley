import Testing
import Foundation
@testable import TranscriberCore

/// When archiving fails, the chunk keeps raw WAV(s) and the transcript records one of them.
/// Which one it records decides whether the rename dialog can play anything (#183).
///
/// On `2026-09-02/150633-Paul feedback` it recorded the SYSTEM wav — a 44-byte empty header — and
/// never mentioned the 60.8 MB `_mic.wav` that held the only audio the recording had. The layout
/// then resolved `local: nil`, every segment was `source: "local"`, and the dialog drew no play
/// button.
@Suite("Mic-only fallback")
struct MicOnlyFallbackTests {

    // MARK: - Which WAV represents the chunk

    @Test("a chunk whose system track is empty is represented by its mic WAV")
    func emptySystemFallsBackToMicWav() {
        #expect(AudioArchiver.fallbackAudioName(
            systemName: "call-0.wav", systemHasFrames: false,
            micName: "call-0_mic.wav", micHasFrames: true) == "call-0_mic.wav")
    }

    @Test("a normal chunk is still represented by its system WAV")
    func normalChunkKeepsTheSystemWav() {
        #expect(AudioArchiver.fallbackAudioName(
            systemName: "call-0.wav", systemHasFrames: true,
            micName: "call-0_mic.wav", micHasFrames: true) == "call-0.wav")
    }

    @Test("with no mic file at all the system WAV is used even when empty")
    func noMicMeansSystemWav() {
        #expect(AudioArchiver.fallbackAudioName(
            systemName: "call-0.wav", systemHasFrames: false,
            micName: nil, micHasFrames: false) == "call-0.wav")
    }

    // MARK: - What a WAV fallback can play

    @Test("a _mic.wav fallback carries LOCAL audio, not system audio")
    func micWavIsNotSystemOnly() {
        #expect(SpeakerSampleLocator.isSystemOnly(URL(fileURLWithPath: "/r/call-0_mic.wav")) == false)
        #expect(SpeakerSampleLocator.isLocalOnly(URL(fileURLWithPath: "/r/call-0_mic.wav")) == true)
    }

    @Test("a plain WAV fallback still carries system audio only")
    func plainWavIsSystemOnly() {
        #expect(SpeakerSampleLocator.isSystemOnly(URL(fileURLWithPath: "/r/call-0.wav")) == true)
        #expect(SpeakerSampleLocator.isLocalOnly(URL(fileURLWithPath: "/r/call-0.wav")) == false)
    }

    @Test("a stereo archive carries both channels")
    func archiveCarriesBothChannels() {
        #expect(SpeakerSampleLocator.isSystemOnly(URL(fileURLWithPath: "/r/call-0.m4a")) == false)
        #expect(SpeakerSampleLocator.isLocalOnly(URL(fileURLWithPath: "/r/call-0.m4a")) == false)
    }

    @Test("a local sample resolves against a _mic.wav fallback chunk")
    func localSampleResolvesOnMicWavFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("call-0_mic.wav")
        FileManager.default.createFile(atPath: mic.path, contents: Data())

        let hit = SpeakerSampleLocator.locate(
            source: "local", start: 5, end: 8,
            layout: .chunkedArchives([mic]), chunkDurations: [60])
        #expect(hit?.url == mic)
        #expect(hit?.isLocal == true)
    }

    @Test("a remote sample does NOT resolve against a _mic.wav fallback chunk")
    func remoteSampleIsRefusedOnMicWavFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miconly-locate2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("call-0_mic.wav")
        FileManager.default.createFile(atPath: mic.path, contents: Data())

        // Playing the mic track for a "Remote Speaker" would audition the wrong person entirely.
        let hit = SpeakerSampleLocator.locate(
            source: "remote", start: 5, end: 8,
            layout: .chunkedArchives([mic]), chunkDurations: [60])
        #expect(hit == nil)
    }
}
