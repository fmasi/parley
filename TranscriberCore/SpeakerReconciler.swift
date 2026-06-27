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
        chunks: [ProcessedChunk],
        threshold: Float = 0.65
    ) -> [Int: [String: String]] {

        var result: [Int: [String: String]] = [:]
        // Global reference embeddings: globalID → embedding
        var referenceEmbeddings: [String: [Float]] = [:]
        // Auto-increment counter for new global IDs
        var nextGlobalIndex: Int = 0

        for chunk in chunks {
            // Merge remote (system) and local (mic) speaker databases so the reconciler
            // can match speakers regardless of which audio stream they came from. (#64)
            // Remote embeddings take precedence on key collision.
            let db = chunk.localSpeakerDatabase.merging(chunk.speakerDatabase) { _, remote in remote }
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
                result[chunk.index] = mapping
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
                    "SpeakerReconciler: chunk \(chunk.index, privacy: .public) remap \(candidate.localID, privacy: .public) → \(candidate.globalID, privacy: .public) (sim=\(candidate.similarity, privacy: .public))"
                )
            }

            // Unmatched local speakers → new global IDs
            for (localID, embedding) in db where mapping[localID] == nil {
                let newGlobalID = "spk_\(nextGlobalIndex)"
                nextGlobalIndex += 1
                mapping[localID] = newGlobalID
                referenceEmbeddings[newGlobalID] = embedding

                Logger.transcription.debug(
                    "SpeakerReconciler: chunk \(chunk.index, privacy: .public) new speaker \(localID, privacy: .public) → \(newGlobalID, privacy: .public)"
                )
            }

            result[chunk.index] = mapping
        }

        return result
    }
}
