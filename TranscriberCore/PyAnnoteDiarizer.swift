import Foundation
import os

/// Temporary bridge: runs pyannote diarization via embedded Python subprocess.
/// Will be replaced by SpeakerKitDiarizer in Phase 2.
public final class PyAnnoteDiarizer: DiarizationProvider, @unchecked Sendable {
    private let pythonPath: URL
    private let scriptPath: URL
    private let hfToken: String

    public init(pythonPath: URL, scriptPath: URL, hfToken: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.hfToken = hfToken
    }

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let startTime = ContinuousClock.now

        Logger.transcription.info("PyAnnote diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

        var arguments = [
            scriptPath.path,
            "-i", audioPath.path,
            "--hf-token", hfToken,
        ]
        if let n = numSpeakers {
            arguments += ["-s", String(n)]
        }

        let process = Process()
        process.executableURL = pythonPath
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Logger.transcription.error("PyAnnote diarization failed: \(stderr, privacy: .public)")
            throw DiarizationError.failed(stderr)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let rawSegments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DiarizationError.invalidOutput
        }

        let segments = rawSegments.compactMap { raw -> DiarizedSegment? in
            guard let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double,
                  let speaker = raw["speaker"] as? String else { return nil }
            return DiarizedSegment(start: start, end: end, speaker: speaker)
        }

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info("PyAnnote diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s")

        return segments
    }

    public enum DiarizationError: LocalizedError {
        case failed(String)
        case invalidOutput

        public var errorDescription: String? {
            switch self {
            case .failed(let msg): return "Diarization failed: \(msg)"
            case .invalidOutput: return "Invalid diarization output"
            }
        }
    }
}
