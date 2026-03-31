import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptWriterTests {

    // MARK: - Timestamp formatting

    @Test func formatTimestampZero() {
        #expect(TranscriptWriter.formatTimestamp(0) == "00:00:00,000")
    }

    @Test func formatTimestampWithMilliseconds() {
        #expect(TranscriptWriter.formatTimestamp(8.039) == "00:00:08,039")
    }

    @Test func formatTimestampMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestamp(3661.5) == "01:01:01,500")
    }

    @Test func formatTimestampShortZero() {
        #expect(TranscriptWriter.formatTimestampShort(0) == "00:00:00")
    }

    @Test func formatTimestampShortTruncatesMillis() {
        #expect(TranscriptWriter.formatTimestampShort(8.039) == "00:00:08")
    }

    @Test func formatTimestampShortMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestampShort(3661.5) == "01:01:01")
    }
}
