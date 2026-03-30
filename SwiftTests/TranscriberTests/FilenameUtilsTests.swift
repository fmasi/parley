import Testing
import Foundation
@testable import TranscriberCore

struct FilenameUtilsTests {

    // MARK: - Basic sanitization

    @Test func removesForwardSlash() {
        #expect(sanitizeFilename("meeting/notes") == "meetingnotes")
    }

    @Test func removesColon() {
        #expect(sanitizeFilename("10:30 standup") == "1030 standup")
    }

    @Test func removesNullByte() {
        #expect(sanitizeFilename("file\0name") == "filename")
    }

    @Test func removesMultipleDangerousChars() {
        #expect(sanitizeFilename("a/b:c\0d") == "abcd")
    }

    // MARK: - Passthrough

    @Test func leavesNormalStringUnchanged() {
        #expect(sanitizeFilename("Sprint Review 2024-03-15") == "Sprint Review 2024-03-15")
    }

    @Test func leavesEmptyStringUnchanged() {
        #expect(sanitizeFilename("") == "")
    }

    @Test func preservesDots() {
        #expect(sanitizeFilename("meeting.notes") == "meeting.notes")
    }

    @Test func preservesDashes() {
        #expect(sanitizeFilename("2024-03-15-standup") == "2024-03-15-standup")
    }

    @Test func preservesUnderscores() {
        #expect(sanitizeFilename("meeting_notes") == "meeting_notes")
    }

    @Test func preservesSpaces() {
        #expect(sanitizeFilename("my meeting") == "my meeting")
    }

    @Test func preservesUnicode() {
        #expect(sanitizeFilename("réunion équipe") == "réunion équipe")
    }

    // MARK: - Edge cases

    @Test func allDangerousCharsProducesEmpty() {
        #expect(sanitizeFilename("/:\0") == "")
    }

    @Test func multipleConsecutiveSlashes() {
        #expect(sanitizeFilename("///path///") == "path")
    }
}
