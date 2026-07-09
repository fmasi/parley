import Testing
import Foundation
@testable import TranscriberCore

/// Tests for the diarization-boundary split fix (issue #120).
///
/// The bug: a single ASR transcript segment can straddle a real speaker-change boundary — classically
/// one speaker's short question immediately followed (zero-gap) by the other's long answer. The old
/// time-overlap assignment handed the whole block to the majority speaker, silently absorbing the
/// other speaker's words and audio-playback range into the wrong person. The fix re-splits such a
/// segment at the word boundaries where the covering diarized speaker changes, before labelling.
///
/// All fixtures are synthetic (generic Interviewer/Interviewee Q+A pairs), no real recording content.
struct SpeakerBoundarySplitTests {

    // Helper: a short interviewer question (words all before `boundary`) glued with zero gap to a
    // long interviewee answer (words after `boundary`) as ONE segment — the exact bug shape.
    private func spanningSegment(boundary: Double, end: Double) -> TranscriptSegment {
        let words = [
            WordTiming(start: boundary - 2.0, end: boundary - 1.4, text: "So"),
            WordTiming(start: boundary - 1.4, end: boundary - 0.7, text: " what"),
            WordTiming(start: boundary - 0.7, end: boundary, text: " happened?"),
            WordTiming(start: boundary + 0.2, end: boundary + 1.0, text: " Well,"),
            WordTiming(start: boundary + 1.0, end: (boundary + end) / 2, text: " it went on"),
            WordTiming(start: (boundary + end) / 2, end: end, text: " for quite a while"),
        ]
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return TranscriptSegment(
            start: boundary - 2.0, end: end, text: text, language: "en", words: words
        )
    }

    // MARK: - splitAcrossSpeakerBoundaries (pure)

    @Test func splitsSegmentSpanningTwoSpeakers() {
        // Interviewer owns [0, 26); interviewee owns [26, 72). One segment spans both.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 2)
        // First piece is the interviewer's question, cut at the boundary.
        #expect(pieces[0].start == 24.0)
        #expect(pieces[0].end == 26.0)
        #expect(pieces[0].text == "So what happened?")
        // Second piece is the interviewee's answer, starting after the boundary.
        #expect(pieces[1].start == 26.2)
        #expect(pieces[1].end == 72.0)
        #expect(pieces[1].text == "Well, it went on for quite a while")
        // Timings stay chronological and non-overlapping across the cut.
        #expect(pieces[0].end <= pieces[1].start)
    }

    @Test func wordStraddlingBoundaryIsNeverSplitMidWord() {
        // A word CAN'T be split mid-word — the function only groups/cuts between whole words. A word
        // whose own time range straddles the diarization boundary [25.5,26.5] with boundary at 26.0
        // ties on overlap (0.5s each side) and has its midpoint (26.0) exactly on the boundary,
        // hitting the documented last-wins-among-ties tiebreak (S1, the second diar entry, wins —
        // verified by hand-trace matching dominantDiarSpeaker's actual algorithm). The straddling word
        // goes whole to S1 along with the rest of the answer; it is never itself cut in two.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 25.5, end: 26.5, text: "question"),  // straddles the boundary
            WordTiming(start: 26.5, end: 72.0, text: " answer"),
        ]
        let seg = TranscriptSegment(start: 25.5, end: 72.0, text: "question answer", language: "en", words: words)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        // No split: both words resolve to S1 (the straddling word via the tiebreak), so one piece —
        // which is itself the proof the straddling word was never cut in two (Swift's array/struct
        // value semantics already guarantee splitAcrossSpeakerBoundaries can't mutate the input
        // `words` it was passed, so asserting against that local binding here would prove nothing).
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "question answer")
    }

    @Test func splitSortsOutOfOrderWordsBeforeGrouping() {
        // Neither current engine produces out-of-order word timing, but nothing in the type enforces
        // it. Passes the SAME words as splitsSegmentSpanningTwoSpeakers, deliberately shuffled in the
        // input array — the sort must restore chronological order before grouping, so the output is
        // identical to the correctly-ordered case (no inverted start > end pieces, correct text/cuts).
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 27.0, end: 72.0, text: " it went on for quite a while"),
            WordTiming(start: 24.0, end: 24.7, text: "So"),
            WordTiming(start: 26.2, end: 27.0, text: " Well,"),
            WordTiming(start: 25.4, end: 26.0, text: " happened?"),
            WordTiming(start: 24.7, end: 25.4, text: " what"),
        ]
        let seg = TranscriptSegment(
            start: 24.0, end: 72.0, text: "So what happened? Well, it went on for quite a while",
            language: "en", words: words
        )

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 2)
        #expect(pieces[0].start == 24.0)
        #expect(pieces[0].end == 26.0)
        #expect(pieces[0].text == "So what happened?")
        #expect(pieces[1].start == 26.2)
        #expect(pieces[1].end == 72.0)
        #expect(pieces[1].text == "Well, it went on for quite a while")
        #expect(pieces[0].end <= pieces[1].start)
    }

    @Test func splitAnchorsFirstAndLastPieceToOriginalSegmentBounds() {
        // Constructs a segment whose OWN start/end extend beyond its first/last word's timing —
        // simulating lead-in/lead-out silence a future engine change could introduce (today neither
        // engine actually produces this; seg.start/end are always derived from the first/last word,
        // see groupTokensIntoSegments and speechAnalyzerWordTimings' callers). The split must anchor
        // the first/last piece to the segment's OWN bounds, not narrow to the word timing, so no
        // playback time is silently dropped and no gap opens versus the segment's neighbors.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 24.0, end: 24.7, text: "So"),
            WordTiming(start: 24.7, end: 25.4, text: " what"),
            WordTiming(start: 25.4, end: 26.0, text: " happened?"),
            WordTiming(start: 26.2, end: 27.0, text: " Well,"),
            WordTiming(start: 27.0, end: 40.0, text: " it went on"),
        ]
        // seg's own bounds extend 0.5s earlier and 2s later than its first/last word.
        let seg = TranscriptSegment(
            start: 23.5, end: 42.0, text: "So what happened? Well, it went on", language: "en", words: words
        )

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 2)
        #expect(pieces[0].start == 23.5)   // anchored to seg.start, not words.first.start (24.0)
        #expect(pieces[0].end == 26.0)     // internal cut point, unaffected by the anchoring
        #expect(pieces[1].start == 26.2)   // internal cut point, unaffected by the anchoring
        #expect(pieces[1].end == 42.0)     // anchored to seg.end, not the last word's end (40.0)
    }

    @Test func splitReturnsOriginalSegmentWhenAllWordsAreWhitespaceOnly() {
        // Both words are whitespace-only. Word 1 opens a piece (S0, since `pieces.isEmpty` bypasses
        // the glue rule for the very first word); word 2 is also whitespace-only and glues onto that
        // SAME piece per the whitespace-glue rule (line 278) rather than opening a second one for S1.
        // So this never reaches the `emitted.isEmpty` fallback (see the comment at that line: it's
        // structurally unreachable via this grouping logic, since only the FIRST piece can ever end
        // up all-empty) — this exercises the earlier `guard pieces.count > 1 else` single-piece early
        // return instead, which must still return the original, unsplit `seg` (not silently drop it)
        // when the sole piece's text is empty.
        let words = [
            WordTiming(start: 1.0, end: 2.0, text: "  "),
            WordTiming(start: 6.0, end: 7.0, text: "  "),
        ]
        let seg = TranscriptSegment(start: 0.0, end: 10.0, text: "  ", language: nil, words: words)
        let diar = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "S0"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "S1"),
        ]

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 1)
        #expect(pieces[0].start == seg.start)
        #expect(pieces[0].end == seg.end)
    }

    @Test func splitAnchorsBothBoundsWhenOnlyOnePieceSurvivesTextFilter() {
        // pieces.count > 1 (a real boundary WAS detected — S0 then S1), but only ONE of the two
        // resulting pieces has non-empty text (the S0 piece is whitespace-only and gets filtered).
        // Exercises the firstIdx == lastIdx branch: the single surviving piece must be anchored to
        // BOTH seg.start and seg.end, not just whichever bound its own position would suggest.
        let words = [
            WordTiming(start: 1.0, end: 2.0, text: "  "),       // → S0, trims empty, filtered
            WordTiming(start: 6.0, end: 7.0, text: "hello"),    // → S1, survives
        ]
        let seg = TranscriptSegment(start: 0.0, end: 10.0, text: "hello", language: nil, words: words)
        let diar = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "S0"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "S1"),
        ]

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 1)
        #expect(pieces[0].text == "hello")
        #expect(pieces[0].start == seg.start)  // anchored to seg.start, not the surviving word's own start (6.0)
        #expect(pieces[0].end == seg.end)      // anchored to seg.end, not the surviving word's own end (7.0)
    }

    @Test func leavesSingleSpeakerSegmentUntouched() {
        // Whole segment falls inside one diarized turn → must be returned byte-identical (keeps the
        // engine's own text, incl. FluidAudio ITN, with no reconstruction).
        let diar = [DiarizedSegment(start: 0.0, end: 100.0, speaker: "S0")]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 1)
        #expect(pieces[0].start == seg.start)
        #expect(pieces[0].end == seg.end)
        #expect(pieces[0].text == seg.text)
        #expect(pieces[0].dominantSpeaker == "S0")  // must propagate for assign() to trust word evidence
    }

    @Test func leavesITNReformattedTextUntouchedWhenNotSplit() {
        // The key ITN-preservation guarantee behind the `guard pieces.count > 1 else { … }` early
        // return: `leavesSingleSpeakerSegmentUntouched` only checks `pieces[0].text == seg.text`,
        // which passes trivially even if seg.text were reconstructed from words — it doesn't prove
        // ITN-reformatted text specifically survives. Here seg.text is a POST-ITN string ("2026")
        // that does NOT match what concatenating the raw PRE-ITN words would produce ("two thousand
        // twenty-six") — if the passthrough ever started reconstructing text instead of returning
        // `seg` unchanged, this would catch it immediately.
        let words = [
            WordTiming(start: 0.0, end: 0.3, text: "two"),
            WordTiming(start: 0.3, end: 0.6, text: " thousand"),
            WordTiming(start: 0.6, end: 0.9, text: " twenty"),
            WordTiming(start: 0.9, end: 1.0, text: "-six"),
        ]
        let seg = TranscriptSegment(start: 0.0, end: 1.0, text: "2026", language: "en", words: words)
        let diar = [DiarizedSegment(start: 0.0, end: 1.0, speaker: "S0")]

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 1)
        #expect(pieces[0].text == "2026")
    }

    @Test func passesThroughSegmentWithoutWordTiming() {
        // No word timing available → cannot split; segment passes through unchanged (fallback C).
        let diar = [
            DiarizedSegment(start: 0.0, end: 3.0, speaker: "S0"),
            DiarizedSegment(start: 3.0, end: 10.0, speaker: "S1"),
        ]
        let seg = TranscriptSegment(start: 0.0, end: 10.0, text: "spans two speakers", language: "en")

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 1)
        #expect(pieces[0].text == "spans two speakers")
    }

    @Test func passesThroughWhenNoDiarization() {
        let seg = spanningSegment(boundary: 26.0, end: 72.0)
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: [])
        #expect(pieces.count == 1)
        #expect(pieces[0].text == seg.text)
    }

    @Test func doesNotSplitWhenAllWordsLandInDiarizationGap() {
        // Gap between turns [0,5) and [15,30); all three words sit in [6,9) — closer to S0's end
        // (dist 1..3) than to S1's start (dist 6..8) for every word, so dominantDiarSpeaker's
        // nearest-turn fallback glues all of them to the SAME turn (verified: no word's distance
        // ordering flips). End-to-end path for wordInGapGluesToNearestTurn: a segment landing
        // entirely in silence between turns must not open a spurious boundary.
        let diar = [
            DiarizedSegment(start: 0, end: 5, speaker: "S0"),
            DiarizedSegment(start: 15, end: 30, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 6, end: 7, text: "one"),
            WordTiming(start: 7, end: 8, text: " two"),
            WordTiming(start: 8, end: 9, text: " three"),
        ]
        let seg = TranscriptSegment(start: 6, end: 9, text: "one two three", language: nil, words: words)
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)
        #expect(pieces.count == 1)
        #expect(pieces[0].text == seg.text)
    }

    @Test func splitPiecesAreRebuiltFromPreITNTokens() {
        // Complements leavesITNReformattedTextUntouchedWhenNotSplit: this is the OTHER side of the
        // contract — a segment that IS split reconstructs its pieces from the raw pre-ITN words, not
        // from seg.text. seg.text is post-ITN ("$1,000 dollars"); the words are the pre-ITN tokens
        // ITN was applied to. Documented known limitation (FluidAudioEngine.swift, PR #121 body) —
        // this pins it so a future attempt to re-apply ITN to split pieces doesn't silently break
        // reconstruction if ITN ever shifts token boundaries.
        let words = [
            WordTiming(start: 0, end: 0.4, text: "one"),
            WordTiming(start: 0.4, end: 0.9, text: " thousand"),
            WordTiming(start: 10, end: 10.5, text: " dollars"),
        ]
        let seg = TranscriptSegment(start: 0, end: 11, text: "$1,000 dollars", language: "en", words: words)
        let diar = [
            DiarizedSegment(start: 0, end: 5, speaker: "S0"),
            DiarizedSegment(start: 5, end: 15, speaker: "S1"),
        ]
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)
        #expect(pieces.count == 2)
        #expect(pieces[0].text == "one thousand")  // pre-ITN, not "$1,000"
        #expect(pieces[1].text == "dollars")        // pre-ITN
    }

    @Test func splitsThreeWayWhenSpeakerRecurs() {
        // A → B → A within one segment (interviewer interjects mid-answer). Same speaker id "A"
        // recurring must still produce three consecutive pieces cut at each change.
        let diar = [
            DiarizedSegment(start: 0.0, end: 10.0, speaker: "A"),
            DiarizedSegment(start: 10.0, end: 20.0, speaker: "B"),
            DiarizedSegment(start: 20.0, end: 30.0, speaker: "A"),
        ]
        let words = [
            WordTiming(start: 5.0, end: 6.0, text: "one"),
            WordTiming(start: 6.0, end: 9.5, text: " two"),      // A
            WordTiming(start: 11.0, end: 13.0, text: " three"),  // B
            WordTiming(start: 13.0, end: 18.0, text: " four"),   // B
            WordTiming(start: 21.0, end: 24.0, text: " five"),   // A
        ]
        let seg = TranscriptSegment(
            start: 5.0, end: 24.0, text: "one two three four five", language: "en", words: words
        )

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 3)
        #expect(pieces[0].text == "one two")
        #expect(pieces[1].text == "three four")
        #expect(pieces[2].text == "five")
        // Middle piece keeps its (non-nil, sorted) words; only anchored first/last get nil.
        #expect(pieces[1].words != nil)
        #expect(pieces[1].words?.first?.start ?? .infinity <= pieces[1].words?.last?.start ?? -.infinity)
    }

    // MARK: - dominantDiarSpeaker gap fallback + tiebreaker

    @Test func wordInGapGluesToNearestTurn() {
        // Word sits fully inside a gap between two turns; must glue to the nearer edge, not open a
        // phantom boundary. Nearest by edge distance here is S1 (gap 30–40, word 38–39).
        let diar = [
            DiarizedSegment(start: 0.0, end: 30.0, speaker: "S0"),
            DiarizedSegment(start: 40.0, end: 70.0, speaker: "S1"),
        ]
        let spk = SpeakerAssignment.dominantDiarSpeaker(wordStart: 38.0, wordEnd: 39.0, in: diar)
        #expect(spk == "S1")
    }

    @Test func tiebreakerPrefersTurnContainingMidpointOnEqualOverlap() {
        // Primary tiebreaker case: two turns overlap the word by an EQUAL amount, so raw overlap
        // alone can't decide. Word [0,10], mid=5. "A"=[0,4] overlaps 4 but does NOT contain mid (5>4).
        // "B"=[3,7] also overlaps 4 AND contains mid (3<=5<=7). The tiebreaker must promote B even
        // though a naive "first strictly-greater overlap wins" scan would otherwise leave A in place.
        let diar = [
            DiarizedSegment(start: 0.0, end: 4.0, speaker: "A"),
            DiarizedSegment(start: 3.0, end: 7.0, speaker: "B"),
        ]
        let spk = SpeakerAssignment.dominantDiarSpeaker(wordStart: 0.0, wordEnd: 10.0, in: diar)
        #expect(spk == "B")
    }

    @Test func tiebreakerNeverFiresOnZeroOverlap() {
        // Regression for the overlap>0 guard: a zero-duration word at t=10 touches BOTH "FIRST"=[10,15]
        // and "SECOND"=[5,10] at their exact boundary — each has overlap=0, but each span's inclusive
        // bounds "contain" the word's midpoint (also 10). Without requiring overlap>0, the tiebreaker
        // fires on both via the initial bestOverlap==0 sentinel and — since it unconditionally
        // overwrites `best` on every match — the LAST candidate in iteration order wins (SECOND), never
        // reaching the nil-fallback path. With the guard, neither zero-overlap candidate can trigger
        // the tiebreaker, so `best` stays nil and control correctly passes to the nearest-turn fallback,
        // whose strict `<` tie rule keeps the FIRST candidate on an exact distance tie (both are 0).
        // The differing winner (FIRST vs SECOND) proves the guard changes behavior, not just intent.
        let diar = [
            DiarizedSegment(start: 10.0, end: 15.0, speaker: "FIRST"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "SECOND"),
        ]
        let spk = SpeakerAssignment.dominantDiarSpeaker(wordStart: 10.0, wordEnd: 10.0, in: diar)
        #expect(spk == "FIRST")
    }

    // MARK: - assign() integration (basic overload)

    @Test func assignReattributesAbsorbedQuestion() {
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg], diarizationSegments: diar
        )

        // The absorbed question now exists as its own segment attributed to the interviewer.
        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[0].text == "So what happened?")
        #expect(labeled[1].speaker == "Speaker 2")
        #expect(labeled[1].text == "Well, it went on for quite a while")
    }

    @Test func assignUnchangedForCleanSingleSpeakerSegments() {
        // Regression guard: segments that don't span a boundary behave exactly as before.
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "hello", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "world", language: nil),
        ]
        let diar = [
            DiarizedSegment(start: 0.0, end: 6.0, speaker: "S0"),
            DiarizedSegment(start: 6.0, end: 10.0, speaker: "S1"),
        ]
        let labeled = SpeakerAssignment.assign(transcriptSegments: transcript, diarizationSegments: diar)
        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[1].speaker == "Speaker 2")
    }

    @Test func splitHandlesHeterogeneousArrayOfSpanningAndCleanSegments() {
        // Every other splitAcrossSpeakerBoundaries test passes either a single segment or a
        // homogeneous array (all-spanning or all-clean). A mixed array [spanning, clean, spanning]
        // must independently split each spanning entry (2 pieces each) while leaving the clean one
        // untouched (1), concatenated in input order: 2 + 1 + 2 = 5 total, no cross-segment state
        // leakage or off-by-one in the output ordering.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let spanning1 = spanningSegment(boundary: 26.0, end: 72.0)
        let clean = TranscriptSegment(start: 100.0, end: 105.0, text: "clean", language: nil)
        let spanning2 = spanningSegment(boundary: 26.0, end: 72.0)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries(
            [spanning1, clean, spanning2], diarizationSegments: diar
        )

        #expect(pieces.count == 5)
        // spanning1 -> 2 pieces
        #expect(pieces[0].text == "So what happened?")
        #expect(pieces[1].text == "Well, it went on for quite a while")
        // clean -> 1 piece, untouched
        #expect(pieces[2].text == "clean")
        #expect(pieces[2].start == 100.0)
        #expect(pieces[2].end == 105.0)
        // spanning2 -> 2 more pieces, independently re-split (no leakage from spanning1's grouping)
        #expect(pieces[3].text == "So what happened?")
        #expect(pieces[4].text == "Well, it went on for quite a while")
    }

    // MARK: - assign() integration (VAD/quality overload)

    @Test func assignVadOverloadSplitsAndLabels() {
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0", qualityScore: 0.9),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1", qualityScore: 0.9),
        ]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)
        // Speech present across the whole span so both pieces pass the VAD gate.
        let speechMap = [SpeechRegion(start: 0.0, end: 80.0, probability: 0.95)]

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg],
            diarizationSegments: diar,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )

        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[0].text == "So what happened?")
        #expect(labeled[1].speaker == "Speaker 2")
    }

    @Test func assignVadOverloadLowQualityShortSplitPieceIsUnknown() {
        // The operationally important case: a short split-off piece (the reattributed question,
        // ~2s) with LOW diarizer confidence, distinct from the long piece it was split from. Both
        // pieces have full speech coverage (isolating quality as the deciding factor) — the short
        // piece's own turn has qualityScore 0.1 (below the 0.3 threshold) while the long piece's
        // turn is 0.9. Confirms the split fix doesn't bypass VAD/quality gating for the piece it
        // creates: high speech + low quality → "Unknown" per the decision matrix, not silently
        // trusted just because it was reattributed from the wrong speaker.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0", qualityScore: 0.1),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1", qualityScore: 0.9),
        ]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)
        let speechMap = [SpeechRegion(start: 0.0, end: 80.0, probability: 0.95)]

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg],
            diarizationSegments: diar,
            speechMap: speechMap,
            vadSpeechThreshold: 0.5,
            qualityScoreThreshold: 0.3
        )

        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Unknown")
        #expect(labeled[0].text == "So what happened?")
        #expect(labeled[1].speaker == "Speaker 2")
        #expect(labeled[1].text == "Well, it went on for quite a while")
    }

    @Test func assignVadOverloadNilSpeechMapStillSplits() {
        // speechMap == nil bypasses VAD filtering but must still re-split the spanning segment.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let seg = spanningSegment(boundary: 26.0, end: 72.0)

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg],
            diarizationSegments: diar,
            speechMap: nil
        )

        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[1].speaker == "Speaker 2")
    }

    @Test func assignVadOverloadUnchangedForCleanSingleSpeakerSegments() {
        // VAD-overload counterpart to assignUnchangedForCleanSingleSpeakerSegments: clean,
        // single-speaker segments (no spanning boundary) through the VAD/quality-gated overload must
        // come out correctly attributed and unaffected by the split logic.
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "hello", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "world", language: nil),
        ]
        let diar = [
            DiarizedSegment(start: 0.0, end: 6.0, speaker: "S0", qualityScore: 0.9),
            DiarizedSegment(start: 6.0, end: 10.0, speaker: "S1", qualityScore: 0.9),
        ]
        let speechMap = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diar, speechMap: speechMap
        )

        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[1].speaker == "Speaker 2")
    }

    // MARK: - FluidAudio token grouping now carries word timing

    @Test func groupTokensAttachesWordTimings() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " world"),
            TokenTiming(startTime: 1.0, endTime: 1.2, token: "."),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 1)
        let words = result[0].words
        #expect(words?.count == 3)
        #expect(words?.first?.start == 0.0)
        #expect(words?.last?.end == 1.2)
        // Concatenating the retained word text reproduces the segment text (post-trim).
        let rebuilt = (words ?? []).map(\.text).joined().trimmingCharacters(in: .whitespaces)
        #expect(rebuilt == result[0].text)
    }

    @Test func groupTokensWordTimingsResetBetweenSentences() {
        // Regression guard for the currentWords accumulator reset: if a future edit dropped the
        // `currentWords = []` reset after each completed segment, the second sentence would silently
        // inherit the first's words too — this pins that each segment carries ONLY its own words.
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " world"),
            TokenTiming(startTime: 1.0, endTime: 1.2, token: "."),
            TokenTiming(startTime: 2.0, endTime: 2.5, token: "Goodbye"),
            TokenTiming(startTime: 2.5, endTime: 3.0, token: " world"),
            TokenTiming(startTime: 3.0, endTime: 3.2, token: "."),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 2)
        #expect(result[0].words?.count == 3)
        #expect(result[1].words?.count == 3)
        #expect(result[1].words?.first?.start == 2.0)
    }

    @Test func groupTokensAttachesWordTimingsOnTrailingUnpunctuatedFlush() {
        // The other segment-flush trigger in groupTokensIntoSegments besides `.!?` punctuation:
        // `i == timings.count - 1` flushes a trailing segment that never hit sentence-ending
        // punctuation. That branch also accumulates currentWords, but only the punctuation-terminated
        // path was tested above — this pins that a purely token-exhaustion-triggered flush still
        // carries correct word timing too.
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " world"),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 1)
        #expect(result[0].words?.count == 2)
        #expect(result[0].words?.first?.start == 0.0)
        #expect(result[0].words?.last?.end == 1.0)
    }

    // MARK: - splitAcrossSpeakerBoundaries: empty (non-nil) words array

    @Test func passesThroughSegmentWithEmptyWordArray() {
        // words = [] (non-nil, zero entries) must pass through unchanged exactly like words == nil —
        // pins the words.count >= 2 guard's documented empty-array behavior explicitly.
        let seg = TranscriptSegment(start: 0, end: 5, text: "hi", language: nil, words: [])
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries(
            [seg], diarizationSegments: [DiarizedSegment(start: 0, end: 5, speaker: "S0")]
        )
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "hi")
    }

    @Test func passesThroughSegmentWithSingleWord() {
        // Completes the words.count >= 2 guard's edge-case set alongside the empty-array test above:
        // a single word can't straddle a speaker boundary, so it must pass through unchanged too.
        let seg = TranscriptSegment(
            start: 0, end: 2, text: "hi", language: nil,
            words: [WordTiming(start: 0, end: 2, text: "hi")]
        )
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries(
            [seg], diarizationSegments: [
                DiarizedSegment(start: 0, end: 1, speaker: "S0"),
                DiarizedSegment(start: 1, end: 2, speaker: "S1"),
            ]
        )
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "hi")
    }

    // MARK: - SpeakerAssignment.speechAnalyzerWordTimings (pure, engine-independent)
    //
    // SpeechAnalyzerEngine itself requires macOS 26 / Swift 6.2+ and is compiled out entirely on
    // CI's Swift 6.0 runner, so its live SpeechTranscriber loop can't be exercised here. The word-
    // timing DECISION logic (issue #120) was deliberately extracted into this pure function so its
    // three outcome paths stay unit-tested regardless.

    @Test func speechAnalyzerWordTimingsPopulatedWhenAllRunsTimedAndRoundTripHolds() {
        let runs: [(text: String, start: Double?, end: Double?)] = [
            (text: "Hello", start: 0.0, end: 0.5),
            (text: " world", start: 0.5, end: 1.0),
        ]
        let words = SpeakerAssignment.speechAnalyzerWordTimings(runs: runs, trimmedSegmentText: "Hello world")
        #expect(words?.count == 2)
        #expect(words?.first?.start == 0.0)
        #expect(words?.last?.end == 1.0)
    }

    @Test func speechAnalyzerWordTimingsNilWhenAnyRunLacksTiming() {
        let runs: [(text: String, start: Double?, end: Double?)] = [
            (text: "Hello", start: 0.0, end: 0.5),
            (text: " world", start: nil, end: nil),  // e.g. a run with no audioTimeRange
        ]
        let words = SpeakerAssignment.speechAnalyzerWordTimings(runs: runs, trimmedSegmentText: "Hello world")
        #expect(words == nil)
    }

    @Test func speechAnalyzerWordTimingsNilWhenRoundTripFails() {
        // Every run IS timed, but concatenating them doesn't reproduce the segment's own text —
        // simulates a space silently lost or misattributed at a run boundary.
        let runs: [(text: String, start: Double?, end: Double?)] = [
            (text: "Hello", start: 0.0, end: 0.5),
            (text: "world", start: 0.5, end: 1.0),  // missing its leading space
        ]
        let words = SpeakerAssignment.speechAnalyzerWordTimings(runs: runs, trimmedSegmentText: "Hello world")
        #expect(words == nil)
    }

    @Test func speechAnalyzerWordTimingsNilWhenRunsIsEmpty() {
        #expect(SpeakerAssignment.speechAnalyzerWordTimings(runs: [], trimmedSegmentText: "") == nil)
    }

    // MARK: - Independent code-council review findings (all 3/3 confirmed)
    //
    // These three findings share one root cause: assign() used to re-derive a segment's speaker from
    // raw geometric time-overlap, completely independent of the word-level ownership decision
    // splitAcrossSpeakerBoundaries/dominantDiarSpeaker already computed. TranscriptSegment now carries
    // that decision forward as `dominantSpeaker`, and assign() trusts it when present.

    @Test func wordlessDiarizationTurnDoesNotOutvoteWordEvidencedSpeaker() {
        // Finding 1 (High): a diarization turn with ZERO covering words (a breath, room noise, an
        // untranscribed cross-talk speaker "X") sits entirely inside an unsplit segment's span and has
        // MORE raw wall-clock overlap than the turns the segment's actual words were assigned to.
        // diar: A[0,2) "So I think", X[2.5,8) wordless (silent pause), A[9,10) "we should go" (same
        // raw id A, reflecting cross-chunk reconciliation). Segment spans [1,9.8] with only 2 words,
        // both independently evidenced as A. Before the fix, assign()'s raw-overlap vote picked X
        // (5.5s > A's 1.0+0.8s, scored per-turn not aggregated) — attributing BOTH real words'
        // segment, wholesale, to a speaker with nothing actually transcribed. Verified via script:
        // X's raw overlap (5.5) > either individual A turn (1.0, 0.8).
        let diar = [
            DiarizedSegment(start: 0.0, end: 2.0, speaker: "A"),
            DiarizedSegment(start: 2.5, end: 8.0, speaker: "X"),
            DiarizedSegment(start: 9.0, end: 10.0, speaker: "A"),
        ]
        let words = [
            WordTiming(start: 1.0, end: 1.9, text: "So I think"),
            WordTiming(start: 9.2, end: 9.8, text: " we should go"),
        ]
        let seg = TranscriptSegment(start: 1.0, end: 9.8, text: "So I think we should go", language: nil, words: words)

        // Split step: both words agree on "A", so this stays ONE piece — but must now carry that
        // word-derived speaker forward rather than discarding it.
        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)
        #expect(pieces.count == 1)
        #expect(pieces[0].dominantSpeaker == "A")

        // End-to-end: assign() must label the segment as A ("Speaker 1", the first raw id
        // encountered), never X ("Speaker 2") despite X's larger raw overlap.
        let labeled = SpeakerAssignment.assign(transcriptSegments: [seg], diarizationSegments: diar)
        #expect(labeled.count == 1)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[0].speaker != "Speaker 2")
    }

    @Test func standalonePunctuationTokenNeverBecomesItsOwnSplitPiece() {
        // Finding 2 (Medium): FluidAudio emits sentence-final punctuation as its OWN TokenTiming
        // (already true of "?" in groupTokensQuestionMark). If a diarization boundary falls exactly
        // between the last real word and its trailing punctuation, dominantDiarSpeaker independently
        // assigns them to DIFFERENT turns. Before the fix, the lone "?" would be split into its own
        // one-character piece and misattributed to whichever speaker happened to own that instant —
        // a phantom "utterance" nobody spoke. Verified via script: "happened"[25.4,26.0] -> S0,
        // "?"[26.0,26.15] -> S1 (different turns, would trigger a spurious cut).
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 24.0, end: 24.7, text: "So"),
            WordTiming(start: 24.7, end: 25.4, text: " what"),
            WordTiming(start: 25.4, end: 26.0, text: " happened"),
            WordTiming(start: 26.0, end: 26.15, text: "?"),  // standalone punctuation token
            WordTiming(start: 26.2, end: 27.0, text: " Well,"),
            WordTiming(start: 27.0, end: 40.0, text: " it went on"),
        ]
        let seg = TranscriptSegment(
            start: 24.0, end: 40.0, text: "So what happened? Well, it went on", language: "en", words: words
        )

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        // Two pieces (the real speaker change), NOT three — the "?" never gets its own piece.
        #expect(pieces.count == 2)
        #expect(pieces[0].text == "So what happened?")  // "?" glued to the question, not split off
        #expect(pieces[1].text == "Well, it went on")
    }

    @Test func emojiTokenIsTreatedAsRealContentNotPunctuation() {
        // Swift's Character.isLetter/.isNumber are both false for emoji, so without also checking
        // .isSymbol, isPunctuationOnly would misclassify an emoji reaction as punctuation and silently
        // glue it to the preceding speaker's piece — even when it's a genuinely different speaker's
        // own content (e.g. a reaction). "hello"[24,25]->S0, then a DIFFERENT speaker's "👍"[26.0,26.3]
        // and "bye"[26.3,27.0], both ->S1. The emoji must open (or join) S1's piece, not vanish into
        // S0's — proven by the emoji surviving into the second piece's text.
        let diar = [
            DiarizedSegment(start: 0.0, end: 26.0, speaker: "S0"),
            DiarizedSegment(start: 26.0, end: 72.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 24.0, end: 25.0, text: "hello"),
            WordTiming(start: 26.0, end: 26.3, text: " 👍"),
            WordTiming(start: 26.3, end: 27.0, text: " bye"),
        ]
        let seg = TranscriptSegment(start: 24.0, end: 27.0, text: "hello 👍 bye", language: "en", words: words)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)

        #expect(pieces.count == 2)
        #expect(pieces[0].text == "hello")
        #expect(pieces[1].text == "👍 bye")  // emoji correctly carried into S1's piece, not dropped
    }

    @Test func gapFallbackSplitPiecesKeepTheirEvidencedSpeakerThroughAssign() {
        // Finding 3 (Medium), end-to-end split->assign (the exact case the existing
        // doesNotSplitWhenAllWordsLandInDiarizationGap test does NOT cover, since there every word
        // agrees on ONE nearest turn). Here the words disagree: diar has a genuine silence gap
        // between S0[0,5) and S1[15,20). Word "one"[6,7] is nearer S0 (dist 1 vs 8); word "two"[12,13]
        // is nearer S1 (dist 2 vs 7) -- dominantDiarSpeaker's gap-fallback confidently assigns each to
        // a DIFFERENT turn, so the segment splits into two pieces. Before the fix, assign()'s plain
        // overlap loop (no gap-fallback of its own) found ZERO overlap for either piece against
        // either turn and collapsed BOTH to "Unknown" -- reproduced live by the code-council's own
        // probe. The split must not discard the very ownership decision that justified it.
        let diar = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "S0"),
            DiarizedSegment(start: 15.0, end: 20.0, speaker: "S1"),
        ]
        let words = [
            WordTiming(start: 6.0, end: 7.0, text: "one"),
            WordTiming(start: 12.0, end: 13.0, text: " two"),
        ]
        let seg = TranscriptSegment(start: 6.0, end: 13.0, text: "one two", language: nil, words: words)

        let pieces = SpeakerAssignment.splitAcrossSpeakerBoundaries([seg], diarizationSegments: diar)
        #expect(pieces.count == 2)
        #expect(pieces[0].dominantSpeaker == "S0")
        #expect(pieces[1].dominantSpeaker == "S1")

        let labeled = SpeakerAssignment.assign(transcriptSegments: [seg], diarizationSegments: diar)
        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")  // NOT "Unknown"
        #expect(labeled[1].speaker == "Speaker 2")  // NOT "Unknown"
    }

    @Test func gapFallbackSplitPiecesKeepEvidencedSpeakerThroughVadOverload() {
        // Same scenario as above, through the VAD/quality-gated assign() overload -- confirms the
        // dominantSpeaker override also survives quality-gate interaction, and that bestQuality is
        // re-derived from a turn matching the EVIDENCED speaker rather than borrowing a mismatched
        // turn's score (neither turn geometrically overlaps either piece here, so quality naturally
        // falls back to nil -> "trust the diarizer" -- both pieces must still pass the gate).
        let diar = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "S0", qualityScore: 0.9),
            DiarizedSegment(start: 15.0, end: 20.0, speaker: "S1", qualityScore: 0.9),
        ]
        let words = [
            WordTiming(start: 6.0, end: 7.0, text: "one"),
            WordTiming(start: 12.0, end: 13.0, text: " two"),
        ]
        let seg = TranscriptSegment(start: 6.0, end: 13.0, text: "one two", language: nil, words: words)
        let speechMap = [SpeechRegion(start: 0.0, end: 20.0, probability: 0.95)]

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg], diarizationSegments: diar,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[1].speaker == "Speaker 2")
    }

    @Test func gapFallbackSplitPiecesAreNotDowngradedByNonOverlappingLowQualityTurn() {
        // Regression for a real bug caught in review on the bestQuality re-derivation above: with
        // BOTH evidenced turns' qualityScore set low (0.1, below the 0.3 threshold), and neither turn
        // geometrically overlapping either piece (same gap geometry as the sibling test), bestQuality
        // must fall back to nil -> 1.0 ("trust the diarizer") rather than inheriting 0.1 from a turn
        // that never actually overlaps this piece. Without the `overlap > 0` filter before `.max`,
        // Swift's max(by:) returns a value even when every candidate ties at overlap == 0, silently
        // downgrading a correct gap-fallback attribution to "Unknown" through the quality gate.
        let diar = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "S0", qualityScore: 0.1),
            DiarizedSegment(start: 15.0, end: 20.0, speaker: "S1", qualityScore: 0.1),
        ]
        let words = [
            WordTiming(start: 6.0, end: 7.0, text: "one"),
            WordTiming(start: 12.0, end: 13.0, text: " two"),
        ]
        let seg = TranscriptSegment(start: 6.0, end: 13.0, text: "one two", language: nil, words: words)
        let speechMap = [SpeechRegion(start: 0.0, end: 20.0, probability: 0.95)]

        let labeled = SpeakerAssignment.assign(
            transcriptSegments: [seg], diarizationSegments: diar,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(labeled.count == 2)
        #expect(labeled[0].speaker == "Speaker 1")  // NOT "Unknown"
        #expect(labeled[1].speaker == "Speaker 2")  // NOT "Unknown"
    }
}
