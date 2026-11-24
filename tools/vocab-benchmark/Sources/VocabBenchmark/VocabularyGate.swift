import Foundation

// Custom vocabulary (#340): the rule the benchmark puts on top of FluidAudio's proposals, which of
// the recogniser's words may be rewritten as a vocabulary term. Foundation only, so it can move into
// TranscriberCore unchanged if the rule is ever built (docs/benchmarks/2026-11-24-custom-vocabulary.md).

/// Whether a word is an ordinary English word, as far as a word list can tell.
///
/// The custom vocabulary rewrites a word only when the recogniser INVENTED its spelling ("Sersha",
/// "Kubernetis"): a spelling that is no word at all is the recogniser saying it did not know the
/// word. A listed word or name is what somebody may really have said, so it is never rewritten.
///
/// The list is macOS's `/usr/share/dict/words` (Webster's Second, with its proper names) plus the
/// inflections and the modern and spoken words it lacks. A miss in either direction is safe or
/// cheap: an ordinary word the list does not know only becomes ELIGIBLE (the similarity floor and
/// FluidAudio's acoustic comparison still have to pass), and an invented spelling that happens to be
/// an obscure listed word is left as the recogniser wrote it.
public struct OrdinaryWords: Sendable {
    /// Words listed in lower case, and the supplement.
    private let common: Set<String>
    /// Words listed only with a capital: proper names ("Matthias"), lowercased.
    private let names: Set<String>

    /// `words` as a word list spells them: an entry with a capital and no lower-case twin is a name.
    public init(words: Set<String>) {
        let lower = Set(words.filter { $0 == $0.lowercased() }).union(Self.supplement)
        self.common = lower
        self.names = Set(words.map { $0.lowercased() }).subtracting(lower)
    }

    /// macOS's word list. `nil` when it cannot be read: the vocabulary then stays off, since
    /// without a list every word would be eligible.
    public static let system: OrdinaryWords? = load(from: URL(fileURLWithPath: "/usr/share/dict/words"))

    static func load(from url: URL) -> OrdinaryWords? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let words = Set(text.split(separator: "\n").map(String.init))
        // A truncated or foreign file would make most words "invented": refuse it.
        guard words.count >= 50_000 else { return nil }
        return OrdinaryWords(words: words)
    }

    /// Words every meeting uses that a 1934 dictionary does not hold. Not exhaustive: see the type's note.
    static let supplement: Set<String> = [
        "ok", "okay", "um", "uh", "uhm", "erm", "mm", "hmm", "mhm", "yeah", "yep", "yup", "nope", "nah",
        "gonna", "wanna", "gotta", "kinda", "sorta", "dunno", "lemme", "gimme", "cuz", "alright",
        "email", "online", "offline", "internet", "website", "web", "app", "blog", "laptop", "smartphone",
        "podcast", "software", "database", "download", "upload", "login", "logout", "wifi", "bluetooth",
        "spreadsheet", "roadmap", "backlog", "onboarding", "stakeholder", "timeline", "deadline", "feedback",
        "workflow", "setup", "signup", "startup", "username", "password", "inbox", "homepage", "hashtag",
        "emoji", "chatbot", "metadata", "analytics", "frontend", "backend", "prototype", "teammate",
        "screenshot", "livestream", "webinar", "upsell", "onsite", "offsite", "rollout", "signoff", "handoff",
        "standup", "sync", "async", "config", "repo", "demo", "ping", "tech", "info", "admin", "dev", "ops",
        "euro", "euros", "percent", "tv",
    ]

    /// Whether `word` (one word, any case, punctuation at its edges allowed) is a listed word or
    /// name: something the recogniser can spell, so never rewritten.
    public func isOrdinary(_ word: String) -> Bool {
        isListed(word, countingNames: true)
    }

    /// Whether `word` is a common word, names apart: "grace" and "will" are, "Matthias" is not.
    /// A calendar name that is one is not added to the vocabulary.
    public func isCommonWord(_ word: String) -> Bool {
        isListed(word, countingNames: false)
    }

    /// Whether every word of `phrase` is a spelling no word list holds: the only phrases the
    /// vocabulary may rewrite. False for an empty phrase.
    public func isInventedSpelling(_ phrase: String) -> Bool {
        let parts = phrase.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return !parts.isEmpty && parts.allSatisfy { !isOrdinary(String($0)) }
    }

    private func isListed(_ word: String, countingNames: Bool) -> Bool {
        var text = word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        if text.hasSuffix("'s") || text.hasSuffix("’s") { text.removeLast(2) }
        // Nothing left, a number, or a short word: never a candidate for rewriting.
        guard text.count > 2, !text.contains(where: \.isNumber) else { return true }
        // A contraction ("don't", "we're") is ordinary speech whatever its stem.
        if text.contains("'") || text.contains("’") { return true }
        if text.contains("-") {
            return text.split(separator: "-").allSatisfy { isListed(String($0), countingNames: countingNames) }
        }
        let has: (String) -> Bool = { self.common.contains($0) || (countingNames && self.names.contains($0)) }
        if Self.isListedOrInflected(text, has) { return true }
        // Two words written as one ("headhunter", "snowflakes"): still words somebody said.
        let characters = Array(text)
        if characters.count >= 8 {
            for cut in 4...(characters.count - 4) {
                if has(String(characters[..<cut])), Self.isListedOrInflected(String(characters[cut...]), has) {
                    return true
                }
            }
        }
        return false
    }

    private static func isListedOrInflected(_ text: String, _ has: (String) -> Bool) -> Bool {
        if has(text) { return true }
        for (suffix, replacements) in inflections where text.hasSuffix(suffix) && text.count > suffix.count + 1 {
            let stem = String(text.dropLast(suffix.count))
            for replacement in replacements where has(stem + replacement) { return true }
            // A doubled consonant before the ending: "stopped", "running", "bigger".
            if let last = stem.last, stem.dropLast().last == last, has(String(stem.dropLast())) {
                return true
            }
        }
        return false
    }

    /// An ending, and what may stand in its place in the listed form: "moved" is "move" + "d",
    /// "batteries" is "battery", "making" is "make".
    private static let inflections: [(String, [String])] = [
        ("ies", ["y"]), ("es", ["", "e"]), ("s", [""]),
        ("ied", ["y"]), ("ed", ["", "e"]), ("d", [""]),
        ("ing", ["", "e"]),
        ("ier", ["y"]), ("iest", ["y"]), ("er", ["", "e"]), ("est", ["", "e"]),
        ("ily", ["y"]), ("ly", [""]),
    ]
}

/// The rule a vocabulary replacement has to pass before it is applied. FluidAudio proposes (string
/// similarity plus its CTC acoustic comparison), or `TextOnlyRule` does; this decides.
///
/// Measured in docs/benchmarks/2026-11-24-custom-vocabulary.md: with FluidAudio's thresholds alone,
/// no setting gave a useful recall without writing terms over ordinary words. With this rule on top
/// an ordinary word cannot be rewritten at all, whatever the thresholds.
public struct VocabularyGate: Sendable {
    /// A term shorter than this stays out of the vocabulary: short terms ("Jira", "Wren") are the ones
    /// a mangled longer name gets mistaken for.
    public static let minimumTermLetters = 5
    /// The lowest string similarity (0...1) between what was heard and the term.
    public static let defaultMinSimilarity = 0.6

    public enum Verdict: String, Equatable, Sendable {
        case accept
        /// The heard phrase holds a dictionary word: somebody may really have said it.
        case heardOrdinaryWord
        case termTooShort
        case belowSimilarity
    }

    let words: OrdinaryWords
    let minSimilarity: Double

    public init(words: OrdinaryWords, minSimilarity: Double = VocabularyGate.defaultMinSimilarity) {
        self.words = words
        // Never below FluidAudio's own floor, never above "identical".
        self.minSimilarity = min(1, max(0.5, minSimilarity))
    }

    /// Whether `term` is long enough to be in the vocabulary. Counted in letters, so a term of
    /// several words ("Ana Li") is judged on what is spoken, not on its spaces.
    public static func isLongEnough(_ term: String) -> Bool {
        term.filter(\.isLetter).count >= minimumTermLetters
    }

    /// Whether FluidAudio's proposal to write `term` where the recogniser wrote `heard` is applied.
    public func verdict(heard: String, term: String, similarity: Double) -> Verdict {
        guard Self.isLongEnough(term) else { return .termTooShort }
        guard similarity.isFinite, similarity >= minSimilarity else { return .belowSimilarity }
        return words.isInventedSpelling(heard) ? .accept : .heardOrdinaryWord
    }
}
