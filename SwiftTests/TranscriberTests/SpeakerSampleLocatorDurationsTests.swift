import Testing
import Foundation
@testable import TranscriberCore

/// `SpeakerSampleLocator.durations(for:cached:)` (#204): a chunked recording's durations can come
/// from `metadata.chunk_durations` (stamped once by `TranscriptAssembler.reconcileAudioPaths`)
/// instead of opening every chunk file — the O(chunks) `AVAudioFile` opens the rename dialog used
/// to pay on every open and every re-detect.
///
/// These use nonexistent chunk paths deliberately: `durations(of:)` (the file-opening fallback)
/// can only ever return `nil` for a path that doesn't exist, so a non-nil result unambiguously
/// proves the cached values were used rather than a fallback re-read.
@Suite("SpeakerSampleLocator cached durations")
struct SpeakerSampleLocatorDurationsTests {

    private func chunks(_ n: Int) -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/does/not/exist/chunk-\($0).m4a") }
    }

    @Test("a cached array matching the chunk count is used as-is, with no file re-read")
    func usesCacheWhenCountMatchesAndAllPositive() {
        let layout = AudioLayout.chunkedArchives(chunks(2))
        let result = SpeakerSampleLocator.durations(for: layout, cached: [12.5, 30.0])
        #expect(result == [12.5, 30.0])
    }

    @Test("a cached array with the wrong count falls back to reading the files")
    func fallsBackOnCountMismatch() {
        let layout = AudioLayout.chunkedArchives(chunks(2))
        // Only one cached value for two chunks — distrust it entirely.
        let result = SpeakerSampleLocator.durations(for: layout, cached: [12.5])
        // Falls back to `durations(of:)`, which reports nil for files that don't exist.
        #expect(result == [nil, nil])
    }

    @Test("a cached array containing a zero (the unreadable-when-stamped sentinel) falls back")
    func fallsBackOnZeroSentinel() {
        let layout = AudioLayout.chunkedArchives(chunks(2))
        let result = SpeakerSampleLocator.durations(for: layout, cached: [12.5, 0])
        #expect(result == [nil, nil])
    }

    @Test("no cached array at all falls back, matching pre-#204 behaviour")
    func fallsBackWhenNoCacheGiven() {
        let layout = AudioLayout.chunkedArchives(chunks(1))
        let result = SpeakerSampleLocator.durations(for: layout)
        #expect(result == [nil])
    }

    @Test("a non-chunked layout ignores the cache and returns empty, as before")
    func nonChunkedLayoutIgnoresCache() {
        let result = SpeakerSampleLocator.durations(
            for: .legacyDualStream(remote: nil, local: nil), cached: [12.5])
        #expect(result.isEmpty)
    }
}
