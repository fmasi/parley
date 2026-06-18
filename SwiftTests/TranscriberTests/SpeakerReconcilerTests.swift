import Testing
import Foundation
@testable import TranscriberCore

@Suite("SpeakerReconciler")
struct SpeakerReconcilerTests {

    // MARK: - cosineSimilarity

    @Test func cosineSimilarityIdenticalVectors() {
        let v = [Float](repeating: 0.5, count: 256)
        let sim = SpeakerReconciler.cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < 1e-5)
    }

    @Test func cosineSimilarityOrthogonalVectors() {
        var a = [Float](repeating: 0, count: 256); a[0] = 1.0
        var b = [Float](repeating: 0, count: 256); b[1] = 1.0
        let sim = SpeakerReconciler.cosineSimilarity(a, b)
        #expect(abs(sim) < 1e-5)
    }

    @Test func cosineSimilarityOppositeVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        let sim = SpeakerReconciler.cosineSimilarity(a, b)
        #expect(abs(sim - (-1.0)) < 1e-5)
    }

    // MARK: - reconcile

    @Test func reconcileSingleChunkReturnsIdentityMapping() {
        var emb0 = [Float](repeating: 0, count: 256); emb0[0] = 1.0
        var emb1 = [Float](repeating: 0, count: 256); emb1[1] = 1.0

        let chunk = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/chunk0.wav",
            segments: [],
            speakerDatabase: ["spk_0": emb0, "spk_1": emb1]
        )

        let mapping = SpeakerReconciler.reconcile(chunks: [chunk])
        // Chunk 0 → identity: each local speaker maps to itself
        #expect(mapping[0]?["spk_0"] == "spk_0")
        #expect(mapping[0]?["spk_1"] == "spk_1")
    }

    @Test func reconcileMatchesSpeakersAcrossChunks() {
        // Chunk 0: spk_0 → axis 0, spk_1 → axis 1
        var emb0 = [Float](repeating: 0, count: 256); emb0[0] = 1.0
        var emb1 = [Float](repeating: 0, count: 256); emb1[1] = 1.0

        let chunk0 = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/chunk0.wav",
            segments: [],
            speakerDatabase: ["spk_0": emb0, "spk_1": emb1]
        )

        // Chunk 1: labels flipped — local "spkA" is axis 0 (= global spk_0),
        //                             local "spkB" is axis 1 (= global spk_1)
        var embA = [Float](repeating: 0, count: 256); embA[0] = 1.0
        var embB = [Float](repeating: 0, count: 256); embB[1] = 1.0

        let chunk1 = ProcessedChunk(
            index: 1,
            startTime: Date(),
            audioPath: "/tmp/chunk1.wav",
            segments: [],
            speakerDatabase: ["spkA": embA, "spkB": embB]
        )

        let mapping = SpeakerReconciler.reconcile(chunks: [chunk0, chunk1])

        // spkA (axis 0) should be matched to spk_0 (axis 0)
        #expect(mapping[1]?["spkA"] == "spk_0")
        // spkB (axis 1) should be matched to spk_1 (axis 1)
        #expect(mapping[1]?["spkB"] == "spk_1")
    }

    @Test func reconcileDetectsNewSpeaker() {
        // Chunk 0: spk_0 → axis 0
        var emb0 = [Float](repeating: 0, count: 256); emb0[0] = 1.0

        let chunk0 = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/chunk0.wav",
            segments: [],
            speakerDatabase: ["spk_0": emb0]
        )

        // Chunk 1: "newPerson" → axis 1 (orthogonal to axis 0 → no match)
        var embNew = [Float](repeating: 0, count: 256); embNew[1] = 1.0

        let chunk1 = ProcessedChunk(
            index: 1,
            startTime: Date(),
            audioPath: "/tmp/chunk1.wav",
            segments: [],
            speakerDatabase: ["newPerson": embNew]
        )

        let mapping = SpeakerReconciler.reconcile(chunks: [chunk0, chunk1])

        // newPerson is orthogonal → below threshold → assigned a new global ID
        let globalID = mapping[1]?["newPerson"]
        #expect(globalID != nil)
        #expect(globalID != "spk_0")
        // New speakers get IDs of the form "spk_N"
        #expect(globalID?.hasPrefix("spk_") == true)
    }

    @Test func reconcileEmptyDatabaseProducesEmptyMapping() {
        let chunk = ProcessedChunk(
            index: 0,
            startTime: Date(),
            audioPath: "/tmp/chunk0.wav",
            segments: [],
            speakerDatabase: [:]
        )

        let mapping = SpeakerReconciler.reconcile(chunks: [chunk])
        #expect(mapping[0]?.isEmpty == true)
    }

    @Test func reconcileSpeakerLeavesAfterChunk1() {
        var emb0 = [Float](repeating: 0, count: 256)
        emb0[0] = 1.0
        var emb1 = [Float](repeating: 0, count: 256)
        emb1[1] = 1.0

        let chunks = [
            ProcessedChunk(
                index: 0, startTime: Date(), audioPath: "m-0.m4a",
                segments: [], speakerDatabase: ["spk_0": emb0, "spk_1": emb1]
            ),
            ProcessedChunk(
                index: 1, startTime: Date(), audioPath: "m-1.m4a",
                segments: [], speakerDatabase: ["spk_0": emb0] // spk_1 left
            )
        ]

        let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
        #expect(mapping[1]?["spk_0"] == "spk_0")
        #expect(mapping[1]?.count == 1)
    }

    @Test func reconcileSingleSpeakerThroughout() {
        var emb = [Float](repeating: 0, count: 256)
        emb[0] = 1.0

        let chunks = (0..<4).map { i in
            ProcessedChunk(
                index: i, startTime: Date(), audioPath: "m-\(i).m4a",
                segments: [], speakerDatabase: ["spk_0": emb]
            )
        }

        let mapping = SpeakerReconciler.reconcile(chunks: chunks, threshold: 0.65)
        for i in 0..<4 {
            #expect(mapping[i]?["spk_0"] == "spk_0")
        }
    }

    // Regression (bug_004): chunks may be stored in processing-completion order,
    // not index order. Reconciliation seeds the global namespace from the first
    // chunk, so the result must not depend on the input array order.
    @Test func reconcileIsIndependentOfInputOrder() {
        // Two different speakers sharing the same local label "spk_0" across chunks.
        var axisA = [Float](repeating: 0, count: 256); axisA[0] = 1.0
        var axisB = [Float](repeating: 0, count: 256); axisB[1] = 1.0

        let chunk0 = ProcessedChunk(
            index: 0, startTime: Date(), audioPath: "m-0.m4a",
            segments: [], speakerDatabase: ["spk_0": axisA]
        )
        let chunk1 = ProcessedChunk(
            index: 1, startTime: Date(), audioPath: "m-1.m4a",
            segments: [], speakerDatabase: ["spk_0": axisB]
        )

        let inOrder = SpeakerReconciler.reconcile(chunks: [chunk0, chunk1])
        let reversed = SpeakerReconciler.reconcile(chunks: [chunk1, chunk0])

        #expect(inOrder == reversed)
        // Chunk 0 (chronologically first) seeds the namespace → identity mapping.
        #expect(inOrder[0]?["spk_0"] == "spk_0")
    }
}
