import Testing
import Foundation
@testable import TranscriberCore

@Suite("TranscriptMerger")
struct TranscriptMergerTests {

    // MARK: - Helpers

    private func makeChunk(
        index: Int,
        startTime: Date,
        segments: [ProcessedChunk.Segment]
    ) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: startTime,
            audioPath: "/tmp/chunk\(index).wav",
            segments: segments,
            speakerDatabase: [:]
        )
    }

    private func makeSeg(
        start: Double,
        end: Double,
        text: String,
        speaker: String = "spk_0",
        source: String = "mic",
        quality: Float? = nil
    ) -> ProcessedChunk.Segment {
        ProcessedChunk.Segment(
            start: start,
            end: end,
            text: text,
            speaker: speaker,
            source: source,
            qualityScore: quality
        )
    }

    // MARK: - Tests

    @Test func mergerSingleChunkPassthrough() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 0)
        let chunk = makeChunk(
            index: 0,
            startTime: meetingStart,
            segments: [
                makeSeg(start: 0.0, end: 1.0, text: "Hello"),
                makeSeg(start: 1.0, end: 2.5, text: "World")
            ]
        )

        let result = TranscriptMerger.merge(
            chunks: [chunk],
            speakerMapping: [:],
            meetingStart: meetingStart
        )

        #expect(result.chunkCount == 1)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].elapsed == 0.0)
        #expect(result.segments[0].text == "Hello")
        #expect(result.segments[1].elapsed == 1.0)
        #expect(result.segments[1].text == "World")
        #expect(result.meetingStart == meetingStart)
    }

    @Test func mergerAppliesTimestampOffsets() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 0)
        let chunk0 = makeChunk(
            index: 0,
            startTime: meetingStart,
            segments: [makeSeg(start: 1.0, end: 2.0, text: "First")]
        )
        let chunk1 = makeChunk(
            index: 1,
            startTime: meetingStart.addingTimeInterval(1800),
            segments: [makeSeg(start: 1.0, end: 2.0, text: "Second")]
        )

        let result = TranscriptMerger.merge(
            chunks: [chunk0, chunk1],
            speakerMapping: [:],
            meetingStart: meetingStart
        )

        #expect(result.segments.count == 2)
        let elapseds = result.segments.map { $0.elapsed }
        #expect(elapseds.contains(1.0))
        #expect(elapseds.contains(1801.0))

        // Verify absolute timestamps
        let seg0 = result.segments.first { $0.text == "First" }!
        let seg1 = result.segments.first { $0.text == "Second" }!
        #expect(seg0.timestamp == meetingStart.addingTimeInterval(1.0))
        #expect(seg1.timestamp == meetingStart.addingTimeInterval(1801.0))
    }

    @Test func mergerRemapsSpeakerLabels() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 0)
        let chunk = makeChunk(
            index: 0,
            startTime: meetingStart,
            segments: [
                makeSeg(start: 0.0, end: 1.0, text: "Hi", speaker: "spk_1"),
                makeSeg(start: 1.0, end: 2.0, text: "There", speaker: "spk_2")
            ]
        )

        // Map chunk 0: spk_1 → spk_0, spk_2 stays unmapped
        let speakerMapping: [Int: [String: String]] = [
            0: ["spk_1": "spk_0"]
        ]

        let result = TranscriptMerger.merge(
            chunks: [chunk],
            speakerMapping: speakerMapping,
            meetingStart: meetingStart
        )

        #expect(result.segments.count == 2)
        let hiSeg = result.segments.first { $0.text == "Hi" }!
        let thereSeg = result.segments.first { $0.text == "There" }!
        #expect(hiSeg.speaker == "spk_0")
        // Unmapped speaker falls back to original label
        #expect(thereSeg.speaker == "spk_2")
    }

    @Test func mergerSortsByElapsedTime() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 0)
        // Single chunk with out-of-order segments
        let chunk = makeChunk(
            index: 0,
            startTime: meetingStart,
            segments: [
                makeSeg(start: 5.0, end: 6.0, text: "Late"),
                makeSeg(start: 0.0, end: 1.0, text: "Early"),
                makeSeg(start: 2.5, end: 3.5, text: "Middle")
            ]
        )

        let result = TranscriptMerger.merge(
            chunks: [chunk],
            speakerMapping: [:],
            meetingStart: meetingStart
        )

        #expect(result.segments.count == 3)
        #expect(result.segments[0].text == "Early")
        #expect(result.segments[1].text == "Middle")
        #expect(result.segments[2].text == "Late")
    }

    @Test func mergerEmptyChunksProduceEmptyResult() {
        let meetingStart = Date(timeIntervalSinceReferenceDate: 0)

        let result = TranscriptMerger.merge(
            chunks: [],
            speakerMapping: [:],
            meetingStart: meetingStart
        )

        #expect(result.segments.isEmpty)
        #expect(result.chunkCount == 0)
        #expect(result.meetingStart == meetingStart)
    }

    @Test func mergerSilentChunkProducesNoSegments() {
        let now = Date()
        let chunks = [
            ProcessedChunk(
                index: 0, startTime: now, audioPath: "m-0.m4a",
                segments: [.init(start: 0, end: 1, text: "A", speaker: "spk_0", source: "system")],
                speakerDatabase: [:]
            ),
            ProcessedChunk(
                index: 1, startTime: now.addingTimeInterval(1800), audioPath: "m-1.m4a",
                segments: [], // Silent chunk
                speakerDatabase: [:]
            ),
            ProcessedChunk(
                index: 2, startTime: now.addingTimeInterval(3600), audioPath: "m-2.m4a",
                segments: [.init(start: 0, end: 1, text: "B", speaker: "spk_0", source: "system")],
                speakerDatabase: [:]
            )
        ]
        let mapping: [Int: [String: String]] = [
            0: ["spk_0": "spk_0"], 1: [:], 2: ["spk_0": "spk_0"]
        ]

        let result = TranscriptMerger.merge(chunks: chunks, speakerMapping: mapping, meetingStart: now)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "A")
        #expect(result.segments[1].text == "B")
        #expect(result.segments[1].elapsed == 3600.0)
    }
}
