import Foundation

/// The directory a caller asked Core to write into could not be created (#246).
///
/// Names the directory itself. Without this the first write into it fails instead, with an error
/// about a file the user never mentioned ("The file “recording_split_mic.wav” doesn’t exist.").
public struct OutputDirectoryError: LocalizedError {
    public let directory: URL
    public let underlying: Error

    public var errorDescription: String? {
        "Cannot create output directory '\(directory.path)': \(underlying.localizedDescription)"
    }
}

public enum OutputDirectory {

    /// Create `directory`, with its intermediates, when it does not exist yet. An existing
    /// directory (or a symlink to one) is left untouched.
    ///
    /// Called by `AudioSourceResolver`'s split, so every caller of the split gets it, and by the
    /// CLI for `--output-dir`. Deliberately NOT called by `TranscriptionRunner.run()`: that is also
    /// the app's stop and recovery path, where a recordings folder that vanished mid-recording
    /// must fail visibly at the transcript write, not be recreated around an empty transcript.
    public static func ensureExists(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OutputDirectoryError(directory: directory, underlying: error)
        }
    }
}
