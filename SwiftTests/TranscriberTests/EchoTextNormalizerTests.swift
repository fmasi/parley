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
        #expect(words("50%") == words("fifty percent"))
    }

    @Test func aLongRunOfDigitsReadOneByOneIsKeptWhole() {
        let text = Array(repeating: "nine", count: 40).joined(separator: " ")
        #expect(words(text) == [String(repeating: "9", count: 40)], "joined as text: no integer to overflow")
    }

    @Test func aRunTooLargeForAnIntegerIsLeftAsWords() {
        #expect(words("nine hundred billion billion billion") == ["nine", "hundred", "billion", "billion", "billion"])
    }

    // MARK: - Case, punctuation, contractions

    @Test func caseAndPunctuationDoNotCount() {
        #expect(words("OK, then!") == ["ok", "then"])
        #expect(words("“Really?” — yes…") == ["really", "yes"])
    }

    @Test func englishContractionsMatchTheirLongForms() {
        #expect(words("it's fine") == words("it is fine"))
        #expect(words("don't go") == words("do not go"))
        #expect(words("Don’t go") == words("do not go"), "a typographic apostrophe")
        #expect(words("won't") == words("will not"))
        #expect(words("can't") == words("can not"))
        #expect(words("cannot") == words("can not"))
        #expect(words("I'm here") == words("I am here"))
        #expect(words("we're late") == words("we are late"))
        #expect(words("they've left") == words("they have left"))
        #expect(words("you'll see") == words("you will see"))
        #expect(words("let's start") == words("let us start"))
        #expect(words("I'd say") == words("I would say"))
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
