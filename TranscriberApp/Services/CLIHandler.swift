import Foundation
import os
import TranscriberCore

enum CLIHandler {

    static func run() -> Never {
        let args = CommandLine.arguments

        guard let command = try? CLIParser.parse(args) else {
            printUsage()
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                switch command {
                case .transcribe(let opts):
                    try await handleTranscribe(opts)
                case .rename(let path):
                    try handleRename(path)
                case .benchmark(let opts):
                    try await handleBenchmark(opts)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }

    private static func handleTranscribe(_ opts: TranscribeOptions) async throws {
        let config = ConfigManager.shared.config
        let model = opts.model ?? config.whisperModel
        let storagePath = ModelManager.resolveStoragePath(config.modelStoragePath)

        // Validate inputs exist
        let inputURLs = opts.inputs.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.fileNotFound(url.path)
            }
        }

        // Validate model downloaded
        let modelDir = storagePath.appendingPathComponent(model)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw CLIError.modelNotDownloaded(model)
        }

        let systemAudio = inputURLs[0]
        let micAudio = inputURLs.count > 1 ? inputURLs[1] : nil

        let outputDir: URL
        if let output = opts.output {
            outputDir = URL(fileURLWithPath: output).deletingLastPathComponent()
        } else {
            outputDir = systemAudio.deletingLastPathComponent()
        }

        let runner = TranscriptionRunner()
        if !opts.noDiarize {
            runner.setDiarizer(NativeSpeakerKitDiarizer())
        }

        var runConfig = config
        runConfig.whisperModel = model
        runConfig.outputFormat = opts.format

        let result = try await runner.run(
            systemAudio: systemAudio,
            micAudio: micAudio,
            outputDirectory: outputDir,
            config: runConfig
        )

        print("Output saved to: \(result.jsonPath.path)")
    }

    private static func handleRename(_ jsonPathStr: String) throws {
        let jsonPath = URL(fileURLWithPath: jsonPathStr)
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw CLIError.fileNotFound(jsonPathStr)
        }
        // CLIRename will be implemented in Task 16
        print("Rename not yet implemented")
    }

    private static func handleBenchmark(_ opts: BenchmarkOptions) async throws {
        let benchmarkDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".audio-transcribe/benchmark")

        guard FileManager.default.fileExists(atPath: benchmarkDir.path) else {
            throw CLIError.noBenchmarkFiles
        }

        print("Benchmark running from: \(benchmarkDir.path)")
        print("(Benchmark execution to be fully implemented)")
    }

    private static func printUsage() {
        let usage = """
        Usage: AudioTranscribe <subcommand> [options]

        Subcommands:
          transcribe  Transcribe audio files
            -i <file>        Input audio file (required, can specify twice for dual-stream)
            -o <file>        Output file path (default: auto from input name)
            -f <format>      Output format: json, srt, txt (default: json)
            -l <lang>        Force language code (auto-detect if omitted)
            -s <count>       Number of speakers (auto-detect if omitted)
            --model <name>   Whisper model (default: from config)
            --no-diarize     Skip speaker diarization

          rename      Rename speakers in a transcript
            -i <file>        Input JSON transcript (required)

          benchmark   Run performance benchmark
            --transcription-only   Only benchmark transcription
            --diarization-only     Only benchmark diarization
        """
        print(usage)
    }

    enum CLIError: LocalizedError {
        case fileNotFound(String)
        case modelNotDownloaded(String)
        case noBenchmarkFiles

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .modelNotDownloaded(let model): return "Model '\(model)' not downloaded. Run the app first to download it."
            case .noBenchmarkFiles: return "No benchmark files found in ~/.audio-transcribe/benchmark/"
            }
        }
    }
}
