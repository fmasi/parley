import Foundation
import os

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let language: String?
    public let confidence: Float?

    public init(start: Double, end: Double, text: String, language: String?, confidence: Float? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.confidence = confidence
    }
}

public struct LabeledSegment: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var source: String
    public var confidence: Float?
    public var language: String?

    public init(start: Double, end: Double, speaker: String, text: String, source: String, confidence: Float? = nil, language: String? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.source = source
        self.confidence = confidence
        self.language = language
    }
}

public enum SpeakerAssignment {

    /// Remove zero-duration and consecutively repeated segments.
    public static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var cleaned: [TranscriptSegment] = []
        var lastText: String?

        for seg in segments {
            if seg.start == seg.end { continue }
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            if trimmed == lastText { continue }
            lastText = trimmed
            cleaned.append(seg)
        }

        Logger.transcription.debug("Deduplicate: \(segments.count) → \(cleaned.count) segments")
        return cleaned
    }

    /// Default minimum turn duration (seconds) for diarization smoothing.
    public static let defaultMinTurnDuration: Double = 0.5

    /// Smooth a list of diarized turns before label assignment.
    ///
    /// The diarizer (FluidAudio) sometimes splits one speaker into several short
    /// turns, or emits spurious very-short turns. Left untouched, a speaker that
    /// only ever appears as a <`minTurnDuration` fragment becomes its own
    /// "Speaker N" box, inflating the speaker count.
    ///
    /// Two passes, run to a fixed point so cascades resolve:
    /// 1. Any turn shorter than `minTurnDuration` is collapsed into the
    ///    temporally-dominant adjacent turn — the longer of its immediate
    ///    previous/next neighbors (if only one neighbor exists, use it). The
    ///    short turn keeps its own timing but adopts the neighbor's speaker.
    /// 2. Adjacent turns that now share a speaker are merged into one turn so
    ///    timing stays clean.
    ///
    /// Turns are assumed to be in chronological order (as produced by the
    /// diarizer). A lone short turn with no neighbors is left unchanged.
    public static func smoothDiarization(
        _ turns: [DiarizedSegment],
        minTurnDuration: Double = defaultMinTurnDuration
    ) -> [DiarizedSegment] {
        guard turns.count > 1 else { return turns }

        var working = turns

        // Pass 1: reassign short turns to their dominant neighbor, repeating
        // until no reassignment happens (a fragment between two fragments may
        // need its neighbors resolved first).
        var changed = true
        while changed {
            changed = false
            for i in working.indices {
                let turn = working[i]
                let duration = turn.end - turn.start
                guard duration < minTurnDuration else { continue }

                let prev = i > 0 ? working[i - 1] : nil
                let next = i < working.count - 1 ? working[i + 1] : nil

                let dominantSpeaker: String?
                switch (prev, next) {
                case let (p?, n?):
                    let prevLen = p.end - p.start
                    let nextLen = n.end - n.start
                    dominantSpeaker = prevLen >= nextLen ? p.speaker : n.speaker
                case let (p?, nil):
                    dominantSpeaker = p.speaker
                case let (nil, n?):
                    dominantSpeaker = n.speaker
                case (nil, nil):
                    dominantSpeaker = nil  // lone turn — nothing to absorb into
                }

                if let dominantSpeaker, dominantSpeaker != turn.speaker {
                    working[i] = DiarizedSegment(
                        start: turn.start,
                        end: turn.end,
                        speaker: dominantSpeaker,
                        qualityScore: turn.qualityScore
                    )
                    changed = true
                }
            }
        }

        // Pass 2: merge adjacent same-speaker turns.
        var merged: [DiarizedSegment] = []
        for turn in working {
            if let last = merged.last, last.speaker == turn.speaker {
                merged[merged.count - 1] = DiarizedSegment(
                    start: last.start,
                    end: max(last.end, turn.end),
                    speaker: last.speaker,
                    // Keep the higher-confidence quality score of the merged pair.
                    qualityScore: maxQuality(last.qualityScore, turn.qualityScore)
                )
            } else {
                merged.append(turn)
            }
        }

        if merged.count != turns.count {
            Logger.transcription.debug(
                "Diarization smoothing: \(turns.count) → \(merged.count) turns (minTurnDuration=\(minTurnDuration, privacy: .public))"
            )
        }
        return merged
    }

    private static func maxQuality(_ a: Float?, _ b: Float?) -> Float? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    /// Assign speaker labels to transcript segments based on time overlap with diarization.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment]
    ) -> [LabeledSegment] {
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        let speakerMap = Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )

        Logger.transcription.debug("Speaker map: \(speakerMap.count) speakers — \(speakerMap, privacy: .public)")

        return transcriptSegments.map { seg in
            let segMid = (seg.start + seg.end) / 2
            var bestSpeaker = "Unknown"
            var bestOverlap: Double = 0

            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }

                // Midpoint tiebreaker: on equal overlap, prefer the segment containing the midpoint.
                if sp.start <= segMid && segMid <= sp.end && overlap == bestOverlap {
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                }
            }

            return LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: bestSpeaker,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                source: "",
                confidence: seg.confidence,
                language: seg.language
            )
        }
    }

    /// Assign speaker labels with VAD + qualityScore filtering.
    ///
    /// Decision matrix:
    /// - High speech + high quality → assign speaker
    /// - High speech + low quality → assign "Unknown"
    /// - Low speech + high quality → trust diarizer (assign speaker)
    /// - Low speech + low quality → filter from output
    ///
    /// When speechMap is nil, falls back to original behavior (no VAD filtering).
    /// When vadSpeechThreshold is 0.0, VAD filtering is disabled but qualityScore is still applied.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment],
        speechMap: [SpeechRegion]?,
        vadSpeechThreshold: Double = 0.5,
        qualityScoreThreshold: Float = 0.3
    ) -> [LabeledSegment] {
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        let speakerMap = Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )

        Logger.transcription.debug("Speaker map: \(speakerMap.count) speakers — \(speakerMap, privacy: .public)")

        var results: [LabeledSegment] = []

        for seg in transcriptSegments {
            let segMid = (seg.start + seg.end) / 2
            var bestSpeaker = "Unknown"
            var bestOverlap: Double = 0
            var bestQuality: Float? = nil

            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }

                // Midpoint tiebreaker: on equal overlap, prefer the segment containing the midpoint.
                if sp.start <= segMid && segMid <= sp.end && overlap == bestOverlap {
                    bestSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }
            }

            let speechOverlap: Double
            if let speechMap, vadSpeechThreshold > 0 {
                speechOverlap = SpeechRegion.speechOverlap(
                    regions: speechMap, start: seg.start, end: seg.end, threshold: 0.5
                )
            } else {
                speechOverlap = 1.0
            }

            // When speechMap is nil, bypass all filtering (original behavior).
            if speechMap == nil {
                results.append(LabeledSegment(
                    start: seg.start, end: seg.end, speaker: bestSpeaker,
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "", confidence: seg.confidence, language: seg.language
                ))
                continue
            }

            let hasHighSpeech = speechOverlap >= vadSpeechThreshold
            let quality = bestQuality ?? 1.0
            let hasHighQuality = quality >= qualityScoreThreshold

            let finalSpeaker: String
            let shouldInclude: Bool

            if hasHighSpeech && hasHighQuality {
                finalSpeaker = bestSpeaker
                shouldInclude = true
            } else if hasHighSpeech && !hasHighQuality {
                finalSpeaker = "Unknown"
                shouldInclude = true
            } else if !hasHighSpeech && hasHighQuality {
                finalSpeaker = bestSpeaker
                shouldInclude = true
            } else {
                finalSpeaker = bestSpeaker
                shouldInclude = false
                Logger.transcription.debug(
                    "VAD filtered [\(seg.start, privacy: .public)–\(seg.end, privacy: .public)] \(bestSpeaker, privacy: .public): speechOverlap=\(speechOverlap, privacy: .public), quality=\(quality, privacy: .public)"
                )
            }

            if shouldInclude {
                results.append(LabeledSegment(
                    start: seg.start, end: seg.end, speaker: finalSpeaker,
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "", confidence: seg.confidence, language: seg.language
                ))
            }
        }

        let filtered = transcriptSegments.count - results.count
        if filtered > 0 {
            Logger.transcription.info("VAD quality filter: \(filtered) segments filtered from \(transcriptSegments.count) total")
        }

        return results
    }

    /// Tag labeled segments with source prefix for dual-stream mode.
    /// Build the raw→friendly speaker name mapping from diarization segments.
    /// Same logic used internally by assign() — e.g. ["S2": "Speaker 1", "S3": "Speaker 2"].
    public static func buildSpeakerMap(from diarizationSegments: [DiarizedSegment]) -> [String: String] {
        var uniqueSpeakers: [String] = []
        for seg in diarizationSegments {
            if !uniqueSpeakers.contains(seg.speaker) {
                uniqueSpeakers.append(seg.speaker)
            }
        }
        return Dictionary(
            uniqueKeysWithValues: uniqueSpeakers.enumerated().map { (i, s) in
                (s, "Speaker \(i + 1)")
            }
        )
    }

    /// Remap speaker database keys using a speaker map (raw ID → friendly name).
    public static func remapDatabaseKeys(
        _ database: [String: [Float]],
        using speakerMap: [String: String]
    ) -> [String: [Float]] {
        Dictionary(uniqueKeysWithValues: database.map { (key, value) in
            (speakerMap[key] ?? key, value)
        })
    }

    public static func tagWithSourcePrefix(_ segments: inout [LabeledSegment]) {
        for i in segments.indices {
            let source = segments[i].source
            let label = source == "local" ? "Local" : "Remote"
            let speaker = segments[i].speaker
            // Idempotency guard: chunked recordings tag at chunk time (ChunkProcessor)
            // and again in TranscriptionRunner.finalize(); skip already-tagged segments
            // so repeated calls don't produce "Local Local Speaker N".
            if speaker == label || speaker.hasPrefix(label + " ") {
                continue
            }
            if !speaker.isEmpty && speaker != "Unknown" {
                segments[i].speaker = "\(label) \(speaker)"
            } else if speaker != "Unknown" {
                segments[i].speaker = label
            }
        }
    }
}
