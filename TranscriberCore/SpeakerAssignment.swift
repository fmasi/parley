import Foundation
import os

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
    /// The raw diarizer speaker ID that word-level evidence (`dominantDiarSpeaker`, run per-word by
    /// `splitAcrossSpeakerBoundaries`) already determined for this segment/piece — set for every
    /// segment that carried usable `words`, whether or not it ended up split. `nil` only when no
    /// word-level evidence was available (no `words`, or too few to evaluate).
    ///
    /// `assign()` trusts this directly instead of re-deriving a speaker from raw geometric time-
    /// overlap, which can silently disagree with word-level evidence: a diarization turn with ZERO
    /// covering words (a breath, room noise, an untranscribed cross-talk speaker) could otherwise
    /// win an unsplit segment's label purely by having more wall-clock duration than the turns real
    /// words were actually assigned to, and a split piece born from `dominantDiarSpeaker`'s gap-
    /// fallback (words glued to the nearest turn across silence) could otherwise fail to
    /// geometrically overlap ANY diarization turn at all and collapse to "Unknown" — discarding the
    /// very ownership decision that justified splitting it out in the first place. (Independent
    /// code-council review, confirmed 3/3 across both findings.)
    public let dominantSpeaker: String?

    public init(start: Double, end: Double, text: String, language: String?, confidence: Float? = nil, words: [WordTiming]? = nil, dominantSpeaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.confidence = confidence
        self.words = words
        self.dominantSpeaker = dominantSpeaker
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
                //
                // Last-wins-among-ties, intentionally: a LATER candidate satisfying this branch always
                // overwrites an earlier strict winner. That's correct GIVEN this tiebreaker's own
                // purpose — prefer whichever turn contains the midpoint over one that merely tied on
                // raw overlap — so if a later candidate genuinely satisfies "contains the midpoint"
                // where the earlier winner didn't, it SHOULD replace it. Safe for FluidAudioDiarizer's
                // genuinely non-overlapping turns EXCEPT at an exact boundary coincidence: two ADJACENT
                // turns sharing an edge (`sp0.end == sp1.start`) both satisfy the inclusive
                // `sp.start <= mid <= sp.end` check when a word's midpoint lands exactly on that shared
                // point, so which one wins depends on the diarizer's array ordering, not audio content
                // — a floating-point coincidence, negligible in practice, not a content-dependent bug.
                // A diarizer producing genuinely OVERLAPPING segments could make this order-dependent
                // among real multi-candidate ties too. Don't "fix" the last-wins behavior itself without
                // first checking whether these assumptions still hold.
                best = sp.speaker
            }
        }
        if best != nil { return best }
        // Word lies fully inside a gap between turns: glue it to the nearest turn by edge distance
        // rather than opening a phantom boundary on silence. Same adjacent-boundary-coincidence
        // ordering dependency as the tiebreaker above (~line 104): a word touching two turns that
        // share an exact edge (e.g. sp0.end == sp1.start == wordEnd) gives both dist == 0, and the
        // strict `<` below keeps whichever candidate comes first in `diar`'s array order.
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

    /// Decide whether a SpeechAnalyzer result segment's per-run timing can safely support boundary
    /// splitting (issue #120). Pure logic with no Speech-framework dependency, extracted from the
    /// live `SpeechTranscriber` result loop specifically so it's unit-testable — `SpeechAnalyzerEngine`
    /// itself requires macOS 26 / Swift 6.2+ and is compiled out entirely on CI's Swift 6.0 runner, so
    /// logic that stayed inline there would be untestable there too; this function has no such
    /// constraint and lives here instead.
    ///
    /// Three outcomes: every run timed AND concatenating their text reconstructs the segment's own
    /// text exactly → `words` populated, splitting enabled. Any run lacking timing → `nil` (can't
    /// represent the segment's full text in word form without it). Every run timed but concatenation
    /// does NOT match the segment's text → `nil` (SpeechAnalyzer's run/space boundaries are an
    /// Apple-internal detail; a space could be silently lost or attached inconsistently at a run
    /// boundary) — disable splitting rather than risk reconstructing garbled text.
    static func speechAnalyzerWordTimings(
        runs: [(text: String, start: Double?, end: Double?)],
        trimmedSegmentText: String
    ) -> [WordTiming]? {
        var words: [WordTiming] = []
        var allRunsTimed = true
        for run in runs {
            if let s = run.start, let e = run.end {
                words.append(WordTiming(start: s, end: e, text: run.text))
            } else {
                // Bail immediately: the guard below discards `words` entirely once any run lacks
                // timing, so there's no point building WordTiming entries for runs after this one.
                allRunsTimed = false
                break
            }
        }
        guard allRunsTimed, !words.isEmpty else { return nil }
        let reconstructed = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return reconstructed == trimmedSegmentText ? words : nil
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
    /// covering diarized speaker changes. Each resulting piece is single-speaker BY CONSTRUCTION.
    ///
    /// This DOES also make a labeling decision now — `TranscriptSegment.dominantSpeaker` — set to the
    /// raw diarizer id every kept word in a piece agreed on via `dominantDiarSpeaker` (whole-segment
    /// or per-piece). Originally this was "a pure normalizer of assign()'s input, not a second
    /// labeller," relying on the existing overlap/VAD/quality logic in `assign()` to re-derive the
    /// speaker correctly from each single-speaker piece's own time range. That assumption broke on
    /// three counts an independent code-council review found (all 3/3 confirmed): a diarization turn
    /// with ZERO covering words could still out-vote real word evidence on raw duration for an unsplit
    /// segment; a piece born from `dominantDiarSpeaker`'s gap-fallback (words glued across a silence
    /// gap to the nearest turn) might not geometrically overlap ANY diarization turn at all and
    /// collapse to "Unknown" in `assign()`'s plain-overlap loop; and a standalone punctuation token
    /// (FluidAudio emits `.!?` as its own `TokenTiming`) could be carved into its own phantom piece.
    /// `dominantSpeaker` closes the first two by giving `assign()` a word-evidenced answer to trust
    /// directly instead of re-deriving one geometrically; the punctuation case is closed separately,
    /// in the grouping loop below, by never letting a punctuation-only token start a new piece.
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
    /// with byte-identical text (zero text-behaviour change for the common case, and FluidAudio's ITN
    /// text on those segments is preserved verbatim — only the rare split pieces are rebuilt from raw
    /// tokens) — only `dominantSpeaker` is newly attached where it wasn't present before.
    static func splitAcrossSpeakerBoundaries(
        _ segments: [TranscriptSegment],
        diarizationSegments diar: [DiarizedSegment]
    ) -> [TranscriptSegment] {
        // Enforcement of the "raw engine output only" contract documented on the emitted.isEmpty
        // fallback below: this function must never be called on its own prior output (or any other
        // already-split segments), since that fallback's correctness relies on dominantSpeaker being
        // nil on entry. A plain `assert` here would be silently stripped in release builds — a
        // violation would then silently propagate a stale, wrong dominantSpeaker into production
        // output with no diagnostic. Instead: crash in debug (assertionFailure), log in release
        // (release-visible, unlike assert), and fail safe either way by returning the input unchanged
        // rather than proceeding on a violated invariant. Both current call sites satisfy this.
        if !segments.allSatisfy({ $0.dominantSpeaker == nil }) {
            Logger.transcription.error("splitAcrossSpeakerBoundaries received already-split segments — contact the maintainer")
            assertionFailure("splitAcrossSpeakerBoundaries must receive raw engine output; do not pass previously-split segments")
            return segments
        }
        guard !diar.isEmpty else { return segments }

        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)

        for seg in segments {
            // `words.count >= 2` also correctly passes through a non-nil-but-EMPTY array (0 >= 2 is
            // false) the same as nil — matters only if a future third engine ever populates `words`
            // with zero entries; neither current engine does (FluidAudio always appends >=1 word
            // before a segment boundary fires; SpeechAnalyzer forces nil on empty, see its round-trip
            // check).
            guard var words = seg.words, words.count >= 2 else {
                out.append(seg)
                continue
            }
            // The grouping below assumes `words` is chronologically ordered — both current engines
            // guarantee this (FluidAudio tokens are assembled in ASR-decode order; SpeechAnalyzer
            // runs are emitted in utterance order from result.text.runs), but nothing in the type
            // enforces it. If it were ever violated, a piece's `first`/`last` word could invert
            // (first.start > last.end), producing a TranscriptSegment with start > end that — for any
            // piece that ISN'T the first/last — wouldn't even get caught by the seg.start/seg.end
            // anchoring, and would propagate a nonsensical time range into assign(). Cheap enough
            // (typically tens of entries per segment) to just guarantee the invariant here.
            words.sort { $0.start < $1.start }

            // Group consecutive words by their covering diarized speaker; a change marks a cut.
            // Standalone punctuation-only tokens (e.g. a trailing "?" FluidAudio emits as its own
            // token — see groupTokensQuestionMark) never START a new group when they trail an
            // existing piece, regardless of which diarized turn their own brief timing happens to
            // touch: they're glued to whichever piece they trail. Without this, a boundary landing
            // between a word and its own punctuation could carve the punctuation into its own phantom
            // one-character "utterance" and misattribute it to the wrong speaker (independent
            // code-council review finding). EXCEPTION: if a punctuation-only token is the very FIRST
            // word (`pieces.isEmpty`), there's no preceding piece to glue it to, so it falls through
            // to the normal grouping path below and can open its own group like any other word —
            // neither current engine emits punctuation as a segment's first token, so this is
            // unreachable in practice, but it's a real difference from "never starts a new group",
            // not just an edge case of the same rule. `isSymbol` (not just `isLetter`/`isNumber`) is
            // required to correctly treat emoji as real content rather than punctuation — Swift's
            // isLetter/isNumber are both false for emoji, which would otherwise misclassify e.g. "👍"
            // as punctuation-only and silently glue it to the preceding piece.
            var pieces: [(speaker: String?, words: [WordTiming])] = []
            for w in words {
                let trimmedWord = w.text.trimmingCharacters(in: .whitespaces)
                let isPunctuationOnly = !trimmedWord.isEmpty
                    && !trimmedWord.contains { $0.isLetter || $0.isNumber || $0.isSymbol }
                // Both punctuation-only AND empty/whitespace-only tokens glue to the current piece
                // rather than opening a new one — but ONLY when there IS a current piece to glue to
                // (`!pieces.isEmpty` guards the WHOLE condition, not just the punctuation half — an
                // empty-first-token variant of this check that let `trimmedWord.isEmpty` alone bypass
                // that guard would index `pieces[pieces.count - 1]` with `pieces.count == 0`, an
                // out-of-bounds crash). Without gluing an empty token, it would fall to the normal path
                // below, call dominantDiarSpeaker, and — if that differs from the current piece's
                // speaker — open a phantom group boundary that severs what should be one continuous
                // piece (the empty group itself gets filtered at emission, but by then the next real
                // word is already artificially split off). Neither current engine emits empty-text
                // tokens, so this is unreachable today — same defensive-guard reasoning as
                // `words.count >= 2` above and the `emitted.isEmpty` fallback below.
                if (isPunctuationOnly || trimmedWord.isEmpty), !pieces.isEmpty {
                    pieces[pieces.count - 1].words.append(w)
                    continue
                }
                let spk = dominantDiarSpeaker(wordStart: w.start, wordEnd: w.end, in: diar)
                if pieces.isEmpty || spk != pieces[pieces.count - 1].speaker {
                    pieces.append((speaker: spk, words: [w]))
                } else {
                    pieces[pieces.count - 1].words.append(w)
                }
            }

            // One covering speaker across the whole segment: emit unchanged so the engine's own text
            // (incl. FluidAudio ITN) is preserved exactly — no reconstruction, no regression — but
            // carry the word-derived speaker forward on `dominantSpeaker` so assign() can trust it
            // instead of re-deriving one from raw geometric overlap (see TranscriptSegment.dominantSpeaker).
            // `words: words` (the already-sorted local copy, not `seg.words`) keeps this passthrough
            // path consistent with split middle pieces, which also get sorted words — costs nothing
            // since `words` is already in scope. (First/last split pieces still get `words: nil`, per
            // the anchoring fixup's NOTE below — that inconsistency is a real anchoring side effect,
            // not just a missed sort.)
            guard pieces.count > 1 else {
                out.append(TranscriptSegment(
                    start: seg.start, end: seg.end, text: seg.text,
                    language: seg.language, confidence: seg.confidence, words: words,
                    dominantSpeaker: pieces.first?.speaker
                ))
                continue
            }

            Logger.transcription.debug(
                "Boundary split: segment [\(seg.start, privacy: .public)–\(seg.end, privacy: .public)] spans \(pieces.count, privacy: .public) diarized turns — re-splitting at word boundaries"
            )

            // Build all emitted pieces first (raw first/last-word timing), THEN anchor the first/last
            // ONE ACTUALLY EMITTED to the original segment's own outer bounds — not the first/last
            // ENTRY OF `pieces`. `pieces[0]`/`pieces.last` could in principle be skipped below (empty
            // text after trim) while a middle entry survives; anchoring by position-in-`pieces` would
            // then silently leave THAT entry un-anchored, opening an unaccounted gap versus this
            // segment's neighbor. Indexing on the emitted array instead makes the anchor land on
            // whichever piece is actually first/last in the OUTPUT, regardless of any skip. Currently
            // unreachable (neither engine emits empty-text tokens), but the same latent-hole shape as
            // the anchoring itself, so it gets the same defensive treatment.
            var emitted: [TranscriptSegment] = []
            for piece in pieces {
                guard let first = piece.words.first, let last = piece.words.last else { continue }
                let text = piece.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                emitted.append(TranscriptSegment(
                    start: first.start,
                    end: last.end,
                    text: text,
                    language: seg.language,
                    confidence: seg.confidence,
                    words: piece.words,
                    dominantSpeaker: piece.speaker
                ))
            }
            if let firstIdx = emitted.indices.first, let lastIdx = emitted.indices.last {
                // Anchoring can move `start`/`end` away from `words.first.start`/`words.last.end` (the
                // whole point — see the anchoring rationale above). That means `words` would then
                // describe a narrower span than the piece itself claims: an invisible trap if any
                // future code ever assumed `piece.words` is bounded by `piece.start`/`piece.end` (a
                // waveform visualizer, an audio-highlight feature, ...). `words` is otherwise a
                // transient, single-pass input to THIS function — `LabeledSegment` (assign()'s output)
                // doesn't carry it forward — so nil it out on exactly the piece(s) whose bound moved,
                // rather than let the array quietly disagree with the segment it's attached to.
                // `dominantSpeaker` is untouched by anchoring — the speaker decision it carries stays
                // correct regardless of where the piece's playback boundary ends up.
                // NOTE for future maintainers: if LabeledSegment or ProcessedChunk.Segment ever gains a
                // word-timing field (audio-highlight, per-word confidence, ...), this nil-ing becomes a
                // silent data loss on exactly the anchored pieces — revisit this decision at that point
                // rather than assuming it's still safe just because it compiles.
                let f = emitted[firstIdx]
                emitted[firstIdx] = TranscriptSegment(
                    start: seg.start, end: f.end, text: f.text,
                    language: f.language, confidence: f.confidence, words: nil,
                    dominantSpeaker: f.dominantSpeaker
                )
                // Re-read AFTER the first-index fixup: when only one piece was emitted (firstIdx ==
                // lastIdx), this must carry the just-applied seg.start forward, not the original.
                let l = emitted[lastIdx]
                emitted[lastIdx] = TranscriptSegment(
                    start: l.start, end: seg.end, text: l.text,
                    language: l.language, confidence: l.confidence, words: nil,
                    dominantSpeaker: l.dominantSpeaker
                )
            }
            // If EVERY piece trimmed to empty text, `emitted` is empty here — appending it would
            // silently drop this segment from the transcript entirely (no text, no audio-playback
            // range, no log line), which is strictly worse than the misattribution this whole fix
            // exists to prevent. Unreachable today for two independent reasons: neither engine emits
            // empty-text tokens, AND even with synthetic all-whitespace input the grouping loop's
            // glue rule (line 278) can produce at most ONE all-empty piece — every piece after the
            // first is opened by a non-glued (i.e. real-content) word, so it can never be all-empty
            // itself. Still, fall back to the original, unsplit `seg` rather than nothing — the same
            // fallback the nil/short-words guard above already uses. `seg` here carries no
            // dominantSpeaker (multiple pieces existed with potentially DIFFERENT speakers and all
            // were discarded — there's no single evidenced owner left to propagate), so assign()
            // correctly falls back to its own raw-overlap heuristic for this already-degenerate,
            // currently-unreachable case. This guarantee relies on `seg.dominantSpeaker` being nil on
            // entry — true for both current call sites (raw engine output, never previously split) —
            // so callers must not pass segments that have already been through this function.
            out.append(contentsOf: emitted.isEmpty ? [seg] : emitted)
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
            let bestSpeaker: String
            if let dominant = seg.dominantSpeaker {
                // Word-level evidence already determined this segment's speaker (via
                // dominantDiarSpeaker, run per-word during splitting, including its gap-fallback) —
                // trust it directly instead of re-deriving one from raw geometric overlap below,
                // which can silently disagree with real word evidence. See
                // TranscriptSegment.dominantSpeaker's doc comment for the full rationale
                // (independent code-council review, confirmed 3/3).
                bestSpeaker = speakerMap[dominant] ?? dominant
            } else {
                // No word-level evidence available for this segment (no `words`, or too few) — fall
                // back to the original raw time-overlap heuristic.
                let segMid = (seg.start + seg.end) / 2
                var overlapSpeaker = "Unknown"
                var bestOverlap: Double = 0

                for sp in diarizationSegments {
                    let overlapStart = max(seg.start, sp.start)
                    let overlapEnd = min(seg.end, sp.end)
                    let overlap = max(0, overlapEnd - overlapStart)

                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        overlapSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    }

                    // Midpoint tiebreaker: on equal overlap, prefer the segment containing the midpoint.
                    // Unlike dominantDiarSpeaker's tiebreaker, this one intentionally has no `overlap > 0`
                    // guard: engines call SpeakerAssignment.deduplicate() before assign() ever runs, which
                    // filters zero-duration segments, and splitAcrossSpeakerBoundaries' first/last pieces
                    // are anchored to the original (already-deduplicated) segment's own bounds. A zero-
                    // duration MIDDLE piece is only reachable from a zero-duration WORD — timing neither
                    // real engine's output ever produces — so this is pre-existing, deliberately
                    // unguarded, and tracked (not forgotten) in #122. Also, unlike dominantDiarSpeaker,
                    // this is still a plain `if` (not `else if`) — also tracked in #122 — so among genuine
                    // ties it exhibits the same intentional last-wins-among-ties behavior documented in
                    // dominantDiarSpeaker's tiebreaker comment (including the exact-boundary-coincidence
                    // caveat); see that comment for the full reasoning rather than repeating it here.
                    if sp.start <= segMid && segMid <= sp.end && overlap == bestOverlap {
                        overlapSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    }
                }
                bestSpeaker = overlapSpeaker
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
            var overlapSpeaker = "Unknown"
            var bestOverlap: Double = 0
            var bestQuality: Float? = nil

            // TODO(perf): when seg.dominantSpeaker is set (the common case post-#120 fix), this whole
            // O(diarizationSegments) loop's overlapSpeaker result is discarded below in favor of word
            // evidence, and bestQuality gets re-derived separately using only overlap > 0 turns — only
            // that re-derivation is actually needed in that case. Not worth restructuring for
            // correctness (this is negligible in post-processing), but worth short-circuiting if
            // recording length or diarizer resolution ever makes this loop show up in profiling. Not a
            // trivial one-liner though: the bestQuality re-derivation would need to be hoisted out of
            // the `if let dominant` block and run independently of overlapSpeaker — a naive "just skip
            // the loop when dominantSpeaker is set" refactor would drop quality-gate filtering entirely
            // for evidenced speakers.
            for sp in diarizationSegments {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd = min(seg.end, sp.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    overlapSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }

                // Midpoint tiebreaker: on equal overlap, prefer the segment containing the midpoint.
                // Same overlap>0-guard omission and if-vs-else-if difference as the basic assign()
                // overload above (~line 423) — see that comment for the full reasoning (tracked in
                // #122) rather than repeating it here.
                if sp.start <= segMid && segMid <= sp.end && overlap == bestOverlap {
                    overlapSpeaker = speakerMap[sp.speaker] ?? sp.speaker
                    bestQuality = sp.qualityScore
                }
            }

            // Word-level evidence overrides the geometrically-derived speaker when present — see the
            // basic assign() overload and TranscriptSegment.dominantSpeaker's doc comment for the full
            // rationale (independent code-council review, confirmed 3/3).
            // bestSpeaker commits to word-evidenced speaker here; bestQuality is still the overlap
            // loop's value at this point and is re-derived below to match (see the `if let dominant`
            // block immediately following).
            let bestSpeaker = seg.dominantSpeaker.map { speakerMap[$0] ?? $0 } ?? overlapSpeaker
            if let dominant = seg.dominantSpeaker {
                // `bestQuality` from the loop above is the quality of whichever turn geometrically
                // overlaps THIS SEGMENT most — which, now that bestSpeaker can come from word
                // evidence instead, may belong to a DIFFERENT, non-evidenced speaker (exactly finding
                // 1's wordless-turn scenario: a turn with no covering words but heavy overlap). Using
                // that mismatched turn's quality score to gate the evidenced speaker would let a low-
                // confidence turn nobody transcribed force a real, word-evidenced attribution to
                // "Unknown" — reintroducing a variant of the same bug through the quality gate instead
                // of the speaker choice. Re-derive quality from whichever turn actually matches the
                // evidenced raw speaker id (by overlap with this segment among that speaker's turns);
                // if none overlaps at all (a gap-fallback-derived piece may not literally overlap its
                // own evidenced turn), leave it nil — `?? 1.0` below then trusts the diarizer, the
                // existing safe default, rather than borrowing an unrelated turn's confidence.
                // The `overlap > 0` filter is load-bearing, not decorative: `max(by:)` on a non-empty
                // collection ALWAYS returns a value, even when every candidate ties at overlap == 0
                // (the comparator `oa < ob` is false for a 0/0 tie, so the first element survives).
                // Without it, a gap-fallback piece whose evidenced speaker's OTHER turns all happen to
                // have low quality would silently inherit one of THEIR scores despite none of them
                // actually overlapping this piece — forcing a correct attribution to "Unknown" through
                // the quality gate rather than the speaker choice (caught in review — this exact
                // omission was present in an earlier version of this fix).
                let overlapWithSeg: (DiarizedSegment) -> Double = {
                    max(0, min(seg.end, $0.end) - max(seg.start, $0.start))
                }
                bestQuality = diarizationSegments
                    .filter { $0.speaker == dominant }
                    .filter { overlapWithSeg($0) > 0 }
                    .max { overlapWithSeg($0) < overlapWithSeg($1) }?.qualityScore
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
