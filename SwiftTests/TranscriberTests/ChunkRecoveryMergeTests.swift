import Testing
import Foundation
@testable import TranscriberCore

/// Regression guard for the #92 data-loss fix: once the crash-orphaned chunk is re-ingested into
/// the session's chunk list, the merge must keep BOTH the pre-crash and post-crash audio — even
/// when the chunk indices have a gap (the on-disk symptom was `{0, 2}` with no `1`).
struct ChunkRecoveryMergeTests {

    private func chunk(
        index: Int, startOffset: TimeInterval, meetingStart: Date,
        text: String, segStart: Double, segEnd: Double
    ) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: meetingStart.addingTimeInterval(startOffset),
            audioPath: "chunk-\(index).m4a",
            segments: [ProcessedChunk.Segment(
                start: segStart, end: segEnd, text: text, speaker: "Speaker 1", source: "local"
            )],
            speakerDatabase: [:]
        )
    }

    @Test func recoveredOrphanAndRecoveryChunkBothMerge() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 100_000)
        // Orphan chunk 0: 0–954s of pre-crash audio. Recovery chunk 1: starts 960s in, 0–150s.
        let chunks = [
            chunk(index: 0, startOffset: 0, meetingStart: meetingStart, text: "ORPHAN", segStart: 0, segEnd: 954),
            chunk(index: 1, startOffset: 960, meetingStart: meetingStart, text: "RECOVERY", segStart: 0, segEnd: 150),
        ]
        let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: [:], meetingStart: meetingStart)
        #expect(result.segments.map { $0.text } == ["ORPHAN", "RECOVERY"])  // both present, time-ordered
        #expect(result.chunkCount == 2)
        #expect(result.segments.last?.elapsed == 960)                        // recovery after the orphan
    }

    @Test func gapInChunkIndicesIsTolerated() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 200_000)
        // Indices {0, 2} (no 1), supplied out of order — merge must keep both, sorted by elapsed.
        let chunks = [
            chunk(index: 2, startOffset: 960, meetingStart: meetingStart, text: "RECOVERY", segStart: 0, segEnd: 150),
            chunk(index: 0, startOffset: 0, meetingStart: meetingStart, text: "ORPHAN", segStart: 0, segEnd: 954),
        ]
        let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: [:], meetingStart: meetingStart)
        #expect(result.segments.map { $0.text } == ["ORPHAN", "RECOVERY"])
        #expect(result.chunkCount == 2)
    }
}
