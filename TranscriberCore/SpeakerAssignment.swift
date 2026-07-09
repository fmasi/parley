import Foundation
import os

/// Timing for one ASR unit inside a segment — a FluidAudio token (sub-word) or a
/// SpeechAnalyzer run. Engine-neutral (no SDK types) so both engines can populate it and the
/// shared assignment layer can re-split segments at true speaker-change boundaries (issue #120).
/// `text` is expected to carry the unit's own leading spacing verbatim, so a piece's text
/// reconstructs by plain concatenation + trim — confirmed true for FluidAudio tokens (verified in
/// `groupTokensAttachesWordTimings`); NOT independently verifiable for SpeechAnalyzer's runs, whose
/// space-ownership is an Apple-internal detail — `SpeechAnalyzerEngine` explicitly round-trip-checks
/// this per segment before ever populating `words`, and disables splitting (falls to `nil`) if the
/// assumption doesn't hold for that segment.
public struct WordTiming: Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let language: String?
    public let confidence: Float?
    /// Per-unit timing (tokens/runs) that produced this segment, when the engine supplies it.
    /// Kept alive past ASR grouping so the assignment layer can split a segment that straddles a
    /// diarization speaker boundary (issue #120). `nil` for engines/paths without word timing —
    /// those segments pass through the boundary split untouched.
    public let words: [WordTiming]?

    public init(start: Double, end: Double, text: String, language: String?, confidence: Float? = nil, words: [WordTiming]? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.confidence = confidence
        self.words = words
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

    /// The diarized speaker (raw diarizer ID) that owns a word's time span: greatest time-overlap,
    /// with a midpoint tiebreaker (mirrors `assign()`), and a nearest-turn fallback when the word
    /// lands in a diarization gap so every word gets a definite owner and silence never forces a
    /// spurious cut. Returns `nil` only when there are no diarization segments at all.
    static func dominantDiarSpeaker(
        wordStart: Double, wordEnd: Double, in diar: [DiarizedSegment]
    ) -> String? {
        let mid = (wordStart + wordEnd) / 2
        var best: String? = nil
        var bestOverlap: Double = 0
        for sp in diar {
            let overlap = max(0, min(wordEnd, sp.end) - max(wordStart, sp.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = sp.speaker
            } else if overlap > 0 && sp.start <= mid && mid <= sp.end && overlap == bestOverlap {
                // Midpoint tiebreaker: on equal overlap, prefer the turn containing the word midpoint.
                // `else if` so this only ever evaluates for a candidate that did NOT just win via
                // strict overlap above — otherwise `overlap == bestOverlap` is trivially true for the
                // very candidate that just set it, redundantly (if harmlessly) re-writing `best` to
                // the same value. `overlap > 0` guards the initial bestOverlap==0 sentinel: without
                // it, a genuinely non-overlapping turn whose span happens to touch the midpoint would
                // match `0 == 0` on the first candidate, pre-empting the nil-fallback (nearest-turn)
                // path below for a candidate that never actually overlapped the word.
                best = sp.speaker
            }
        }
        if best != nil { return best }
        // Word lies fully inside a gap between turns: glue it to the nearest turn by edge distance
        // rather than opening a phantom boundary on silence.
        var nearest: String? = nil
        var nearestDist = Double.greatestFiniteMagnitude
        for sp in diar {
            let dist = wordStart > sp.end ? wordStart - sp.end
                     : (sp.start > wordEnd ? sp.start - wordEnd : 0)
            if dist < nearestDist {
                nearestDist = dist
                nearest = sp.speaker
            }
        }
        return nearest
    }

    /// Re-split any transcript segment whose words straddle a diarization speaker-change boundary.
    ///
    /// ARCHITECTURE (issue #120): ASR segmentation is diarization-unaware. FluidAudio splits on
    /// sentence punctuation (`.!?`); SpeechAnalyzer splits on utterance/pause `isFinal` marks.
    /// Either can emit one segment whose words cross a real speaker turn — classically one speaker's
    /// short question immediately followed, with a zero-second gap, by the other's long answer. The
    /// downstream time-overlap `assign()` then hands that WHOLE block (text AND its audio-playback
    /// span) to the majority speaker, silently absorbing the other speaker's words into the wrong
    /// person. For a courtroom-grade transcript that is close to worst-case.
    ///
    /// The fix restores the per-unit timing both engines already compute but used to discard
    /// (`TranscriptSegment.words`) and cuts a multi-speaker segment at the word boundaries where the
    /// covering diarized speaker changes. Each resulting piece is single-speaker BY CONSTRUCTION, so
    /// the existing overlap/VAD/quality logic that follows labels it correctly with no further change
    /// — this function is a pure normalizer of `assign()`'s input, not a second labeller.
    ///
    /// It lives at the shared assignment layer (not per-engine) because this is the one place where
    /// BOTH the transcript words and the diarization turns are in hand, so a single code path fixes
    /// both engines. (Design option A. Option B — diarization-first re-chunking, running ASR per turn
    /// so segments are single-speaker by construction — was rejected: it multiplies ASR latency,
    /// destroys cross-turn decoder context for short backchannels, and buys no attribution accuracy
    /// over word-level splitting. Option C — splitting only the time range when word text is absent —
    /// is the built-in fallback: a segment with `nil`/empty `words` simply passes through unchanged.)
    ///
    /// Segments that fall entirely within one speaker, or that carry no word timing, pass through
    /// byte-identical — zero behaviour change for the common case, and FluidAudio's ITN text on those
    /// segments is preserved verbatim (only the rare split pieces are rebuilt from raw tokens).
    public static func splitAcrossSpeakerBoundaries(
        _ segments: [TranscriptSegment],
        diarizationSegments diar: [DiarizedSegment]
    ) -> [TranscriptSegment] {
        guard !diar.isEmpty else { return segments }

        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)

        for seg in segments {
            // `words.count >= 2` also correctly passes through a non-nil-but-EMPTY array (0 >= 2 is
            // false) the same as nil — matters only if a future third engine ever populates `words`
            // with zero entries; neither current engine does (FluidAudio always appends >=1 word
            // before a segment boundary fires; SpeechAnalyzer forces nil on empty, see its round-trip
            // check).
            guard let words = seg.words, words.count >= 2 else {
                out.append(seg)
                continue
            }

            // Group consecutive words by their covering diarized speaker; a change marks a cut.
            var pieces: [[WordTiming]] = []
            var currentSpeaker: String? = nil
            for w in words {
                let spk = dominantDiarSpeaker(wordStart: w.start, wordEnd: w.end, in: diar)
                if pieces.isEmpty || spk != currentSpeaker {
                    pieces.append([w])
                    currentSpeaker = spk
                } else {
                    pieces[pieces.count - 1].append(w)
                }
            }

            // One covering speaker across the whole segment: emit unchanged so the engine's own
            // text (incl. FluidAudio ITN) is preserved exactly — no reconstruction, no regression.
            guard pieces.count > 1 else {
                out.append(seg)
                continue
            }

            Logger.transcription.debug(
                "Boundary split: segment [\(seg.start, privacy: .public)–\(seg.end, privacy: .public)] spans \(pieces.count, privacy: .public) diarized turns — re-splitting at word boundaries"
            )

            for piece in pieces {
                guard let first = piece.first, let last = piece.last else { continue }
                let text = piece.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    start: first.start,
                    end: last.end,
                    text: text,
                    language: seg.language,
                    confidence: seg.confidence,
                    words: piece
                ))
            }
        }

        return out
    }

    /// Assign speaker labels to transcript segments based on time overlap with diarization.
    public static func assign(
        transcriptSegments: [TranscriptSegment],
        diarizationSegments: [DiarizedSegment]
    ) -> [LabeledSegment] {
        // Normalize input so no segment straddles a speaker boundary (issue #120), then label.
        let transcriptSegments = splitAcrossSpeakerBoundaries(
            transcriptSegments, diarizationSegments: diarizationSegments
        )
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
        // Normalize input so no segment straddles a speaker boundary (issue #120), then label.
        // Each resulting single-speaker piece runs through VAD/quality gating on its own.
        let transcriptSegments = splitAcrossSpeakerBoundaries(
            transcriptSegments, diarizationSegments: diarizationSegments
        )
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
                    "VAD filtered [\(seg.start, privacy: .public)–\(seg.end, privacy: .public)] \(bestSpeaker, privacy: .private): speechOverlap=\(speechOverlap, privacy: .public), quality=\(quality, privacy: .public)"
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

    /// In dual-stream, each source (local mic / remote system) is a known channel the diarizer
    /// clustered SEPARATELY. `sourceSpeakerCounts` is the DIARIZER's speaker-cluster count per source
    /// (`speakerDatabase.count`) — the authority on how many people are on that channel. When it found
    /// exactly ONE speaker, every segment on that channel is that speaker, including the ones a later
    /// VAD quality gate blanked to `Unknown` (telephony/quiet audio fails the quality threshold even
    /// when the diarizer was right). Collapse those `Unknown`s to the one speaker. A channel the
    /// diarizer split into 2+ speakers — a conference room, or a background TV it separated — is left
    /// UNTOUCHED: its `Unknown`s stay `Unknown`, since we can't safely attribute them (#71). This
    /// leans on the diarizer's clustering rather than guessing from surviving labels, so a quiet
    /// second speaker that the gate happened to blank entirely is NOT merged into the main speaker.
    /// Runs BEFORE `tagWithSourcePrefix`, on raw (unprefixed) labels.
    public static func resolveUnknownsWithinSource(
        _ segments: inout [LabeledSegment], sourceSpeakerCounts: [String: Int]
    ) {
        let indicesBySource = Dictionary(grouping: segments.indices, by: { segments[$0].source })
        for (source, indices) in indicesBySource {
            guard sourceSpeakerCounts[source] == 1 else { continue }
            // Collapse only toward a speaker the channel actually CONFIRMED on ≥1 segment — never
            // invent one. If the diarizer found 1 speaker but the VAD gate blanked EVERY segment,
            // leave them `Unknown` (honest: audio captured, nothing met the confidence bar) rather
            // than asserting a definite speaker no segment corroborated (#71 / courtroom-grade truth).
            guard let target = indices.map({ segments[$0].speaker })
                .first(where: { !$0.isEmpty && $0 != "Unknown" }) else { continue }
            var collapsed = 0
            for i in indices where segments[i].speaker.isEmpty || segments[i].speaker == "Unknown" {
                segments[i].speaker = target
                collapsed += 1
            }
            if collapsed > 0 {
                Logger.transcription.debug("Collapsed \(collapsed) Unknown \(source, privacy: .public) segments to \(target, privacy: .private) (diarizer found 1 speaker)")
            }
        }
    }

    public static func tagWithSourcePrefix(_ segments: inout [LabeledSegment]) {
        for i in segments.indices {
            let speaker = segments[i].speaker
            // Idempotency guard: skip if the prefix was already applied (prevents
            // "Local Local Speaker N" when finalize() and ChunkProcessor both call this). (#55)
            if speaker.hasPrefix("Local ") || speaker.hasPrefix("Remote ") {
                continue
            }
            let source = segments[i].source
            // Only genuine dual-stream sources get a side prefix (single-stream uses source "").
            guard source == "local" || source == "remote" else { continue }
            let label = source == "local" ? "Local" : "Remote"
            if !speaker.isEmpty && speaker != "Unknown" {
                segments[i].speaker = "\(label) \(speaker)"
            } else {
                // Unknown/empty on a known channel: still attribute the SIDE so the segment is
                // identifiable as `Local Unknown` / `Remote Unknown` rather than a bare `Unknown` (#71).
                segments[i].speaker = "\(label) Unknown"
            }
        }
    }
}
