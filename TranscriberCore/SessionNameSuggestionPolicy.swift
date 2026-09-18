import Foundation

/// Pure decision logic for whether a late-arriving calendar suggestion (#197) should replace the
/// session name the user is currently looking at. Extracted out of `SessionNameDialog`'s
/// `onChange(of: suggestion.eventTitle)` closure so the actual behavior is unit-testable without
/// SwiftUI or the app target (mirrors `CalendarEventPicker`'s split of pure logic from the API
/// call that feeds it).
public enum SessionNameSuggestionPolicy {
    /// Returns the name to adopt, or `nil` if the late arrival should be ignored.
    ///
    /// - Parameters:
    ///   - userHasEdited: `true` once the user has typed anything into the name field — a
    ///     one-way latch, so a late suggestion never overwrites deliberate user input.
    ///   - newTitle: the calendar lookup's late-arriving result.
    public static func adopt(userHasEdited: Bool, newTitle: String?) -> String? {
        // Whitespace-only titles are treated the same as empty: an all-space event title would
        // otherwise flash the "Suggested from your calendar" hint and fill the field with
        // invisible spaces even though `start()` trims the name before using it.
        guard !userHasEdited, let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return newTitle
    }
}
