import Foundation

public enum CrashRecoveryPlanner {
    public struct OrphanChunk: Equatable {
        public let index: Int; public let baseName: String
        public init(index: Int, baseName: String) { self.index = index; self.baseName = baseName }
    }
    public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let prefix = "\(sessionId)-"
        var found: [OrphanChunk] = []
        for name in names where name.hasSuffix(".wav") && !name.hasSuffix("_mic.wav") && name.hasPrefix(prefix) {
            let stem = String(name.dropLast(4))
            guard let idx = Int(stem.dropFirst(prefix.count)), !completedIndices.contains(idx) else { continue }
            found.append(OrphanChunk(index: idx, baseName: stem))
        }
        return found.sorted { $0.index < $1.index }
    }
    public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool {
        let state = SessionState.read(directory: outputDirectory)
        if let state, !state.chunks.isEmpty { return true }
        let completed = Set(state?.chunks.map(\.index) ?? [])
        return !orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed).isEmpty
    }
}
