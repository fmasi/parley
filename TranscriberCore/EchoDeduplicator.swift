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
        embeddingThreshold: Double? = nil
    ) -> DeduplicationResult {
        let tThresh = temporalThreshold ?? defaultTemporalThreshold
        let xThresh = textThreshold ?? defaultTextThreshold
        let eThresh = Float(embeddingThreshold ?? Double(defaultEmbeddingThreshold))

        Logger.transcription.debug(
            "Echo dedup: \(segments.count, privacy: .public) segments, localDb keys: \(Array(localSpeakerDatabase.keys), privacy: .public), remoteDb keys: \(Array(remoteSpeakerDatabase.keys), privacy: .public), thresholds: temporal=\(tThresh, privacy: .public) text=\(xThresh, privacy: .public) embedding=\(eThresh, privacy: .public)"
        )

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
                      localDb: localSpeakerDatabase, remoteDb: remoteSpeakerDatabase,
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
                "Echo dedup: no embedding for '\(localSpeakerName, privacy: .public)' (localDb keys: \(Array(localDb.keys), privacy: .public))"
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
                "Echo dedup: embedding gate FAILED for '\(localSpeakerName, privacy: .public)' — best match '\(bestRemoteKey, privacy: .public)' at \(String(format: "%.3f", bestSimilarity), privacy: .public) (threshold \(embeddingThreshold, privacy: .public))"
            )
            return false
        }
        Logger.transcription.debug(
            "Echo dedup: embedding gate PASSED for '\(localSpeakerName, privacy: .public)' — matches '\(bestRemoteKey, privacy: .public)' at \(String(format: "%.3f", bestSimilarity), privacy: .public)"
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
                "Echo dedup: '\(localSpeakerName, privacy: .public)' vs '\(remote.speaker, privacy: .public)' — temporal=\(String(format: "%.3f", overlap), privacy: .public) text=\(String(format: "%.3f", textSim), privacy: .public) (thresholds: \(String(format: "%.2f", temporalThreshold), privacy: .public)/\(String(format: "%.2f", textThreshold), privacy: .public)) local=\"\(local.text.prefix(60), privacy: .public)\" remote=\"\(remote.text.prefix(60), privacy: .public)\""
            )
            if textSim > textThreshold {
                Logger.transcription.debug(
                    "Echo dedup: REMOVING '\(localSpeakerName, privacy: .public)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — echo of '\(remote.speaker, privacy: .public)'"
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
                        "Echo dedup: '\(localSpeakerName, privacy: .public)' vs '\(remote.speaker, privacy: .public)' — containment=\(String(format: "%.3f", containment), privacy: .public) (Jaccard was \(String(format: "%.3f", textSim), privacy: .public))"
                    )
                    Logger.transcription.debug(
                        "Echo dedup: REMOVING '\(localSpeakerName, privacy: .public)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — contained in '\(remote.speaker, privacy: .public)'"
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
                "Echo dedup: '\(localSpeakerName, privacy: .public)' vs WINDOW(\(sorted.count, privacy: .public) segs) — text=\(String(format: "%.3f", windowSim), privacy: .public) (threshold: \(String(format: "%.2f", textThreshold), privacy: .public)) local=\"\(local.text.prefix(60), privacy: .public)\" window=\"\(windowText.prefix(80), privacy: .public)\""
            )
            if windowSim > textThreshold {
                Logger.transcription.debug(
                    "Echo dedup: REMOVING '\(localSpeakerName, privacy: .public)' segment [\(String(format: "%.1f", local.start), privacy: .public)-\(String(format: "%.1f", local.end), privacy: .public)s] — echo of window [\(speakers, privacy: .public)]"
                )
                return true
            }
        }

        return false
    }
}
