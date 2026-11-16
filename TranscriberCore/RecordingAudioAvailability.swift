import Foundation

/// Whether a transcript's audio is still on disk, for the rename dialog (#29): Play and Re-detect need it, renaming
/// speakers or the recording never does. An old recording's archives may have been removed by the storage limit
/// (`audio_removed`, #224 — `TranscriptAudioMark`), or no longer be where the transcript's `audio_paths` say (a folder
/// moved by hand). Re-detect reads every chunk of the channel (`TranscriptRediarizer`), so a chunked recording needs ALL
/// of them; a legacy two-file recording (`[system, mic]`) needs only its channel's file. Play shows only for a sample
/// whose file is there (`SpeakerSampleLocator.locate`).
public enum RecordingAudioAvailability: Equatable, Sendable {
    case available
    /// The storage limit removed this recording's audio — every file, or part of it.
    case removedByStorageLimit(all: Bool)
    /// Files the transcript lists are not on disk, and no storage-limit mark says why. `redetectable`: the channels
    /// (`"local"` / `"remote"`) whose audio is still whole — only ever one, the other file of a legacy two-file recording.
    case missing(all: Bool, redetectable: Set<String> = [])
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
        guard removed.isEmpty else { return .removedByStorageLimit(all: all) }
        // A legacy two-file recording keeps each channel in a file of its own: the one still there can be re-detected.
        var redetectable: Set<String> = []
        if !all, case .legacyDualStream(let remote, let local) = SpeakerSampleLocator.classify(audioPaths: paths.map { URL(fileURLWithPath: $0) }) {
            if let remote, fileExists(remote.path) { redetectable.insert("remote") }
            if let local, fileExists(local.path) { redetectable.insert("local") }
        }
        return .missing(all: all, redetectable: redetectable)
    }

    /// From a parsed transcript, looking on disk. Blocks on the folder: off the main thread only.
    public static func of(json: [String: Any]) -> RecordingAudioAvailability {
        of(metadata: json["metadata"] as? [String: Any], fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Whether Re-detect can run on `channel` (`"local"` / `"remote"`): every file it reads is there.
    public func allowsRedetect(on channel: String) -> Bool {
        switch self {
        case .available: return true
        case .missing(_, let redetectable): return redetectable.contains(channel)
        case .removedByStorageLimit, .notListed: return false
        }
    }

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
        case .missing(all: true, _):
            return "This recording’s audio isn’t where its transcript says, so samples can’t be played or speakers re-detected. Names can still be changed."
        case .missing(all: false, let redetectable) where redetectable.isEmpty:
            return "Part of this recording’s audio isn’t where its transcript says: only some samples play, and Re-detect needs all of it. Names can still be changed."
        case .missing(all: false, _):
            return "One side’s audio isn’t where its transcript says: its samples don’t play and it can’t be re-detected. Names can still be changed."
        case .notListed:
            return "This transcript lists no audio, so samples can’t be played or speakers re-detected. Names can still be changed."
        }
    }
}
