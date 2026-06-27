import Foundation
import os

/// Persisted crash-recovery signal written at recording start, deleted on clean stop.
/// If `~/Library/Application Support/Parley/recording.json` exists at launch, a crash occurred during recording.
public struct RecordingSentinel: Codable, Equatable {
    public var startedAt: Date
    public var sessionName: String
    public var systemAudioPath: String
    public var micAudioPath: String
    public var micDeviceUID: String?
    public var segment: Int
    public var chunkIndex: Int

    public init(
        startedAt: Date,
        sessionName: String,
        systemAudioPath: String,
        micAudioPath: String,
        micDeviceUID: String? = nil,
        segment: Int = 0,
        chunkIndex: Int = 0
    ) {
        self.startedAt = startedAt
        self.sessionName = sessionName
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.micDeviceUID = micDeviceUID
        self.segment = segment
        self.chunkIndex = chunkIndex
    }

    // MARK: - Codable (backwards-compatible: chunkIndex defaults to 0 if missing)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        systemAudioPath = try container.decode(String.self, forKey: .systemAudioPath)
        micAudioPath = try container.decode(String.self, forKey: .micAudioPath)
        micDeviceUID = try container.decodeIfPresent(String.self, forKey: .micDeviceUID)
        segment = try container.decode(Int.self, forKey: .segment)
        chunkIndex = try container.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
    }

    // MARK: - File location

    private static let fileName = "recording.json"

    private static func fileURL(directory: URL?) -> URL {
        let dir = directory ?? AppPaths.dataDirectory
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - JSON encoder/decoder

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Static I/O

    /// Atomically write sentinel to disk (write to temp file, then rename).
    public static func write(_ sentinel: RecordingSentinel, directory: URL? = nil) throws {
        let dest = fileURL(directory: directory)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try makeEncoder().encode(sentinel)

        // Write to a temp file in the same directory, then rename for atomicity.
        let tmp = dir.appendingPathComponent("\(fileName).tmp")
        try data.write(to: tmp, options: .atomic)
        // Rename (atomic on same volume)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)

        Logger.state.debug("RecordingSentinel written — session: \(sentinel.sessionName, privacy: .private), segment: \(sentinel.segment)")
    }

    /// Read sentinel from disk. Returns nil if file is missing or corrupt.
    public static func read(directory: URL? = nil) -> RecordingSentinel? {
        let url = fileURL(directory: directory)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let sentinel = try? makeDecoder().decode(RecordingSentinel.self, from: data) else {
            Logger.state.warning("RecordingSentinel at \(url.path, privacy: .private) is corrupt — ignoring")
            return nil
        }
        Logger.state.info("RecordingSentinel found — session: \(sentinel.sessionName, privacy: .private), segment: \(sentinel.segment)")
        return sentinel
    }

    /// Delete sentinel from disk. No-op if file does not exist.
    public static func delete(directory: URL? = nil) {
        let url = fileURL(directory: directory)
        do {
            try FileManager.default.removeItem(at: url)
            Logger.state.debug("RecordingSentinel deleted")
        } catch CocoaError.fileNoSuchFile {
            // Expected when no crash occurred — not an error.
        } catch {
            Logger.state.warning("RecordingSentinel delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Instance helpers

    /// Returns a copy with segment incremented by 1 and updated audio paths.
    public func incrementedSegment(systemAudioPath: String, micAudioPath: String) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: startedAt,
            sessionName: sessionName,
            systemAudioPath: systemAudioPath,
            micAudioPath: micAudioPath,
            micDeviceUID: micDeviceUID,
            segment: segment + 1,
            chunkIndex: chunkIndex
        )
    }
}
