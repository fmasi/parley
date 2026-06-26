import Foundation

/// Strip any trailing `-N` segment suffix from a filename (without extension).
/// Example: "recording-2" -> "recording", "recording" -> "recording"
public func stripSegmentSuffix(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
}

/// Compute the base name for a new recording segment.
/// Strips any existing `-N` suffix from the original path's filename,
/// then appends the new segment number.
///
/// Example: segmentBaseName(originalPath: "/tmp/recording-2.wav", segment: 3) → "recording-3"
public func segmentBaseName(originalPath: String, segment: Int) -> String {
    let cleanBase = stripSegmentSuffix(originalPath)
    return "\(cleanBase)-\(segment)"
}

/// A recovery plan for a live XPC crash mid-recording: identifies the orphaned in-progress
/// chunk (so its WAVs can be re-ingested) and the index/name for the post-recovery chunk.
///
/// Both names are derived from the live `ChunkRotator.currentChunkIndex`, **not** from the
/// crash sentinel — the sentinel is only written at session start and goes stale after the
/// first rotation, so using it would re-enqueue the already-processed chunk and drop the true
/// orphan, trading one data-loss bug for another (#92).
public struct ChunkRecoveryPlan: Equatable {
    /// The index of the orphaned in-progress chunk (keeps the live index).
    public let orphanIndex: Int
    /// The index for the post-recovery chunk (orphanIndex + 1).
    public let recoveryIndex: Int
    /// Base name (no extension) of the orphan's WAVs, e.g. `meeting-0`.
    public let orphanBaseName: String
    /// Base name (no extension) for the recovery segment's files, e.g. `meeting-1`.
    public let recoveryBaseName: String

    public init(orphanIndex: Int, recoveryIndex: Int, orphanBaseName: String, recoveryBaseName: String) {
        self.orphanIndex = orphanIndex
        self.recoveryIndex = recoveryIndex
        self.orphanBaseName = orphanBaseName
        self.recoveryBaseName = recoveryBaseName
    }
}

/// Compute the recovery plan for a crash at `currentChunkIndex`. The orphan keeps the live
/// index; the recovery chunk takes the next index, so names stay monotonic and never collide.
///
/// - Parameters:
///   - sessionBaseName: the session base without a segment suffix (e.g. `143400-weekly-sync`).
///   - currentChunkIndex: the live `ChunkRotator.currentChunkIndex` at the moment of the crash.
public func chunkRecoveryPlan(sessionBaseName: String, currentChunkIndex: Int) -> ChunkRecoveryPlan {
    let recoveryIndex = currentChunkIndex + 1
    return ChunkRecoveryPlan(
        orphanIndex: currentChunkIndex,
        recoveryIndex: recoveryIndex,
        orphanBaseName: "\(sessionBaseName)-\(currentChunkIndex)",
        recoveryBaseName: "\(sessionBaseName)-\(recoveryIndex)"
    )
}
