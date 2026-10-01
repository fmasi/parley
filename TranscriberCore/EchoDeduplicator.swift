import Foundation
import os

public enum EchoDeduplicator {

    // MARK: - Default thresholds

    public static let defaultTemporalThreshold: Double = 0.5
    public static let defaultTextThreshold: Double = 0.7

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

    // MARK: - Cluster rule (constants, not config keys)

    /// A local cluster is echo when at least this share of its duration matches concurrent remote
    /// speech. Measured on a real speaker-mode call: 0.91 for the bleed cluster, never above 0.05
    /// for the user's own (#242).
    public static let clusterShareThreshold: Double = 0.5
    /// A cluster with less speech than this is not judged as a cluster (three one-word replies are
    /// no evidence of anything).
    public static let clusterMinimumSeconds: Double = 30
    /// Outside an echo cluster a matched segment is flagged only from this many words: "Yes." said
    /// on both sides at once matches on time and text and is not an echo.
    public static let minimumWordsOutsideEchoCluster = 3

    /// Whitespace-separated words that hold at least one letter or digit ("It's okay." is 2).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    // MARK: - Result

    /// What the dedup found for one local cluster (one diarized speaker label on the mic side):
    /// numbers and labels only, never text. Persisted on `ProcessedChunk.echoClusters` and written to
    /// the transcript's `metadata.echo_clusters`, so the decision can be audited without a re-run.
    ///
    /// Only UNFLAGGED local segments are counted: one already `filtered` or `duplicate` is neither a
    /// candidate nor part of these totals. "Matched" means the segment overlaps a remote segment in
    /// time and repeats its words; it is flagged `echo` when the cluster's verdict is `.echo`, or
    /// when it has `minimumWordsOutsideEchoCluster` words or more.
    public struct ClusterVerdict: Codable, Equatable, Sendable {
        public enum Verdict: String, Codable, Sendable {
            /// The cluster is the other side's voice through the speakers: every matched segment is flagged.
            case echo
            /// The cluster is somebody on this side: only its matches of 3 words or more are flagged.
            case kept
        }

        /// The cluster's speaker label as its segments carry it ("Local Speaker 2").
        public var label: String
        public var segments: Int
        public var matchedSegments: Int
        public var seconds: Double
        public var matchedSeconds: Double
        public var words: Int
        public var matchedWords: Int
        /// `matchedSeconds / seconds` (0 when the cluster holds no time).
        public var share: Double
        public var verdict: Verdict
        /// The highest cosine similarity between this cluster's voice and any remote speaker's.
        /// EVIDENCE ONLY — it plays no part in the verdict. nil when either side has no embedding.
        public var bestEmbeddingSimilarity: Double?
        /// Per remote speaker label, the seconds of this cluster's matched segments that overlap the
        /// remote speech they repeat.
        public var matchedRemote: [String: Double]

        public var isEcho: Bool { verdict == .echo }

        public init(label: String, segments: Int, matchedSegments: Int, seconds: Double, matchedSeconds: Double,
                    words: Int, matchedWords: Int, share: Double, verdict: Verdict,
                    bestEmbeddingSimilarity: Double? = nil, matchedRemote: [String: Double] = [:]) {
            self.label = label
            self.segments = segments
            self.matchedSegments = matchedSegments
            self.seconds = seconds
            self.matchedSeconds = matchedSeconds
            self.words = words
            self.matchedWords = matchedWords
            self.share = share
            self.verdict = verdict
            self.bestEmbeddingSimilarity = bestEmbeddingSimilarity
            self.matchedRemote = matchedRemote
        }

        /// The same names as `metadata.echo_clusters`, so session.json and the transcript read alike.
        private enum CodingKeys: String, CodingKey {
            case label, segments, seconds, words, share, verdict
            case matchedSegments = "matched_segments"
            case matchedSeconds = "matched_seconds"
            case matchedWords = "matched_words"
            case bestEmbeddingSimilarity = "embedding_similarity"
            case matchedRemote = "matched_remote"
        }

        /// One `metadata.echo_clusters` entry. `chunk` is left out when the dedup ran over a whole
        /// file rather than one chunk (the single-file path). `relabel` maps a chunk-local speaker
        /// label to the transcript's global one; remote labels that land on the same global label
        /// are summed.
        public func metadataDictionary(track: String = "local", chunk: Int?, relabel: (String) -> String = { $0 }) -> [String: Any] {
            func rounded(_ value: Double, _ places: Double) -> Double { (value * places).rounded() / places }
            var remote: [String: Double] = [:]
            for (label, seconds) in matchedRemote { remote[relabel(label), default: 0] += seconds }
            var d: [String: Any] = [
                "track": track,
                "label": relabel(label),
                "segments": segments,
                "matched_segments": matchedSegments,
                "seconds": rounded(seconds, 1000),
                "matched_seconds": rounded(matchedSeconds, 1000),
                "words": words,
                "matched_words": matchedWords,
                "share": rounded(share, 10_000),
                "verdict": verdict.rawValue,
                "matched_remote": remote.mapValues { rounded($0, 1000) },
            ]
            if let chunk { d["chunk"] = chunk }
            if let bestEmbeddingSimilarity {
                d["embedding_similarity"] = rounded(bestEmbeddingSimilarity, 10_000)
            }
            return d
        }
    }

    public struct DeduplicationResult {
        /// Every input segment; echoes carry `echo = true` (P11 — flagged, never deleted).
        public let segments: [LabeledSegment]
        /// How many local segments were flagged as echo.
        public let flaggedCount: Int
        /// One verdict per local cluster that holds an unflagged segment, sorted by label.
        public let clusters: [ClusterVerdict]

        public init(segments: [LabeledSegment], flaggedCount: Int, clusters: [ClusterVerdict] = []) {
            self.segments = segments
            self.flaggedCount = flaggedCount
            self.clusters = clusters
        }

        /// The chunk's processing issues for this result, both informational: `echo_flagged` (how
        /// many segments) and `echo_cluster` (how many local clusters were judged to be echo).
        public var issues: [ChunkIssue] {
            let echoClusters = clusters.filter(\.isEcho).count
            return (flaggedCount > 0 ? [ChunkIssue(code: .echoFlagged, track: "local", count: flaggedCount)] : [])
                + (echoClusters > 0 ? [ChunkIssue(code: .echoCluster, track: "local", count: echoClusters)] : [])
        }
    }

    // MARK: - Main deduplication

    /// Flags local segments that are mic bleed of the remote side (#242).
    ///
    /// 1. Per segment, speaker-independent: an unflagged local segment MATCHES when an unflagged
    ///    remote segment of ANY remote speaker overlaps it in time (> `temporalThreshold` of the
    ///    shorter one) and repeats its words (Jaccard or containment > `textThreshold`, or the
    ///    Jaccard against all the overlapping remote segments joined).
    /// 2. Per local cluster (speaker label): `share = matched seconds / total seconds`. The cluster
    ///    is echo when `share >= clusterShareThreshold` and it holds `clusterMinimumSeconds`.
    /// 3. In an echo cluster every matched segment is flagged, whatever its length; its unmatched
    ///    segments stay unflagged under the cluster's label. Elsewhere a matched segment is flagged
    ///    only from `minimumWordsOutsideEchoCluster` words.
    ///
    /// The voice similarity is recorded as evidence and decides nothing: speaker playback into a
    /// far-field mic changes a voice enough to fail any fixed threshold (0.68 on the call behind
    /// #242), and bleed absorbed into the user's own cluster carries the user's embedding.
    ///
    /// - Parameter embeddingThreshold: DEPRECATED and ignored (`echo_embedding_threshold`). Kept for
    ///   one release so existing callers and config files keep working.
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

        // An already-flagged segment (gate-filtered noise, an abutting repeat) is neither an echo
        // candidate nor evidence for one.
        let remoteSegments = segments.filter { $0.source == "remote" && !$0.isFlagged }

        // 1. Per-segment match.
        var matches: [Int: [String: Double]] = [:]   // segment index → remote label → overlap seconds
        var clusterIndices: [String: [Int]] = [:]
        for i in segments.indices where segments[i].source == "local" && !segments[i].isFlagged {
            clusterIndices[segments[i].speaker, default: []].append(i)
            if let remote = matchedRemote(local: segments[i], remoteSegments: remoteSegments,
                                          temporalThreshold: tThresh, textThreshold: xThresh) {
                matches[i] = remote
            }
        }

        // 2. Cluster verdicts, 3. flags.
        let similarities = bestEmbeddingSimilarities(
            local: localSpeakerDatabase, remote: remoteSpeakerDatabase, embeddingDim: embeddingDim)
        var result = segments
        var flaggedCount = 0
        var clusters: [ClusterVerdict] = []
        for (label, indices) in clusterIndices.sorted(by: { $0.key < $1.key }) {
            let matched = indices.filter { matches[$0] != nil }
            let seconds = indices.reduce(0) { $0 + duration(of: segments[$1]) }
            let matchedSeconds = matched.reduce(0) { $0 + duration(of: segments[$1]) }
            let words = indices.reduce(0) { $0 + wordCount(segments[$1].text) }
            let matchedWords = matched.reduce(0) { $0 + wordCount(segments[$1].text) }
            var remote: [String: Double] = [:]
            for i in matched {
                for (remoteLabel, overlap) in matches[i] ?? [:] { remote[remoteLabel, default: 0] += overlap }
            }
            let share = seconds > 0 ? matchedSeconds / seconds : 0
            let isEcho = share >= clusterShareThreshold && seconds >= clusterMinimumSeconds
            var flagged = 0
            for i in matched where isEcho || wordCount(segments[i].text) >= minimumWordsOutsideEchoCluster {
                result[i].echo = true
                flagged += 1
            }
            flaggedCount += flagged
            let dbKey = label.hasPrefix("Local ") ? String(label.dropFirst("Local ".count)) : label
            let verdict = ClusterVerdict(
                label: label, segments: indices.count, matchedSegments: matched.count,
                seconds: seconds, matchedSeconds: matchedSeconds, words: words, matchedWords: matchedWords,
                share: share, verdict: isEcho ? .echo : .kept,
                bestEmbeddingSimilarity: similarities[dbKey], matchedRemote: remote)
            clusters.append(verdict)
            // Numbers only are public; a label becomes a name once the user renames a speaker.
            Logger.transcription.info(
                "Echo cluster \(label, privacy: .private): verdict \(verdict.verdict.rawValue, privacy: .public), share \(share, format: .fixed(precision: 3), privacy: .public), matched \(matched.count, privacy: .public)/\(indices.count, privacy: .public) segments, \(matchedSeconds, format: .fixed(precision: 1), privacy: .public)/\(seconds, format: .fixed(precision: 1), privacy: .public) s, \(matchedWords, privacy: .public)/\(words, privacy: .public) words, flagged \(flagged, privacy: .public), remote speakers matched \(remote.count, privacy: .public), embedding similarity \(verdict.bestEmbeddingSimilarity ?? .nan, format: .fixed(precision: 3), privacy: .public) (evidence only)"
            )
        }

        return DeduplicationResult(segments: result, flaggedCount: flaggedCount, clusters: clusters)
    }

    /// A segment's length; 0 when its times are not finite or run backwards.
    private static func duration(of segment: LabeledSegment) -> Double {
        let d = segment.end - segment.start
        return d.isFinite && d > 0 ? d : 0
    }

    /// Whether `local` repeats concurrent remote speech, from whichever remote speaker: nil when it
    /// does not, else the seconds it overlaps the remote segment(s) it repeats, per remote label.
    private static func matchedRemote(
        local: LabeledSegment,
        remoteSegments: [LabeledSegment],
        temporalThreshold: Double,
        textThreshold: Double
    ) -> [String: Double]? {
        guard duration(of: local) > 0 else { return nil }
        func overlapSeconds(_ remote: LabeledSegment) -> Double {
            max(min(local.end, remote.end) - max(local.start, remote.start), 0)
        }

        // Every remote segment that overlaps this one in time. Compared one by one, then joined, to
        // handle misaligned boundaries — one long local segment over what the remote side split
        // into several shorter ones.
        let overlapping = remoteSegments.filter { remote in
            duration(of: remote) > 0 && temporalOverlap(
                aStart: local.start, aEnd: local.end, bStart: remote.start, bEnd: remote.end
            ) > temporalThreshold
        }
        guard !overlapping.isEmpty else { return nil }

        // Jaccard, or containment when the local segment is a short excerpt of a longer remote one
        // (Jaccard then fails on the size of the union). The best-scoring remote segment wins.
        var best: (remote: LabeledSegment, score: Double)?
        for remote in overlapping {
            let score = max(textSimilarity(local.text, remote.text), textContainment(local.text, remote.text))
            if score > textThreshold, score > (best?.score ?? 0) { best = (remote, score) }
        }
        if let best { return [best.remote.speaker: overlapSeconds(best.remote)] }

        guard overlapping.count > 1 else { return nil }
        let window = overlapping.sorted { $0.start < $1.start }
        guard textSimilarity(local.text, window.map(\.text).joined(separator: " ")) > textThreshold else { return nil }
        var result: [String: Double] = [:]
        for remote in window { result[remote.speaker, default: 0] += overlapSeconds(remote) }
        return result
    }

    /// Per local speaker key, the highest cosine similarity to any remote speaker. Evidence only.
    private static func bestEmbeddingSimilarities(
        local: [String: [Float]], remote: [String: [Float]], embeddingDim: Int?
    ) -> [String: Double] {
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
            baseDim = (Array(local.values) + Array(remote.values)).filter { !$0.isEmpty }.map(\.count).reduce(0) { gcd($0, $1) }
        }
        // Pool each speaker's accumulated vectors into one centroid so `cosineSimilarity` always
        // receives equal-length vectors. For single-segment databases (the common case) a no-op.
        let remoteCentroids = remote.values.filter { !$0.isEmpty }.map { centroid(from: $0, dim: baseDim) }
        var result: [String: Double] = [:]
        for (key, embedding) in local where !embedding.isEmpty {
            let mine = centroid(from: embedding, dim: baseDim)
            // Vectors of different lengths are not comparable (cosineSimilarity would say 0).
            // Finite only: the verdict is persisted, and a NaN cannot be encoded as JSON.
            let similarities = remoteCentroids.filter { $0.count == mine.count }.map { cosineSimilarity(mine, $0) }.filter(\.isFinite)
            if let best = similarities.max() { result[key] = Double(best) }
        }
        return result
    }
}
