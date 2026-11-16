import Foundation

/// Whether a transcript's audio is still on disk, for the rename dialog (#29): Play and Re-detect need it, renaming
/// speakers or the recording never does. An old recording's archives may have been removed by the storage limit
/// (`audio_removed`, #224 — `TranscriptAudioMark`), or no longer be where the transcript's `audio_paths` say (a folder
/// moved by hand). Which channels can be re-detected is the re-detect's own check (`TranscriptRediarizer.audioPrecheck`),
/// never a second rule: a chunked recording needs every chunk, a legacy two-file recording only its channel's file. Play
/// shows only for a sample whose file is there (`SpeakerSampleLocator.locate`).
public struct RecordingAudioAvailability: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case available
        /// The storage limit removed this recording's audio — every file, or part of it.
        case removedByStorageLimit(all: Bool)
        /// Files the transcript lists are not on disk, and no storage-limit mark says why.
        case missing(all: Bool)
        /// The transcript lists no audio at all.
        case notListed
    }

    public let status: Status
    /// The channels (`"local"` / `"remote"`) a re-detect can run on: those `TranscriptRediarizer.audioPrecheck` passes.
    public let redetectable: Set<String>

    /// Nothing known to be missing: Play and Re-detect as before (the dialog's default).
    public static let available = RecordingAudioAvailability(status: .available, redetectable: ["local", "remote"])

    public init(status: Status, redetectable: Set<String>) {
        self.status = status
        self.redetectable = redetectable
    }

    /// From the transcript's metadata; `fileExists` is the only file-system call (off the main thread: the rename
    /// panel's read). A storage-limit mark whose files are all back on disk is `.available`: the audio is there.
    public static func of(metadata: [String: Any]?, fileExists: (String) -> Bool) -> RecordingAudioAvailability {
        let paths = metadata?["audio_paths"] as? [String] ?? []
        let removed = ((metadata?[TranscriptAudioMark.key] as? [String: Any])?["files"] as? [String]) ?? []
        let layout = SpeakerSampleLocator.classify(audioPaths: paths.map { URL(fileURLWithPath: $0, isDirectory: false) })
        let redetectable = Set(["local", "remote"].filter {
            (try? TranscriptRediarizer.audioPrecheck(layout: layout, source: $0, fileExists: fileExists)) != nil
        })
        let status: Status
        if paths.isEmpty {
            status = removed.isEmpty ? .notListed : .removedByStorageLimit(all: true)
        } else {
            let missing = paths.filter { !fileExists($0) }.count
            if missing == 0 {
                status = .available
            } else {
                let all = missing == paths.count
                status = removed.isEmpty ? .missing(all: all) : .removedByStorageLimit(all: all)
            }
        }
        return RecordingAudioAvailability(status: status, redetectable: redetectable)
    }

    /// From a parsed transcript, looking on disk. Blocks on the folder: off the main thread only.
    public static func of(json: [String: Any]) -> RecordingAudioAvailability {
        of(metadata: json["metadata"] as? [String: Any], fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Whether Re-detect can run on `channel` (`"local"` / `"remote"`).
    public func allowsRedetect(on channel: String) -> Bool { redetectable.contains(channel) }

    /// Why Re-detect is not offered on `channel` (the button's hover); nil where it is.
    public func redetectHelp(on channel: String) -> String? {
        guard !allowsRedetect(on: channel) else { return nil }
        return notice ?? "This side has no audio to re-detect."
    }

    /// The dialog's one line on why Play or Re-detect is not offered; nil when the audio is all there. Names no path (the
    /// dialog can be on a shared screen).
    public var notice: String? {
        switch status {
        case .available:
            return nil
        case .removedByStorageLimit(all: true):
            return "The storage limit removed this recording’s audio, so samples can’t be played or speakers re-detected. Names can still be changed."
        case .removedByStorageLimit(all: false):
            return "The storage limit removed part of this recording’s audio: only some samples play, and Re-detect needs all of it. Names can still be changed."
        case .missing(all: true):
            return "This recording’s audio isn’t where its transcript says, so samples can’t be played or speakers re-detected. Names can still be changed."
        case .missing(all: false) where redetectable.isEmpty:
            return "Part of this recording’s audio isn’t where its transcript says: only some samples play, and Re-detect needs all of it. Names can still be changed."
        case .missing(all: false):
            return "One side’s audio isn’t where its transcript says: its samples don’t play and it can’t be re-detected. Names can still be changed."
        case .notListed:
            return "This transcript lists no audio, so samples can’t be played or speakers re-detected. Names can still be changed."
        }
    }
}
