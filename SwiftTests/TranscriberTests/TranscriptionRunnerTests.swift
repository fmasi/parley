import Foundation
import Testing
@testable import TranscriberCore

/// #135 H2: each per-segment WAV in a crash-recovered / CLI multi-segment run starts at its own
/// t=0. Without a cumulative offset, segment 2's minute-2 line collides with segment 1's minute-2
/// line in the merged transcript. `segmentStartOffsets` is the pure, unit-tested guarantee that
/// `run()` turns each segment's file-relative timestamps into absolute ones.
@Suite struct TranscriptionRunnerTests {

    @Test func cumulativeOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [60, 45, 30]) == [0, 60, 105])
    }

    @Test func singleSegmentHasNoOffset() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [42]) == [0])
    }

    @Test func noSegmentsYieldsNoOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: []) == [])
    }
}

/// #135 H3: each recovery/CLI segment is diarized independently, so segment 0's "Speaker 1" and
/// segment 1's "Speaker 1" are unrelated raw labels — they may be the SAME person or two DIFFERENT
/// people. `reconcileRecoverySegments` reuses `SpeakerReconciler`'s cosine matching (rather than a
/// hand-rolled comparator) to decide which, and returns a segment-namespaced mapping so `run()` can
/// relabel every segment's segments into one consistent global namespace before merging.
@Suite struct TranscriptionRunnerReconciliationTests {

    @Test func crossSegmentIdentityYieldsTwoSpeakers() {
        // Two segments, each a single speaker under the same raw label "Speaker 1", but with
        // far-apart embeddings — i.e. two different people who both happened to be diarized as
        // "Speaker 1" locally. Must NOT collapse into one global speaker.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0, 1, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 2)
    }

    @Test func crossSegmentMatchingVoiceprintYieldsOneSpeaker() {
        // Same person's voiceprint (near-identical embedding) reappearing under "Speaker 1" in
        // both segments must reconcile to the SAME global label.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0.99, 0.01, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 1)
    }
}

/// #246: the non-split CLI path (`Parley transcribe -i a.wav --output-dir ./out`) had the same gap
/// as the split path — nothing created `./out` — but found out only AFTER the whole transcription
/// had run, when the transcript write failed. `run()` now ensures its output directory up front.
///
/// The input is a header-only WAV (a recording with no audio), which `run()` skips without ever
/// calling the engine — so these tests need no model and no media daemon.
@Suite struct TranscriptionRunnerOutputDirectoryTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-outdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHeaderOnlyWav(in dir: URL) throws -> URL {
        let wav = dir.appendingPathComponent("empty.wav")
        try WavFileWriter(path: wav.path).finalize()
        return wav
    }

    /// FluidAudio is pinned so the test does not depend on which engine this macOS defaults to.
    private var config: Config {
        var config = Config.default
        config.engine = .fluidAudio
        return config
    }

    @MainActor
    @Test func runCreatesAMissingOutputDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeHeaderOnlyWav(in: dir)

        let outputDir = dir.appendingPathComponent("out/nested", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: outputDir.path))

        let result = try await TranscriptionRunner().run(
            systemAudio: wav, micAudio: nil, outputDirectory: outputDir, config: config)

        #expect(result.jsonPath.deletingLastPathComponent().path == outputDir.path)
        let data = try Data(contentsOf: result.jsonPath)
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    }

    /// Fails before any transcription work, naming the directory rather than the transcript file.
    @MainActor
    @Test func runFailsNamingAnUncreatableOutputDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeHeaderOnlyWav(in: dir)

        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocker)

        do {
            _ = try await TranscriptionRunner().run(
                systemAudio: wav, micAudio: nil, outputDirectory: blocker, config: config)
            Issue.record("writing a transcript into a path occupied by a regular file must throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains(blocker.path), "error must name the output directory: \(message)")
            #expect(!message.contains("empty.json"), "error must not name a downstream file: \(message)")
        }
        #expect(try Data(contentsOf: blocker) == Data("occupied".utf8))
    }
}
