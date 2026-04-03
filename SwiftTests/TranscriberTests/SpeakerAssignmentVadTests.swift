import Testing
import Foundation
@testable import TranscriberCore

struct SpeakerAssignmentVadTests {

    private func diarized(_ start: Double, _ end: Double, _ speaker: String, quality: Float? = nil) -> DiarizedSegment {
        DiarizedSegment(start: start, end: end, speaker: speaker, qualityScore: quality)
    }

    private func transcript(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, language: nil)
    }

    @Test func highSpeechHighQualityAssignsSpeaker() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.9)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.5
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func highSpeechLowQualityAssignsUnknown() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.1)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Unknown")
    }

    @Test func lowSpeechLowQualityFiltered() {
        let transcript = [
            transcript(0.0, 5.0, "real speech"),
            transcript(5.0, 10.0, "noise segment"),
        ]
        let diarization = [
            diarized(0.0, 5.0, "SPEAKER_00", quality: 0.9),
            diarized(5.0, 10.0, "SPEAKER_01", quality: 0.1),
        ]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].text == "real speech")
    }

    @Test func lowSpeechHighQualityTrustsDiarizer() {
        let transcript = [transcript(5.0, 10.0, "quiet speaker")]
        let diarization = [diarized(5.0, 10.0, "SPEAKER_00", quality: 0.9)]
        let speechMap: [SpeechRegion] = []
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func nilSpeechMapFallsBackToOriginal() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: 0.1)]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: nil, vadSpeechThreshold: 0.5
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func nilQualityScoreTreatedAsHighQuality() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00", quality: nil)]
        let speechMap = [SpeechRegion(start: 0.0, end: 5.0, probability: 0.95)]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.5, qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func zeroThresholdDisablesVadFiltering() {
        let transcript = [transcript(5.0, 10.0, "noise")]
        let diarization = [diarized(5.0, 10.0, "SPEAKER_00", quality: 0.1)]
        let speechMap: [SpeechRegion] = []
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization,
            speechMap: speechMap, vadSpeechThreshold: 0.0, qualityScoreThreshold: 0.3
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Unknown")
    }

    @Test func originalAssignMethodUnchanged() {
        let transcript = [transcript(0.0, 5.0, "hello")]
        let diarization = [diarized(0.0, 5.0, "SPEAKER_00")]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Speaker 1")
    }
}
