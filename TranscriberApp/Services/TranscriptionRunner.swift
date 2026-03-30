import Foundation

struct TranscriptionResult {
    let outputPath: URL
    let jsonPath: URL?
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case pythonNotFound
        case scriptNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound: return "Embedded Python not found in app bundle"
            case .scriptNotFound: return "transcribe.py not found in app bundle"
            case .failed(let msg): return msg
            }
        }
    }

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputFormat: String,
        outputDirectory: URL,
        hfToken: String = ""
    ) async throws -> TranscriptionResult {
        let resources = Bundle.main.resourceURL!
        let pythonHome = resources.appendingPathComponent("python")
        let pythonBin = pythonHome.appendingPathComponent("bin/python3")
        let sitePackages = pythonHome
            .appendingPathComponent("lib/python3.11/site-packages")
        let transcribeScript = resources
            .appendingPathComponent("Python/transcribe.py")

        guard FileManager.default.fileExists(atPath: pythonBin.path) else {
            throw RunnerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RunnerError.scriptNotFound
        }

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let outputFile = outputDirectory
            .appendingPathComponent(baseName + "." + outputFormat)

        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", outputFormat]
        arguments += ["-o", outputFile.path]
        if !hfToken.isEmpty {
            arguments += ["--hf-token", hfToken]
        }

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = arguments
        process.environment = [
            "PYTHONHOME": pythonHome.path,
            "PYTHONPATH": sitePackages.path,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": [
                pythonHome.appendingPathComponent("bin").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ].joined(separator: ":"),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let output = stderr.isEmpty ? stdout : stderr
                    cont.resume(throwing: RunnerError.failed(
                        "transcribe.py exited with code \(proc.terminationStatus): \(output)"
                    ))
                    return
                }

                let jsonFile = outputDirectory
                    .appendingPathComponent(baseName + ".json")
                cont.resume(returning: TranscriptionResult(
                    outputPath: outputFile,
                    jsonPath: jsonFile
                ))
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: RunnerError.failed(
                    "Failed to launch transcribe.py: \(error.localizedDescription)"
                ))
            }
        }
    }
}
