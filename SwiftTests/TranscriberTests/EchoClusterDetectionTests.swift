import Testing
import Foundation
@testable import TranscriberCore

/// Synthetic fixtures for the echo tests: numbered words, never natural language, and unit vectors
/// at a chosen cosine. Nothing here comes from a recording.
enum EchoFixture {
    /// `count` numbered words starting at `first`: "w100 w101 w102 …".
    static func words(_ first: Int, _ count: Int) -> String {
        (first..<(first + count)).map { "w\($0)" }.joined(separator: " ")
    }

    /// The reference voice: every remote speaker 1 embedding in these tests.
    static let reference: [Float] = [1, 0, 0, 0]

    /// A unit vector whose cosine to `reference` is `cosine`.
    static func voice(cosine: Float) -> [Float] {
        [cosine, (1 - cosine * cosine).squareRoot(), 0, 0]
    }

    static func remote(_ start: Double, _ end: Double, _ text: String, speaker: Int = 1) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Remote Speaker \(speaker)", text: text, source: "remote")
    }

    static func local(_ start: Double, _ end: Double, _ text: String, speaker: Int = 1) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Local Speaker \(speaker)", text: text, source: "local")
    }

    /// Mic bleed of `segment`: the same words, heard `delay` seconds later on the local side.
    static func bleed(of segment: LabeledSegment, speaker: Int, delay: Double = 0.2) -> LabeledSegment {
        local(segment.start + delay, segment.end + delay, segment.text, speaker: speaker)
    }
}

/// #242: the echo decision is made per local cluster, on time and text, and the voice similarity is
/// evidence only.
struct EchoClusterDetectionTests {

    private func flaggedTexts(_ result: EchoDeduplicator.DeduplicationResult) -> Set<String> {
        Set(result.segments.filter(\.echo).map(\.text))
    }

    private func cluster(_ label: String, in result: EchoDeduplicator.DeduplicationResult) throws -> EchoDeduplicator.ClusterVerdict {
        try #require(result.clusters.first { $0.label == label })
    }

    private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
        a.map { abs($0 - b) < tolerance } ?? false
    }

    // MARK: - A whole bleed cluster whose voice does not resemble the remote speaker enough

    /// 40 remote segments of 10 s; the local side holds a second cluster of 40 segments, 36 of them
    /// the same words 0.2 s later (0.9 of its duration) and 4 with words of their own. Its voice
    /// scores 0.68 against the remote speaker — under the old 0.8 gate, so nothing was flagged.
    private func bleedClusterFixture() -> (segments: [LabeledSegment], copies: Set<String>, residue: Set<String>, own: Set<String>) {
        var segments: [LabeledSegment] = []
        var copies = Set<String>(), residue = Set<String>(), own = Set<String>()
        for i in 0..<40 {
            let start = Double(i) * 11
            let remote = EchoFixture.remote(start, start + 10, EchoFixture.words(i * 100, 12))
            segments.append(remote)
            if i % 10 == 9 {
                // The cluster's residue: same time, other words.
                let text = EchoFixture.words(50_000 + i * 100, 12)
                segments.append(EchoFixture.local(start + 0.2, start + 10.2, text, speaker: 2))
                residue.insert(text)
            } else if i % 3 == 0 {
                // The local recogniser heard one word differently: 11 of 12 words agree.
                let text = EchoFixture.words(i * 100, 11) + " x\(i)"
                segments.append(EchoFixture.local(start + 0.2, start + 10.2, text, speaker: 2))
                copies.insert(text)
            } else {
                segments.append(EchoFixture.bleed(of: remote, speaker: 2))
                copies.insert(remote.text)
            }
            // The user's own cluster speaks in the 1 s pauses.
            if i % 4 == 0 {
                let text = EchoFixture.words(90_000 + i * 100, 6)
                segments.append(EchoFixture.local(start + 10.3, start + 10.9, text, speaker: 1))
                own.insert(text)
            }
        }
        return (segments.sorted { $0.start < $1.start }, copies, residue, own)
    }

    private var bleedDatabases: (local: [String: [Float]], remote: [String: [Float]]) {
        (["Speaker 1": EchoFixture.voice(cosine: 0.08), "Speaker 2": EchoFixture.voice(cosine: 0.68)],
         ["Speaker 1": EchoFixture.reference])
    }

    @Test func aBleedClusterBelowTheOldEmbeddingGateHasItsMatchedSegmentsFlagged() throws {
        let fixture = bleedClusterFixture()
        #expect(fixture.copies.count == 36 && fixture.residue.count == 4)
        let result = EchoDeduplicator.deduplicate(
            segments: fixture.segments,
            localSpeakerDatabase: bleedDatabases.local, remoteSpeakerDatabase: bleedDatabases.remote
        )
        #expect(flaggedTexts(result) == fixture.copies, "every matched segment of the cluster is flagged, and nothing else")
        #expect(result.flaggedCount == 36)
        // Flag, never delete: every segment is still there, in order, with its words and its label.
        #expect(result.segments.map(\.text) == fixture.segments.map(\.text))
        #expect(result.segments.map(\.speaker) == fixture.segments.map(\.speaker))
        #expect(result.segments.filter { fixture.residue.contains($0.text) }.allSatisfy { !$0.echo && $0.speaker == "Local Speaker 2" },
                "the unmatched segments stay unflagged under the cluster's label")
        #expect(result.segments.filter { $0.source == "remote" || fixture.own.contains($0.text) }.allSatisfy { !$0.isFlagged })

        // The verdict, with the numbers behind it.
        #expect(result.clusters.map(\.label) == ["Local Speaker 1", "Local Speaker 2"])
        let bleed = try cluster("Local Speaker 2", in: result)
        #expect(bleed.verdict == .echo && bleed.isEcho)
        #expect(bleed.segments == 40 && bleed.matchedSegments == 36)
        #expect(near(bleed.seconds, 400) && near(bleed.matchedSeconds, 360) && near(bleed.share, 0.9))
        #expect(bleed.words == 480 && bleed.matchedWords == 432)
        #expect(near(bleed.bestEmbeddingSimilarity, 0.68), "recorded as evidence: under the old 0.8 gate")
        #expect(bleed.matchedRemote.keys.sorted() == ["Remote Speaker 1"])
        #expect(near(bleed.matchedRemote["Remote Speaker 1"], 36 * 9.8), "each copy overlaps its remote segment for 9.8 s")
        let own = try cluster("Local Speaker 1", in: result)
        #expect(own.verdict == .kept && !own.isEcho)
        #expect(own.segments == 10 && own.matchedSegments == 0 && own.share == 0 && own.matchedRemote.isEmpty)
        #expect(near(own.seconds, 6) && own.words == 60 && own.matchedWords == 0)
        #expect(near(own.bestEmbeddingSimilarity, 0.08))
        #expect(result.issues == [ChunkIssue(code: .echoFlagged, track: "local", count: 36),
                                  ChunkIssue(code: .echoCluster, track: "local", count: 1)])
        #expect(!ChunkIssue.Code.echoCluster.affectsContent && !ChunkIssue.Code.echoFlagged.affectsContent, "informational")
    }

    /// The same cluster with the old threshold spelled out, or with no embeddings at all: the
    /// decision is the same, because the voice similarity is not part of it.
    @Test func theVerdictDoesNotDependOnTheEmbeddings() throws {
        let fixture = bleedClusterFixture()
        let withThreshold = EchoDeduplicator.deduplicate(
            segments: fixture.segments,
            localSpeakerDatabase: bleedDatabases.local, remoteSpeakerDatabase: bleedDatabases.remote,
            embeddingThreshold: 0.8
        )
        let withoutEmbeddings = EchoDeduplicator.deduplicate(
            segments: fixture.segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(flaggedTexts(withThreshold) == fixture.copies && flaggedTexts(withoutEmbeddings) == fixture.copies)
        #expect(try cluster("Local Speaker 2", in: withoutEmbeddings).bestEmbeddingSimilarity == nil)
        #expect(try cluster("Local Speaker 2", in: withoutEmbeddings).verdict == .echo)
    }

    // MARK: - The user's own cluster

    /// One- and two-word segments identical to and simultaneous with the remote side ("yes" said on
    /// both ends) are not echo, even when the voices resemble each other.
    @Test func simultaneousOneAndTwoWordSegmentsInTheUsersClusterAreNotFlagged() throws {
        var segments: [LabeledSegment] = []
        for i in 0..<20 {
            let start = Double(i) * 12
            segments.append(EchoFixture.local(start, start + 5, EchoFixture.words(70_000 + i * 100, 9)))
            segments.append(EchoFixture.remote(start + 5.5, start + 10.5, EchoFixture.words(i * 100, 9)))
        }
        for i in 0..<8 {
            let start = Double(i) * 12 + 11
            let text = EchoFixture.words(900 + i, i % 2 == 0 ? 1 : 2)
            segments.append(EchoFixture.remote(start, start + 0.8, text))
            segments.append(EchoFixture.local(start, start + 0.8, text))
        }
        let result = EchoDeduplicator.deduplicate(
            segments: segments.sorted { $0.start < $1.start },
            localSpeakerDatabase: ["Speaker 1": EchoFixture.voice(cosine: 0.95)],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
        )
        #expect(result.flaggedCount == 0)
        #expect(result.segments.allSatisfy { !$0.echo })
        let own = try cluster("Local Speaker 1", in: result)
        #expect(own.verdict == .kept)
        #expect(own.segments == 28 && own.matchedSegments == 8, "the 8 short ones match on time and text; that alone flags nothing")
        #expect(near(own.seconds, 106.4) && near(own.matchedSeconds, 6.4) && own.share < 0.1)
        #expect(result.issues.isEmpty)
    }

    /// The user's own speech plus six copies of remote segments, 8 words or more each, under 10% of
    /// the cluster's duration: only the copies are flagged.
    @Test func aBlendedClusterHasOnlyItsCopiesFlagged() throws {
        var segments: [LabeledSegment] = []
        var copies = Set<String>()
        for i in 0..<60 {
            let start = Double(i) * 20
            segments.append(EchoFixture.local(start, start + 10, EchoFixture.words(70_000 + i * 100, 14)))
            let remote = EchoFixture.remote(start + 11, start + 19, EchoFixture.words(i * 100, 8 + i % 5))
            segments.append(remote)
            if i % 10 == 3 {
                segments.append(EchoFixture.bleed(of: remote, speaker: 1))
                copies.insert(remote.text)
            }
        }
        #expect(copies.count == 6)
        let result = EchoDeduplicator.deduplicate(
            segments: segments.sorted { $0.start < $1.start },
            localSpeakerDatabase: ["Speaker 1": EchoFixture.voice(cosine: 0.08)],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
        )
        #expect(flaggedTexts(result) == copies)
        #expect(result.flaggedCount == 6)
        let blended = try cluster("Local Speaker 1", in: result)
        #expect(blended.verdict == .kept)
        #expect(blended.segments == 66 && blended.matchedSegments == 6)
        #expect(near(blended.seconds, 648) && near(blended.matchedSeconds, 48) && blended.share < 0.1)
        #expect(result.issues == [ChunkIssue(code: .echoFlagged, track: "local", count: 6)], "segments flagged, no cluster judged echo")
    }

    // MARK: - Two remote speakers

    @Test func twoRemoteSpeakersBleedingIntoOneLocalClusterAreBothMatched() throws {
        var segments: [LabeledSegment] = []
        for i in 0..<20 {
            let start = Double(i) * 6
            let remote = EchoFixture.remote(start, start + 5, EchoFixture.words(i * 100, 10), speaker: i % 2 == 0 ? 1 : 2)
            segments.append(remote)
            segments.append(EchoFixture.bleed(of: remote, speaker: 2))
        }
        let result = EchoDeduplicator.deduplicate(
            segments: segments,
            localSpeakerDatabase: ["Speaker 2": EchoFixture.voice(cosine: 0.68)],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference, "Speaker 2": [0, 0, 1, 0]]
        )
        #expect(result.flaggedCount == 20)
        #expect(result.segments.filter { $0.source == "local" }.allSatisfy { $0.echo })
        let bleed = try cluster("Local Speaker 2", in: result)
        #expect(bleed.verdict == .echo && near(bleed.share, 1))
        #expect(bleed.matchedRemote.keys.sorted() == ["Remote Speaker 1", "Remote Speaker 2"])
        #expect(near(bleed.matchedRemote["Remote Speaker 1"], 48) && near(bleed.matchedRemote["Remote Speaker 2"], 48))
        #expect(near(bleed.bestEmbeddingSimilarity, 0.68), "the best of the two remote voices")
    }

    /// One long local segment over what the remote side split between two speakers: matched against
    /// the joined window, and both speakers are recorded with the seconds each overlaps.
    @Test func aLocalSegmentSpanningTwoRemoteSpeakersRecordsBoth() throws {
        let first = EchoFixture.remote(0, 10, EchoFixture.words(100, 10), speaker: 1)
        let second = EchoFixture.remote(10, 30, EchoFixture.words(200, 10), speaker: 2)
        let result = EchoDeduplicator.deduplicate(
            segments: [first, second, EchoFixture.local(0, 30, first.text + " " + second.text, speaker: 2)],
            localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.flaggedCount == 1)
        let bleed = try cluster("Local Speaker 2", in: result)
        #expect(bleed.verdict == .echo)
        #expect(near(bleed.matchedRemote["Remote Speaker 1"], 10) && near(bleed.matchedRemote["Remote Speaker 2"], 20))
    }

    // MARK: - Too little speech to judge as a cluster

    /// 20 s in all, 0.65 of it matching: under the 30 s floor, so it is not judged as a cluster and
    /// only its matches of 3 words or more are flagged.
    @Test func aClusterUnderThirtySecondsIsNotJudgedAsACluster() throws {
        let long1 = EchoFixture.remote(0, 6, EchoFixture.words(100, 9))
        let long2 = EchoFixture.remote(7, 13, EchoFixture.words(200, 9))
        let short = EchoFixture.remote(14, 15, EchoFixture.words(300, 1))
        let segments = [
            long1, EchoFixture.bleed(of: long1, speaker: 2),
            long2, EchoFixture.bleed(of: long2, speaker: 2),
            short, EchoFixture.bleed(of: short, speaker: 2, delay: 0),
            EchoFixture.local(16, 23, EchoFixture.words(70_000, 9), speaker: 2),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments,
            localSpeakerDatabase: ["Speaker 2": EchoFixture.voice(cosine: 0.68)],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
        )
        #expect(flaggedTexts(result) == [long1.text, long2.text])
        #expect(result.flaggedCount == 2)
        let short20 = try cluster("Local Speaker 2", in: result)
        #expect(short20.verdict == .kept, "0.65 of its duration matches, but 20 s is too little to judge")
        #expect(near(short20.seconds, 20) && near(short20.share, 0.65) && short20.matchedSegments == 3)
    }

    /// The two cluster constants, at their edges: a share of exactly 0.5 over exactly 30 s is an echo
    /// cluster, and there even a one-word match is flagged; a hair under 30 s it is not.
    @Test func theClusterRuleIsInclusiveAtHalfTheDurationAndThirtySeconds() {
        func run(unmatchedSeconds: Double) -> EchoDeduplicator.DeduplicationResult {
            let word = EchoFixture.remote(0, 15, EchoFixture.words(300, 1))
            return EchoDeduplicator.deduplicate(
                segments: [word, EchoFixture.bleed(of: word, speaker: 2, delay: 0),
                           EchoFixture.local(20, 20 + unmatchedSeconds, EchoFixture.words(70_000, 9), speaker: 2)],
                localSpeakerDatabase: ["Speaker 2": EchoFixture.voice(cosine: 0.68)],
                remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
            )
        }
        #expect(EchoDeduplicator.clusterShareThreshold == 0.5 && EchoDeduplicator.clusterMinimumSeconds == 30
            && EchoDeduplicator.minimumWordsOutsideEchoCluster == 3)
        #expect(run(unmatchedSeconds: 15).flaggedCount == 1)
        #expect(run(unmatchedSeconds: 15).clusters.map(\.verdict) == [.echo])
        #expect(run(unmatchedSeconds: 14.5).clusters.map(\.verdict) == [.kept])
        #expect(run(unmatchedSeconds: 15.5).clusters.map(\.verdict) == [.kept])
        #expect(run(unmatchedSeconds: 14.5).flaggedCount == 0, "29.5 s: not judged as a cluster, and one word is not flagged on its own")
        #expect(run(unmatchedSeconds: 15.5).flaggedCount == 0, "30.5 s at a share under 0.5: kept")
    }

    // MARK: - Segments already flagged

    /// A segment the quality gate filtered, or an abutting repeat, is neither an echo candidate nor
    /// evidence for one.
    @Test func alreadyFlaggedSegmentsAreNeitherCandidatesNorEvidence() {
        let heard = EchoFixture.remote(0, 6, EchoFixture.words(100, 9))
        var filteredRemote = EchoFixture.remote(10, 16, EchoFixture.words(200, 9))
        filteredRemote.filtered = true
        var filteredLocal = EchoFixture.bleed(of: heard, speaker: 1)
        filteredLocal.filtered = true
        var duplicateLocal = EchoFixture.bleed(of: heard, speaker: 1, delay: 0.3)
        duplicateLocal.duplicate = true
        let segments = [
            heard, filteredLocal, duplicateLocal,
            filteredRemote, EchoFixture.bleed(of: filteredRemote, speaker: 1),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments,
            localSpeakerDatabase: ["Speaker 1": EchoFixture.voice(cosine: 0.98)],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
        )
        #expect(result.flaggedCount == 0)
        #expect(result.segments.allSatisfy { !$0.echo }, "a flagged candidate is left as it is; a flagged remote segment proves nothing")
        #expect(result.segments.map(\.filtered) == segments.map(\.filtered) && result.segments.map(\.duplicate) == segments.map(\.duplicate))
        // Only the one unflagged local segment is counted, and it matched nothing.
        #expect(result.clusters == [EchoDeduplicator.ClusterVerdict(
            label: "Local Speaker 1", segments: 1, matchedSegments: 0, seconds: 6, matchedSeconds: 0,
            words: 9, matchedWords: 0, share: 0, verdict: .kept, bestEmbeddingSimilarity: result.clusters.first?.bestEmbeddingSimilarity)])
        #expect(near(result.clusters.first?.bestEmbeddingSimilarity, 0.98))
    }

    /// A segment echo dedup flagged on an earlier pass is left alone and not counted again.
    @Test func anAlreadyEchoFlaggedSegmentIsNotCountedAgain() {
        let heard = EchoFixture.remote(0, 6, EchoFixture.words(100, 9))
        var flagged = EchoFixture.bleed(of: heard, speaker: 1)
        flagged.echo = true
        let result = EchoDeduplicator.deduplicate(
            segments: [heard, flagged], localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.flaggedCount == 0 && result.clusters.isEmpty)
        #expect(result.segments.map(\.echo) == [false, true], "its flag is kept")
    }

    // MARK: - What is persisted

    /// A voice vector whose cosine is not a number (an infinite component: inf / inf) gives no
    /// similarity, so the verdict can always be encoded.
    @Test func aNonFiniteEmbeddingIsNotRecorded() throws {
        let heard = EchoFixture.remote(0, 6, EchoFixture.words(100, 9))
        let result = EchoDeduplicator.deduplicate(
            segments: [heard, EchoFixture.bleed(of: heard, speaker: 1)],
            localSpeakerDatabase: ["Speaker 1": [.infinity, 0, 0, 0]],
            remoteSpeakerDatabase: ["Speaker 1": EchoFixture.reference]
        )
        #expect(result.flaggedCount == 1)
        #expect(result.clusters.first?.bestEmbeddingSimilarity == nil)
        #expect(JSONSerialization.isValidJSONObject(result.clusters.map { $0.metadataDictionary(chunk: 0) }))
        _ = try JSONEncoder().encode(result.clusters)
    }

    @Test func aVerdictRoundTripsThroughCodableWithTheTranscriptsKeys() throws {
        let verdict = EchoDeduplicator.ClusterVerdict(
            label: "Local Speaker 2", segments: 40, matchedSegments: 36, seconds: 400, matchedSeconds: 360,
            words: 480, matchedWords: 432, share: 0.9, verdict: .echo, bestEmbeddingSimilarity: 0.68,
            matchedRemote: ["Remote Speaker 1": 352.8])
        let data = try JSONEncoder().encode(verdict)
        #expect(try JSONDecoder().decode(EchoDeduplicator.ClusterVerdict.self, from: data) == verdict)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        #expect(keys == ["embedding_similarity", "label", "matched_remote", "matched_seconds", "matched_segments",
                         "matched_words", "seconds", "segments", "share", "verdict", "words"])
    }

    /// The transcript entry: numbers and labels only, rounded, labels remapped; `chunk` and the
    /// similarity are left out when there is none.
    @Test func theMetadataEntryHoldsNumbersAndLabelsOnly() throws {
        let verdict = EchoDeduplicator.ClusterVerdict(
            label: "Local Speaker 2", segments: 40, matchedSegments: 36, seconds: 400.00004, matchedSeconds: 360.00004,
            words: 480, matchedWords: 432, share: 0.900012345, verdict: .echo, bestEmbeddingSimilarity: 0.6800000071525574,
            matchedRemote: ["Remote Speaker 1": 300.12345, "Remote Speaker 3": 52.5])
        let mapping = ["Local Speaker 2": "Local Speaker 5", "Remote Speaker 1": "Remote Speaker 4", "Remote Speaker 3": "Remote Speaker 4"]
        let entry = verdict.metadataDictionary(chunk: 7) { mapping[$0] ?? $0 }
        #expect(entry.keys.sorted() == ["chunk", "embedding_similarity", "label", "matched_remote", "matched_seconds",
                                        "matched_segments", "matched_words", "seconds", "segments", "share", "track",
                                        "verdict", "words"])
        #expect(entry["track"] as? String == "local" && entry["chunk"] as? Int == 7)
        #expect(entry["label"] as? String == "Local Speaker 5" && entry["verdict"] as? String == "echo")
        #expect(entry["segments"] as? Int == 40 && entry["matched_segments"] as? Int == 36)
        #expect(entry["words"] as? Int == 480 && entry["matched_words"] as? Int == 432)
        #expect(entry["seconds"] as? Double == 400 && entry["matched_seconds"] as? Double == 360)
        #expect(entry["share"] as? Double == 0.9 && entry["embedding_similarity"] as? Double == 0.68)
        #expect(entry["matched_remote"] as? [String: Double] == ["Remote Speaker 4": 352.623], "two chunk labels on one global speaker are summed")
        #expect(JSONSerialization.isValidJSONObject(entry))

        let bare = EchoDeduplicator.ClusterVerdict(
            label: "Local Speaker 1", segments: 1, matchedSegments: 0, seconds: 5, matchedSeconds: 0,
            words: 4, matchedWords: 0, share: 0, verdict: .kept).metadataDictionary(chunk: nil)
        #expect(bare["chunk"] == nil && bare["embedding_similarity"] == nil)
        #expect(bare["label"] as? String == "Local Speaker 1" && bare["verdict"] as? String == "kept")
        #expect((bare["matched_remote"] as? [String: Double])?.isEmpty == true)
    }
}
