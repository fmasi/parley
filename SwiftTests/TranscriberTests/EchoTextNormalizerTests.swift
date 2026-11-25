import Testing
import Foundation
@testable import TranscriberCore

/// #363: the echo check compares words after normalising both sides, so the same speech written two
/// ways by the two channels' recognisers ("one ninety five" / "195") still matches, and different
/// numbers never do. Synthetic sentences only.
struct EchoTextNormalizerTests {

    private func words(_ text: String) -> [String] { EchoTextNormalizer.words(text) }

    /// What the comparison split on before #363: lower-cased, cut at anything that is not a letter
    /// or a digit.
    private func legacyWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: - The issue's examples

    @Test func spokenNumbersFromTheIssueBecomeTheirDigits() {
        #expect(words("one ninety five") == ["195"])
        #expect(words("twenty twenty six") == ["2026"])
        #expect(words("one eighty three") == ["183"])
        #expect(words("seven thousand five hundred") == ["7500"])
        #expect(words("195") == ["195"])
        #expect(words("2026") == ["2026"])
        #expect(words("7,500") == ["7500"])
        #expect(words("7500") == ["7500"])
    }

    @Test func theIssuesLinesMatchTheirDigitForms() {
        #expect(EchoDeduplicator.textSimilarity("The price is one ninety five per seat.", "The price is 195 per seat.") == 1)
        #expect(EchoDeduplicator.textSimilarity("In twenty twenty six we had one eighty three of them",
                                                "In 2026 we had 183 of them") == 1)
        #expect(EchoDeduplicator.textSimilarity("Seven thousand five hundred a year", "7,500 a year") == 1)
    }

    @Test func differentNumbersNeverMatch() {
        #expect(words("one ninety five") != words("185"))
        #expect(words("one ninety five") != words("1 95"))
        #expect(words("twenty twenty six") != words("2025"))
        #expect(words("seven thousand five hundred") != words("7600"))
        #expect(words("seven thousand five hundred") != words("75"))
        #expect(EchoDeduplicator.textSimilarity("It was one ninety five", "It was 185") < 0.7)
        #expect(EchoDeduplicator.textSimilarity("we need 7,500", "we need 7,600") < 0.7)
    }

    // MARK: - Number forms

    @Test func standardNumberWordsAreEvaluated() {
        #expect(words("two thousand twenty six") == ["2026"])
        #expect(words("one hundred and five") == ["105"])
        #expect(words("a hundred people") == ["100", "people"])
        #expect(words("twenty-six") == ["26"])
        #expect(words("twenty five hundred") == ["2500"])
        #expect(words("nineteen hundred eighty four") == ["1984"])
        #expect(words("five hundred thousand") == ["500000"])
        #expect(words("two million") == ["2000000"])
        #expect(words("zero") == ["0"])
        #expect(words("eleven") == ["11"])
    }

    @Test func numbersReadInPairsOrDigitsAreJoined() {
        #expect(words("nineteen eighty four") == ["1984"])
        #expect(words("twenty oh five") == ["2005"])
        #expect(words("one two three") == ["123"])
    }

    @Test func punctuationBetweenNumberWordsSeparatesNumbers() {
        #expect(words("one, two, three") == ["1", "2", "3"])
        #expect(words("one, two, three") == words("1, 2, 3"))
    }

    @Test func wordsThatAreNumbersOnlyBesideOtherNumberWordsStayWords() {
        #expect(words("oh no") == ["oh", "no"])
        #expect(words("and then") == ["and", "then"])
        #expect(words("a cat") == ["a", "cat"])
        #expect(words("five and six") == ["5", "and", "6"], "and joins numbers only after hundred, thousand or more")
    }

    @Test func digitGroupingAndDecimals() {
        #expect(words("1,250,000") == ["1250000"])
        #expect(words("7.500") == ["7500"])
        #expect(words("7.5") == ["7.5"])
        #expect(words("7,5") == ["7.5"])
        #expect(words("50%") == ["50"], "a percent sign is punctuation, as before")
    }

    @Test func aLongRunOfDigitsReadOneByOneIsKeptWhole() {
        let text = Array(repeating: "nine", count: 40).joined(separator: " ")
        #expect(words(text) == [String(repeating: "9", count: 40)], "joined as text: no integer to overflow")
    }

    /// #363 only ever adds matches: number words punctuation keeps apart on one side and not on the other
    /// compared as they did on main (each pair scored 1.0 there).
    @Test func numberWordsSplitDifferentlyStillMatchAsOnMain() {
        #expect(EchoDeduplicator.textSimilarity("one two three four", "one, two, three, four") == 1)
        #expect(EchoDeduplicator.textSimilarity("twenty, twenty six", "twenty twenty six") == 1)
        #expect(EchoDeduplicator.textContainment("one two three four", "one, two, three, four, five") == 1)
    }

    /// A long string of number words neither traps nor loses its words.
    @Test func aLongNumberWordStringNeverTraps() {
        let text = (["ninety nine"] + Array(repeating: "hundred", count: 12) + ["ninety nine", "thousand", "billion", "billion"])
            .joined(separator: " ")
        let result = words(text)
        #expect(!result.isEmpty)
        #expect(result.joined(separator: " ") == text, "too large: given back as words")
    }

    @Test func aRunTooLargeForAnIntegerIsLeftAsWords() {
        #expect(words("nine hundred billion billion billion") == ["nine", "hundred", "billion", "billion", "billion"])
    }

    // MARK: - Case, punctuation, apostrophes

    @Test func caseAndPunctuationDoNotCount() {
        #expect(words("OK, then!") == ["ok", "then"])
        #expect(words("“Really?” — yes…") == ["really", "yes"])
    }

    @Test func everyApostropheSplitsAsBefore() {
        #expect(words("Don’t go") == words("don't go"), "a typographic apostrophe")
        #expect(words("don't go") == ["don", "t", "go"])
        #expect(words("it's fine") == ["it", "s", "fine"])
    }

    /// Contractions are not expanded nor joined: either way, measured on real transcripts, made short lines
    /// of the user's match long remote lines ("she's" bringing an "is"), or lowered true echo under the
    /// threshold. These two lines of the user's must not match the remote line beside them.
    @Test func contractionsAddNoCommonWords() {
        #expect(EchoDeduplicator.textContainment("Is he ready now?", "No, he's not ready yet, why?") < 0.7)
        #expect(EchoDeduplicator.textContainment("So my view is quite simple.",
                                                 "So in my view, that's a simple question for the board.") < 0.7)
        #expect(EchoDeduplicator.textContainment("I'm at the office.", "Are you, you're at the office?") < 0.7)
    }

    @Test func aPossessiveIsNotAContraction() {
        #expect(words("the client's offer") == ["the", "client", "s", "offer"], "as before #363")
    }

    // MARK: - Other languages

    /// Text in the other languages Parley transcribes splits as it did before #363: no number word,
    /// apostrophe or accent of theirs is touched.
    @Test func otherLanguagesSplitAsBefore() {
        let sentences = [
            "C'est l'homme qu'elle a vu aujourd'hui, à midi.",
            "Die Straße ist schön, oder nicht?",
            "Dell'anno scorso non ricordo nulla.",
            "Het is één uur, zo'n beetje.",
            "¿Qué hora es? Son las once.",
            "Mówię, że dokument jest gotowy.",
            "Tämä on hyvä päivä.",
            "Αυτό είναι καλό.",
            "Это хорошо, спасибо.",
        ]
        for sentence in sentences {
            #expect(words(sentence) == legacyWords(sentence), "\(sentence)")
        }
    }

    /// Where an English number word is also a word of another language ("six" in French, "ten" in
    /// Polish or Czech), it is mapped the same way on both sides: no comparison of two lines in that
    /// language changes.
    @Test func otherLanguagesCompareAsBefore() {
        let pairs = [
            ("Mówię, że ten dokument jest gotowy.", "Mówię, że ten dokument nie jest gotowy."),
            ("Il est six heures et demie.", "Il est six heures."),
            ("C'est l'homme qu'elle a vu.", "C'est l'homme qu'il a vu."),
            ("Het is één uur, zo'n beetje.", "Het is twee uur."),
            ("Die Straße ist schön.", "Die Strasse ist schon."),
        ]
        func legacy(_ a: String, _ b: String) -> Double {
            let x = Set(legacyWords(a)), y = Set(legacyWords(b))
            return Double(x.intersection(y).count) / Double(x.union(y).count)
        }
        for (a, b) in pairs {
            #expect(EchoDeduplicator.textSimilarity(a, b) == legacy(a, b), "\(a) / \(b)")
        }
    }

    @Test func accentsStayDistinct() {
        #expect(words("schön") != words("schon"))
        #expect(words("où") != words("ou"))
    }

    // MARK: - Invalid input

    @Test func emptyAndPunctuationOnlyTextHasNoWords() {
        #expect(words("").isEmpty)
        #expect(words("— ... ?!").isEmpty)
        #expect(words("'").isEmpty)
    }
}
