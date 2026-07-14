import Foundation
import Testing
@testable import TranscriberCore

@Suite struct ChunkLocatorTests {

    @Test func locatesWithinSingleChunk() {
        let loc = ChunkLocator.locate(start: 10, end: 20, chunkDurations: [1800])
        #expect(loc == ChunkLocator.Location(index: 0, start: 10, end: 20))
    }

    @Test func locatesWithinSecondChunk() {
        let loc = ChunkLocator.locate(start: 1900, end: 1950, chunkDurations: [1800, 1281])
        #expect(loc == ChunkLocator.Location(index: 1, start: 100, end: 150))
    }

    /// The real "Yumi" case (issue #132): a 2-chunk recording where the speaker's
    /// best sample lives in chunk 2. Previously resolved against chunk 1 and played nothing.
    @Test func locatesSampleInLaterChunk() throws {
        let loc = try #require(ChunkLocator.locate(
            start: 3010.0, end: 3049.6, chunkDurations: [1800.021333, 1280.757333]
        ))
        #expect(loc.index == 1)
        #expect(abs(loc.start - 1209.978667) < 0.001)
        #expect(abs(loc.end - 1249.578667) < 0.001)
    }

    @Test func chunkBoundaryStartBelongsToLaterChunk() {
        let loc = ChunkLocator.locate(start: 1800, end: 1810, chunkDurations: [1800, 1281])
        #expect(loc == ChunkLocator.Location(index: 1, start: 0, end: 10))
    }

    /// A sample spanning a seam is truncated to the chunk holding its start, rather
    /// than reading past EOF (which silently produced zero frames before).
    @Test func clampsSampleSpanningChunkBoundary() {
        let loc = ChunkLocator.locate(start: 1790, end: 1810, chunkDurations: [1800, 1281])
        #expect(loc == ChunkLocator.Location(index: 0, start: 1790, end: 1800))
    }

    @Test func clampsEndToChunkDuration() {
        let loc = ChunkLocator.locate(start: 3000, end: 9999, chunkDurations: [1800, 1281])
        #expect(loc?.index == 1)
        #expect(loc?.end == 1281)
    }

    @Test func returnsNilPastEndOfTimeline() {
        #expect(ChunkLocator.locate(start: 3100, end: 3110, chunkDurations: [1800, 1281]) == nil)
    }

    @Test func returnsNilForNegativeStart() {
        #expect(ChunkLocator.locate(start: -5, end: 10, chunkDurations: [1800]) == nil)
    }

    @Test func returnsNilForEmptyChunkList() {
        #expect(ChunkLocator.locate(start: 0, end: 10, chunkDurations: []) == nil)
    }

    @Test func returnsNilForZeroLengthRange() {
        #expect(ChunkLocator.locate(start: 100, end: 100, chunkDurations: [1800]) == nil)
    }

    @Test func returnsNilWhenRangeStartsExactlyAtTimelineEnd() {
        #expect(ChunkLocator.locate(start: 3081, end: 3090, chunkDurations: [1800, 1281]) == nil)
    }

    /// A chunk of unknown length (missing / corrupt / evicted by the storage quota) makes every
    /// LATER position un-anchorable: without its duration we cannot know where the next chunk
    /// starts. Returning a location anyway would silently close the gap and play the WRONG
    /// speaker's voice, which is the exact harm the rename dialog exists to prevent.
    @Test func unknownDurationChunkMakesLaterPositionsUnresolvable() {
        #expect(ChunkLocator.locate(start: 10, end: 20, chunkDurations: [nil, 1800]) == nil)
        #expect(ChunkLocator.locate(start: 2000, end: 2010, chunkDurations: [1800, nil, 1800]) == nil)
    }

    /// Positions BEFORE the unknown chunk are still anchored, so they stay playable.
    @Test func positionsBeforeUnknownDurationChunkStillResolve() {
        let loc = ChunkLocator.locate(start: 10, end: 20, chunkDurations: [1800, nil])
        #expect(loc == ChunkLocator.Location(index: 0, start: 10, end: 20))
    }

    /// Samples are capped so playback never allocates a buffer sized from an
    /// arbitrarily long diarization segment (a 406s segment was observed in the wild).
    @Test func capsSampleDuration() {
        let loc = ChunkLocator.locate(
            start: 100, end: 500, chunkDurations: [1800], maxDuration: 15
        )
        #expect(loc == ChunkLocator.Location(index: 0, start: 100, end: 115))
    }

    @Test func capDoesNotExtendShortSamples() {
        let loc = ChunkLocator.locate(
            start: 100, end: 105, chunkDurations: [1800], maxDuration: 15
        )
        #expect(loc == ChunkLocator.Location(index: 0, start: 100, end: 105))
    }
}

@Suite struct SpeakerSampleLocatorTests {

    private func url(_ s: String) -> URL { URL(fileURLWithPath: s) }

    @Test func classifiesMultipleArchivesAsChunks() {
        let paths = [url("/r/a-0.m4a"), url("/r/a-1.m4a")]
        #expect(SpeakerSampleLocator.classify(audioPaths: paths) == .chunkedArchives(paths))
    }

    /// A single archive is the same layout with one chunk — previously the ONLY case
    /// handled correctly (#132).
    @Test func classifiesSingleArchiveAsOneChunk() {
        let paths = [url("/r/a.m4a")]
        #expect(SpeakerSampleLocator.classify(audioPaths: paths) == .chunkedArchives(paths))
    }

    @Test func classifiesDualWavAsLegacy() {
        let sys = url("/r/sys.wav")
        let mic = url("/r/mic.wav")
        #expect(
            SpeakerSampleLocator.classify(audioPaths: [sys, mic])
                == .legacyDualStream(remote: sys, local: mic)
        )
    }

    @Test func classifiesEmptyAsUnavailable() {
        #expect(SpeakerSampleLocator.classify(audioPaths: []) == .unavailable)
    }

    @Test func unavailableLayoutLocatesNothing() {
        let hit = SpeakerSampleLocator.locate(
            source: "remote", start: 0, end: 10, layout: .unavailable, chunkDurations: []
        )
        #expect(hit == nil)
    }

    /// Channel selection follows the segment's `source`, never the display name — so renaming
    /// a speaker cannot flip which channel we read (#132).
    @Test func channelAndFileFollowSourceNotName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sys = dir.appendingPathComponent("sys.wav")
        let mic = dir.appendingPathComponent("mic.wav")
        try Data([0]).write(to: sys)
        try Data([0]).write(to: mic)

        let layout = SpeakerSampleLocator.classify(audioPaths: [sys, mic])

        let local = try #require(SpeakerSampleLocator.locate(
            source: "local", start: 10, end: 20, layout: layout, chunkDurations: []
        ))
        #expect(local.isLocal)
        #expect(local.url == mic)

        let remote = try #require(SpeakerSampleLocator.locate(
            source: "remote", start: 10, end: 20, layout: layout, chunkDurations: []
        ))
        #expect(!remote.isLocal)
        #expect(remote.url == sys)
    }

    /// Playback must never size a buffer from a 400s diarization segment.
    @Test func capsLegacySampleDuration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sys = dir.appendingPathComponent("sys.wav")
        try Data([0]).write(to: sys)

        let hit = try #require(SpeakerSampleLocator.locate(
            source: "remote", start: 100, end: 506,
            layout: .legacyDualStream(remote: sys, local: nil), chunkDurations: [],
            maxSampleDuration: 15
        ))
        #expect(hit.end - hit.start == 15)
    }

    /// A chunk whose AAC archiving failed keeps its raw .wav. Reading such a mixed list as a
    /// legacy [system, mic] pair is the #132 hazard reintroduced — it must classify as chunks.
    @Test func classifiesMixedArchiveAndWavAsChunks() {
        let paths = [url("/r/a-0.m4a"), url("/r/a-1.wav"), url("/r/a-2.m4a")]
        #expect(SpeakerSampleLocator.classify(audioPaths: paths) == .chunkedArchives(paths))
    }

    /// More than two WAVs cannot be a [system, mic] pair.
    @Test func classifiesManyWavsAsChunks() {
        let paths = [url("/r/c0.wav"), url("/r/c1.wav"), url("/r/c2.wav")]
        #expect(SpeakerSampleLocator.classify(audioPaths: paths) == .chunkedArchives(paths))
    }

    /// A WAV-fallback chunk carries system audio only — there is no mic channel in it, so a
    /// local sample must resolve to nothing rather than playing the remote participants.
    @Test func localSampleInWavFallbackChunkIsUnplayable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavChunk = dir.appendingPathComponent("c0.wav")
        try Data([0]).write(to: wavChunk)
        let layout = AudioLayout.chunkedArchives([wavChunk])

        let local = SpeakerSampleLocator.locate(
            source: "local", start: 10, end: 20, layout: layout, chunkDurations: [1800]
        )
        #expect(local == nil)

        let remote = try #require(SpeakerSampleLocator.locate(
            source: "remote", start: 10, end: 20, layout: layout, chunkDurations: [1800]
        ))
        #expect(!remote.isLocal)
    }

    @Test func missingFileYieldsNoLocation() {
        let hit = SpeakerSampleLocator.locate(
            source: "remote", start: 0, end: 10,
            layout: .legacyDualStream(remote: url("/nope/missing.wav"), local: nil),
            chunkDurations: []
        )
        #expect(hit == nil)
    }
}
