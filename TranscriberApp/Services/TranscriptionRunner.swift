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
        outputDirectory: URL
    ) async throws -> TranscriptionResult {
        let resources = Bundle.main.resourceURL!
        let pythonHome = resources
            .appendingPathComponent("python/Python.framework/Versions/3.11")
        let pythonBin = pythonHome.appendingPathComponent("bin/python3")
        let sitePackages = resources
            .appendingPathComponent("python/lib/python3.11/site-packages")
        let transcribeScript = resources
            .appendingPathComponent("Python/transcribe.py")

        guard FileManager.default.fileExists(atPath: pythonBin.path) else {
            throw RunnerError.pythonNotFound
        }
        guard FileManager.default.fileExists(atPath: transcribeScript.path) else {
            throw RunnerError.scriptNotFound
        }

        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", outputFormat]
        arguments += ["-o", outputDirectory.path]

        let process = Process()
        process.executableURL = pythonBin
        process.arguments = arguments
        process.environment = [
            "PYTHONHOME": pythonHome.path,
            "PYTHONPATH": sitePackages.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(throwing: RunnerError.failed(
                        "transcribe.py exited with code \(proc.terminationStatus): \(stderr)"
                    ))
                    return
                }

                // transcribe.py always writes <baseName>.json (master) + <baseName>.<format>
                // Derive both paths from the system audio input — no stdout parsing needed.
                let baseName = systemAudio.deletingPathExtension().lastPathComponent
                let outputFile = outputDirectory
                    .appendingPathComponent(baseName + "." + outputFormat)
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
