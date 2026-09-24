import Foundation
import os

// MARK: - ChunkIssue

/// Something that went wrong — or was deliberately removed — while processing one chunk.
///
/// Every failure `ChunkProcessor` used to swallow (an ASR error became an empty chunk, a failed
/// diarization a single "Unknown" speaker) is recorded here and carried into the transcript's
/// `metadata.processing_issues`, so the record states what it lost instead of presenting a
/// degraded chunk as a clean one (§7.2, P3).
public struct ChunkIssue: Codable, Equatable, Sendable {
    /// An issue code. A struct over its raw string rather than a closed enum, so a code written by a
    /// newer build decodes here as itself (unknown, not content-affecting) instead of failing the
    /// whole session.json and dropping an in-progress recording (a downgrade mid-recording).
    public struct Code: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let asrFailed = Code(rawValue: "asr_failed")
        public static let diarizationFailed = Code(rawValue: "diarization_failed")
        /// The VAD model is not cached: the quality gate ran without a speech map (informational).
        public static let vadUnavailable = Code(rawValue: "vad_unavailable")
        /// VAD threw at runtime (a real failure, unlike `vadUnavailable`).
        public static let vadFailed = Code(rawValue: "vad_failed")
        /// The stream's WAV holds no audio (a header only): an idle side, not a problem.
        public static let streamEmpty = Code(rawValue: "stream_empty")
        /// The stream's WAV does not exist at all.
        public static let streamMissing = Code(rawValue: "stream_missing")
        public static let archiveFailed = Code(rawValue: "archive_failed")
        public static let sessionWriteFailed = Code(rawValue: "session_write_failed")
        public static let duplicatesDropped = Code(rawValue: "duplicates_dropped")
        public static let segmentsFiltered = Code(rawValue: "segments_filtered")
        public static let clustersAbsorbed = Code(rawValue: "clusters_absorbed")
        public static let echoFlagged = Code(rawValue: "echo_flagged")
        /// A chunk arrived under an index already held by a different recording file; it was
        /// processed under a fresh index. `count` carries the index it collided with.
        public static let chunkIndexCollision = Code(rawValue: "chunk_index_collision")
        /// A resumed session was seeded with a session.json of another session id or engine.
        public static let seedMismatch = Code(rawValue: "seed_mismatch")

        /// Codes meaning content may be missing or wrong. `streamEmpty` is NOT one: an idle side
        /// (nobody spoke, nothing played) is not a processing problem (§7.1/§9, scan C13). An
        /// unknown code (from a newer build) is not one either.
        static let contentAffecting: Set<Code> = [
            .asrFailed, .diarizationFailed, .vadFailed, .streamMissing, .archiveFailed,
            .sessionWriteFailed, .chunkIndexCollision, .seedMismatch,
        ]

        public var affectsContent: Bool { Self.contentAffecting.contains(self) }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    public let code: Code
    /// "remote" | "local" — the stream the issue belongs to; nil when it is chunk-wide.
    public let track: String?
    /// How many items the issue covers (dropped duplicates, absorbed clusters…); nil when not a count.
    public let count: Int?

    public init(code: Code, track: String?, count: Int?) {
        self.code = code
        self.track = track
        self.count = count
    }

    /// See `Code.contentAffecting`. NOT streamEmpty.
    public var affectsContent: Bool { code.affectsContent }
}

extension ChunkIssue {
    /// Over `metadata.processing_issues` entries (`{chunk?, code, …}`): how many issues affect
    /// content, and how many distinct chunks have one. Content-affecting issues with no `chunk`
    /// (session-level, e.g. a failed write after a capture gap) count as one more "chunk", so the
    /// completion notice is never silent about them. Unknown codes do not count.
    public static func problemCounts(in dictionaries: [[String: Any]]) -> (issues: Int, chunks: Int) {
        let affecting = dictionaries.filter { issue in
            (issue["code"] as? String).map(Code.init(rawValue:))?.affectsContent ?? false
        }
        let chunks = Set(affecting.compactMap { $0["chunk"] as? Int }).count
        let sessionLevel = affecting.contains { $0["chunk"] == nil } ? 1 : 0
        return (affecting.count, chunks + sessionLevel)
    }
}

/// An issue that could not be stored on a chunk itself — the chunk was already appended when it
/// happened (a session.json write that failed after the append), or it concerns the session, not a
/// chunk (`chunk == nil`: a failed write after a capture gap).
public struct SessionIssue: Codable, Equatable, Sendable {
    public let chunk: Int?
    public let issue: ChunkIssue

    public init(chunk: Int?, issue: ChunkIssue) {
        self.chunk = chunk
        self.issue = issue
    }
}

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
        /// Failed the VAD/quality gate: kept, hidden from readable output (P10).
        public let filtered: Bool
        /// Mic bleed of a remote speaker: kept, hidden from readable output (P11).
        public let echo: Bool

        public init(
            start: Double,
            end: Double,
            text: String,
            speaker: String,
            source: String,
            qualityScore: Float? = nil,
            filtered: Bool = false,
            echo: Bool = false
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.source = source
            self.qualityScore = qualityScore
            self.filtered = filtered
            self.echo = echo
        }

        private enum CodingKeys: String, CodingKey {
            case start, end, text, speaker, source, qualityScore, filtered, echo
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            text = try c.decode(String.self, forKey: .text)
            speaker = try c.decode(String.self, forKey: .speaker)
            source = try c.decode(String.self, forKey: .source)
            qualityScore = try c.decodeIfPresent(Float.self, forKey: .qualityScore)
            // Absent in session.json written before P10/P11 → not flagged.
            filtered = try c.decodeIfPresent(Bool.self, forKey: .filtered) ?? false
            echo = try c.decodeIfPresent(Bool.self, forKey: .echo) ?? false
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
    /// What went wrong or was removed while processing this chunk (P3). Absent in legacy
    /// session.json → `[]`.
    public let issues: [ChunkIssue]

    public init(
        index: Int,
        startTime: Date,
        audioPath: String,
        segments: [Segment],
        speakerDatabase: [String: [Float]],
        localSpeakerDatabase: [String: [Float]] = [:],
        echoSegmentsRemoved: Int = 0,
        isDualStream: Bool = false,
        issues: [ChunkIssue] = []
    ) {
        self.index = index
        self.startTime = startTime
        self.audioPath = audioPath
        self.segments = segments
        self.speakerDatabase = speakerDatabase
        self.localSpeakerDatabase = localSpeakerDatabase
        self.echoSegmentsRemoved = echoSegmentsRemoved
        self.isDualStream = isDualStream
        self.issues = issues
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
        case issues
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
        issues = try c.decodeIfPresent([ChunkIssue].self, forKey: .issues) ?? []
    }
}

// MARK: - CaptureGap

/// A wall-clock period during a recording in which nothing was captured — the app relaunched
/// after a crash, or the Mac slept. Persisted in `session.json` and stamped into the transcript's
/// `metadata.capture.gaps` so the record states the hole instead of silently closing it (§7.2).
public struct CaptureGap: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Why nothing was recorded: "app relaunch" | "sleep".
    public let reason: String
    /// The gap's length, computed once from the PRECISE dates and stored: session.json's date coder
    /// keeps whole seconds, so recomputing after a round trip would drift. Never negative (a clock
    /// step can put `end` before `start`).
    public let seconds: Double

    public init(start: Date, end: Date, reason: String) {
        self.start = start
        self.end = end
        self.reason = reason
        self.seconds = max(0, end.timeIntervalSince(start))
    }

    private enum CodingKeys: String, CodingKey { case start, end, reason, seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        reason = try c.decode(String.self, forKey: .reason)
        seconds = max(0, try c.decodeIfPresent(Double.self, forKey: .seconds) ?? end.timeIntervalSince(start))
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
    /// for sessions that never recorded one.
    public var provenance: CaptureProvenance?
    /// Periods with no capture (relaunch, sleep). Absent in legacy session.json → `[]`.
    public var gaps: [CaptureGap]
    /// Chunk issues that happened after the chunk was appended (a failed session.json write).
    /// Absent in legacy session.json → `[]`.
    public var issues: [SessionIssue]

    public init(
        sessionId: String,
        meetingStart: Date,
        engine: String,
        chunkDurationMinutes: Int,
        chunks: [ProcessedChunk] = [],
        provenance: CaptureProvenance? = nil,
        gaps: [CaptureGap] = [],
        issues: [SessionIssue] = []
    ) {
        self.sessionId = sessionId
        self.meetingStart = meetingStart
        self.engine = engine
        self.chunkDurationMinutes = chunkDurationMinutes
        self.chunks = chunks
        self.provenance = provenance
        self.gaps = gaps
        self.issues = issues
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case sessionId, meetingStart, engine, chunkDurationMinutes, chunks, provenance, gaps, issues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        meetingStart = try c.decode(Date.self, forKey: .meetingStart)
        engine = try c.decode(String.self, forKey: .engine)
        chunkDurationMinutes = try c.decode(Int.self, forKey: .chunkDurationMinutes)
        chunks = try c.decode([ProcessedChunk].self, forKey: .chunks)
        provenance = try c.decodeIfPresent(CaptureProvenance.self, forKey: .provenance)
        gaps = try c.decodeIfPresent([CaptureGap].self, forKey: .gaps) ?? []
        issues = try c.decodeIfPresent([SessionIssue].self, forKey: .issues) ?? []
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

        Logger.state.debug("SessionState written — id: \(state.sessionId, privacy: .sensitive), chunks: \(state.chunks.count)")
    }

    /// Read session state from disk. Returns nil if file is missing or corrupt.
    public static func read(directory: URL) -> SessionState? {
        let url = fileURL(directory: directory)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let state = try? makeDecoder().decode(SessionState.self, from: data) else {
            Logger.state.warning("SessionState at \(url.path, privacy: .sensitive) is corrupt — ignoring")
            return nil
        }
        Logger.state.debug("SessionState read — id: \(state.sessionId, privacy: .sensitive), chunks: \(state.chunks.count)")
        return state
    }

    /// Read session state only if it belongs to `sessionId` (P12). A session.json left in the same
    /// folder by a different recording must never be merged into this one: nil on a mismatch.
    public static func read(directory: URL, sessionId: String) -> SessionState? {
        guard let state = read(directory: directory) else { return nil }
        guard state.sessionId == sessionId else {
            Logger.state.warning(
                "SessionState belongs to \(state.sessionId, privacy: .sensitive), not \(sessionId, privacy: .sensitive) — ignoring it"
            )
            return nil
        }
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
