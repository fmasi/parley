import Foundation

/// One read-modify-write of a transcript JSON at a time, across every writer in the process (#224 review).
///
/// The storage limit's pass marks OLDER transcripts (`TranscriptAudioMark`) while the user may be renaming
/// speakers on, or re-detecting, the same file. Each writer reads the file, changes it and replaces it; two
/// interleaved, the later replace silently drops the earlier edit. Every read-modify-write of a transcript runs
/// inside `exclusive`. One lock for all transcripts: each hold is a read, an encode and a durable write.
public enum TranscriptWrites {
    private static let lock = NSLock()

    public static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
