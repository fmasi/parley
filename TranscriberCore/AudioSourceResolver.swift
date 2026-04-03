import Foundation
import os

/// Detected audio source format for a recording.
public enum AudioSourceFormat {
    /// Two separate WAV files: system audio + microphone
    case dualWav(system: URL, mic: URL)
    /// Single WAV file (system audio only, no mic)
    case singleWav(URL)
    /// Single stereo AAC archive: L=local mic, R=remote system
    case stereoAac(URL)
}

public enum AudioSourceResolverError: LocalizedError {
    case noAudioFiles(baseName: String, directory: URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioFiles(let baseName, let directory):
            return "No audio files found for '\(baseName)' in \(directory.path)"
        }
    }
}

/// Detects the audio source format for a recording and provides
/// channel-separated streams to the pipeline.
///
/// Channel convention for stereo AAC:
/// - Left channel = local microphone (the user)
/// - Right channel = remote system audio (other participants)
public enum AudioSourceResolver {

    /// Detect the audio format for a recording base name in a directory.
    /// Prefers dual WAV over stereo AAC when both exist (WAVs are the source of truth).
    public static func detect(baseName: String, in directory: URL) throws -> AudioSourceFormat {
        let fm = FileManager.default
        let systemWav = directory.appendingPathComponent("\(baseName).wav")
        let micWav = directory.appendingPathComponent("\(baseName)_mic.wav")
        let stereoAac = directory.appendingPathComponent("\(baseName).m4a")

        if fm.fileExists(atPath: systemWav.path) && fm.fileExists(atPath: micWav.path) {
            Logger.files.debug("AudioSourceResolver: dual WAV detected for \(baseName, privacy: .public)")
            return .dualWav(system: systemWav, mic: micWav)
        }

        if fm.fileExists(atPath: systemWav.path) {
            Logger.files.debug("AudioSourceResolver: single WAV detected for \(baseName, privacy: .public)")
            return .singleWav(systemWav)
        }

        if fm.fileExists(atPath: stereoAac.path) {
            Logger.files.debug("AudioSourceResolver: stereo AAC detected for \(baseName, privacy: .public)")
            return .stereoAac(stereoAac)
        }

        throw AudioSourceResolverError.noAudioFiles(baseName: baseName, directory: directory)
    }
}
