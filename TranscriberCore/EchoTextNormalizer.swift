import Foundation

/// The words the echo check compares (#363): both sides' text in one form, so the same speech written
/// two ways by the two channels' recognisers still matches. On a loudspeaker call ASR wrote "one ninety
/// five" on the mic and "195" on the system side; word overlap fell under the threshold and the echo lines
/// stayed visible under the user's name.
///
/// The rules, applied to both sides alike:
/// - **Case and punctuation** do not count: lower-cased, cut at anything that is not a letter or a digit,
///   as before. Accents are kept ("schön" is not "schon"): folding them would make different words equal.
/// - **Digit groups**: "7,500" and "7.500" are "7500" (a separator followed by exactly three digits); any
///   other separator between digits is a decimal point ("7,5" and "7.5" are "7.5").
/// - **Apostrophes** of every form (', ’, ‘, ʼ) split a word as before, so "don’t" and "don't" agree.
///   Contractions are not otherwise normalised (see `expanded`: both ways were measured, and both did harm).
/// - **English number words** become digits. A run of them, unbroken by punctuation other than a hyphen, is
///   one number: evaluated with its scale words ("seven thousand five hundred" is 7500, "one hundred and
///   five" 105, "a hundred" 100), else read in pairs or digit by digit and joined ("one ninety five" is 195,
///   "twenty twenty six" 2026, "twenty oh five" 2005, "one two three" 123). "and", "oh" and "a" count only
///   beside number words; elsewhere they are words.
///
/// Limits: English only for numbers (the other 24 languages' number words are left as they
/// are, so their comparisons are unchanged; where an English number word is also one of theirs — French
/// "six", Polish "ten" — it maps the same way on both sides). Not handled: ordinals ("twenty fifth"),
/// decimals read aloud ("seven point five"), times ("one fifteen" against "1:15"), currencies ("five
/// dollars" against "$5"), percentages ("fifty percent" against "50%"), contractions ("it's" against "it is").
/// A run of number words two separate numbers were said in ("one, ninety five" said
/// without a pause) reads as one number; the other side's digits then decide whether they match.
public enum EchoTextNormalizer {

    /// `text`'s words in the compared form, in order.
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flushRun() {
            if !run.isEmpty { out.append(contentsOf: numbers(in: run)); run.removeAll() }
        }
        for token in tokens(of: text) {
            if token.breaksRun { flushRun() }
            for word in expanded(token.text) {
                if isNumberAtom(word) {
                    run.append(word)
                } else {
                    flushRun()
                    out.append(word)
                }
            }
        }
        flushRun()
        return out
    }

    // MARK: - Tokens

    private struct Token {
        var text: String
        /// Punctuation other than whitespace or a hyphen came before it: a number run ends there.
        var breaksRun: Bool
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]

    private static func tokens(of text: String) -> [Token] {
        let chars = Array(text.lowercased())
        var tokens: [Token] = []
        var current = ""
        var pendingBreak = false
        func emit() {
            if !current.isEmpty { tokens.append(Token(text: current, breaksRun: pendingBreak)); pendingBreak = false }
            current = ""
        }
        for i in chars.indices {
            let c = chars[i]
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if apostrophes.contains(c), previous?.isLetter == true, next?.isLetter == true {
                current.append("'")
            } else if c == "," || c == ".", previous?.isNumber == true, next?.isNumber == true, !current.isEmpty {
                current.append(c)
            } else {
                emit()
                if !c.isWhitespace && c != "-" && c != "\u{2010}" && c != "\u{2011}" { pendingBreak = true }
            }
        }
        emit()
        return tokens.map { Token(text: canonicalDigits($0.text), breaksRun: $0.breaksRun) }
    }

    /// "7,500" / "7.500" → "7500"; "7,5" → "7.5". Anything that is not digits with separators is returned as is.
    private static func canonicalDigits(_ token: String) -> String {
        guard token.contains(where: { $0 == "," || $0 == "." }),
              token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }) else { return token }
        let groups = token.split(whereSeparator: { $0 == "," || $0 == "." })
        if groups.count > 1, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) {
            return groups.joined()
        }
        return token.replacingOccurrences(of: ",", with: ".")
    }

    // MARK: - Apostrophes

    /// A token's words: split at its apostrophes, as before #363 ("it's" is "it" "s", "l'homme" "l" "homme").
    ///
    /// English contractions are deliberately NOT normalised. Both ways were measured on real transcripts:
    /// expanding "she's" into "she is" adds common words a long remote line nearly always holds, and short
    /// lines of the user's then looked "contained" in it (new false flags); joining a contraction and its
    /// long form into one token ("she_is") also joins "who is" / "who are" and the like, which lowered true
    /// echo lines under the threshold and made "I'm back" match "you're back". Both channels are read by the
    /// same recogniser, which writes a contraction the same way on both.
    private static func expanded(_ token: String) -> [String] {
        token.split(separator: "'").map(String.init)
    }

    // MARK: - Numbers

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    /// Number words only beside other number words; decided in `numbers(in:)`.
    private static let joiners: Set<String> = ["and", "oh", "a"]

    private static func isNumberAtom(_ word: String) -> Bool {
        units[word] != nil || teens[word] != nil || tens[word] != nil || scales[word] != nil || joiners.contains(word)
    }

    private enum Value {
        /// 0-99.
        case small(Int)
        case scale(Int)
    }

    /// A run's piece: a number value with the words it was read from, or a word kept as a word ("and",
    /// "oh", "a" where they are not part of a number).
    private enum Atom {
        case number(Value, words: [String])
        case word(String)
    }

    /// A run of number-word candidates (no punctuation inside) as the words that replace it.
    private static func numbers(in run: [String]) -> [String] {
        // 1. Atoms: tens + unit is one small number; joiners only where they join numbers.
        var atoms: [Atom] = []
        var i = 0
        func isUnit(_ index: Int) -> Bool { index < run.count && units[run[index]] != nil }
        func isSmallStart(_ index: Int) -> Bool {
            index < run.count && (units[run[index]] != nil || teens[run[index]] != nil || tens[run[index]] != nil)
        }
        func previousIs(scale: Bool) -> Bool {
            guard case .number(let value, _)? = atoms.last else { return false }
            if case .scale = value { return scale } else { return !scale }
        }
        // "and" inside a number says nothing; its word is kept with the next number, so a stretch that cannot
        // be read is given back word for word.
        var carried: [String] = []
        func appendNumber(_ value: Value, _ words: [String]) {
            atoms.append(.number(value, words: carried + words))
            carried.removeAll()
        }
        while i < run.count {
            let word = run[i]
            if let t = tens[word] {
                if isUnit(i + 1), let u = units[run[i + 1]], u > 0 {
                    appendNumber(.small(t + u), [word, run[i + 1]]); i += 2
                } else {
                    appendNumber(.small(t), [word]); i += 1
                }
            } else if let n = teens[word] ?? units[word] {
                appendNumber(.small(n), [word]); i += 1
            } else if let k = scales[word] {
                appendNumber(.scale(k), [word]); i += 1
            } else if word == "and", previousIs(scale: true), isSmallStart(i + 1) {
                carried.append(word); i += 1  // "one hundred and five"
            } else if word == "oh", previousIs(scale: false), isUnit(i + 1) {
                appendNumber(.small(0), [word]); i += 1  // "twenty oh five"
            } else if word == "a", i + 1 < run.count, scales[run[i + 1]] != nil {
                appendNumber(.small(1), [word]); i += 1  // "a hundred"
            } else {
                atoms.append(.word(word)); i += 1
            }
        }
        // 2. Each stretch of numeric atoms is one number (or, with a scale, may be several).
        var out: [String] = []
        var stretch: [(value: Value, words: [String])] = []
        func flush() {
            guard !stretch.isEmpty else { return }
            out.append(contentsOf: evaluate(stretch.map(\.value)) ?? stretch.flatMap(\.words))
            stretch.removeAll()
        }
        for atom in atoms {
            switch atom {
            case .word(let w): flush(); out.append(w)
            case .number(let value, let words): stretch.append((value, words))
            }
        }
        flush()
        return out
    }

    /// A stretch of numbers and scales as digit strings; nil when a value does not fit an integer.
    private static func evaluate(_ stretch: [Value]) -> [String]? {
        let hasScale = stretch.contains { if case .scale = $0 { return true } else { return false } }
        if !hasScale {
            // Read in pairs or digit by digit: joined as text, so no length overflows.
            return [stretch.map { if case .small(let n) = $0 { return String(n) } else { return "" } }.joined()]
        }
        var values: [String] = []
        var total = 0, current = 0
        var lastWasSmall = false, lastWasBigScale = false
        for value in stretch {
            switch value {
            case .small(let n):
                if lastWasSmall {
                    let (sum, overflow) = total.addingReportingOverflow(current)
                    if overflow { return nil }
                    values.append(String(sum))
                    total = 0; current = 0
                }
                let (added, overflow) = current.addingReportingOverflow(n)
                if overflow { return nil }
                current = added
                lastWasSmall = true; lastWasBigScale = false
            case .scale(let k) where k == 100:
                let (product, overflow) = (current == 0 ? 1 : current).multipliedReportingOverflow(by: 100)
                if overflow { return nil }
                current = product
                lastWasSmall = false; lastWasBigScale = false
            case .scale(let k):
                if lastWasBigScale, current == 0 {
                    let (product, overflow) = total.multipliedReportingOverflow(by: k)
                    if overflow { return nil }
                    total = product
                } else {
                    let (product, overflow) = (current == 0 ? 1 : current).multipliedReportingOverflow(by: k)
                    if overflow { return nil }
                    let (sum, overflowSum) = total.addingReportingOverflow(product)
                    if overflowSum { return nil }
                    total = sum
                    current = 0
                }
                lastWasSmall = false; lastWasBigScale = true
            }
        }
        let (sum, overflow) = total.addingReportingOverflow(current)
        if overflow { return nil }
        values.append(String(sum))
        return values
    }
}
