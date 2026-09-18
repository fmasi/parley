import Testing
@testable import TranscriberCore

struct SessionNameSuggestionPolicyTests {
    @Test func adoptsWhenNotEditedAndTitleNonEmpty() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: false, newTitle: "Weekly Standup")
        #expect(result == "Weekly Standup")
    }

    @Test func ignoresWhenUserHasEdited() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: true, newTitle: "Weekly Standup")
        #expect(result == nil)
    }

    @Test func ignoresNilTitle() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: false, newTitle: nil)
        #expect(result == nil)
    }

    @Test func ignoresEmptyTitle() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: false, newTitle: "")
        #expect(result == nil)
    }

    @Test func editedAndEmptyStillIgnored() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: true, newTitle: "")
        #expect(result == nil)
    }

    @Test func ignoresWhitespaceOnlyTitle() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: false, newTitle: "   ")
        #expect(result == nil)
    }

    @Test func ignoresNewlineOnlyTitle() {
        let result = SessionNameSuggestionPolicy.adopt(userHasEdited: false, newTitle: "\n\n")
        #expect(result == nil)
    }
}
