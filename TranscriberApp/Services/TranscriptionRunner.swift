import Foundation
import os
import TranscriberCore

struct TranscriptionResult {
    let jsonPath: URL
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
        let jsonFile = outputDirectory.appendingPathComponent(baseName + ".json")

        var arguments = [
            transcribeScript.path,
            "-i", systemAudio.path,
        ]
        if let mic = micAudio {
            arguments += ["-i", mic.path]
        }
        arguments += ["-f", "json"]
        arguments += ["-o", jsonFile.path]
        if !hfToken.isEmpty {
            arguments += ["--hf-token", hfToken]
        }

        let inputCount = micAudio != nil ? 2 : 1
        Logger.transcription.info("Launching transcription — format: json, inputs: \(inputCount)")
        Logger.transcription.debug("Python args: \(arguments, privacy: .private)")

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

        Logger.transcription.debug("Python env — PYTHONHOME: \(pythonHome.path, privacy: .private), PATH: \(process.environment?["PATH"] ?? "", privacy: .private)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate stderr for error reporting on failure
        let stderrAccumulator = StderrAccumulator()

        // Real-time forwarding of Python output to unified log
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                Logger.transcription.info("[python] \(line, privacy: .public)")
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrAccumulator] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrAccumulator.append(data)
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    Logger.transcription.error("[python-err] \(line, privacy: .public)")
                }
            }
        }

        let startTime = ContinuousClock.now

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { [stderrAccumulator] proc in
                // Clean up handlers to avoid retain cycles
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let elapsed = ContinuousClock.now - startTime
                let seconds = elapsed.components.seconds

                if proc.terminationStatus != 0 {
                    let stderr = stderrAccumulator.string
                    // Read any remaining stdout
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let output = stderr.isEmpty ? stdout : stderr
                    Logger.transcription.error("Transcription failed — exit code: \(proc.terminationStatus), duration: \(seconds)s")
                    cont.resume(throwing: RunnerError.failed(
                        "transcribe.py exited with code \(proc.terminationStatus): \(output)"
                    ))
                    return
                }

                Logger.transcription.info("Transcription complete — exit code: 0, duration: \(seconds)s")

                cont.resume(returning: TranscriptionResult(
                    jsonPath: jsonFile
                ))
            }

            do {
                try process.run()
            } catch {
                Logger.transcription.error("Failed to launch Python: \(error, privacy: .public)")
                cont.resume(throwing: RunnerError.failed(
                    "Failed to launch transcribe.py: \(error.localizedDescription)"
                ))
            }
        }
    }
}

/// Thread-safe accumulator for stderr data from the Python process.
private final class StderrAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
