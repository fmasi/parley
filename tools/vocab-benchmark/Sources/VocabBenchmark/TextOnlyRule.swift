import Foundation

// The control experiment: the same gate with NO second model. An invented spelling is replaced by
// the listed term it is closest to in letters. If this does as well as the CTC path, the CTC model
// is not what earns the result.

enum TextOnlyRule {
    static func letters(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 - (edit distance / the longer length): 1 is identical, 0 shares nothing.
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    struct Replacement {
        let range: Range<Int>
        let heard: String
        let term: String
        let similarity: Double
    }

    /// One- and two-word spans made only of invented spellings, each matched to its closest term;
    /// the closest matches win where spans overlap.
    static func replacements(words: [String], terms: [String], gate: VocabularyGate) -> [Replacement] {
        var found: [Replacement] = []
        for length in 1...2 where words.count >= length {
            for start in 0...(words.count - length) {
                let span = words[start..<(start + length)].joined(separator: " ")
                let spanLetters = letters(span)
                var best: (term: String, similarity: Double)?
                for term in terms {
                    let score = similarity(spanLetters, letters(term))
                    if score > (best?.similarity ?? 0) { best = (term, score) }
                }
                guard let best, spanLetters != letters(best.term),
                      gate.verdict(heard: span, term: best.term, similarity: best.similarity) == .accept
                else { continue }
                found.append(Replacement(range: start..<(start + length), heard: span, term: best.term, similarity: best.similarity))
            }
        }
        var taken = Set<Int>()
        var kept: [Replacement] = []
        for candidate in found.sorted(by: { $0.similarity > $1.similarity }) where taken.isDisjoint(with: candidate.range) {
            taken.formUnion(candidate.range)
            kept.append(candidate)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
