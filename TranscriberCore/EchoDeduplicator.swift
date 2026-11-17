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

    /// Word-level Jaccard similarity, over the words `EchoTextNormalizer` makes of each side (#363).
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(EchoTextNormalizer.words(a))
        let wordsB = Set(EchoTextNormalizer.words(b))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    /// What fraction of words in `a` appear in `b`.
    /// Useful when `a` is a short excerpt of a longer `b` — Jaccard penalises
    /// the size mismatch, but containment captures that `a` is fully inside `b`.
    public static func textContainment(_ a: String, _ b: String) -> Double {
        let wordsA = Set(EchoTextNormalizer.words(a))
        let wordsB = Set(EchoTextNormalizer.words(b))
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

    // MARK: - Per-line safeguards (#365, constants, not config keys)

    /// The longest loudspeaker-to-mic delay an echo copy can have: the canceller's own bound
    /// (`LocalVQEEchoCanceller.maxDelaySamples`, 500 ms; Bluetooth output is about 200-300 ms).
    public static let maximumEchoDelaySeconds =
        Double(LocalVQEEchoCanceller.maxDelaySamples) / Double(LocalVQEEchoCanceller.sampleRate)
    /// How far apart the two channels' recognisers may place the same sound: each decodes its own channel
    /// and places a line's start to within a frame or two (Parakeet's frames are 80 ms), on capture
    /// timelines aligned to the wall clock. The physical minimum echo delay (buffers and air, tens of
    /// milliseconds) is below this resolution, so it is folded in here as 0.
    public static let echoTimingToleranceSeconds = 0.3

    /// What echo cancellation measured about the acoustic path from the loudspeaker to the mic (#365):
    /// per measured span of the segments' timeline, how far the raw mic rose above its own floor while the
    /// far end talked (`MicEchoCancelRecord.farEndLiftDB`). Where the canceller found no coupling — a
    /// headphone call measured 2.5 dB, a loudspeaker call 31 — there was no echo for the mic to pick up,
    /// and a line that repeats the far end is the user repeating it.
    public struct AcousticCoupling: Equatable, Sendable {
        public struct Span: Equatable, Sendable {
            public let start: Double
            public let end: Double
            /// nil: too little far-end speech to measure (`EchoReduction.farEndLift`).
            public let farEndLiftDB: Double?

            public init(start: Double, end: Double, farEndLiftDB: Double?) {
                self.start = start
                self.end = end
                self.farEndLiftDB = farEndLiftDB
            }
        }

        /// Below this lift the mic did not hear the far end: the canceller's own line for "there was an echo
        /// to remove" (`EchoReduction.audibleEchoLiftDB`, 15 dB), so the record never says both "no echo to
        /// remove" and "echo lines flagged one by one". Measured: about 0-3 dB on headphones, 27-32 dB on
        /// loudspeakers; the 6 dB the issue suggested would also separate those, and 15 dB holds back more
        /// lines where the measure is unsure, which is the side a wrong call should fall on.
        public static let uncoupledBelowLiftDB = EchoReduction.audibleEchoLiftDB

        public let spans: [Span]

        /// Nothing measured: the per-line rule applies everywhere.
        public static let unknown = AcousticCoupling(spans: [])

        public init(spans: [Span]) {
            // A span with no extent, or a NaN, holds no line.
            self.spans = spans.filter { $0.end > $0.start }
        }

        /// One chunk's record, over the whole chunk whatever its timeline; unknown without a record.
        public static func chunk(_ record: MicEchoCancelRecord?) -> AcousticCoupling {
            guard let record else { return .unknown }
            return AcousticCoupling(spans: [Span(start: -.infinity, end: .infinity, farEndLiftDB: record.farEndLiftDB)])
        }

        /// The chunks' measures a transcript keeps in `metadata.mic_echo_cancel.per_chunk` (on the
        /// transcript's timeline); unknown for a transcript written before #365 or without cancellation.
        public init(transcriptMetadata metadata: [String: Any]) {
            let entries = (metadata["mic_echo_cancel"] as? [String: Any])?["per_chunk"] as? [[String: Any]] ?? []
            self.init(spans: entries.compactMap { entry in
                guard let start = (entry["start"] as? NSNumber)?.doubleValue,
                      let seconds = (entry["seconds"] as? NSNumber)?.doubleValue,
                      start.isFinite, seconds.isFinite, seconds > 0 else { return nil }
                return Span(start: start, end: start + seconds, farEndLiftDB: (entry["far_end_lift_db"] as? NSNumber)?.doubleValue)
            })
        }

        /// One `per_chunk` entry: where the chunk sits on the transcript's timeline and what was measured.
        public static func metadataEntry(chunk: Int, start: Double, record: MicEchoCancelRecord) -> [String: Any] {
            var entry: [String: Any] = ["chunk": chunk, "start": (start * 1000).rounded() / 1000, "seconds": record.seconds]
            if let lift = record.farEndLiftDB { entry["far_end_lift_db"] = lift }
            if let erle = record.erleDB { entry["erle_db"] = erle }
            return entry
        }

        /// Whether a line from `start` to `end` touches a span measured without coupling. A line across a
        /// chunk boundary counts as uncoupled when either chunk is: in doubt, not flagged.
        public func isUncoupled(start: Double, end: Double) -> Bool {
            spans.contains { span in
                guard let lift = span.farEndLiftDB, lift < Self.uncoupledBelowLiftDB else { return false }
                return start <= span.end && end >= span.start
            }
        }
    }

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
        /// The indices (into `segments`) of every local segment that matched concurrent remote speech,
        /// flagged or not: a match of 1–2 words outside an echo cluster is matched and left unflagged.
        public let matchedLocal: Set<Int>

        public init(segments: [LabeledSegment], flaggedCount: Int, clusters: [ClusterVerdict] = [], matchedLocal: Set<Int> = []) {
            self.segments = segments
            self.flaggedCount = flaggedCount
            self.clusters = clusters
            self.matchedLocal = matchedLocal
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
    /// Outside an echo cluster a matched segment is also flagged only when it can be an echo copy (#365):
    /// - (a) the mic heard the far end where it was said: not where echo cancellation measured no
    ///   coupling (`coupling`, `AcousticCoupling.uncoupledBelowLiftDB`);
    /// - (b) it is no longer, in normalised words, than the far end's speech around it (every remote
    ///   segment within `echoTimingToleranceSeconds`: a repetition adds "No, …" or "…, thanks"), starts no
    ///   earlier than that speech (less the tolerance), and, when it holds as many words as all of it, within
    ///   `maximumEchoDelaySeconds` + the tolerance of its start (a full repetition starts once the far end
    ///   has said it). A shorter copy is placed anywhere inside it, as the recognisers cut lines differently.
    /// Neither changes a match, a share or a cluster's verdict, and neither applies in an echo cluster.
    ///
    /// - Parameter embeddingThreshold: DEPRECATED and ignored (`echo_embedding_threshold`). Kept for
    ///   one release so existing callers and config files keep working.
    /// - Parameter logPrefix: put before each verdict's log line, so a check whose verdicts are not
    ///   the record (the one before minority absorption, #249) does not read like the record.
    /// - Parameter coupling: what echo cancellation measured for these segments; `.unknown` when it did
    ///   not run.
    public static func deduplicate(
        segments: [LabeledSegment],
        localSpeakerDatabase: [String: [Float]],
        remoteSpeakerDatabase: [String: [Float]],
        temporalThreshold: Double? = nil,
        textThreshold: Double? = nil,
        embeddingThreshold: Double? = nil,
        embeddingDim: Int? = nil,
        logPrefix: String = "",
        coupling: AcousticCoupling = .unknown
    ) -> DeduplicationResult {
        let tThresh = temporalThreshold ?? defaultTemporalThreshold
        let xThresh = textThreshold ?? defaultTextThreshold

        // An already-flagged segment (gate-filtered noise, an abutting repeat) is neither an echo
        // candidate nor evidence for one.
        let remoteSegments = segments.filter { $0.source == "remote" && !$0.isFlagged }

        // 1. Per-segment match.
        var matches: [Int: Match] = [:]
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
                for (remoteLabel, overlap) in matches[i]?.overlapSeconds ?? [:] { remote[remoteLabel, default: 0] += overlap }
            }
            let share = seconds > 0 ? matchedSeconds / seconds : 0
            let isEcho = share >= clusterShareThreshold && seconds >= clusterMinimumSeconds
            var flagged = 0, heldUncoupled = 0, heldTiming = 0
            for i in matched {
                if !isEcho {
                    guard wordCount(segments[i].text) >= minimumWordsOutsideEchoCluster else { continue }
                    if coupling.isUncoupled(start: segments[i].start, end: segments[i].end) { heldUncoupled += 1; continue }
                    if let match = matches[i], !canBeEchoCopy(segments[i], of: match) { heldTiming += 1; continue }
                }
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
                "\(logPrefix, privacy: .public)Echo cluster \(label, privacy: .private): verdict \(verdict.verdict.rawValue, privacy: .public), share \(share, format: .fixed(precision: 3), privacy: .public), matched \(matched.count, privacy: .public)/\(indices.count, privacy: .public) segments, \(matchedSeconds, format: .fixed(precision: 1), privacy: .public)/\(seconds, format: .fixed(precision: 1), privacy: .public) s, \(matchedWords, privacy: .public)/\(words, privacy: .public) words, flagged \(flagged, privacy: .public) (held back: \(heldUncoupled, privacy: .public) no coupling, \(heldTiming, privacy: .public) not an echo copy), remote speakers matched \(remote.count, privacy: .public), embedding similarity \(verdict.bestEmbeddingSimilarity ?? .nan, format: .fixed(precision: 3), privacy: .public) (evidence only)"
            )
        }

        return DeduplicationResult(segments: result, flaggedCount: flaggedCount, clusters: clusters,
                                   matchedLocal: Set(matches.keys))
    }

    /// A segment's length; 0 when its times are not finite or run backwards.
    private static func duration(of segment: LabeledSegment) -> Double {
        let d = segment.end - segment.start
        return d.isFinite && d > 0 ? d : 0
    }

    /// What a local segment repeats, and the remote speech around it.
    private struct Match {
        /// Per remote label, the seconds the local segment overlaps the remote speech it repeats.
        var overlapSeconds: [String: Double]
        /// The far end's speech around the local line: every unflagged remote segment within
        /// `echoTimingToleranceSeconds` of it. Not only the segment(s) it matched: the two recognisers cut
        /// lines differently, and an echo line often carries the tail of the remote line before.
        var contextStart: Double
        var contextEnd: Double
        /// The context's normalised words (`EchoTextNormalizer`), counted with repeats.
        var contextWords: Int
    }

    /// #365 (b): whether `local` can be an echo copy of the far end's speech around it, by length and timing.
    private static func canBeEchoCopy(_ local: LabeledSegment, of match: Match) -> Bool {
        let words = EchoTextNormalizer.words(local.text).count
        // A repetition adds words ("No, …", "…, thanks"); an echo copy holds no more than the far end said
        // around it (a recogniser drops words more often than it adds them).
        guard words <= match.contextWords else { return false }
        // An echo never precedes its source.
        guard local.start >= match.contextStart - echoTimingToleranceSeconds else { return false }
        // A copy of everything the far end said there starts within the echo delay of it; a repetition only
        // once it has been said. A shorter copy can start anywhere inside it.
        if words == match.contextWords {
            return local.start <= match.contextStart + maximumEchoDelaySeconds + echoTimingToleranceSeconds
        }
        return local.start < match.contextEnd
    }

    /// Whether `local` repeats concurrent remote speech, from whichever remote speaker: nil when it
    /// does not, else what it repeats.
    private static func matchedRemote(
        local: LabeledSegment,
        remoteSegments: [LabeledSegment],
        temporalThreshold: Double,
        textThreshold: Double
    ) -> Match? {
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
        var matched: [String: Double]?
        if let best {
            matched = [best.remote.speaker: overlapSeconds(best.remote)]
        } else if overlapping.count > 1 {
            let window = overlapping.sorted { $0.start < $1.start }
            if textSimilarity(local.text, window.map(\.text).joined(separator: " ")) > textThreshold {
                var result: [String: Double] = [:]
                for remote in window { result[remote.speaker, default: 0] += overlapSeconds(remote) }
                matched = result
            }
        }
        guard let matched else { return nil }
        let context = remoteSegments.filter { remote in
            duration(of: remote) > 0 && remote.end >= local.start - echoTimingToleranceSeconds
                && remote.start <= local.end + echoTimingToleranceSeconds
        }
        return Match(overlapSeconds: matched,
                     contextStart: context.map(\.start).min() ?? local.start,
                     contextEnd: context.map(\.end).max() ?? local.end,
                     contextWords: context.reduce(0) { $0 + EchoTextNormalizer.words($1.text).count })
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
