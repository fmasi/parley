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
    ///   - isDualStream: When true, the mic (local) and system (remote) channels are reconciled in
    ///     SEPARATE namespaces and the output keys/values are `Local `/`Remote `-prefixed to match the
    ///     labels `tagWithSourcePrefix` put on the segments. A mic speaker never merges with a system
    ///     speaker (they are different channels — acoustic bleed can make their embeddings similar),
    ///     and the prefixed keys actually match `seg.speaker`, so `TranscriptMerger`'s remap applies —
    ///     fixing the previously-inert cross-chunk reconciliation for dual-stream (#64/#71).
    ///   - threshold: Minimum cosine similarity to consider two embeddings a match (default 0.65).
    /// - Returns: `[chunkIndex: [speakerLabel: globalSpeakerLabel]]`, keyed to match `seg.speaker`.
    public static func reconcile(
        chunks: [ProcessedChunk],
        isDualStream: Bool = false,
        threshold: Float = 0.65
    ) -> [Int: [String: String]] {
        guard isDualStream else {
            // Single-stream: one namespace, unprefixed — matches the unprefixed "Speaker N" segments.
            return reconcileNamespace(
                chunks: chunks, database: \.speakerDatabase, prefix: "", threshold: threshold
            )
        }
        // Dual-stream: reconcile each channel independently, prefixed to match the segment labels.
        var result: [Int: [String: String]] = [:]
        for (idx, mapping) in reconcileNamespace(
            chunks: chunks, database: \.localSpeakerDatabase, prefix: "Local ", threshold: threshold
        ) {
            result[idx, default: [:]].merge(mapping) { existing, _ in existing }
        }
        for (idx, mapping) in reconcileNamespace(
            chunks: chunks, database: \.speakerDatabase, prefix: "Remote ", threshold: threshold
        ) {
            result[idx, default: [:]].merge(mapping) { existing, _ in existing }
        }
        return result
    }

    /// Greedy cross-chunk cosine reconciliation over ONE channel's per-chunk database. Output labels
    /// are `prefix`-tagged so they match the segment labels (`prefix` is `""` for single-stream). New
    /// global IDs are `prefix`-tagged too, so a local `spk_0` and a remote `spk_0` never collide.
    private static func reconcileNamespace(
        chunks: [ProcessedChunk],
        database: KeyPath<ProcessedChunk, [String: [Float]]>,
        prefix: String,
        threshold: Float
    ) -> [Int: [String: String]] {

        var result: [Int: [String: String]] = [:]
        var referenceEmbeddings: [String: [Float]] = [:]   // unprefixed globalID → embedding
        var nextGlobalIndex: Int = 0

        for chunk in chunks {
            let db = chunk[keyPath: database]
            if db.isEmpty { continue }   // this channel had no identified speakers in this chunk
            var mapping: [String: String] = [:]

            if referenceEmbeddings.isEmpty {
                // First non-empty chunk for this channel: identity mapping, seed references.
                for (localID, embedding) in db {
                    mapping[prefix + localID] = prefix + localID
                    referenceEmbeddings[localID] = embedding
                    // Keep nextGlobalIndex above every index already in use. Production labels are
                    // "Speaker N" (space-separated), so the old "_"-split never parsed them and the
                    // counter stayed at 0 -- causing minted speakers to leak as "spk_0" (#113).
                    if let n = trailingIndex(localID) {
                        nextGlobalIndex = max(nextGlobalIndex, n + 1)
                    }
                }
                result[chunk.index] = mapping
                continue
            }

            var candidates: [(localID: String, globalID: String, similarity: Float)] = []
            for (localID, localEmb) in db {
                for (globalID, refEmb) in referenceEmbeddings {
                    let sim = cosineSimilarity(localEmb, refEmb)
                    if sim >= threshold { candidates.append((localID, globalID, sim)) }
                }
            }

            candidates.sort { $0.similarity > $1.similarity }
            var assignedLocals  = Set<String>()
            var assignedGlobals = Set<String>()

            for candidate in candidates {
                guard !assignedLocals.contains(candidate.localID),
                      !assignedGlobals.contains(candidate.globalID) else { continue }

                mapping[prefix + candidate.localID] = prefix + candidate.globalID
                assignedLocals.insert(candidate.localID)
                assignedGlobals.insert(candidate.globalID)

                let alpha: Float = 0.9
                if let oldRef = referenceEmbeddings[candidate.globalID],
                   let chunkEmb = db[candidate.localID] {
                    referenceEmbeddings[candidate.globalID] =
                        zip(oldRef, chunkEmb).map { alpha * $0 + (1 - alpha) * $1 }
                }

                Logger.transcription.debug(
                    "SpeakerReconciler: chunk \(chunk.index, privacy: .public) remap \(prefix + candidate.localID, privacy: .private) → \(prefix + candidate.globalID, privacy: .private) (sim=\(candidate.similarity, privacy: .public))"
                )
            }

            for (localID, embedding) in db where mapping[prefix + localID] == nil {
                // Mint a human-friendly global label that CONTINUES the seed chunk's "Speaker N"
                // numbering rather than a raw internal "spk_N" that would surface verbatim in the
                // transcript (#113). nextGlobalIndex is held above every index seen so far, so this
                // never collides with an existing global label in this channel's namespace.
                let newGlobalID = "Speaker \(nextGlobalIndex)"
                nextGlobalIndex += 1
                mapping[prefix + localID] = prefix + newGlobalID
                referenceEmbeddings[newGlobalID] = embedding

                Logger.transcription.debug(
                    "SpeakerReconciler: chunk \(chunk.index, privacy: .public) new speaker \(prefix + localID, privacy: .private) → \(prefix + newGlobalID, privacy: .private)"
                )
            }

            result[chunk.index] = mapping
        }

        return result
    }

    /// Extracts the trailing integer from a speaker label, handling both the production
    /// space-separated form ("Speaker 3" → 3) and the legacy underscore form ("spk_3" → 3).
    /// Returns nil when there is no trailing integer.
    static func trailingIndex(_ label: String) -> Int? {
        let digits = String(label.reversed().prefix { $0.isNumber }.reversed())
        return digits.isEmpty ? nil : Int(digits)
    }
}
