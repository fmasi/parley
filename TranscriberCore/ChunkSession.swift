import Foundation
import os

// MARK: - ProcessedChunk

/// A single processed audio chunk with transcription segments and speaker embeddings.
public struct ProcessedChunk: Codable {

    /// A single transcription segment within a chunk.
    public struct Segment: Codable {
        public let start: Double
        public let end: Double
        public let text: String
        public let speaker: String
        public let source: String
        public let qualityScore: Float?

        public init(
            start: Double,
            end: Double,
            text: String,
            speaker: String,
            source: String,
            qualityScore: Float? = nil
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.source = source
            self.qualityScore = qualityScore
        }
    }

    public let index: Int
    public let startTime: Date
    public let audioPath: String
    public let segments: [Segment]
    /// Speaker embeddings from the remote/system audio stream (keyed by friendly name).
    public let speakerDatabase: [String: [Float]]
    /// Speaker embeddings from the local/mic audio stream (keyed by friendly name). (#64)
    public let localSpeakerDatabase: [String: [Float]]
    public let echoSegmentsRemoved: Int
    /// Whether a MIC STREAM WAS CAPTURED for this chunk — a property of the recording, not of
    /// whether the user happened to say anything.
    ///
    /// This must not be inferred from "did the mic produce segments". A chunk the user sat through
    /// in silence yields zero local segments, and inferring from that made the chunk skip source
    /// prefixing while its siblings kept it. The reconciler then emitted `Remote Speaker N` keys
    /// that matched nothing in that chunk, its mapping silently fell back to the identity, and its
    /// chunk-local speaker numbering was laundered into the global namespace — swapping speakers
    /// for the rest of the meeting with no error anywhere. Persist the capture-time answer instead,
    /// so the writer and the reader cannot disagree.
    public let isDualStream: Bool

    public init(
        index: Int,
        startTime: Date,
        audioPath: String,
        segments: [Segment],
        speakerDatabase: [String: [Float]],
        localSpeakerDatabase: [String: [Float]] = [:],
        echoSegmentsRemoved: Int = 0,
        isDualStream: Bool = false
    ) {
        self.index = index
        self.startTime = startTime
        self.audioPath = audioPath
        self.segments = segments
        self.speakerDatabase = speakerDatabase
        self.localSpeakerDatabase = localSpeakerDatabase
        self.echoSegmentsRemoved = echoSegmentsRemoved
        self.isDualStream = isDualStream
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case index
        case startTime
        case audioPath
        case segments
        case speakerDatabase
        case localSpeakerDatabase
        case echoSegmentsRemoved = "echo_segments_removed"
        case isDualStream = "is_dual_stream"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        startTime = try c.decode(Date.self, forKey: .startTime)
        audioPath = try c.decode(String.self, forKey: .audioPath)
        segments = try c.decode([Segment].self, forKey: .segments)
        speakerDatabase = try c.decode([String: [Float]].self, forKey: .speakerDatabase)
        localSpeakerDatabase = try c.decodeIfPresent([String: [Float]].self, forKey: .localSpeakerDatabase) ?? [:]
        echoSegmentsRemoved = try c.decodeIfPresent(Int.self, forKey: .echoSegmentsRemoved) ?? 0
        // Legacy session.json predates the flag: fall back to the old inference so an in-flight
        // recording recovered by a newer build still reconciles the way it was written.
        if let flag = try c.decodeIfPresent(Bool.self, forKey: .isDualStream) {
            isDualStream = flag
        } else {
            isDualStream = segments.contains { $0.source == "local" }
        }
    }
}

// MARK: - SessionState

/// Persistent session state written to `session.json` alongside transcript files.
/// Tracks all processed chunks and their speaker databases for incremental processing.
public struct SessionState: Codable {

    public let sessionId: String
    public let meetingStart: Date
    public let engine: String
    public let chunkDurationMinutes: Int
    public var chunks: [ProcessedChunk]
    /// Capture provenance stamp (#95). Optional → omitted/`nil` for legacy session.json and
    /// for sessions that never recorded one; synthesized Codable decodes a missing key as nil.
    public var provenance: CaptureProvenance?

    public init(
        sessionId: String,
        meetingStart: Date,
        engine: String,
        chunkDurationMinutes: Int,
        chunks: [ProcessedChunk] = [],
        provenance: CaptureProvenance? = nil
    ) {
        self.sessionId = sessionId
        self.meetingStart = meetingStart
        self.engine = engine
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunks = chunks
        self.provenance = provenance
    }

    // MARK: - File location

    private static let fileName = "session.json"

    private static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
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

    /// Atomically write session state to disk (write to temp file, then rename).
    public static func write(_ state: SessionState, directory: URL) throws {
        let dest = fileURL(directory: directory)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try makeEncoder().encode(state)

        // Write to a temp file in the same directory, then rename for atomicity.
        let tmp = dir.appendingPathComponent("\(fileName).tmp")
        try data.write(to: tmp, options: .atomic)
        // Rename (atomic on same volume)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)

        Logger.state.debug("SessionState written — id: \(state.sessionId, privacy: .private), chunks: \(state.chunks.count)")
    }

    /// Read session state from disk. Returns nil if file is missing or corrupt.
    public static func read(directory: URL) -> SessionState? {
        let url = fileURL(directory: directory)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let state = try? makeDecoder().decode(SessionState.self, from: data) else {
            Logger.state.warning("SessionState at \(url.path, privacy: .private) is corrupt — ignoring")
            return nil
        }
        Logger.state.debug("SessionState read — id: \(state.sessionId, privacy: .private), chunks: \(state.chunks.count)")
        return state
    }

    /// Delete session state from disk. No-op if file does not exist.
    public static func delete(directory: URL) {
        let url = fileURL(directory: directory)
        do {
            try FileManager.default.removeItem(at: url)
            Logger.state.debug("SessionState deleted")
        } catch CocoaError.fileNoSuchFile {
            // Expected when session was never written — not an error.
        } catch {
            Logger.state.warning("SessionState delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
