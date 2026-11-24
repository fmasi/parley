import FluidAudio
import Foundation

// Custom-vocabulary benchmark (#340). See README.md beside Package.swift, and
// docs/benchmarks/2026-11-24-custom-vocabulary.md for the results.
//
//   vocab-benchmark generate <workdir>            speak the corpus with `say` (16 kHz mono WAV)
//   vocab-benchmark run <workdir> [--ctc 110m|06b] [--min-term-length N]
//                                                 transcribe, rescore across the sweep, score
//   vocab-benchmark textonly <workdir> [results.json]
//                                                 the control: the rule with no CTC model, on a run's transcripts

// MARK: - Text helpers

func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "-" })
        .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        .filter { !$0.isEmpty }
}

func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
        return true
    }
    // A term the transcript wrote as one word in two, or the reverse ("Hub Spot" / "HubSpot"),
    // is not the term as listed: only the listed spelling counts.
    return false
}

func indicesOfSequence(_ haystack: [String], _ needle: [String]) -> Set<Int> {
    guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
        return Set(start..<(start + needle.count))
    }
    return []
}

/// Levenshtein alignment: for each hypothesis word, the reference index it lines up with
/// (a match or a substitution), or nil when it is an insertion.
func align(hypothesis: [String], reference: [String]) -> [Int?] {
    let h = hypothesis.count
    let r = reference.count
    var cost = Array(repeating: Array(repeating: 0, count: r + 1), count: h + 1)
    for i in 0...h { cost[i][0] = i }
    for j in 0...r { cost[0][j] = j }
    if h > 0 && r > 0 {
        for i in 1...h {
            for j in 1...r {
                let substitution = cost[i - 1][j - 1] + (hypothesis[i - 1] == reference[j - 1] ? 0 : 1)
                cost[i][j] = min(substitution, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
    }
    var mapping = [Int?](repeating: nil, count: h)
    var i = h
    var j = r
    while i > 0 && j > 0 {
        let substitution = cost[i - 1][j - 1] + (hypothesis[i - 1] == reference[j - 1] ? 0 : 1)
        if cost[i][j] == substitution {
            mapping[i - 1] = j - 1
            i -= 1
            j -= 1
        } else if cost[i][j] == cost[i - 1][j] + 1 {
            i -= 1
        } else {
            j -= 1
        }
    }
    return mapping
}

// MARK: - Generate

func generate(workdir: URL) throws {
    let audioDir = workdir.appendingPathComponent("audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    let utterances = Corpus.utterances()
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: 6)
    let queue = DispatchQueue(label: "say", attributes: .concurrent)
    for utterance in utterances {
        let output = audioDir.appendingPathComponent("\(utterance.id).wav")
        if FileManager.default.fileExists(atPath: output.path) { continue }
        semaphore.wait()
        group.enter()
        queue.async {
            defer {
                semaphore.signal()
                group.leave()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [
                "-v", utterance.voice, "-o", output.path, "--data-format=LEI16@16000", utterance.text,
            ]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                FileHandle.standardError.write(Data("say failed for \(utterance.id): \(error)\n".utf8))
            }
        }
    }
    group.wait()
    let made = try FileManager.default.contentsOfDirectory(atPath: audioDir.path).filter { $0.hasSuffix(".wav") }.count
    print("\(made) of \(utterances.count) utterances in \(audioDir.path)")
}

// MARK: - Run

struct SweepConfig: Hashable, Codable {
    let minSimilarity: Float
    /// Context-biasing weight: what a term's score is raised by before it is compared with the
    /// transcribed words' own. nil = FluidAudio's default for the vocabulary size (4.5).
    let cbw: Float?
    let gate: Bool
}

struct Substitution: Codable {
    let utterance: String
    let kind: Corpus.Kind
    let heard: String
    let written: String
    let similarity: Float
    let origin: String
    let vocabularyScore: Float?
    let originalScore: Float?
    let boost: Float?
    /// The lowest decoder confidence among the replaced tokens.
    let heardConfidence: Float?
    let verdict: String
}

struct CategoryCount: Codable {
    var utterances = 0
    var baselineHits = 0
    var boostedHits = 0
}

struct Stats: Codable {
    var config: SweepConfig
    var positives = 0
    var baselineHits = 0
    var boostedHits = 0
    var fixed = 0
    var broken = 0
    var byCategory: [String: CategoryCount] = [:]
    var trueReplacements = 0
    var falseOnPositive = 0
    var falseOnFiller = 0
    var falseOnHardNegative = 0
    /// An ordinary word that only gained the term's capital letter ("will" -> "Will").
    var caseOnlyOnOrdinaryWord = 0
    /// Every replacement made, with its verdict and the evidence behind it.
    var applied: [Substitution] = []

    var falseSubstitutions: Int { falseOnPositive + falseOnFiller + falseOnHardNegative }
}

final class Flag: @unchecked Sendable {
    var value = false
}

func run(workdir: URL, variant: CtcModelVariant, minTermLength: Int) async throws {
    let audioDir = workdir.appendingPathComponent("audio", isDirectory: true)
    let utterances = Corpus.utterances()

    print("Loading Parakeet TDT v3…")
    let asrModels = try await AsrModels.downloadAndLoad()
    let asr = AsrManager()
    try await asr.loadModels(asrModels)

    // The CTC model goes into the work directory, not FluidAudio's shared cache: the benchmark
    // must not make Parley on this Mac look as if Setup had already downloaded it.
    let ctcDir = workdir.appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent(variant.repo.folderName, isDirectory: true)
    print("Loading \(variant.displayName) from \(ctcDir.path)…")
    try await CtcModels.download(to: ctcDir, variant: variant)
    let ctcModels = try await CtcModels.load(from: ctcDir, variant: variant)

    let tokenizer = try await CtcTokenizer.load(from: ctcDir)
    // Terms shorter than `minTermLength` letters stay out of the vocabulary; the utterances that speak
    // them stay in the corpus, so recall is still counted over all 780.
    let terms = Corpus.terms.filter { $0.text.count >= minTermLength }.map { CustomVocabularyTerm(text: $0.text, ctcTokenIds: tokenizer.encode($0.text)) }
    let vocabulary = CustomVocabularyContext(terms: terms)
    let blankId = ctcModels.vocabulary.count
    let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
    let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count)
    print("Vocabulary: \(terms.count) terms; size defaults: minSimilarity \(sizeConfig.minSimilarity), cbw \(sizeConfig.cbw)")

    // The rule on top (VocabularyGate.swift): terms under five letters stay out of the gated vocabulary,
    // and a replacement is applied only where the recogniser invented a spelling.
    guard let wordList = OrdinaryWords.system else {
        throw NSError(
            domain: "VocabBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "no /usr/share/dict/words"])
    }

    let gatedTerms = terms.filter { VocabularyGate.isLongEnough($0.text) }
    let refused = terms.filter { !VocabularyGate.isLongEnough($0.text) }.map(\.text)
    print("The rule leaves out \(refused.count) short terms: \(refused.joined(separator: ", "))")
    let gatedSizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: gatedTerms.count)
    let rescorers: [Bool: VocabularyRescorer] = [
        true: try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: CustomVocabularyContext(terms: gatedTerms), ctcModelDirectory: ctcDir),
        false: try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocabulary, ctcModelDirectory: ctcDir),
    ]

    let similarities: [Float] = [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00]
    let weights: [Float?] = [nil, 0.0]
    var configs: [SweepConfig] = []
    for rescue in [false, true] {
        for weight in weights {
            for similarity in similarities {
                configs.append(SweepConfig(minSimilarity: similarity, cbw: weight, gate: rescue))
            }
        }
    }
    var stats = configs.map { Stats(config: $0) }

    var audioSeconds = 0.0
    var asrSeconds = 0.0
    var ctcSeconds = 0.0
    var rescoreSeconds = 0.0
    var ordinaryWords = 0
    var blankFrames = 0
    var totalFrames = 0
    var legacyTextMismatches = 0
    var baselineTranscripts: [[String: String]] = []
    let converter = AudioConverter()
    let clock = ContinuousClock()

    for (number, utterance) in utterances.enumerated() {
        let url = audioDir.appendingPathComponent("\(utterance.id).wav")
        let samples = try converter.resampleAudioFile(url)
        audioSeconds += Double(samples.count) / 16_000

        var decoderState = try TdtDecoderState()
        let asrStart = clock.now
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        asrSeconds += Double((clock.now - asrStart).components.attoseconds) / 1e18
            + Double((clock.now - asrStart).components.seconds)
        let timings = result.tokenTimings ?? []
        baselineTranscripts.append(["id": utterance.id, "reference": utterance.text, "heard": result.text])

        let reference = normalizedWords(utterance.text)
        let termWords = utterance.term.map(normalizedWords) ?? []
        let termReferenceIndices = indicesOfSequence(reference, termWords)
        ordinaryWords += reference.count - termReferenceIndices.count

        guard !timings.isEmpty else { continue }

        let ctcStart = clock.now
        let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocabulary)
        ctcSeconds += Double((clock.now - ctcStart).components.attoseconds) / 1e18
            + Double((clock.now - ctcStart).components.seconds)
        for frame in spot.logProbs {
            totalFrames += 1
            if let best = frame.indices.max(by: { frame[$0] < frame[$1] }), best == blankId { blankFrames += 1 }
        }
        guard !spot.logProbs.isEmpty else { continue }

        // FluidAudio's own rewriting path for the first configuration: timed (the cost of one rescoring
        // pass) and compared below with applying its candidates ourselves.
        let firstConfig = configs[0]
        let rescoreStart = clock.now
        let legacyText = rescorers[firstConfig.gate].map {
            $0.ctcTokenRescore(
                transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
                frameDuration: spot.frameDuration, cbw: firstConfig.cbw ?? sizeConfig.cbw, marginSeconds: 0.5,
                minSimilarity: firstConfig.minSimilarity
            ).text
        }
        rescoreSeconds += Double((clock.now - rescoreStart).components.attoseconds) / 1e18
            + Double((clock.now - rescoreStart).components.seconds)
        let mismatch = Flag()

        // Each configuration writes only its own element, so the sweep can use every core.
        stats.withUnsafeMutableBufferPointer { stats in
          DispatchQueue.concurrentPerform(iterations: stats.count) { index in
            let config = stats[index].config
            guard let rescorer = rescorers[config.gate] else { return }
            let output = rescorer.ctcTokenEvaluateCandidates(
                transcript: result.text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: config.cbw ?? (config.gate ? gatedSizeConfig.cbw : sizeConfig.cbw),
                marginSeconds: 0.5,
                minSimilarity: config.minSimilarity
            )
            let gate = VocabularyGate(words: wordList, minSimilarity: Double(config.minSimilarity))
            let applied = output.candidates
                .filter { $0.legacyOutcome == .applied && !$0.wordRange.isEmpty }
                .filter {
                    !config.gate
                        || gate.verdict(
                            heard: $0.basePhrase, term: $0.canonicalTerm, similarity: Double($0.similarity)) == .accept
                }
                .sorted { $0.wordRange.lowerBound < $1.wordRange.lowerBound }

            // The transcript as Parley would write it: the decoder's words, with each applied
            // candidate's span replaced by its term.
            var boosted: [String] = []
            var replacementSpans: [(candidate: VocabularyRescorer.CandidateEvidence, range: Range<Int>)] = []
            var cursor = 0
            for candidate in applied where candidate.wordRange.lowerBound >= cursor {
                for word in output.baseWords[cursor..<candidate.wordRange.lowerBound] {
                    boosted.append(contentsOf: normalizedWords(word))
                }
                let start = boosted.count
                boosted.append(contentsOf: normalizedWords(candidate.canonicalTerm))
                replacementSpans.append((candidate, start..<boosted.count))
                cursor = candidate.wordRange.upperBound
            }
            for word in output.baseWords[min(cursor, output.baseWords.count)...] {
                boosted.append(contentsOf: normalizedWords(word))
            }
            let baseline = output.baseWords.flatMap(normalizedWords)

            if index == 0, let legacyText, normalizedWords(legacyText) != boosted { mismatch.value = true }

            if utterance.kind == .positive, let category = utterance.category {
                let baseHit = containsSequence(baseline, termWords)
                let boostHit = containsSequence(boosted, termWords)
                stats[index].positives += 1
                stats[index].baselineHits += baseHit ? 1 : 0
                stats[index].boostedHits += boostHit ? 1 : 0
                stats[index].fixed += (!baseHit && boostHit) ? 1 : 0
                stats[index].broken += (baseHit && !boostHit) ? 1 : 0
                var count = stats[index].byCategory[category.rawValue] ?? CategoryCount()
                count.utterances += 1
                count.baselineHits += baseHit ? 1 : 0
                count.boostedHits += boostHit ? 1 : 0
                stats[index].byCategory[category.rawValue] = count
            }

            let mapping = align(hypothesis: boosted, reference: reference)
            for (candidate, range) in replacementSpans {
                let written = normalizedWords(candidate.canonicalTerm)
                let heard = normalizedWords(candidate.basePhrase)
                let landsOnTerm =
                    written == termWords
                    && range.allSatisfy { position in
                        mapping[position].map { termReferenceIndices.contains($0) } ?? false
                    }
                let verdict: String
                if landsOnTerm {
                    stats[index].trueReplacements += 1
                    verdict = "true"
                } else if heard == written {
                    stats[index].caseOnlyOnOrdinaryWord += 1
                    verdict = "case-only"
                } else {
                    switch utterance.kind {
                    case .positive: stats[index].falseOnPositive += 1
                    case .filler: stats[index].falseOnFiller += 1
                    case .hardNegative: stats[index].falseOnHardNegative += 1
                    }
                    verdict = "false"
                }
                let heardConfidence = candidate.tokenRange.flatMap { range in
                    timings[range].map(\.confidence).min()
                }
                do {
                    stats[index].applied.append(
                        Substitution(
                            utterance: utterance.id, kind: utterance.kind, heard: candidate.basePhrase,
                            written: candidate.canonicalTerm, similarity: candidate.similarity,
                            origin: candidate.origin.rawValue, vocabularyScore: candidate.rawVocabularyCTCScore,
                            originalScore: candidate.rawOriginalCTCScore, boost: candidate.effectiveBoost,
                            heardConfidence: heardConfidence, verdict: verdict))
                }
            }
          }
        }
        if mismatch.value { legacyTextMismatches += 1 }
        if (number + 1) % 100 == 0 { print("  \(number + 1) / \(utterances.count)") }
    }

    // MARK: Report

    let hours = audioSeconds / 3600
    print("")
    print(String(format: "Audio: %.1f min, %d utterances, %d ordinary words", audioSeconds / 60, utterances.count, ordinaryWords))
    print(String(format: "Speed: Parakeet %.0fx real time, CTC + spotting %.0fx real time", audioSeconds / asrSeconds, audioSeconds / ctcSeconds))
    print(String(format: "Rescoring one pass: %.2f s per minute of audio (%d terms)", rescoreSeconds / (audioSeconds / 60), terms.count))
    print(String(format: "CTC frames whose best token is blank: %.1f%% of %d", 100 * Double(blankFrames) / Double(max(totalFrames, 1)), totalFrames))
    print("Utterances where FluidAudio's own rewrite differs from applying its candidates: \(legacyTextMismatches)")
    print("")
    print("| minSimilarity | cbw | Parley rule | recall | fixed | broken | right | wrong: on term sentences | on filler | on sound-alikes | wrong per hour | capital only |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for stat in stats {
        let config = stat.config
        print(
            String(
                format: "| %.2f | %@ | %@ | %.1f%% (%d/%d) | %d | %d | %d | %d | %d | %d | %.1f | %d |",
                config.minSimilarity, config.cbw.map { String(format: "%.1f", $0) } ?? "4.5",
                config.gate ? "on" : "off",
                100 * Double(stat.boostedHits) / Double(max(stat.positives, 1)), stat.boostedHits, stat.positives,
                stat.fixed, stat.broken, stat.trueReplacements, stat.falseOnPositive, stat.falseOnFiller,
                stat.falseOnHardNegative, Double(stat.falseSubstitutions) / hours, stat.caseOnlyOnOrdinaryWord))
    }
    if let first = stats.first {
        print("")
        print(String(format: "Without the vocabulary: recall %.1f%% (%d/%d)", 100 * Double(first.baselineHits) / Double(max(first.positives, 1)), first.baselineHits, first.positives))
        for category in Corpus.Category.allCases {
            if let count = first.byCategory[category.rawValue] {
                print("  \(category.rawValue): \(count.baselineHits)/\(count.utterances)")
            }
        }
    }

    struct Results: Codable {
        let fluidAudio: String
        let ctcVariant: String
        let audioMinutes: Double
        let utterances: Int
        let ordinaryWords: Int
        let asrRealTimeFactor: Double
        let ctcRealTimeFactor: Double
        let blankFrameShare: Double
        let stats: [Stats]
        let transcripts: [[String: String]]
    }
    let results = Results(
        fluidAudio: ProcessInfo.processInfo.environment["FLUIDAUDIO_VERSION"] ?? "0.17.7",
        ctcVariant: variant.rawValue, audioMinutes: audioSeconds / 60, utterances: utterances.count,
        ordinaryWords: ordinaryWords, asrRealTimeFactor: audioSeconds / asrSeconds,
        ctcRealTimeFactor: audioSeconds / ctcSeconds,
        blankFrameShare: Double(blankFrames) / Double(max(totalFrames, 1)),
        stats: stats,
        transcripts: baselineTranscripts)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let suffix = minTermLength > 1 ? "-min\(minTermLength)" : ""
    let output = workdir.appendingPathComponent("results-\(results.fluidAudio)-\(variant.rawValue)\(suffix).json")
    try encoder.encode(results).write(to: output)
    print("\nWrote \(output.path)")
}

// MARK: - Text-only control

/// Scores `TextOnlyRule` on the transcripts a `run` saved: no model, no audio.
func textOnly(workdir: URL, resultsName: String) throws {
    struct Saved: Decodable {
        let transcripts: [[String: String]]
        let audioMinutes: Double
    }
    let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: workdir.appendingPathComponent(resultsName)))
    let heardByID = Dictionary(uniqueKeysWithValues: saved.transcripts.compactMap { row in
        row["id"].flatMap { id in row["heard"].map { (id, $0) } }
    })
    guard let wordList = OrdinaryWords.system else { return }
    let terms = Corpus.terms.map(\.text).filter { VocabularyGate.isLongEnough($0) }
    print("Text-only rule on \(resultsName): \(terms.count) terms, no CTC model")
    print("")
    print("| minSimilarity | recall | fixed | broken | right | wrong: on term sentences | on filler | on sound-alikes | wrong per hour |")
    print("|---|---|---|---|---|---|---|---|---|")
    for floor in [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90] {
        let gate = VocabularyGate(words: wordList, minSimilarity: floor)
        var positives = 0, hits = 0, fixed = 0, broken = 0, right = 0
        var wrong: [Corpus.Kind: Int] = [:]
        var wrongList: [String: Int] = [:]
        for utterance in Corpus.utterances() {
            guard let heard = heardByID[utterance.id] else { continue }
            let words = heard.split(separator: " ").map(String.init)
            let replacements = TextOnlyRule.replacements(words: words, terms: terms, gate: gate)
            var boosted: [String] = []
            var spans: [(TextOnlyRule.Replacement, Range<Int>)] = []
            var cursor = 0
            for replacement in replacements {
                for word in words[cursor..<replacement.range.lowerBound] { boosted.append(contentsOf: normalizedWords(word)) }
                let start = boosted.count
                boosted.append(contentsOf: normalizedWords(replacement.term))
                spans.append((replacement, start..<boosted.count))
                cursor = replacement.range.upperBound
            }
            for word in words[cursor...] { boosted.append(contentsOf: normalizedWords(word)) }
            let baseline = words.flatMap(normalizedWords)
            let reference = normalizedWords(utterance.text)
            let termWords = utterance.term.map(normalizedWords) ?? []
            let termIndices = indicesOfSequence(reference, termWords)
            if utterance.kind == .positive {
                let baseHit = containsSequence(baseline, termWords)
                let boostHit = containsSequence(boosted, termWords)
                positives += 1
                hits += boostHit ? 1 : 0
                fixed += (!baseHit && boostHit) ? 1 : 0
                broken += (baseHit && !boostHit) ? 1 : 0
            }
            let mapping = align(hypothesis: boosted, reference: reference)
            for (replacement, range) in spans {
                let lands = normalizedWords(replacement.term) == termWords
                    && range.allSatisfy { mapping[$0].map { termIndices.contains($0) } ?? false }
                if lands {
                    right += 1
                } else {
                    wrong[utterance.kind, default: 0] += 1
                    wrongList["\(replacement.heard) -> \(replacement.term)", default: 0] += 1
                }
            }
        }
        let wrongTotal = wrong.values.reduce(0, +)
        print(
            String(
                format: "| %.2f | %.1f%% (%d/%d) | %d | %d | %d | %d | %d | %d | %.1f |", floor,
                100 * Double(hits) / Double(max(positives, 1)), hits, positives, fixed, broken, right,
                wrong[.positive] ?? 0, wrong[.filler] ?? 0, wrong[.hardNegative] ?? 0,
                Double(wrongTotal) / (saved.audioMinutes / 60)))
        if floor == 0.6 || floor == 0.7 {
            for (pair, count) in wrongList.sorted(by: { $0.key < $1.key }) { print("    wrong at \(floor): \(count)x \(pair)") }
        }
    }
}

// MARK: - Entry

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2, let command = arguments.first else {
    print("usage: vocab-benchmark generate|run|textonly <workdir> [--ctc 110m|06b] [--min-term-length N]")
    exit(2)
}
let workdir = URL(fileURLWithPath: Array(arguments)[1], isDirectory: true)
do {
    switch command {
    case "generate":
        try generate(workdir: workdir)
    case "textonly":
        try textOnly(workdir: workdir, resultsName: arguments.count >= 3 ? Array(arguments)[2] : "results-0.18.3-ctc110m.json")
    case "run":
        var variant = CtcModelVariant.ctc110m
        if let flag = arguments.firstIndex(of: "--ctc"), arguments.index(after: flag) < arguments.endIndex {
            variant = arguments[arguments.index(after: flag)] == "06b" ? .ctc06b : .ctc110m
        }
        var minTermLength = 1
        if let flag = arguments.firstIndex(of: "--min-term-length"), arguments.index(after: flag) < arguments.endIndex {
            minTermLength = Int(arguments[arguments.index(after: flag)]) ?? 1
        }
        try await run(workdir: workdir, variant: variant, minTermLength: minTermLength)
    default:
        print("unknown command \(command)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("vocab-benchmark failed: \(error)\n".utf8))
    exit(1)
}
