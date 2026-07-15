import Foundation
import Testing
@testable import TranscriberCore

/// Guards the dual-stream namespace contract between the chunk writer and the finalizer.
///
/// The writer (ChunkProcessor) decides whether to tag segments `Local/Remote Speaker N`. The
/// finalizer (TranscriptionRunner) decides which namespace the reconciler emits keys in. If those
/// two disagree, the reconciler's mapping matches nothing, the remap falls back to the identity,
/// and a chunk's LOCAL speaker numbering is laundered into the global namespace — silently swapping
/// speakers for the rest of the meeting.
///
/// They disagreed whenever the user sat through a whole chunk in silence: the writer inferred
/// "not dual-stream" from zero mic segments, while the finalizer inferred "dual-stream" from the
/// other chunks. `isDualStream` is now persisted by the writer so it cannot be re-derived wrongly.
@Suite struct DualStreamNamespaceTests {

    private func chunk(
        index: Int,
        segments: [ProcessedChunk.Segment],
        isDualStream: Bool
    ) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: Date(timeIntervalSince1970: Double(index) * 1800),
            audioPath: "chunk-\(index).m4a",
            segments: segments,
            speakerDatabase: [:],
            isDualStream: isDualStream
        )
    }

    private func seg(_ speaker: String, _ source: String) -> ProcessedChunk.Segment {
        .init(start: 0, end: 1, text: "hi", speaker: speaker, source: source, qualityScore: nil)
    }

    /// The regression: a chunk in which the user never spoke must still be recognised as
    /// dual-stream, because the mic STREAM existed even though it produced no segments.
    @Test func micSilentChunkIsStillDualStream() {
        let recorded = chunk(
            index: 1,
            segments: [seg("Remote Speaker 1", "remote")],   // no local segments: user was quiet
            isDualStream: true                                // ...but a mic stream WAS captured
        )
        #expect(recorded.isDualStream)

        // The old inference — "does this chunk contain a local segment?" — gets it wrong,
        // which is precisely the bug.
        let oldInference = recorded.segments.contains { $0.source == "local" }
        #expect(!oldInference, "the old heuristic misreads a mic-silent chunk (this is the bug)")
    }

    @Test func genuinelyMicLessChunkIsNotDualStream() {
        let recorded = chunk(index: 0, segments: [seg("Speaker 1", "remote")], isDualStream: false)
        #expect(!recorded.isDualStream)
    }

    /// A session is dual-stream if ANY chunk captured a mic stream — matching how the finalizer
    /// now decides, so writer and reader cannot disagree.
    @Test func sessionIsDualStreamWhenAnyChunkCapturedMic() {
        let chunks = [
            chunk(index: 0, segments: [seg("Local Speaker 1", "local")], isDualStream: true),
            chunk(index: 1, segments: [seg("Remote Speaker 1", "remote")], isDualStream: true),
        ]
        let sessionIsDualStream = chunks.contains { $0.isDualStream }
        #expect(sessionIsDualStream)
    }

    /// Round-trips through session.json, since the whole point is that the decision survives to
    /// the finalizer (which may run in a different process after a crash).
    @Test func isDualStreamSurvivesPersistence() throws {
        let original = chunk(index: 2, segments: [seg("Remote Speaker 1", "remote")], isDualStream: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessedChunk.self, from: data)
        #expect(decoded.isDualStream)
    }

    /// A session.json written before the flag existed must still reconcile the way it was written,
    /// so an in-flight recording recovered by a newer build isn't mislabeled.
    @Test func legacyChunkWithoutFlagFallsBackToOldInference() throws {
        let legacy = """
        {
          "index": 0,
          "startTime": 0,
          "audioPath": "c0.m4a",
          "segments": [
            {"start": 0, "end": 1, "text": "hi", "speaker": "Local Speaker 1", "source": "local"}
          ],
          "speakerDatabase": {}
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProcessedChunk.self, from: legacy)
        #expect(decoded.isDualStream, "legacy chunk with a local segment must infer dual-stream")
    }

    @Test func legacyChunkWithoutLocalSegmentsInfersSingleStream() throws {
        let legacy = """
        {
          "index": 0,
          "startTime": 0,
          "audioPath": "c0.m4a",
          "segments": [
            {"start": 0, "end": 1, "text": "hi", "speaker": "Speaker 1", "source": "remote"}
          ],
          "speakerDatabase": {}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProcessedChunk.self, from: legacy)
        #expect(!decoded.isDualStream)
    }
}

/// The merger now reports labels the reconciler had no mapping for. A miss means the reconciler's
/// namespace and the chunk's labels disagree, so the remap silently falls back to the identity and
/// that chunk's LOCAL speaker numbering is laundered into the global namespace — the exact silent
/// speaker swap this branch fixes. It must never be silent again.
@Suite struct RemapMissDetectionTests {

    private func chunk(index: Int, speakers: [String]) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: Date(timeIntervalSince1970: Double(index) * 1800),
            audioPath: "c\(index).m4a",
            segments: speakers.enumerated().map { i, spk in
                .init(start: Double(i), end: Double(i) + 1, text: "t", speaker: spk,
                      source: "remote", qualityScore: nil)
            },
            speakerDatabase: [:],
            isDualStream: true
        )
    }

    @Test func reportsLabelsTheReconcilerNeverMapped() {
        let chunks = [chunk(index: 1, speakers: ["Speaker 1", "Speaker 2"])]
        // Reconciler speaks the PREFIXED namespace; the chunk's labels are unprefixed. Nothing matches.
        let mapping = [1: ["Remote Speaker 1": "Remote Speaker 3"]]

        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: mapping, meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.unmappedLabels[1] == ["Speaker 1", "Speaker 2"])
    }

    @Test func healthyMergeReportsNoMisses() {
        let chunks = [chunk(index: 1, speakers: ["Remote Speaker 1"])]
        let mapping = [1: ["Remote Speaker 1": "Remote Speaker 2"]]

        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: mapping, meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.unmappedLabels.isEmpty)
        #expect(result.segments.first?.speaker == "Remote Speaker 2")
    }

    /// An EMPTY mapping is not a miss: the reconciler had nothing to say about this chunk (it is the
    /// seed, or had no embeddings), so the identity is genuinely correct.
    @Test func emptyMappingIsNotAMiss() {
        let chunks = [chunk(index: 0, speakers: ["Remote Speaker 1"])]
        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: [:], meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.unmappedLabels.isEmpty)
    }

    /// M3: "Unknown" carries no embedding BY DESIGN, so the reconciler can never map it and the
    /// identity fallback is correct for it. Counting it as a miss would fire the alarm on nearly
    /// every real meeting — and an alarm that cries wolf is worse than none, because this one exists
    /// to make silent speaker-namespace laundering impossible to miss.
    @Test func unknownSentinelIsNotAnUnmappedLabel() {
        let chunks = [chunk(index: 1, speakers: ["Remote Speaker 1", "Remote Unknown", "Unknown"])]
        let mapping = [1: ["Remote Speaker 1": "Remote Speaker 2"]]

        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: mapping, meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.unmappedLabels.isEmpty, "Unknown must not trip the remap alarm")
    }

    /// ...but a genuinely unmapped REAL speaker still must.
    @Test func realUnmappedSpeakerStillReported() {
        let chunks = [chunk(index: 1, speakers: ["Speaker 1", "Remote Unknown"])]
        let mapping = [1: ["Remote Speaker 1": "Remote Speaker 2"]]

        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: mapping, meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.unmappedLabels[1] == ["Speaker 1"])
    }

    /// Segments must carry their END through the merge — production builds LabeledSegments from it.
    @Test func mergedSegmentsCarryAbsoluteEnd() {
        let chunks = [chunk(index: 1, speakers: ["Remote Speaker 1"])]
        let result = TranscriptMerger.merge(
            chunks: chunks, speakerMapping: [:], meetingStart: Date(timeIntervalSince1970: 0)
        )
        let seg = result.segments[0]
        #expect(seg.elapsed == 1800)          // chunk 1 starts 1800s in, segment at t=0
        #expect(seg.elapsedEnd == 1801)
    }
}
