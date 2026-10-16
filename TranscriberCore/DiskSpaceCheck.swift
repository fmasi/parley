import Foundation

/// Disk thresholds for a recording (§8.7). Two 48 kHz mono Int16 WAVs = 2 × 96 000 B/s.
public enum DiskSpaceCheck {
    public static let headroomBytes = 200_000_000
    private static let bytesPerSecondPerTrack = 96_000

    public static func bytesPerChunk(chunkMinutes: Int) -> Int { chunkMinutes * 60 * 2 * bytesPerSecondPerTrack }

    public static func canStart(freeBytes: Int, chunkMinutes: Int) -> Bool {
        freeBytes >= 2 * bytesPerChunk(chunkMinutes: chunkMinutes) + headroomBytes
    }

    public enum RotationVerdict: Equatable, Sendable { case ok, low }

    public static func rotationVerdict(freeBytes: Int, chunkMinutes: Int, currentlyLow: Bool) -> RotationVerdict {
        let one = bytesPerChunk(chunkMinutes: chunkMinutes)
        if freeBytes < one { return .low }
        if currentlyLow, freeBytes < 2 * one { return .low }
        return .ok
    }

    public static func freeBytes(at url: URL) -> Int? {
        freeBytes(at: url) { url in
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            return (important: values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }, plain: values?.volumeAvailableCapacity)
        }
    }

    /// Review fix 5: `volumeAvailableCapacityForImportantUsage` reads 0 on non-APFS volumes (exFAT,
    /// HFS+) — a 0 there is not "no space", it's "this key isn't meaningful here". Falls back to
    /// `.volumeAvailableCapacityKey`; nil only when neither is available. The `resolve` seam makes
    /// the fallback testable without a real non-APFS volume.
    static func freeBytes(at url: URL, resolve: (URL) -> (important: Int?, plain: Int?)) -> Int? {
        let (important, plain) = resolve(url)
        if let important, important > 0 { return important }
        return plain
    }

    public static func message(freeBytes: Int, chunkMinutes: Int) -> String {
        let needed = 2 * bytesPerChunk(chunkMinutes: chunkMinutes) + headroomBytes
        return "Only \(freeBytes / 1_000_000) MB free — Parley needs at least \(needed / 1_000_000) MB to record \(chunkMinutes)-minute chunks."
    }
}
