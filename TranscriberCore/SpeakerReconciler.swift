import Foundation
import os

/// Cross-chunk speaker matching via cosine similarity.
///
/// Maintains a reference embedding per global speaker ID and uses greedy
/// cosine-similarity matching to reconcile local speaker labels produced by
/// per-chunk diarization into a consistent global namespace.
public enum SpeakerReconciler {

    // MARK: - Cosine similarity

    /// Cosine similarity between two equal-length embedding vectors.
    ///
    /// Returns `0` for empty arrays, mismatched lengths, or zero-norm inputs.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0 ..< a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - Reconcile

    /// Reconcile per-chunk local speaker IDs into global speaker IDs.
    ///
    /// - Parameters:
    ///   - chunks: Ordered array of `ProcessedChunk` values.
    ///   - threshold: Minimum cosine similarity to consider two embeddings a match (default 0.65).
    /// - Returns: `[chunkIndex: [localSpeakerID: globalSpeakerID]]`
    public static func reconcile(
        chunks unsortedChunks: [ProcessedChunk],
        threshold: Float = 0.65
    ) -> [Int: [String: String]] {
        // Thin wrapper preserving the original behavior: reconcile over each
        // chunk's remote/system speaker database.
        let databases = unsortedChunks.map { (chunkIndex: $0.index, database: $0.speakerDatabase) }
        return reconcile(databases: databases, threshold: threshold)
    }

    /// Reconcile an ordered list of per-chunk speaker databases into a global
    /// namespace. This is the shared core used by both the remote and local
    /// speaker pools (called separately so the pools never merge).
    ///
    /// - Parameters:
    ///   - databases: Ordered list of `(chunkIndex, database)` pairs. Sorted by
    ///     `chunkIndex` internally for deterministic seeding.
    ///   - threshold: Minimum cosine similarity to consider a match (default 0.65).
    /// - Returns: `[chunkIndex: [localSpeakerID: globalSpeakerID]]`
    static func reconcile(
        databases unsortedDatabases: [(chunkIndex: Int, database: [String: [Float]])],
        threshold: Float = 0.65
    ) -> [Int: [String: String]] {

        // Seed the global namespace from the chronologically-first chunk. Callers
        // (TranscriptionRunner.finalize) may pass chunks in processing-completion
        // order, so sort by index to keep reconciliation deterministic.
        let databases = unsortedDatabases.sorted { $0.chunkIndex < $1.chunkIndex }

        var result: [Int: [String: String]] = [:]
        // Global reference embeddings: globalID → embedding
        var referenceEmbeddings: [String: [Float]] = [:]
        // Auto-increment counter for new global IDs
        var nextGlobalIndex: Int = 0

        for entry in databases {
            let chunkIndex = entry.chunkIndex
            let db = entry.database
            var mapping: [String: String] = [:]

            if referenceEmbeddings.isEmpty {
                // First chunk (or first non-empty database): identity mapping, seed references
                for (localID, embedding) in db {
                    let globalID = localID
                    mapping[localID] = globalID
                    referenceEmbeddings[globalID] = embedding
                    // Keep next index ahead of any numeric suffix in seed IDs
                    if let suffix = localID.components(separatedBy: "_").last,
                       let n = Int(suffix) {
                        nextGlobalIndex = max(nextGlobalIndex, n + 1)
                    }
                }
                result[chunkIndex] = mapping
                continue
            }

            // Build candidate pairs: (localID, globalID, similarity)
            var candidates: [(localID: String, globalID: String, similarity: Float)] = []
            for (localID, localEmb) in db {
                for (globalID, refEmb) in referenceEmbeddings {
                    let sim = cosineSimilarity(localEmb, refEmb)
                    if sim >= threshold {
                        candidates.append((localID, globalID, sim))
                    }
                }
            }

            // Greedy assignment: highest similarity first
            candidates.sort { $0.similarity > $1.similarity }
            var assignedLocals  = Set<String>()
            var assignedGlobals = Set<String>()

            for candidate in candidates {
                guard !assignedLocals.contains(candidate.localID),
                      !assignedGlobals.contains(candidate.globalID) else { continue }

                mapping[candidate.localID] = candidate.globalID
                assignedLocals.insert(candidate.localID)
                assignedGlobals.insert(candidate.globalID)

                // EMA update reference embedding (alpha = 0.9)
                let alpha: Float = 0.9
                if let oldRef = referenceEmbeddings[candidate.globalID],
                   let chunkEmb = db[candidate.localID] {
                    let newRef = zip(oldRef, chunkEmb).map { alpha * $0 + (1 - alpha) * $1 }
                    referenceEmbeddings[candidate.globalID] = newRef
                }

                Logger.transcription.debug(
                    "SpeakerReconciler: chunk \(chunkIndex, privacy: .public) remap \(candidate.localID, privacy: .public) → \(candidate.globalID, privacy: .public) (sim=\(candidate.similarity, privacy: .public))"
                )
            }

            // Unmatched local speakers → new global IDs
            for (localID, embedding) in db where mapping[localID] == nil {
                let newGlobalID = "spk_\(nextGlobalIndex)"
                nextGlobalIndex += 1
                mapping[localID] = newGlobalID
                referenceEmbeddings[newGlobalID] = embedding

                Logger.transcription.debug(
                    "SpeakerReconciler: chunk \(chunkIndex, privacy: .public) new speaker \(localID, privacy: .public) → \(newGlobalID, privacy: .public)"
                )
            }

            result[chunkIndex] = mapping
        }

        return result
    }
}
