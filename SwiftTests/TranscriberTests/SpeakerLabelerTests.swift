import Testing
import Foundation
@testable import TranscriberCore

@Suite("SpeakerLabeler")
struct SpeakerLabelerTests {

    // Build a 256-dim embedding with a single axis set to 1.0.
    private func axis(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[i] = 1.0
        return v
    }

    private func seg(
        _ start: Double,
        _ end: Double,
        _ speaker: String,
        _ source: String
    ) -> ProcessedChunk.Segment {
        ProcessedChunk.Segment(
            start: start, end: end, text: "x",
            speaker: speaker, source: source, qualityScore: nil
        )
    }

    private func chunk(
        index: Int,
        startOffset: TimeInterval,
        meetingStart: Date,
        segments: [ProcessedChunk.Segment],
        remoteDB: [String: [Float]] = [:],
        localDB: [String: [Float]] = [:]
    ) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: meetingStart.addingTimeInterval(startOffset),
            audioPath: "/tmp/chunk-\(index).m4a",
            segments: segments,
            speakerDatabase: remoteDB,
            echoSegmentsRemoved: 0,
            localSpeakerDatabase: localDB
        )
    }

    // A local person appearing as "Speaker 1" in chunk 0 and "Speaker 2" in
    // chunk 1, with matching embeddings, must collapse to one "Local Speaker 1".
    @Test func localSpeakerMatchedAcrossChunksCollapsesToOne() {
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks = [
            chunk(
                index: 0, startOffset: 0, meetingStart: meetingStart,
                segments: [seg(0, 5, "Local Speaker 1", "local")],
                localDB: ["Speaker 1": axis(0)]
            ),
            chunk(
                index: 1, startOffset: 300, meetingStart: meetingStart,
                segments: [seg(0, 5, "Local Speaker 2", "local")],
                localDB: ["Speaker 2": axis(0)]
            )
        ]

        let result = SpeakerLabeler.label(chunks: chunks, meetingStart: meetingStart)
        let speakers = Set(result.map(\.speaker))
        #expect(speakers == ["Local Speaker 1"])
    }

    // A remote person matched across chunks collapses to one "Remote Speaker 1".
    @Test func remoteSpeakerMatchedAcrossChunksCollapsesToOne() {
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks = [
            chunk(
                index: 0, startOffset: 0, meetingStart: meetingStart,
                segments: [seg(0, 5, "Remote Speaker 1", "remote")],
                remoteDB: ["Speaker 1": axis(3)]
            ),
            chunk(
                index: 1, startOffset: 300, meetingStart: meetingStart,
                segments: [seg(0, 5, "Remote Speaker 2", "remote")],
                remoteDB: ["Speaker 2": axis(3)]
            )
        ]

        let result = SpeakerLabeler.label(chunks: chunks, meetingStart: meetingStart)
        let speakers = Set(result.map(\.speaker))
        #expect(speakers == ["Remote Speaker 1"])
    }

    // A local and a remote speaker with IDENTICAL embeddings must NOT merge —
    // they are reconciled in separate pools (different audio streams).
    @Test func localAndRemoteWithSameEmbeddingStaySeparate() {
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks = [
            chunk(
                index: 0, startOffset: 0, meetingStart: meetingStart,
                segments: [
                    seg(0, 5, "Remote Speaker 1", "remote"),
                    seg(1, 6, "Local Speaker 1", "local")
                ],
                remoteDB: ["Speaker 1": axis(7)],
                localDB: ["Speaker 1": axis(7)]
            )
        ]

        let result = SpeakerLabeler.label(chunks: chunks, meetingStart: meetingStart)
        let speakers = Set(result.map(\.speaker))
        #expect(speakers.contains("Remote Speaker 1"))
        #expect(speakers.contains("Local Speaker 1"))
        #expect(speakers.count == 2)
    }

    // Two genuinely different local speakers (orthogonal embeddings) stay distinct.
    @Test func distinctLocalSpeakersStayDistinct() {
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks = [
            chunk(
                index: 0, startOffset: 0, meetingStart: meetingStart,
                segments: [
                    seg(0, 5, "Local Speaker 1", "local"),
                    seg(10, 15, "Local Speaker 2", "local")
                ],
                localDB: ["Speaker 1": axis(0), "Speaker 2": axis(1)]
            )
        ]

        let result = SpeakerLabeler.label(chunks: chunks, meetingStart: meetingStart)
        let speakers = Set(result.map(\.speaker))
        #expect(speakers == ["Local Speaker 1", "Local Speaker 2"])
    }

    // Display numbering follows order of first appearance across time-sorted segments.
    @Test func displayNumbersFollowFirstAppearanceOrder() {
        let meetingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chunks = [
            chunk(
                index: 0, startOffset: 0, meetingStart: meetingStart,
                segments: [
                    // axis(1) person speaks first → should become "Local Speaker 1"
                    seg(0, 5, "Local Speaker 2", "local"),
                    seg(10, 15, "Local Speaker 1", "local")
                ],
                localDB: ["Speaker 1": axis(0), "Speaker 2": axis(1)]
            )
        ]

        let result = SpeakerLabeler.label(chunks: chunks, meetingStart: meetingStart)
            .sorted { $0.start < $1.start }
        #expect(result.first?.speaker == "Local Speaker 1")
        #expect(result.last?.speaker == "Local Speaker 2")
    }
}
