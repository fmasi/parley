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

    /// The words compared before #363: lower-cased, cut at anything that is not a letter or a digit.
    static func plainWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Both ways a text is read for the comparison: as before #363, and through `EchoTextNormalizer`.
    /// Each score is the higher of the two, so the normalisation only ever adds matches: number words
    /// one side keeps apart with commas ("one, two, three") still match as they did.
    private static let readings: [(String) -> [String]] = [plainWords, EchoTextNormalizer.words]

    /// Word-level Jaccard similarity: the higher of the plain and the normalised reading (#363).
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        readings.map { read in
            let wordsA = Set(read(a)), wordsB = Set(read(b))
            guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
            return Double(wordsA.intersection(wordsB).count) / Double(wordsA.union(wordsB).count)
        }.max() ?? 0
    }

    /// What fraction of words in `a` appear in `b`.
    /// Useful when `a` is a short excerpt of a longer `b` — Jaccard penalises
    /// the size mismatch, but containment captures that `a` is fully inside `b`.
    /// The higher of the plain and the normalised reading, as `textSimilarity`.
    public static func textContainment(_ a: String, _ b: String) -> Double {
        readings.map { read in
            let wordsA = Set(read(a)), wordsB = Set(read(b))
            guard !wordsA.isEmpty else { return 0 }
            return Double(wordsA.intersection(wordsB).count) / Double(wordsA.count)
        }.max() ?? 0
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

    // MARK: - Who is late (#252)

    /// A local cluster whose matched lines START this much earlier than the remote lines they match (the
    /// cluster's median) is the original, and the remote holds the copy: the far end returned the user's
    /// voice (a room system or speakerphone without echo cancellation). `echo_local_lead_margin_seconds`.
    ///
    /// From the issue's data, one direction only: on a real loudspeaker call the local copy started a
    /// median of +0.08 s AFTER the remote (IQR 0.00 to 0.08 s, 80 pairs); a round trip that returns the
    /// user's voice trails by the network delay, 0.15 s or more (0.4-0.6 s seen on AirPods, 2026-10-07).
    /// 0.1 s sits 0.18 s from the bleed median and 0.05 s inside the shortest round trip expected. It needs
    /// a real recording of the mirror case to confirm.
    public static let defaultLocalLeadMarginSeconds = 0.1
    /// The configurable margin's sane range: past a second the rule stops describing a round trip.
    public static let localLeadMarginRange: ClosedRange<Double> = 0...1
    /// The evidence the rule needs before it overturns a cluster (review of #252): the lines' placement is
    /// only good to `echoTimingToleranceSeconds` (0.3 s) and about 12 % of pairs are placed more than 0.2 s
    /// off, so a few early pairs must not unflag a whole bleed cluster. All three must hold, per cluster and
    /// per chunk: at least this many timed (near-identical) pairs ...
    public static let minimumLagPairs = 5
    /// ... at least this share of the matched lines timed (a bleed cluster with 60 matches, 5 of them timed,
    /// is not judged by those 5) ...
    public static let minimumTimedShare = 1.0 / 3
    /// ... and at least this share of the timed pairs leading by more than the margin, each on its own, as
    /// well as their median. A line whose own lag trails by more than the margin is still judged by the
    /// per-line rules even then.
    public static let minimumLeadingShare = 2.0 / 3

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

    /// What was measured about the acoustic path from the loudspeaker to the mic (#365, #374): per measured
    /// span of the segments' timeline, how far the raw mic rose above its own floor while the far end talked
    /// (`FarEndLift`, the same measure as `MicEchoCancelRecord.farEndLiftDB`). Measured on every dual-stream
    /// chunk since #374, with echo cancellation on or off. Where it found no coupling — a headphone call
    /// measured 2.5 dB, a loudspeaker call 31 — there was no echo for the mic to pick up, and a line that
    /// repeats the far end is the user repeating it.
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
        ///
        /// UNMEASURED BAND (#374): nothing between about 3 and 27 dB has been recorded. A quiet loudspeaker in a
        /// noisy room could lift 7-15 dB: it reads as "no coupling" here and its echo lines are held back
        /// (shown, not hidden). Measure such a call before moving this line.
        public static let uncoupledBelowLiftDB = EchoReduction.audibleEchoLiftDB

        /// Where a transcript keeps the measure (#374): `metadata.acoustic_coupling.per_chunk`, one entry per
        /// measured chunk, written whether or not echo cancellation ran.
        public static let metadataKey = "acoustic_coupling"

        public let spans: [Span]

        /// Nothing measured: the per-line rule applies everywhere.
        public static let unknown = AcousticCoupling(spans: [])

        public init(spans: [Span]) {
            // A span with no extent, or a NaN, holds no line.
            self.spans = spans.filter { $0.end > $0.start }
        }

        /// One chunk's record, over the whole chunk whatever its timeline; unknown without a record.
        public static func chunk(_ record: MicEchoCancelRecord?) -> AcousticCoupling {
            chunk(lift: record.map(FarEndLiftRecord.init))
        }

        /// One chunk's measure (#374) on the chunk's own timeline: its windows; a record without windows (the
        /// canceller's, or one written before them) over the whole chunk. Unknown without one.
        public static func chunk(lift: FarEndLiftRecord?) -> AcousticCoupling {
            guard let lift else { return .unknown }
            guard let windows = lift.windows else {
                return AcousticCoupling(spans: [Span(start: -.infinity, end: .infinity, farEndLiftDB: lift.farEndLiftDB)])
            }
            return AcousticCoupling(spans: windows.map { Span(start: $0.start, end: $0.start + $0.seconds, farEndLiftDB: $0.farEndLiftDB) })
        }

        /// The chunks' measures a transcript keeps, on the transcript's timeline: `metadata.acoustic_coupling.per_chunk`
        /// (#374, every measured chunk), else — a transcript written by the #365 build, which measured only with
        /// echo cancellation — `metadata.mic_echo_cancel.per_chunk`. Unknown for a transcript that has neither:
        /// the per-line rule then applies everywhere, as it did before #365.
        public init(transcriptMetadata metadata: [String: Any]) {
            let current = (metadata[Self.metadataKey] as? [String: Any])?["per_chunk"] as? [[String: Any]]
            let legacy = (metadata["mic_echo_cancel"] as? [String: Any])?["per_chunk"] as? [[String: Any]]
            let entries = current ?? legacy ?? []
            func span(_ entry: [String: Any]) -> Span? {
                guard let start = (entry["start"] as? NSNumber)?.doubleValue,
                      let seconds = (entry["seconds"] as? NSNumber)?.doubleValue,
                      start.isFinite, seconds.isFinite, seconds > 0 else { return nil }
                return Span(start: start, end: start + seconds, farEndLiftDB: (entry["far_end_lift_db"] as? NSNumber)?.doubleValue)
            }
            // A chunk with windows is judged by them (already on the transcript's timeline); one without, whole.
            self.init(spans: entries.flatMap { entry -> [Span] in
                if let windows = entry["windows"] as? [[String: Any]] { return windows.compactMap(span) }
                return span(entry).map { [$0] } ?? []
            })
        }

        /// One `mic_echo_cancel.per_chunk` entry: where the chunk sits on the transcript's timeline and what
        /// echo cancellation measured.
        public static func metadataEntry(chunk: Int, start: Double, record: MicEchoCancelRecord) -> [String: Any] {
            var entry = metadataEntry(chunk: chunk, start: start, lift: FarEndLiftRecord(record))
            if let erle = record.erleDB { entry["erle_db"] = erle }
            return entry
        }

        /// One `acoustic_coupling.per_chunk` entry (#374): where the chunk sits on the transcript's timeline, its
        /// whole lift, and its `windows` placed on the transcript's timeline too; each `far_end_lift_db` left out
        /// when there was too little far-end speech to measure.
        public static func metadataEntry(chunk: Int, start: Double, lift: FarEndLiftRecord) -> [String: Any] {
            func ms(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
            var entry: [String: Any] = ["chunk": chunk, "start": ms(start), "seconds": lift.seconds]
            if let value = lift.farEndLiftDB { entry["far_end_lift_db"] = value }
            if let windows = lift.windows {
                entry["windows"] = windows.map { window -> [String: Any] in
                    var w: [String: Any] = ["start": ms(start + window.start), "seconds": window.seconds]
                    if let value = window.farEndLiftDB { w["far_end_lift_db"] = value }
                    return w
                }
            }
            return entry
        }

        /// `metadata.acoustic_coupling` (#374): the entries, and the line they were judged against; nil (the key
        /// left out) when no chunk was measured.
        public static func metadataDictionary(perChunk: [[String: Any]]) -> [String: Any]? {
            guard !perChunk.isEmpty else { return nil }
            return ["per_chunk": perChunk, "uncoupled_below_db": uncoupledBelowLiftDB]
        }

        /// Whether a line from `start` to `end` was said where the mic did not hear the far end: EVERY span over it
        /// is measured and below the line, and there is one. A span that heard the far end, or one too little
        /// far-end speech was in to measure, keeps the per-line rule: holding back a bleed line shows the other
        /// side's words under the user's name, the worse of the two wrong calls (review of #374). So a line
        /// across a chunk boundary, or a window edge, is held back only when both sides say "no coupling".
        public func isUncoupled(start: Double, end: Double) -> Bool {
            let over = spans.filter { start <= $0.end && end >= $0.start }
            return !over.isEmpty && over.allSatisfy { span in
                guard let lift = span.farEndLiftDB else { return false }
                return lift < Self.uncoupledBelowLiftDB
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
        /// Who is late (#252): the median, over the matched near-identical lines, of the local line's start
        /// minus the start of the remote line it copies. Positive: the local side trails, as an echo copy does.
        /// nil without such a line, or in a verdict written before #252.
        public var medianLagSeconds: Double?
        /// How many matched lines that median is over; the rule needs `minimumLagPairs`.
        public var lagPairs: Int?
        /// Why the cluster or its lines were held back from the echo flag beyond the share: `reasonLocalLeads`
        /// when its matched lines lead the remote by more than the margin. nil otherwise.
        public var reason: String?

        /// `reason`: the local side leads, so it is the original and the remote holds the copy (#252).
        public static let reasonLocalLeads = "local_leads"

        public var isEcho: Bool { verdict == .echo }

        public init(label: String, segments: Int, matchedSegments: Int, seconds: Double, matchedSeconds: Double,
                    words: Int, matchedWords: Int, share: Double, verdict: Verdict,
                    bestEmbeddingSimilarity: Double? = nil, matchedRemote: [String: Double] = [:],
                    medianLagSeconds: Double? = nil, lagPairs: Int? = nil, reason: String? = nil) {
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
            self.medianLagSeconds = medianLagSeconds
            self.lagPairs = lagPairs
            self.reason = reason
        }

        /// The same names as `metadata.echo_clusters`, so session.json and the transcript read alike.
        private enum CodingKeys: String, CodingKey {
            case label, segments, seconds, words, share, verdict
            case matchedSegments = "matched_segments"
            case matchedSeconds = "matched_seconds"
            case matchedWords = "matched_words"
            case bestEmbeddingSimilarity = "embedding_similarity"
            case matchedRemote = "matched_remote"
            case medianLagSeconds = "median_lag_seconds"
            case lagPairs = "lag_pairs"
            case reason
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
            if let medianLagSeconds { d["median_lag_seconds"] = rounded(medianLagSeconds, 1000) }
            if let lagPairs { d["lag_pairs"] = lagPairs }
            if let reason { d["reason"] = reason }
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
        /// The matches outside an echo cluster the per-line rules hold back as the user's own (#365): where
        /// no coupling was measured, or not shaped like an echo copy; and every match of a cluster whose lines
        /// lead the remote (#252). Judged whatever the line's length, so one or two words are listed too. A
        /// subset of `matchedLocal`, never flagged.
        public let heldBack: Set<Int>

        public init(segments: [LabeledSegment], flaggedCount: Int, clusters: [ClusterVerdict] = [], matchedLocal: Set<Int> = [],
                    heldBack: Set<Int> = []) {
            self.segments = segments
            self.flaggedCount = flaggedCount
            self.clusters = clusters
            self.matchedLocal = matchedLocal
            self.heldBack = heldBack
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
    /// **Who is late (#252).** The original precedes its copy. Per local cluster, the median over its matched
    /// near-identical lines (word overlap with one remote line above the text threshold; not an excerpt
    /// matched by containment, nor a line matched against several joined) of (local start - start of that
    /// remote line), judged per chunk (`chunkStarts`). The local side leads there when it has
    /// `minimumLagPairs` timed pairs or more, they are `minimumTimedShare` of its matched lines or more,
    /// `minimumLeadingShare` of them lead by more than `localLeadMarginSeconds` each, and their median does
    /// too. It is then the original and the remote holds the copy (a far end that returns the user's voice):
    /// the cluster is never echo, whatever its share, and its timed lines there are not flagged, except a line
    /// whose own lag trails by more than the margin; that one and the untimed matches are judged by the
    /// per-line rules. The verdict
    /// records `reason: local_leads`. Not a per-line rule: line starts on the two channels differ by more
    /// than 0.2 s for about one pair in eight.
    ///
    /// - Parameter embeddingThreshold: DEPRECATED and ignored (`echo_embedding_threshold`). Kept for
    ///   one release so existing callers and config files keep working.
    /// - Parameter logPrefix: put before each verdict's log line, so a check whose verdicts are not
    ///   the record (the one before minority absorption, #249) does not read like the record.
    /// - Parameter coupling: the far-end lift measured for these segments (#374); `.unknown` when it was not
    ///   measured.
    /// - Parameter chunkStarts: where each chunk after the first starts on the segments' timeline, when they
    ///   span several (re-detect, the single-file path): who is late is judged per chunk, as the pipeline
    ///   judges it, so a mirror episode in one chunk is not drowned by the rest of the call.
    public static func deduplicate(
        segments: [LabeledSegment],
        localSpeakerDatabase: [String: [Float]],
        remoteSpeakerDatabase: [String: [Float]],
        temporalThreshold: Double? = nil,
        textThreshold: Double? = nil,
        embeddingThreshold: Double? = nil,
        embeddingDim: Int? = nil,
        logPrefix: String = "",
        localLeadMarginSeconds: Double? = nil,
        coupling: AcousticCoupling = .unknown,
        chunkStarts: [Double] = []
    ) -> DeduplicationResult {
        let tThresh = temporalThreshold ?? defaultTemporalThreshold
        let xThresh = textThreshold ?? defaultTextThreshold
        let leadMargin = localLeadMarginSeconds.flatMap { localLeadMarginRange.contains($0) ? $0 : nil }
            ?? defaultLocalLeadMarginSeconds

        // An already-flagged segment (gate-filtered noise, an abutting repeat) is neither an echo
        // candidate nor evidence for one.
        let remoteSegments = segments.filter { $0.source == "remote" && !$0.isFlagged }
        // Flagged remote speech is still the far end's sound: it is part of what an echo line may carry.
        let allRemote = segments.filter { $0.source == "remote" && duration(of: $0) > 0 }

        // 1. Per-segment match.
        var matches: [Int: Match] = [:]
        var clusterIndices: [String: [Int]] = [:]
        for i in segments.indices where segments[i].source == "local" && !segments[i].isFlagged {
            clusterIndices[segments[i].speaker, default: []].append(i)
            if let remote = matchedRemote(local: segments[i], remoteSegments: remoteSegments, allRemote: allRemote,
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
        var heldBack = Set<Int>()
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
            // Who is late (#252): local start minus the start of the remote line each near-identical line copies.
            var lagOf: [Int: Double] = [:]
            for i in matched {
                if let start = matches[i]?.remoteStart, (segments[i].start - start).isFinite { lagOf[i] = segments[i].start - start }
            }
            let lags = matched.compactMap { lagOf[$0] }
            let medianLag = lags.isEmpty ? nil : median(lags)
            // Judged per chunk: the chunks in which this cluster's lines lead.
            let chunkOf = { (i: Int) in chunkStarts.filter { $0 <= segments[i].start }.count }
            let leadingChunks = Set(Dictionary(grouping: matched, by: chunkOf).filter { _, lines in
                localLeads(timed: lines.compactMap { lagOf[$0] }, matched: lines.count, margin: leadMargin)
            }.keys)
            let localLeads = !leadingChunks.isEmpty
            let isEcho = !localLeads && share >= clusterShareThreshold && seconds >= clusterMinimumSeconds
            var flagged = 0, heldUncoupled = 0, heldTiming = 0, heldLeading = 0
            for i in matched {
                // The original, where its lines lead: a timed line there is not an echo copy, unless it itself
                // clearly trails. An untimed match keeps the per-line rules: held back, a bleed line would read
                // as the user's words.
                if leadingChunks.contains(chunkOf(i)), let lag = lagOf[i], lag <= leadMargin {
                    heldBack.insert(i)
                    heldLeading += 1
                    continue
                }
                if !isEcho {
                    // The per-line rules, judged for every match so the held-back ones are known whatever
                    // their length; only lines of 3 words or more can be flagged.
                    let uncoupled = coupling.isUncoupled(start: segments[i].start, end: segments[i].end)
                    let notACopy = !uncoupled && !(matches[i].map { canBeEchoCopy(segments[i], of: $0) } ?? true)
                    if uncoupled || notACopy { heldBack.insert(i) }
                    // Counted both ways, the fewer wins: "Twenty twenty six." is one word against "2026".
                    let words = min(wordCount(segments[i].text), EchoTextNormalizer.words(segments[i].text).count)
                    guard words >= minimumWordsOutsideEchoCluster else { continue }
                    if uncoupled { heldUncoupled += 1; continue }
                    if notACopy { heldTiming += 1; continue }
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
                bestEmbeddingSimilarity: similarities[dbKey], matchedRemote: remote,
                medianLagSeconds: medianLag, lagPairs: lags.isEmpty ? nil : lags.count,
                reason: localLeads ? ClusterVerdict.reasonLocalLeads : nil)
            clusters.append(verdict)
            // Numbers only are public; a label becomes a name once the user renames a speaker.
            Logger.transcription.info(
                "\(logPrefix, privacy: .public)Echo cluster \(label, privacy: .private): verdict \(verdict.verdict.rawValue, privacy: .public), share \(share, format: .fixed(precision: 3), privacy: .public), matched \(matched.count, privacy: .public)/\(indices.count, privacy: .public) segments, \(matchedSeconds, format: .fixed(precision: 1), privacy: .public)/\(seconds, format: .fixed(precision: 1), privacy: .public) s, \(matchedWords, privacy: .public)/\(words, privacy: .public) words, flagged \(flagged, privacy: .public) (held back: \(heldUncoupled, privacy: .public) no coupling, \(heldTiming, privacy: .public) not an echo copy, \(heldLeading, privacy: .public) local side leads), median lag \(medianLag ?? .nan, format: .fixed(precision: 2), privacy: .public) s over \(lags.count, privacy: .public) line(s), remote speakers matched \(remote.count, privacy: .public), embedding similarity \(verdict.bestEmbeddingSimilarity ?? .nan, format: .fixed(precision: 3), privacy: .public) (evidence only)"
            )
        }

        return DeduplicationResult(segments: result, flaggedCount: flaggedCount, clusters: clusters,
                                   matchedLocal: Set(matches.keys), heldBack: heldBack)
    }

    /// Whether a cluster's lines in one chunk lead the remote (#252): enough timed pairs, enough of its
    /// matches timed, enough of them leading each on its own, and their median leading.
    private static func localLeads(timed lags: [Double], matched: Int, margin: Double) -> Bool {
        guard lags.count >= minimumLagPairs, matched > 0,
              Double(lags.count) >= minimumTimedShare * Double(matched) else { return false }
        let leading = lags.filter { $0 < -margin }.count
        return Double(leading) >= minimumLeadingShare * Double(lags.count) && median(lags) < -margin
    }

    /// The median of a non-empty list.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// A segment's length; 0 when its times are not finite or run backwards.
    private static func duration(of segment: LabeledSegment) -> Double {
        let d = segment.end - segment.start
        return d.isFinite && d > 0 ? d : 0
    }

    /// What a local segment repeats, and the far end's speech around it (#365 (b)).
    private struct Match {
        /// Per remote label, the seconds the local segment overlaps the remote speech it repeats.
        var overlapSeconds: [String: Double]
        /// Where the remote line it copies starts, for who is late (#252): only for a near-identical pair (the
        /// best remote line's word overlap is above the text threshold, as the issue's 80 timed pairs were).
        /// nil for an excerpt matched by containment or a line matched against several remote lines joined:
        /// their starts are where the recognisers cut the lines, not who spoke first.
        var remoteStart: Double?
        /// Remote speech that overlaps the local line in time (any remote segment, flagged ones included).
        var core: [LabeledSegment]
        /// Remote lines that ended within the whole echo delay before the local line starts
        /// (`maximumEchoDelaySeconds` + `echoTimingToleranceSeconds`): an echo line can carry their tail.
        var lead: [LabeledSegment]
        /// Remote lines that start within `echoTimingToleranceSeconds` after the local line ends: an echo line
        /// can carry their first word or two, where the recognisers placed the boundary differently.
        var trail: [LabeledSegment]
    }

    /// #365 (b): whether `local` can be an echo copy of the far end's speech around it, by length and timing.
    ///
    /// The far end's speech the line can hold is everything that overlaps it, plus the words it actually
    /// shares with the line's edges: its first words found in the remote lines just before, its last words
    /// found in the remote lines just after. A neighbouring line's other words are not counted: they were
    /// never in the mic's line, and a repetition that adds a word ("No, …") must not pass for a copy because
    /// the far end happened to speak right before or after it.
    ///
    /// Both readings of the words are tried (plain and normalised) and the one that fits better decides.
    private static func canBeEchoCopy(_ local: LabeledSegment, of match: Match) -> Bool {
        struct Fit { let excess: Int; let carried: Bool }
        let fits = readings.map { read -> Fit in
            let words = read(local.text)
            let core = match.core.reduce(0) { $0 + read($1.text).count }
            let leadWords = Set(match.lead.flatMap { read($0.text) })
            let trailWords = Set(match.trail.flatMap { read($0.text) })
            let lead = words.prefix { leadWords.contains($0) }.count
            let trail = min(Array(words.reversed()).prefix { trailWords.contains($0) }.count, words.count - lead)
            return Fit(excess: words.count - (core + lead + trail), carried: lead + trail > 0)
        }
        guard let fit = fits.min(by: { $0.excess < $1.excess }) else { return false }
        // A repetition adds words; an echo copy holds no more than the far end said there (a recogniser drops
        // words more often than it adds them).
        guard fit.excess <= 0 else { return false }
        // A line that starts with the tail of an earlier remote line is placed by that line, not by the core.
        if fit.carried { return true }
        let coreStart = match.core.map(\.start).min() ?? local.start
        // An echo never precedes its source.
        guard local.start >= coreStart - echoTimingToleranceSeconds else { return false }
        // A copy of everything the far end said there starts within the echo delay of it; a repetition only
        // once it has been said. A shorter copy can start anywhere inside it.
        if fit.excess == 0 {
            return local.start <= coreStart + maximumEchoDelaySeconds + echoTimingToleranceSeconds
        }
        return true
    }

    /// Whether `local` repeats concurrent remote speech, from whichever remote speaker: nil when it
    /// does not, else what it repeats.
    private static func matchedRemote(
        local: LabeledSegment,
        remoteSegments: [LabeledSegment],
        allRemote: [LabeledSegment],
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
        var matched: (overlap: [String: Double], remoteStart: Double?)?
        if let best {
            let nearIdentical = textSimilarity(local.text, best.remote.text) > textThreshold
            matched = ([best.remote.speaker: overlapSeconds(best.remote)], nearIdentical ? best.remote.start : nil)
        } else if overlapping.count > 1 {
            let window = overlapping.sorted { $0.start < $1.start }
            if textSimilarity(local.text, window.map(\.text).joined(separator: " ")) > textThreshold {
                var result: [String: Double] = [:]
                for remote in window { result[remote.speaker, default: 0] += overlapSeconds(remote) }
                matched = (result, nil)
            }
        }
        guard let matched else { return nil }
        let reach = maximumEchoDelaySeconds + echoTimingToleranceSeconds
        return Match(
            overlapSeconds: matched.overlap,
            remoteStart: matched.remoteStart,
            core: allRemote.filter { $0.end > local.start && $0.start < local.end },
            lead: allRemote.filter { $0.end <= local.start && $0.end >= local.start - reach },
            trail: allRemote.filter { $0.start >= local.end && $0.start <= local.end + echoTimingToleranceSeconds })
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
