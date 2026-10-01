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

    // MARK: - Fitting a name into a byte budget (L review 262)

    @Test func aNameThatFitsIsUnchanged() {
        #expect(fittedFilename("Weekly Sync", maxBytes: 11) == "Weekly Sync")
    }

    @Test func aLongNameIsCutOnACharacterBoundaryAndHashed() {
        let family = "👩‍👩‍👧", name = String(repeating: family, count: 20)   // 18-byte characters: never split
        let fitted = fittedFilename(name, maxBytes: 100)
        #expect(fitted.utf8.count <= 100)
        #expect(name.hasPrefix(String(fitted.dropLast(9))) && fitted.dropLast(9).count == (100 - 9) / family.utf8.count, "\(fitted)")
        #expect(fitted.hasSuffix(String(fittedFilename(name, maxBytes: 100).suffix(9))), "the same name fits the same way every time")
        #expect(fittedFilename(name + "x", maxBytes: 100) != fitted, "another name, another fit")
    }
}
