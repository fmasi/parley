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
}
