import Testing
import Foundation
@testable import TranscriberCore

struct EchoDeduplicatorTests {

    // MARK: - Temporal overlap

    @Test func fullOverlapReturnsOne() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 15.0, bStart: 10.0, bEnd: 15.0
        )
        #expect(ratio == 1.0)
    }

    @Test func halfOverlapReturnsFifty() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 20.0, bStart: 15.0, bEnd: 25.0
        )
        #expect(abs(ratio - 0.5) < 0.01)
    }

    @Test func noOverlapReturnsZero() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 0.0, aEnd: 5.0, bStart: 10.0, bEnd: 15.0
        )
        #expect(ratio == 0.0)
    }

    @Test func containedSegmentReturnsOne() {
        let ratio = EchoDeduplicator.temporalOverlap(
            aStart: 10.0, aEnd: 12.0, bStart: 8.0, bEnd: 20.0
        )
        #expect(ratio == 1.0)
    }

    // MARK: - Text similarity

    @Test func identicalTextReturnsOne() {
        let ratio = EchoDeduplicator.textSimilarity(
            "the quick brown fox jumps over the lazy dog",
            "the quick brown fox jumps over the lazy dog"
        )
        #expect(ratio == 1.0)
    }

    @Test func nearIdenticalTextReturnsHigh() {
        let ratio = EchoDeduplicator.textSimilarity(
            "Adding these two strikes caused like vortex generation",
            "Adding these two strakes caused like vortex generation"
        )
        #expect(ratio > 0.7)
    }

    @Test func completelyDifferentTextReturnsLow() {
        let ratio = EchoDeduplicator.textSimilarity(
            "the quick brown fox",
            "lorem ipsum dolor sit amet"
        )
        #expect(ratio < 0.3)
    }

    @Test func emptyTextReturnsZero() {
        #expect(EchoDeduplicator.textSimilarity("", "") == 0.0)
        #expect(EchoDeduplicator.textSimilarity("hello", "") == 0.0)
    }

    // MARK: - Text containment

    @Test func fullContainmentReturnsOne() {
        let ratio = EchoDeduplicator.textContainment(
            "restaurants and cafes",
            "so many restaurants and cafes made for cyclists that are open all year long"
        )
        #expect(ratio == 1.0)
    }

    @Test func partialContainmentReturnsCorrectRatio() {
        let ratio = EchoDeduplicator.textContainment(
            "hello world foo bar",  // 4 words, 2 in b
            "hello world baz qux"
        )
        #expect(abs(ratio - 0.5) < 0.01)
    }

    @Test func emptyContainmentReturnsZero() {
        #expect(EchoDeduplicator.textContainment("", "hello world") == 0.0)
    }

    // MARK: - Cosine similarity

    @Test func identicalEmbeddingsReturnOne() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [1, 0, 0, 0]
        #expect(abs(EchoDeduplicator.cosineSimilarity(a, b) - 1.0) < 0.001)
    }

    @Test func orthogonalEmbeddingsReturnZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        #expect(abs(EchoDeduplicator.cosineSimilarity(a, b)) < 0.001)
    }

    @Test func similarEmbeddingsReturnHigh() {
        let a: [Float] = [1.0, 0.9, 0.8, 0.7]
        let b: [Float] = [1.0, 0.85, 0.82, 0.72]
        #expect(EchoDeduplicator.cosineSimilarity(a, b) > 0.99)
    }

    @Test func emptyEmbeddingsReturnZero() {
        #expect(EchoDeduplicator.cosineSimilarity([], []) == 0.0)
    }

    // MARK: - Centroid pooling (accumulated embeddings)

    @Test func gcdRecoversDimensionWhenNoSpeakerIsSingleSegment() {
        // Two speakers each accumulated across the same number of segments:
        // entries are 2×dim and 3×dim. min() would wrongly infer 2×dim (=8);
        // gcd(8, 12) correctly recovers dim = 4.
        #expect(EchoDeduplicator.gcd(8, 12) == 4)
        #expect(EchoDeduplicator.gcd(0, 4) == 4)   // seed-from-zero reduce
        #expect(EchoDeduplicator.gcd(4, 4) == 4)   // single-segment common case
    }

    @Test func centroidAveragesAccumulatedVectors() {
        // Two 4-dim vectors concatenated → centroid is their element-wise mean.
        let accumulated: [Float] = [2, 4, 6, 8, 4, 8, 10, 12]
        let c = EchoDeduplicator.centroid(from: accumulated, dim: 4)
        #expect(c == [3, 6, 8, 10])
    }

    @Test func centroidSingleSegmentIsNoOp() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(EchoDeduplicator.centroid(from: v, dim: 4) == v)
    }

    // MARK: - Deduplication

    @Test func removesEchoWhenAllThreeSignalsMatch() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10.1, end: 15.2, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2, "nothing is deleted any more")
        #expect(result.segments.filter { !$0.echo }.map(\.source) == ["remote"])
        #expect(result.segments.first { $0.source == "local" }?.echo == true)
        #expect(result.flaggedCount == 1)
    }

    @Test func pooledEmbeddingEvidenceWithAccumulatedEmbeddingsWhenDimThreaded() {
        // Crash-recovery path: each speaker's embedding is accumulated across 2 segments, so DB
        // entries are 2×dim (8 floats) and the dim cannot be inferred from their lengths. Passing
        // embeddingDim lets centroid() pool them back to dim, so the recorded similarity is the
        // voices' (an [a,b] vs [c,d] cosine over 8 floats would be a different number).
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10.1, end: 15.2, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0, 0, 1, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [0, 1, 0, 0, 1, 0, 0, 0]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb,
            embeddingDim: 4
        )
        #expect(result.flaggedCount == 1)
        #expect(result.segments.count == 2, "flagged, not deleted")
        #expect(result.segments.filter { !$0.echo }.map(\.source) == ["remote"])
        // Both centroids are [0.5, 0.5, 0, 0]: the same voice. Unpooled, the 8-float cosine is 0.
        #expect(abs((result.clusters.first?.bestEmbeddingSimilarity ?? 0) - 1) < 0.001)
    }

    @Test func keepsLocalWhenTextDiffers() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "I totally agree with that", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
        #expect(result.flaggedCount == 0)
    }

    @Test func keepsLocalWhenTimestampsDontOverlap() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "Hello world", source: "remote"),
            LabeledSegment(start: 30, end: 35, speaker: "Local Speaker 1", text: "Hello world", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
        #expect(result.flaggedCount == 0)
    }

    /// #242 (was `keepsLocalWhenEmbeddingsDiffer`): a voice that does not resemble the remote
    /// speaker no longer vetoes the echo. Same words at the same time, 3 words or more: flagged.
    @Test func flagsEchoWhenEmbeddingsDiffer() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Same text here", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "Same text here", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [0, 0, 0, 1]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 2)
        #expect(result.flaggedCount == 1)
        #expect(result.segments.first { $0.source == "local" }?.echo == true)
        #expect(result.clusters.first?.bestEmbeddingSimilarity == 0, "recorded as evidence, not used")
    }

    /// The guard for what the embedding veto used to protect: both sides saying the same one or two
    /// words at once is not an echo — whatever the voices look like, here identical.
    @Test func keepsOneAndTwoWordMatchesWhateverTheEmbedding() {
        let segments = [
            LabeledSegment(start: 10, end: 11, speaker: "Remote Speaker 1", text: "Yeah.", source: "remote"),
            LabeledSegment(start: 10, end: 11, speaker: "Local Speaker 1", text: "Yeah.", source: "local"),
            LabeledSegment(start: 20, end: 21, speaker: "Remote Speaker 1", text: "It's okay.", source: "remote"),
            LabeledSegment(start: 20, end: 21, speaker: "Local Speaker 1", text: "It's okay.", source: "local"),
        ]
        let db: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: db, remoteSpeakerDatabase: db
        )
        #expect(result.flaggedCount == 0)
        #expect(result.segments.allSatisfy { !$0.echo })
        #expect(result.clusters.first?.matchedSegments == 2, "they match; they are too short to be flagged on their own")
    }

    @Test func wordCountIsWhitespaceWordsWithALetterOrDigit() {
        #expect(EchoDeduplicator.wordCount("Yeah.") == 1)
        #expect(EchoDeduplicator.wordCount("It's okay.") == 2)
        #expect(EchoDeduplicator.wordCount("  one  two\tthree\n") == 3)
        #expect(EchoDeduplicator.wordCount("— ... ?") == 0)
        #expect(EchoDeduplicator.wordCount("") == 0)
    }

    @Test func handlesEmptySegments() {
        let result = EchoDeduplicator.deduplicate(
            segments: [], localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.segments.isEmpty)
        #expect(result.flaggedCount == 0)
    }

    @Test func handlesSingleSourceOnly() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "Hello", source: "remote"),
            LabeledSegment(start: 6, end: 10, speaker: "Remote Speaker 2", text: "World", source: "remote"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.segments.count == 2)
        #expect(result.flaggedCount == 0)
    }

    @Test func handlesMultipleEchoesInSequence() {
        let segments = [
            LabeledSegment(start: 0, end: 5, speaker: "Remote Speaker 1", text: "First sentence here", source: "remote"),
            LabeledSegment(start: 0.1, end: 5.1, speaker: "Local Speaker 1", text: "First sentence here", source: "local"),
            LabeledSegment(start: 6, end: 10, speaker: "Remote Speaker 1", text: "Second sentence here", source: "remote"),
            LabeledSegment(start: 6.1, end: 10.2, speaker: "Local Speaker 1", text: "Second sentence here", source: "local"),
            LabeledSegment(start: 11, end: 15, speaker: "Local Speaker 2", text: "My own unique thought", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = [
            "Speaker 1": [0.98, 0.52, 0.31, 0.19],
            "Speaker 2": [0.1, 0.9, 0.1, 0.1],
        ]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 5, "flagged, not deleted")
        #expect(result.segments.filter { !$0.echo }.count == 3)
        #expect(result.flaggedCount == 2)
        #expect(result.segments.contains { $0.text == "My own unique thought" && !$0.echo })
    }

    // MARK: - Windowed text comparison (misaligned segment boundaries)

    @Test func removesEchoWhenLocalMergesMultipleRemoteSegments() {
        // Local ASR merged 3 remote segments into one long segment (common with mic bleed)
        let segments = [
            LabeledSegment(start: 10, end: 20, speaker: "Remote Speaker 1", text: "bike shops in case of mechanical issue", source: "remote"),
            LabeledSegment(start: 20, end: 25, speaker: "Remote Speaker 1", text: "options for bike rentals", source: "remote"),
            LabeledSegment(start: 25, end: 30, speaker: "Remote Speaker 1", text: "unlimited and easily find great rentals", source: "remote"),
            // Local segment covers all 3 remote segments as one merged segment
            LabeledSegment(start: 10.1, end: 30.2, speaker: "Local Speaker 1", text: "bike shops in case of mechanical issue options for bike rentals unlimited and easily find great rentals", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.flaggedCount == 1)
        #expect(result.segments.count == 4, "flagged, not deleted")
        #expect(result.segments.filter { !$0.echo }.allSatisfy { $0.source == "remote" })
    }

    @Test func removesEchoWhenLocalIsSubsetOfLongerRemote() {
        // Local segment is a shorter excerpt of a longer remote segment
        let segments = [
            LabeledSegment(start: 20, end: 35, speaker: "Remote Speaker 1", text: "here is my take on the topic from someone who has been cycling in Mallorca for almost ten years and loving it", source: "remote"),
            LabeledSegment(start: 29, end: 34, speaker: "Local Speaker 1", text: "here is my take on the topic from someone who has been cycling in Mallorca for almost ten years", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        // Individual comparison should catch this since local is subset — Jaccard should be high
        #expect(result.flaggedCount == 1)
    }

    @Test func removesEchoWhenLocalIsShortExcerptOfLongRemote() {
        // Local is a short excerpt from the middle of a much longer remote segment
        // Jaccard fails (small intersection / huge union), but containment catches it
        let segments = [
            LabeledSegment(start: 140, end: 170, speaker: "Remote Speaker 1",
                text: "Don't get me wrong there are also lots of options out there so do your research but you will find a bike your size and have a great time and finally it also means that you have so many restaurants and cafes made for cyclists that are open all year long",
                source: "remote"),
            LabeledSegment(start: 158, end: 162, speaker: "Local Speaker 1",
                text: "And finally it also means that you have so many restaurants and cafes",
                source: "local"),
            LabeledSegment(start: 167, end: 170, speaker: "Local Speaker 1",
                text: "Made for cyclists that are open all year long",
                source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.flaggedCount == 2)
        #expect(result.segments.count == 3, "flagged, not deleted")
        #expect(result.segments.filter { !$0.echo }.map(\.source) == ["remote"])
    }

    @Test func keepsLocalWhenContainmentIsLowDespiteSomeWordOverlap() {
        // Local shares some words with remote but is genuinely different speech
        let segments = [
            LabeledSegment(start: 140, end: 170, speaker: "Remote Speaker 1",
                text: "cycling in Mallorca is great because there are so many restaurants and cafes and bike shops open all year long for tourists",
                source: "remote"),
            LabeledSegment(start: 152, end: 158, speaker: "Local Speaker 1",
                text: "Maybe that's a solution for a first cycling holiday to go with Hunter and rent a bike locally",
                source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.flaggedCount == 0)
        #expect(result.segments.count == 2)
    }

    @Test func keepsLocalWhenWindowTextStillDiffers() {
        // Local speaker is genuinely talking about a related topic while remote plays
        let segments = [
            LabeledSegment(start: 10, end: 20, speaker: "Remote Speaker 1", text: "cycling in Mallorca is amazing", source: "remote"),
            LabeledSegment(start: 20, end: 30, speaker: "Remote Speaker 1", text: "the weather is perfect year round", source: "remote"),
            LabeledSegment(start: 10, end: 30, speaker: "Local Speaker 1", text: "I need to buy new bib shorts and maybe a helmet before our trip", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1.0, 0.5, 0.3, 0.2]]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.flaggedCount == 0)
        #expect(result.segments.count == 3)
    }

    /// #242 (was `worksWithoutEmbeddings`, which asserted only that nothing was deleted): with no
    /// embeddings at all the echo is still judged on time and text, and no similarity is recorded.
    @Test func flagsEchoWithoutEmbeddings() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Same text here", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Local Speaker 1", text: "Same text here", source: "local"),
            LabeledSegment(start: 20, end: 22, speaker: "Remote Speaker 1", text: "Same text", source: "remote"),
            LabeledSegment(start: 20, end: 22, speaker: "Local Speaker 1", text: "Same text", source: "local"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.segments.count == 4)
        #expect(result.segments.filter(\.echo).map(\.text) == ["Same text here"], "two words alone are not flagged")
        #expect(result.clusters.count == 1 && result.clusters.first?.bestEmbeddingSimilarity == nil)
    }

    /// #242 (was `keepsLocalWhenOverlappingTextIsFromDifferentRemoteSpeaker`): the local voice
    /// resembles Remote Speaker 1, and the words are Remote Speaker 2's. The match is made against
    /// every remote speaker, so this is an echo of Speaker 2 and the verdict says so.
    @Test func flagsEchoOfARemoteSpeakerTheLocalVoiceDoesNotResemble() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Totally different content", source: "remote"),
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 2", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10.1, end: 15.2, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
        ]
        // Local Speaker 1 embeds like Remote Speaker 1 (not Speaker 2)
        let remoteDb: [String: [Float]] = [
            "Speaker 1": [1.0, 0.5, 0.3, 0.2],
            "Speaker 2": [0.1, 0.2, 0.9, 0.4],
        ]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 3)
        #expect(result.flaggedCount == 1)
        #expect(result.clusters.first?.matchedRemote.keys.sorted() == ["Remote Speaker 2"])
    }

    /// The guard for the cross-talk case that test used to protect: a one- or two-word reply that a
    /// different remote speaker happens to say at the same moment is kept.
    @Test func keepsShortLocalReplyThatADifferentRemoteSpeakerAlsoSays() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "Totally different content", source: "remote"),
            LabeledSegment(start: 12, end: 13, speaker: "Remote Speaker 2", text: "Quick fox", source: "remote"),
            LabeledSegment(start: 12.1, end: 13.1, speaker: "Local Speaker 1", text: "Quick fox", source: "local"),
        ]
        let remoteDb: [String: [Float]] = [
            "Speaker 1": [1.0, 0.5, 0.3, 0.2],
            "Speaker 2": [0.1, 0.2, 0.9, 0.4],
        ]
        let localDb: [String: [Float]] = ["Speaker 1": [0.98, 0.52, 0.31, 0.19]]

        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb
        )
        #expect(result.segments.count == 3)
        #expect(result.flaggedCount == 0)
    }

    /// The deprecated `echo_embedding_threshold` is accepted and changes nothing.
    @Test func theEmbeddingThresholdIsIgnored() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: 10.1, end: 15.2, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
        ]
        let remoteDb: [String: [Float]] = ["Speaker 1": [1, 0, 0, 0]]
        let localDb: [String: [Float]] = ["Speaker 1": [0, 1, 0, 0]]
        for threshold in [0.0, 0.8, 1.0] {
            let result = EchoDeduplicator.deduplicate(
                segments: segments, localSpeakerDatabase: localDb, remoteSpeakerDatabase: remoteDb,
                embeddingThreshold: threshold
            )
            #expect(result.flaggedCount == 1)
        }
    }

    // MARK: - Invalid input

    /// A segment whose times are not finite or run backwards is never a candidate nor evidence, and
    /// it adds no time to its cluster.
    @Test func segmentsWithUnusableTimesAreNeverMatched() {
        let segments = [
            LabeledSegment(start: 10, end: 15, speaker: "Remote Speaker 1", text: "The quick brown fox", source: "remote"),
            LabeledSegment(start: .nan, end: 15, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
            LabeledSegment(start: 15, end: 10, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
            LabeledSegment(start: 12, end: 12, speaker: "Local Speaker 1", text: "The quick brown fox", source: "local"),
            LabeledSegment(start: .infinity, end: .infinity, speaker: "Remote Speaker 1", text: "Jumps over the dog", source: "remote"),
            LabeledSegment(start: 30, end: 35, speaker: "Local Speaker 1", text: "Jumps over the dog", source: "local"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:]
        )
        #expect(result.flaggedCount == 0)
        let cluster = result.clusters.first
        #expect(cluster?.segments == 4 && cluster?.seconds == 5 && cluster?.matchedSeconds == 0 && cluster?.share == 0)
    }

    /// A dual-stream recording where the remote side said nothing: every local cluster is reported
    /// as kept with nothing matched.
    @Test func noRemoteSpeechKeepsEveryClusterAndStillReportsIt() {
        let segments = [
            LabeledSegment(start: 0, end: 40, speaker: "Local Speaker 1", text: "My own unique thought", source: "local"),
        ]
        let result = EchoDeduplicator.deduplicate(
            segments: segments, localSpeakerDatabase: ["Speaker 1": [1, 0, 0, 0]], remoteSpeakerDatabase: [:]
        )
        #expect(result.flaggedCount == 0)
        #expect(result.clusters == [EchoDeduplicator.ClusterVerdict(
            label: "Local Speaker 1", segments: 1, matchedSegments: 0, seconds: 40, matchedSeconds: 0,
            words: 4, matchedWords: 0, share: 0, verdict: .kept)])
    }
}
