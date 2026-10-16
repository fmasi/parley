import Foundation

/// One read-modify-write of a given transcript JSON at a time, across every writer in the process (#224 review).
///
/// The storage limit's pass marks OLDER transcripts (`TranscriptAudioMark`) while the user may be renaming
/// speakers on, or re-detecting, the same file. Each writer reads the file, changes it and replaces it; two
/// interleaved, the later replace silently drops the earlier edit. Every read-modify-write of a transcript runs
/// inside `exclusive(_:)` for that file.
///
/// One lock PER FILE, not one for all: a write is a durable replace with no deadline, and on a stalled network
/// share it can hang. A mark on an old transcript must never hold up a rename saved on the main actor for another
/// one. Two writers of the SAME file wait for each other — the save would hang on that file's own write anyway.
public enum TranscriptWrites {
    private final class Entry { let lock = NSLock(); var users = 0 }
    private static let table = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    public static func exclusive<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        table.lock()
        let entry = entries[key] ?? Entry()
        entry.users += 1
        entries[key] = entry
        table.unlock()
        defer {
            table.lock()
            entry.users -= 1
            if entry.users == 0 { entries[key] = nil }
            table.unlock()
        }
        entry.lock.lock()
        defer { entry.lock.unlock() }
        return try body()
    }
}
