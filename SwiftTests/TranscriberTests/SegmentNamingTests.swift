import Testing
import Foundation
@testable import TranscriberCore

struct SegmentNamingTests {

    @Test func stripsExistingSegmentSuffix() {
        #expect(segmentBaseName(originalPath: "/tmp/recording-2.wav", segment: 3) == "recording-3")
    }

    @Test func handlesNoExistingSuffix() {
        #expect(segmentBaseName(originalPath: "/tmp/recording.wav", segment: 2) == "recording-2")
    }

    @Test func handlesMultiDigitSuffix() {
        #expect(segmentBaseName(originalPath: "/tmp/recording-15.wav", segment: 16) == "recording-16")
    }

    @Test func preservesHyphensInName() {
        // Only strips the LAST -\d+ group
        #expect(segmentBaseName(originalPath: "/tmp/my-meeting-recording-2.wav", segment: 3) == "my-meeting-recording-3")
    }

    @Test func handlesNestedPath() {
        #expect(segmentBaseName(
            originalPath: "/Users/x/.audio-transcribe/2026-04-03/143400-weekly-sync-2.wav",
            segment: 3
        ) == "143400-weekly-sync-3")
    }

    @Test func preservesDigitsNotAfterHyphen() {
        // Regex requires a hyphen before the digit run; bare digits in name are kept
        #expect(segmentBaseName(originalPath: "/tmp/meeting2.wav", segment: 2) == "meeting2-2")
    }
}
