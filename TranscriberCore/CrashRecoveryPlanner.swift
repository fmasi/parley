import Foundation

public enum CrashRecoveryPlanner {
    public struct OrphanChunk: Equatable {
        public let index: Int; public let baseName: String
        public init(index: Int, baseName: String) { self.index = index; self.baseName = baseName }
    }
    /// Scan `outputDirectory` for `<sessionId>-N.wav` chunk files (excluding the `_mic.wav`
    /// companion), returning each discovered index alongside its base name (no extension).
    /// Shared by `orphanChunks` and `nextFreeChunkIndex` so both use identical name parsing.
    private static func onDiskChunkIndices(outputDirectory: URL, sessionId: String) -> [(index: Int, baseName: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let prefix = "\(sessionId)-"
        var found: [(index: Int, baseName: String)] = []
        for name in names where name.hasSuffix(".wav") && !name.hasSuffix("_mic.wav") && name.hasPrefix(prefix) {
            let stem = String(name.dropLast(4))
            guard let idx = Int(stem.dropFirst(prefix.count)) else { continue }
            found.append((index: idx, baseName: stem))
        }
        return found
    }
    public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        onDiskChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId)
            .filter { !completedIndices.contains($0.index) }
            .map { OrphanChunk(index: $0.index, baseName: $0.baseName) }
            .sorted { $0.index < $1.index }
    }
    public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool {
        let state = SessionState.read(directory: outputDirectory)
        if let state, !state.chunks.isEmpty { return true }
        let completed = Set(state?.chunks.map(\.index) ?? [])
        return !orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed).isEmpty
    }

    /// The next chunk index guaranteed not to collide with any chunk index already known to this
    /// session — either recorded as completed in `session.json` or present as a `<sessionId>-N.wav`
    /// file on disk. Restart-capture sites (crash-relaunch, no-live-rotator XPC crash) must name
    /// their new WAV with this index, never with the legacy segment counter: the segment counter
    /// and the chunk-index namespace can collide, and colliding either drops the restart file as
    /// "already completed" or truncates an in-progress chunk's WAV on create (#135).
    public static func nextFreeChunkIndex(outputDirectory: URL, sessionId: String) -> Int {
        let completed = SessionState.read(directory: outputDirectory)?.chunks.map(\.index) ?? []
        let onDisk = onDiskChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId).map(\.index)
        guard let maxIndex = (completed + onDisk).max() else { return 0 }
        return maxIndex + 1
    }

    /// The chunk index a restart-capture WAV must use so it never collides with any index this
    /// session already owns. Floors `nextFreeChunkIndex` at `sentinel.chunkIndex + 1` so a
    /// corrupt/unreadable `session.json` — which makes `nextFreeChunkIndex` under-report — can
    /// never hand back an index that drops the restart file as "already completed" or truncates
    /// the in-progress chunk's WAV on create (#135). This is the single collision guard shared by
    /// every restart site (crash-relaunch Flow B, XPC-crash restart, Flow A re-attach); call it,
    /// never re-derive the `max(nextFreeChunkIndex, chunkIndex + 1)` formula inline.
    public static func safeRestartChunkIndex(sentinel: RecordingSentinel, outputDirectory: URL) -> Int {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        return max(
            nextFreeChunkIndex(outputDirectory: outputDirectory, sessionId: sessionId),
            sentinel.chunkIndex + 1
        )
    }
}
