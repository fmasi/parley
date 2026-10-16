import Foundation

/// The rename panel's reads of a transcript (L reviews 134, 175): off the main actor, bounded — a recordings folder that
/// does not answer skips the panel with a note, so the rename queue never wedges — and through a folder reader of its
/// OWN: its own queue per volume, its own keys. Never the coordinator's reader (`FolderReads.shared`): a panel's parse
/// of a slow transcript then never makes a recovery read of the same folder "no answer yet" — a session wrongly kept
/// waiting — nor holds the queue that read waits on; and a recovery read never skips a panel.
public final class RenameReads: Sendable {
    /// The app's one.
    public static let shared = RenameReads()
    /// How long a panel's transcript read may take before the panel is skipped (L review 134).
    public static let parseDeadlineSeconds: Double = 10

    /// Its own reader, never shared with the coordinator's. Tests inject one that hangs.
    let reads: FolderReads

    init(reads: FolderReads = FolderReads(label: "eu.fmasi.parley.rename-reads")) {
        self.reads = reads
    }

    /// `parse(transcript)` on this reader's queue for the transcript's volume, bounded by `seconds` of awake time; nil
    /// when it did not answer — or when a read of the same transcript is still out.
    public func read<T>(transcript: URL, seconds: Double = parseDeadlineSeconds, _ parse: @escaping @Sendable (URL) -> T) async -> T? {
        await reads.read("rename: transcript", folder: transcript.deletingLastPathComponent().path, key: transcript.path,
                         seconds: seconds) { parse(transcript) }
    }
}
