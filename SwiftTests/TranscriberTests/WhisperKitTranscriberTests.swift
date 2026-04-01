import Testing
import Foundation
@testable import TranscriberCore

struct WhisperKitTranscriberTests {

    @Test func transcriptSegmentInit() {
        let seg = TranscriptSegment(start: 1.5, end: 3.0, text: "hello", language: "en")
        #expect(seg.start == 1.5)
        #expect(seg.end == 3.0)
        #expect(seg.text == "hello")
        #expect(seg.language == "en")
    }

    @Test func transcriptSegmentNilLanguage() {
        let seg = TranscriptSegment(start: 0, end: 1, text: "test", language: nil)
        #expect(seg.language == nil)
    }
}
