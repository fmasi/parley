import AppKit
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

        // rename-gui needs NSApplication for the NSPanel to be interactive
        if case .renameGUI(let path) = command {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    try await handleRenameGUI(path)
                } catch {
                    fputs("Error: \(error.localizedDescription)\n", stderr)
                }
                exit(0)
            }
            app.run()
            exit(0)
        }

        // Use MainActor task + RunLoop to avoid deadlock — TranscriptionRunner is @MainActor,
        // so DispatchSemaphore.wait() on the main thread would block the actor hop.
        var finished = false
        var exitCode: Int32 = 0

        Task { @MainActor in
            do {
                switch command {
                case .transcribe(let opts):
                    try await handleTranscribe(opts)
                case .rename(let path):
                    try handleRename(path)
                case .renameGUI:
                    break  // handled above, before semaphore
                case .benchmark(let opts):
                    try await handleBenchmark(opts)
                case .summarize(let opts):
                    try await handleSummarize(opts)
                }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            finished = true
        }

        while !finished {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(exitCode)
    }

    private static func handleTranscribe(_ opts: TranscribeOptions) async throws {
        // Spawn log stream for --debug (streams unified logs to stderr alongside normal output)
        var logProcess: Process?
        if opts.debug {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            proc.arguments = [
                "stream", "--level", "debug", "--style", "compact",
                "--predicate", "subsystem == \"com.audio-transcribe.app\""
            ]
            proc.standardOutput = FileHandle.standardError
            try? proc.run()
            logProcess = proc
        }
        defer { logProcess?.terminate() }

        let config = ConfigManager.shared.config

        // Validate inputs exist
        let inputURLs = opts.inputs.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.fileNotFound(url.path)
            }
        }

        let outputDir: URL
        if let output = opts.outputDir {
            outputDir = URL(fileURLWithPath: output)
        } else {
            outputDir = inputURLs[0].deletingLastPathComponent()
        }

        // If a single stereo AAC archive is provided, split into dual mono WAVs
        let systemAudio: URL
        let micAudio: URL?
        if inputURLs.count == 1 && inputURLs[0].pathExtension.lowercased() == "m4a" {
            let split = try await AudioSourceResolver.splitChannels(
                stereoAac: inputURLs[0], outputDirectory: outputDir
            )
            systemAudio = split.remote
            micAudio = split.local
        } else {
            systemAudio = inputURLs[0]
            micAudio = inputURLs.count > 1 ? inputURLs[1] : nil
        }

        let runner = await TranscriptionRunner()
        if opts.noDiarize {
            await runner.disableDiarization()
        }

        var runConfig = config
        if let engineStr = opts.engine, let engineID = EngineID(rawValue: engineStr) {
            runConfig.engine = engineID
        }
        runConfig.outputFormat = opts.format

        let result = try await runner.run(
            systemAudio: systemAudio,
            micAudio: micAudio,
            outputDirectory: outputDir,
            config: runConfig,
            legacyDedup: opts.legacyDedup
        )

        print("Output saved to: \(result.jsonPath.path)")
    }

    private static func handleRename(_ jsonPathStr: String) throws {
        let jsonPath = URL(fileURLWithPath: jsonPathStr)
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw CLIError.fileNotFound(jsonPathStr)
        }
        try CLIRename.run(jsonPath: jsonPath)
    }

    @MainActor
    private static func handleRenameGUI(_ jsonPathStr: String) async throws {
        let jsonPath = URL(fileURLWithPath: jsonPathStr)
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw CLIError.fileNotFound(jsonPathStr)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RenameWindowController.shared.show(
                jsonPath: jsonPath,
                onDismiss: { continuation.resume() }
            )
        }
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

    private static func handleSummarize(_ opts: SummarizeOptions) async throws {
        let jsonPath = URL(fileURLWithPath: opts.input)
        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw CLIError.fileNotFound(opts.input)
        }

        let config = ConfigManager.shared.config

        let providerStr = opts.provider ?? config.summary?.provider.rawValue ?? "openai"
        let endpoint = opts.endpoint ?? config.summary?.endpoint
        let apiKey = opts.apiKey ?? config.summary?.apiKey ?? ""
        let model = opts.model ?? config.summary?.model
        let contextLength = opts.contextLength ?? config.summary?.contextLength

        guard let endpoint, let model else {
            fputs("Error: No endpoint/model configured. Use --endpoint and --model flags, or configure in Settings.\n", stderr)
            throw CLIError.missingConfig("summary endpoint and model")
        }

        let providerType = SummaryProviderType(rawValue: providerStr) ?? .openai
        let summaryConfig = SummaryConfig(
            enabled: true,
            provider: providerType,
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            contextLength: contextLength
        )
        let provider = MeetingSummarizer.createProvider(from: summaryConfig)
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider)

        let baseName = jsonPath.deletingPathExtension().lastPathComponent
        let summaryPath = jsonPath.deletingLastPathComponent().appendingPathComponent(baseName + "-summary.md")
        print("Summary saved to: \(summaryPath.path)")
    }

    private static func printUsage() {
        let usage = """
        Usage: AudioTranscribe <subcommand> [options]

        Subcommands:
          transcribe  Transcribe audio files
            -i <file>        Input audio file (required, can specify twice for dual-stream)
            --output-dir <dir>  Output directory (default: same as input file)
            -f <format>      Output format: json, srt, txt (default: json)
            --engine <id>    Engine: speech_analyzer, fluid_audio (default: from config)
            --no-diarize     Skip speaker diarization
                --debug          Stream unified logs to stderr
                --legacy-dedup   Use original Jaccard-only echo dedup (no window/containment)

          rename      Rename speakers in a transcript (CLI)
            -i <file>        Input JSON transcript (required)

          rename-gui  Rename speakers with the GUI dialog
            -i <file>        Input JSON transcript (required)

          benchmark   Run performance benchmark
            --transcription-only   Only benchmark transcription
            --diarization-only     Only benchmark diarization

          summarize   Generate meeting summary from transcript
            -i <file>        Input JSON transcript (required)
            --provider <type> Provider: openai, lmstudio (default: from config)
            --endpoint <url> LLM endpoint URL (default: from config)
            --api-key <key>  API key (default: from config)
            --model <name>   Model name (default: from config)
            --context-length <n> Context window size (LM Studio only)
        """
        print(usage)
    }

    enum CLIError: LocalizedError {
        case fileNotFound(String)
        case noBenchmarkFiles
        case missingConfig(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .noBenchmarkFiles: return "No benchmark files found in ~/.audio-transcribe/benchmark/"
            case .missingConfig(let what): return "Missing configuration: \(what)"
            }
        }
    }
}
