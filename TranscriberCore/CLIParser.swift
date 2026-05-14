import Foundation

public enum SplitMode: Equatable {
    /// Force L/R channel split (app convention: L=mic, R=system)
    case split
    /// Force single-stream processing (external recording)
    case noSplit
    /// Prompt the user interactively
    case ask
}

public struct TranscribeOptions {
    public let inputs: [String]
    public let outputDir: String?
    public let format: String
    public let noDiarize: Bool
    public let engine: String?
    public let debug: Bool
    public let splitMode: SplitMode
}

public struct BenchmarkOptions {
    public let transcriptionOnly: Bool
    public let diarizationOnly: Bool
}

public struct SummarizeOptions {
    public let input: String
    public let provider: String?
    public let endpoint: String?
    public let apiKey: String?
    public let model: String?
    public let contextLength: Int?
}

public enum CLICommand {
    case transcribe(TranscribeOptions)
    case rename(String)
    case renameGUI(String)
    case benchmark(BenchmarkOptions)
    case summarize(SummarizeOptions)
}

public enum CLIParser {

    public enum ParseError: LocalizedError {
        case missingSubcommand
        case unknownSubcommand(String)
        case missingRequiredArg(String)
        case conflictingFlags(String)

        public var errorDescription: String? {
            switch self {
            case .missingSubcommand: return "Usage: AudioTranscribe <transcribe|rename|benchmark|summarize>"
            case .unknownSubcommand(let cmd): return "Unknown subcommand: \(cmd)"
            case .missingRequiredArg(let arg): return "Missing required argument: \(arg)"
            case .conflictingFlags(let msg): return "Conflicting flags: \(msg)"
            }
        }
    }

    public static func parse(_ args: [String]) throws -> CLICommand? {
        guard args.count > 1 else { return nil }

        let subcommand = args[1]
        let rest = Array(args.dropFirst(2))

        switch subcommand {
        case "transcribe":
            return .transcribe(try parseTranscribe(rest))
        case "rename":
            return .rename(try parseRename(rest))
        case "rename-gui":
            return .renameGUI(try parseRename(rest))
        case "benchmark":
            return .benchmark(parseBenchmark(rest))
        case "summarize":
            return .summarize(try parseSummarize(rest))
        default:
            throw ParseError.unknownSubcommand(subcommand)
        }
    }

    private static func parseTranscribe(_ args: [String]) throws -> TranscribeOptions {
        var inputs: [String] = []
        var outputDir: String?
        var format = "json"
        var noDiarize = false
        var engine: String?
        var debug = false
        var hasSplit = false
        var hasNoSplit = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i", "--input":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                inputs.append(args[i])
            case "--output-dir":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--output-dir") }
                outputDir = args[i]
            case "-f", "--format":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-f") }
                format = args[i]
            case "--no-diarize":
                noDiarize = true
            case "--engine":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--engine") }
                engine = args[i]
            case "--debug":
                debug = true
            case "--split":
                hasSplit = true
            case "--no-split":
                hasNoSplit = true
            default:
                break
            }
            i += 1
        }

        guard !inputs.isEmpty else { throw ParseError.missingRequiredArg("-i") }

        if hasSplit && hasNoSplit {
            throw ParseError.conflictingFlags("--split and --no-split cannot be used together")
        }

        let splitMode: SplitMode
        if hasSplit { splitMode = .split }
        else if hasNoSplit { splitMode = .noSplit }
        else { splitMode = .ask }

        return TranscribeOptions(
            inputs: inputs, outputDir: outputDir, format: format,
            noDiarize: noDiarize, engine: engine, debug: debug,
            splitMode: splitMode
        )
    }

    private static func parseRename(_ args: [String]) throws -> String {
        var input: String?
        var i = 0
        while i < args.count {
            if args[i] == "-i" || args[i] == "--input" {
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                input = args[i]
            }
            i += 1
        }
        guard let input else { throw ParseError.missingRequiredArg("-i") }
        return input
    }

    private static func parseBenchmark(_ args: [String]) -> BenchmarkOptions {
        BenchmarkOptions(
            transcriptionOnly: args.contains("--transcription-only"),
            diarizationOnly: args.contains("--diarization-only")
        )
    }

    private static func parseSummarize(_ args: [String]) throws -> SummarizeOptions {
        var input: String?
        var provider: String?
        var endpoint: String?
        var apiKey: String?
        var model: String?
        var contextLength: Int?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i", "--input":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                input = args[i]
            case "--provider":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--provider") }
                provider = args[i]
            case "--endpoint":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--endpoint") }
                endpoint = args[i]
            case "--api-key":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--api-key") }
                apiKey = args[i]
            case "--model":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--model") }
                model = args[i]
            case "--context-length":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--context-length") }
                contextLength = Int(args[i])
            default:
                break
            }
            i += 1
        }

        guard let input else { throw ParseError.missingRequiredArg("-i") }
        return SummarizeOptions(
            input: input, provider: provider, endpoint: endpoint,
            apiKey: apiKey, model: model, contextLength: contextLength
        )
    }
}
