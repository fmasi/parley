import Foundation
import os

public enum EchoDeduplicator {

    // MARK: - Default thresholds

    public static let defaultTemporalThreshold: Double = 0.5
    public static let defaultTextThreshold: Double = 0.7
    public static let defaultEmbeddingThreshold: Float = 0.8

    // MARK: - Helper functions

    public static func temporalOverlap(
        aStart: Double, aEnd: Double,
        bStart: Double, bEnd: Double
    ) -> Double {
        let overlapStart = max(aStart, bStart)
        let overlapEnd = min(aEnd, bEnd)
        let overlap = max(overlapEnd - overlapStart, 0)
        let shorter = min(aEnd - aStart, bEnd - bStart)
        guard shorter > 0 else { return 0 }
        return min(overlap / shorter, 1.0)
    }

    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    /// What fraction of words in `a` appear in `b`.
    /// Useful when `a` is a short excerpt of a longer `b` — Jaccard penalises
    /// the size mismatch, but containment captures that `a` is fully inside `b`.
    public static func textContainment(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !wordsA.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        return Double(intersection) / Double(wordsA.count)
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Compute the centroid (mean) of multiple embedding vectors stored as a single
    /// flat concatenated `[Float]` array. Each individual embedding has `dim` floats.
    ///
    /// When `TranscriptionRunner` accumulates speaker databases across crash-recovery
    /// segments with `existing + new`, each entry grows to `N × dim` floats where N
    /// is the number of segments the speaker appeared in. This function collapses that
    /// back to a single `dim`-float centroid so `cosineSimilarity` always receives
    /// equal-length vectors regardless of per-speaker segment counts.
    ///
    /// If `accumulated.count == dim` (single embedding), returns it unchanged.
    /// Falls back to returning `accumulated` as-is if lengths do not divide evenly.
    public static func centroid(from accumulated: [Float], dim: Int) -> [Float] {
        guard dim > 0, !accumulated.isEmpty, accumulated.count % dim == 0 else {
            return accumulated
        }
        let count = accumulated.count / dim
        guard count > 1 else { return accumulated }
        var result = [Float](repeating: 0, count: dim)
        for segment in 0..<count {
            for d in 0..<dim {
                result[d] += accumulated[segment * dim + d]
            }
        }
        return result.map { $0 / Float(count) }
    }

    /// Greatest common divisor (Euclid). `gcd(0, n) == n`, so reducing a list of
    /// embedding lengths from a seed of 0 yields the GCD of the whole list.
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    // MARK: - Result

    public struct DeduplicationResult {
        public let segments: [LabeledSegment]
        public let removedCount: Int
    }

    // MARK: - Main deduplication

    public static func deduplicate(
        segments: [LabeledSegment],
        localSpeakerDatabase: [String: [Float]],
        remoteSpeakerDatabase: [String: [Float]],
        temporalThreshold: Double? = nil,
        textThreshold: Double? = nil,
        embeddingThreshold: Double? = nil,
        embeddingDim: Int? = nil
    ) -> DeduplicationResult {
        let tThresh = temporalThreshold ?? defaultTemporalThreshold
        let xThresh = textThreshold ?? defaultTextThreshold
        let eThresh = Float(embeddingThreshold ?? Double(defaultEmbeddingThreshold))

        Logger.transcription.debug(
            "Echo dedup: \(segments.count, privacy: .public) segments, localDb keys: \(Array(localSpeakerDatabase.keys), privacy: .private), remoteDb keys: \(Array(remoteSpeakerDatabase.keys), privacy: .private), thresholds: temporal=\(tThresh, privacy: .public) text=\(xThresh, privacy: .public) embedding=\(eThresh, privacy: .public)"
        )

        // Base embedding dimension, used to pool accumulated multi-segment embeddings into a
        // centroid. The robust source is `embeddingDim` passed by the caller, captured from a
        // known single-segment embedding before any accumulation (TranscriptionRunner does
        // this in the crash-recovery merge path). When it isn't supplied we fall back to the
        // GCD of all non-empty entry lengths — correct whenever speakers have differing
        // segment counts, but it cannot recover `dim` if EVERY speaker appears the same number
        // of times ≥2 (e.g. a 2-person call recovered as 2 chunks → all entries 2×dim →
        // gcd = 2×dim). Hence callers on the accumulation path should pass `embeddingDim`.
        let baseDim: Int
        if let embeddingDim, embeddingDim > 0 {
            baseDim = embeddingDim
        } else {
            var allLengths: [Int] = []
            for v in localSpeakerDatabase.values where !v.isEmpty { allLengths.append(v.count) }
            for v in remoteSpeakerDatabase.values where !v.isEmpty { allLengths.append(v.count) }
            baseDim = allLengths.reduce(0) { gcd($0, $1) }
        }

        // Pool each speaker's accumulated embedding vectors into a single centroid so that
        // cosineSimilarity always receives equal-length vectors regardless of per-speaker
        // segment counts. For single-segment databases (the common case) this is a no-op.
        let localCentroidDb  = localSpeakerDatabase.mapValues  { centroid(from: $0, dim: baseDim) }
        let remoteCentroidDb = remoteSpeakerDatabase.mapValues { centroid(from: $0, dim: baseDim) }

        let remoteSegments = segments.filter { $0.source == "remote" }
        guard !remoteSegments.isEmpty else {
            return DeduplicationResult(segments: segments, removedCount: 0)
        }

        var kept: [LabeledSegment] = []
        var removedCount = 0

        for seg in segments {
            guard seg.source == "local" else {
                kept.append(seg)
                continue
            }

            if isEcho(local: seg, remoteSegments: remoteSegments,
                      localDb: localCentroidDb, remoteDb: remoteCentroidDb,
                      temporalThreshold: tThresh, textThreshold: xThresh, embeddingThreshold: eThresh) {
                removedCount += 1
            } else {
                kept.append(seg)
            }
        }

        if removedCount > 0 {
            Logger.transcription.debug("Echo dedup: removed \(removedCount, privacy: .public) local segments (mic bleed of remote speaker)")
        }

        return DeduplicationResult(segments: kept, removedCount: removedCount)
    }

    private static func isEcho(
        local: LabeledSegment,
        remoteSegments: [LabeledSegment],
        localDb: [String: [Float]],
        remoteDb: [String: [Float]],
        temporalThreshold: Double,
        textThreshold: Double,
        embeddingThreshold: Float
    ) -> Bool {
        // Speaker embedding gate runs first (cheap), then temporal+text per overlap.
        // Recover the DB key for this local speaker (segments are prefixed by
        // tagWithSourcePrefix as "Local Speaker N"; DB keys are "Speaker N").
        let localSpeakerName = local.speaker.hasPrefix("Local ")
            ? String(local.speaker.dropFirst("Local ".count))
            : local.speaker
        guard let localEmbedding = localDb[localSpeakerName],
              !localEmbedding.isEmpty else {
            Logger.transcription.debug(
                "Echo dedup: no embedding for '\(localSpeakerName, privacy: .private)' (localDb keys: \(Array(localDb.keys), privacy: .private))"
            )
            return false
        }

        var bestSimilarity: Float = 0
        var bestRemoteKey = ""
        for (remoteKey, remoteEmbedding) in remoteDb {
            let sim = cosineSimilarity(localEmbedding, remoteEmbedding)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestRemoteKey = remoteKey
            }
        }

        guard bestSimilarity > embeddingThreshold else {
            Logger.transcription.debug(
                "Echo dedup: embedding gate FAILED for '\(localSpeakerName, privacy: .private)' — best match '\(bestRemoteKey, privacy: .private)' at \(String(format: "%.3f", bestSimilarity), privacy: .public) (threshold \(embeddingThreshold, privacy: .public))"
            )
            return false
        }
        Logger.transcription.debug(
            "Echo dedup: embedding gate PASSED for '\(localSpeakerName, privacy: .private)' — matches '\(bestRemoteKey, privacy: .private)' at \(String(format: "%.3f", bestSimilarity), privacy: .public)"
        )

        // The local voice resembles `bestRemoteKey`. Only that remote speaker's
        // segments can be the source of the echo, so filter before the temporal
        // + text loop (otherwise cross-talk from a different remote speaker can
        // produce a false positive).
        let bestRemoteSpeaker = "Remote \(bestRemoteKey)"
        let candidateRemotes = remoteSegments.filter { $0.speaker == bestRemoteSpeaker }

        // Temporal + text gates (windowed). Collect all candidate remote segments
        // that temporally overlap with this local segment, then compare local text
        // against each one (and concatenated, if multiple) to handle misaligned
        // boundaries — one long local segment covering content that the remote
        // side split into multiple shorter ones.
        var overlappingRemotes: [(segment: LabeledSegment, overlap: Double)] = []
        for remote in candidateRemotes {
            let overlap = temporalOverlap(
                aStart: local.start, aEnd: local.end,
                bStart: remote.start, bEnd: remote.end
            )
            if overlap > temporalThreshold {
                overlappingRemotes.append((remote, overlap))
            }
        }

        guard !overlappingRemotes.isEmpty else { return false }

        // Try individual comparisons first (handles aligned segments efficiently)
        for (remote, overlap) in overlappingRemotes {
            let textSim = textSimilarity(local.text, remote.text)
            Logger.transcription.debug(
                "Echo dedup: '\(localSpeakerName, privacy: .private)' vs '\(remote.speaker, privacy: .private)' — temporal=\(String(format: "%.3f", overlap), privacy: .public) text=\(String(format: "%.3f", textSim), privacy: .public) (thresholds: \(String(format: "%.2f", temporalThreshold), privacy: .public)/\(String(format: "%.2f", textThreshold), privacy: .public)) local=\"\(local.text.prefix(60), privacy: .private)\" remote=\"\(remote.text.prefix(60), privacy: .private)\""
            )
            if textSim > textThreshold {
                Logger.transcription.debug(
                    "Echo dedup: REMOVING '\(localSpeakerName, privacy: .private)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — echo of '\(remote.speaker, privacy: .private)'"
                )
                return true
            }

            // Containment fallback: when local is a short excerpt of a longer remote,
            // Jaccard fails because the union is huge. Check if most local words appear
            // in the remote text (local ⊂ remote).
            if textSim <= textThreshold {
                let containment = textContainment(local.text, remote.text)
                if containment > textThreshold {
                    Logger.transcription.debug(
                        "Echo dedup: '\(localSpeakerName, privacy: .private)' vs '\(remote.speaker, privacy: .private)' — containment=\(String(format: "%.3f", containment), privacy: .public) (Jaccard was \(String(format: "%.3f", textSim), privacy: .public))"
                    )
                    Logger.transcription.debug(
                        "Echo dedup: REMOVING '\(localSpeakerName, privacy: .private)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — contained in '\(remote.speaker, privacy: .private)'"
                    )
                    return true
                }
            }
        }

        // If no individual match, try concatenated window (handles misaligned boundaries)
        if overlappingRemotes.count > 1 {
            let sorted = overlappingRemotes.sorted { $0.0.start < $1.0.start }
            let windowText = sorted.map(\.0.text).joined(separator: " ")
            let windowSim = textSimilarity(local.text, windowText)
            let speakers = Array(Set(sorted.map(\.0.speaker))).joined(separator: "+")
            Logger.transcription.debug(
                "Echo dedup: '\(localSpeakerName, privacy: .private)' vs WINDOW(\(sorted.count, privacy: .public) segs) — text=\(String(format: "%.3f", windowSim), privacy: .public) (threshold: \(String(format: "%.2f", textThreshold), privacy: .public)) local=\"\(local.text.prefix(60), privacy: .private)\" window=\"\(windowText.prefix(80), privacy: .private)\""
            )
            if windowSim > textThreshold {
                Logger.transcription.debug(
                    "Echo dedup: REMOVING '\(localSpeakerName, privacy: .private)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — echo of window [\(speakers, privacy: .private)]"
                )
                return true
            }
        }

        return false
    }
}
