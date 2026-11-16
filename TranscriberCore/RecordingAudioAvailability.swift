import Foundation

/// Whether a transcript's audio is still on disk, for the rename dialog (#29): Play and Re-detect need it, renaming
/// speakers or the recording never does. An old recording's archives may have been removed by the storage limit
/// (`audio_removed`, #224 — `TranscriptAudioMark`), or no longer be where the transcript's `audio_paths` say (a folder
/// moved by hand). Re-detect reads every chunk of the channel, so it needs ALL of them; Play shows only for a sample
/// whose file is there (`SpeakerSampleLocator.locate`).
public enum RecordingAudioAvailability: Equatable, Sendable {
    case available
    /// The storage limit removed this recording's audio — every file, or part of it.
    case removedByStorageLimit(all: Bool)
    /// Files the transcript lists are not on disk, and no storage-limit mark says why.
    case missing(all: Bool)
    /// The transcript lists no audio at all.
    case notListed

    /// From the transcript's metadata; `fileExists` is the only file-system call (off the main thread: the rename
    /// panel's read). A storage-limit mark whose files are all back on disk is `.available`: the audio is there.
    public static func of(metadata: [String: Any]?, fileExists: (String) -> Bool) -> RecordingAudioAvailability {
        let paths = metadata?["audio_paths"] as? [String] ?? []
        let removed = ((metadata?[TranscriptAudioMark.key] as? [String: Any])?["files"] as? [String]) ?? []
        guard !paths.isEmpty else { return removed.isEmpty ? .notListed : .removedByStorageLimit(all: true) }
        let missing = paths.filter { !fileExists($0) }.count
        guard missing > 0 else { return .available }
        let all = missing == paths.count
        return removed.isEmpty ? .missing(all: all) : .removedByStorageLimit(all: all)
    }

    /// From a parsed transcript, looking on disk. Blocks on the folder: off the main thread only.
    public static func of(json: [String: Any]) -> RecordingAudioAvailability {
        of(metadata: json["metadata"] as? [String: Any], fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Whether Re-detect can run: every file there.
    public var allowsRedetect: Bool { self == .available }

    /// The dialog's one line on why Play or Re-detect is not offered; nil when the audio is all there. Names no path (the
    /// dialog can be on a shared screen).
    public var notice: String? {
        switch self {
        case .available:
            return nil
        case .removedByStorageLimit(all: true):
            return "The storage limit removed this recording’s audio, so samples can’t be played or speakers re-detected. Names can still be changed."
        case .removedByStorageLimit(all: false):
            return "The storage limit removed part of this recording’s audio: only some samples play, and Re-detect needs all of it. Names can still be changed."
        case .missing(all: true):
            return "This recording’s audio isn’t where its transcript says, so samples can’t be played or speakers re-detected. Names can still be changed."
        case .missing(all: false):
            return "Part of this recording’s audio isn’t where its transcript says: only some samples play, and Re-detect needs all of it. Names can still be changed."
        case .notListed:
            return "This transcript lists no audio, so samples can’t be played or speakers re-detected. Names can still be changed."
        }
    }
}
