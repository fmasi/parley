import Foundation

public struct TranscribeOptions {
    public let inputs: [String]
    public let output: String?
    public let format: String
    public let language: String?
    public let noDiarize: Bool
    public let engine: String?
    public let speakers: Int?
}

public struct BenchmarkOptions {
    public let transcriptionOnly: Bool
    public let diarizationOnly: Bool
}

public enum CLICommand {
    case transcribe(TranscribeOptions)
    case rename(String)
    case benchmark(BenchmarkOptions)
}

public enum CLIParser {

    public enum ParseError: LocalizedError {
        case missingSubcommand
        case unknownSubcommand(String)
        case missingRequiredArg(String)

        public var errorDescription: String? {
            switch self {
            case .missingSubcommand: return "Usage: AudioTranscribe <transcribe|rename|benchmark>"
            case .unknownSubcommand(let cmd): return "Unknown subcommand: \(cmd)"
            case .missingRequiredArg(let arg): return "Missing required argument: \(arg)"
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
        case "benchmark":
            return .benchmark(parseBenchmark(rest))
        default:
            throw ParseError.unknownSubcommand(subcommand)
        }
    }

    private static func parseTranscribe(_ args: [String]) throws -> TranscribeOptions {
        var inputs: [String] = []
        var output: String?
        var format = "json"
        var language: String?
        var noDiarize = false
        var engine: String?
        var speakers: Int?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-i", "--input":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
                inputs.append(args[i])
            case "-o", "--output":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-o") }
                output = args[i]
            case "-f", "--format":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-f") }
                format = args[i]
            case "-l", "--language":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-l") }
                language = args[i]
            case "--no-diarize":
                noDiarize = true
            case "--engine":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("--engine") }
                engine = args[i]
            case "-s", "--speakers":
                i += 1
                guard i < args.count else { throw ParseError.missingRequiredArg("-s") }
                speakers = Int(args[i])
            default:
                break
            }
            i += 1
        }

        guard !inputs.isEmpty else { throw ParseError.missingRequiredArg("-i") }

        return TranscribeOptions(
            inputs: inputs, output: output, format: format,
            language: language, noDiarize: noDiarize,
            engine: engine, speakers: speakers
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
}
