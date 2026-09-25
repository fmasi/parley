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
        /// Repeats that abutted the previous segment: kept, flagged `duplicate`, hidden when read.
        public static let duplicatesFlagged = Code(rawValue: "duplicates_flagged")
        /// Zero-duration segments (no audio behind them) that were dropped.
        public static let zeroLengthDropped = Code(rawValue: "zero_length_dropped")
        public static let segmentsFiltered = Code(rawValue: "segments_filtered")
        public static let clustersAbsorbed = Code(rawValue: "clusters_absorbed")
        public static let echoFlagged = Code(rawValue: "echo_flagged")
        /// A chunk arrived under an index already held by a different recording file; it was
        /// processed under a fresh index. `count` carries the index it collided with.
        public static let chunkIndexCollision = Code(rawValue: "chunk_index_collision")
        /// A file already processed under one index arrived again under ANOTHER (a re-indexed
        /// collided chunk, re-ingested by a relaunch orphan scan) and was skipped. Recorded on the
        /// session against the known index; `count` carries the incoming index. Nothing was lost.
        public static let duplicateSourceOtherIndex = Code(rawValue: "duplicate_source_other_index")
        /// A resume was offered a session.json of another session id: refused, the session started
        /// fresh (a problem — whatever this recording held before the resume is not in this record).
        public static let seedMismatch = Code(rawValue: "seed_mismatch")
        /// A resumed session's seed was transcribed with another engine (informational: the
        /// engine setting changed between crash and resume).
        public static let seedEngineChanged = Code(rawValue: "seed_engine_changed")
        /// This session's first write found the day folder's session.json holding ANOTHER session
        /// and moved that file aside (`session-<id>.json`) instead of overwriting it (informational:
        /// nothing of this recording is missing; the other one is preserved).
        public static let sessionFileDisplaced = Code(rawValue: "session_file_displaced")
        /// The chunk's WAVs were gone and its words were recognised from its `.m4a` archive (a crash
        /// between archiving and the session.json write). Informational: the archive is the audio.
        public static let transcribedFromArchive = Code(rawValue: "transcribed_from_archive")
        /// The chunk had no microphone stream: no mic WAV (or, from an archive, a mic channel with
        /// no signal), so it was processed remote-only (C-M4). Informational — a system-only source is
        /// legitimate; `metadata.capture.local` holds the mic's coverage.
        public static let micStreamAbsent = Code(rawValue: "mic_stream_absent")
        /// The storage quota deleted this chunk's archive during the recording (C-M9; the quota's
        /// scope is the owner's call, #224). Informational: the chunk's words are in the record, its
        /// audio is not on disk any more.
        public static let chunkAudioEvicted = Code(rawValue: "chunk_audio_evicted")
        /// The chunks' start times were implausible for one timeline (a gap over 12 h, a start that
        /// is not a real time or before the first chunk's): they were not merged, and the transcript
        /// lists each chunk's own audio file (round 5). Informational: no audio is missing.
        public static let mergeSkippedImplausibleTiming = Code(rawValue: "merge_skipped_implausible_timing")

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
        /// A repeat abutting the previous segment: kept, hidden from readable output (P2).
        public let duplicate: Bool

        public init(
            start: Double,
            end: Double,
            text: String,
            speaker: String,
            source: String,
            qualityScore: Float? = nil,
            filtered: Bool = false,
            echo: Bool = false,
            duplicate: Bool = false
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.source = source
            self.qualityScore = qualityScore
            self.filtered = filtered
            self.echo = echo
            self.duplicate = duplicate
        }

        private enum CodingKeys: String, CodingKey {
            case start, end, text, speaker, source, qualityScore, filtered, echo, duplicate
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
            duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
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

// MARK: - DurableFile

/// Writes a file so that it survives a power loss, not only a crash (R2a M6, round 3 item 2): a fresh
/// temp file next to it, flushed to the disk itself with F_FULLFSYNC (plain `fsync` where the file
/// system can't), renamed over the destination, then the folder synced (best effort). Used where a
/// later step acts on the strength of the write: WAVs are deleted once session.json holds their
/// chunk, and the finalized marker vouches for the transcript.
enum DurableFile {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var synced: [String] = []

    /// Test seam, OFF in production (round 4 item 4): while on, every fully synced path is recorded
    /// in order. Off, nothing is kept — the paths carry meeting names.
    nonisolated(unsafe) static var recordsSyncsForTesting = false
    /// Test seam: every path fully synced while `recordsSyncsForTesting` was on, in order.
    static var syncedForTesting: [String] { lock.withLock { synced } }

    static func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let tmp = directory.appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try write(data, toNewFile: tmp, recordingAs: url)
            guard Darwin.rename(tmp.path, url.path) == 0 else { throw posixError(errno) }
            syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func write(_ data: Data, toNewFile url: URL, recordingAs final: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw posixError(n < 0 ? errno : EIO) }
                offset += n
            }
        }
        if fcntl(fd, F_FULLFSYNC) == 0 {
            if recordsSyncsForTesting { lock.withLock { synced.append(final.path) } }
        } else if fsync(fd) != 0 {
            throw posixError(errno)
        }
    }

    static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }

    static func posixError(_ code: Int32) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }
}

// MARK: - SessionState

/// A session.json that belonged to another recording, moved aside rather than overwritten.
public struct DisplacedSession: Equatable, Sendable {
    /// The displaced file's session id; nil when it could not be read.
    public let sessionId: String?
    public let movedTo: URL
}

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

    /// One per day folder (the folder is the session's output directory). Its id is checked on every
    /// write and delete; a file of another session is moved aside to `session-<id>.json` (or, when
    /// that name is taken, `session-<id>.<uuid>.json`), never overwritten (C-I3, R2a M1).
    private static let fileName = "session.json"

    private static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// `session-<id>.json`, or for an id that can't be read `session-unreadable-<uuid>.json` (it is not
    /// known to be anybody's, so it is not known to be expendable).
    private static func asideURL(directory: URL, sessionId: String?) -> URL {
        directory.appendingPathComponent("session-\(sessionId ?? "unreadable-\(UUID().uuidString)").json")
    }

    /// Every aside copy of `sessionId`'s state: `session-<id>.json` and `session-<id>.<uuid>.json`.
    private static func asideURLs(directory: URL, sessionId: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let plain = "session-\(sessionId).json", prefix = "session-\(sessionId)."
        return names.filter { name in
            if name == plain { return true }
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
            let middle = name.dropFirst(prefix.count).dropLast(".json".count)
            return UUID(uuidString: String(middle)) != nil
        }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Durable marker that `sessionId` was finalized (R2a item 12): `.<id>.finalized` next to its
    /// transcript. A lingering recovery file must never re-ingest or re-finalize such a session.
    private static func finalizedMarkerURL(directory: URL, sessionId: String) -> URL {
        directory.appendingPathComponent(".\(sessionId).finalized")
    }

    /// Serializes every session.json write and delete in this process. Two writers renaming over the
    /// same file concurrently hung the process in the kernel (`renameatx_np`) in a test; a salvage and
    /// a live recording can share a day folder.
    private static let ioLock = NSLock()
    /// Test seam: behave as a volume without `RENAME_EXCL` (exFAT, SMB).
    nonisolated(unsafe) static var exclusiveRenameUnsupportedForTesting = false

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

    /// Just the id, so a session written by a newer build (whose full shape this one may not
    /// decode) is still recognised as its own session or another's.
    private struct StoredId: Decodable { let sessionId: String }

    /// The session id stored in the file at `url`, `.some(nil)` when the file exists but its id
    /// can't be read, nil when there is no file.
    private static func storedSessionId(at url: URL) -> String?? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredId.self, from: data)
        else { return .some(nil) }
        return .some(stored.sessionId)
    }

    // MARK: - Static I/O

    /// Atomically and durably write session state: a uniquely named temp file in the same folder,
    /// flushed to the disk (F_FULLFSYNC, R2a M6 — the WAVs are deleted on the strength of this write,
    /// so it must survive a power loss), then renamed over `session.json` (B-M11). Temp files left by
    /// a write that died are swept first (R2a M8).
    ///
    /// When `session.json` holds ANOTHER session (or one whose id can't be read), that file is moved
    /// aside first — exclusively, never over an existing copy (R2a M1) — and returned, so the caller
    /// can record it: the next recording in a day folder used to overwrite an unfinalized session's
    /// recognised text (C-I3). If it can't be moved aside, nothing is written and this throws.
    @discardableResult
    public static func write(_ state: SessionState, directory: URL) throws -> DisplacedSession? {
        let data = try makeEncoder().encode(state)
        ioLock.lock(); defer { ioLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepStaleTemporaryFiles(in: directory)
        let dest = fileURL(directory: directory)

        var displaced: DisplacedSession?
        if let theirs = storedSessionId(at: dest), let finished = theirs, finished != state.sessionId,
           CrashRecoveryPlanner.isFinalized(outputDirectory: directory, sessionId: finished),
           TranscriptAssembler.verifies(directory.appendingPathComponent("\(finished).json")) {
            // A FINISHED session's leftover (a crash between its marker and this file's deletion): its
            // verified transcript is the durable copy. Deleted, not moved aside, and nothing is
            // recorded as displaced — nothing was (round 4 item 1).
            try FileManager.default.removeItem(at: dest)
            Logger.state.info("Removed the leftover session.json of an already finalized session")
        } else if let theirs = storedSessionId(at: dest), theirs != state.sessionId {
            let aside = try moveAsideExclusively(dest, directory: directory, sessionId: theirs)
            Logger.state.error(
                "session.json belonged to \(theirs ?? "a session whose id can't be read", privacy: .sensitive), not \(state.sessionId, privacy: .sensitive) — moved it aside to \(aside.lastPathComponent, privacy: .sensitive) instead of overwriting it"
            )
            displaced = DisplacedSession(sessionId: theirs, movedTo: aside)
        }

        try DurableFile.replace(dest, with: data)

        Logger.state.debug("SessionState written — id: \(state.sessionId, privacy: .sensitive), chunks: \(state.chunks.count)")
        return displaced
    }

    /// `session-<id>.json`, or `session-<id>.<uuid>.json` when that name is taken: `RENAME_EXCL`
    /// never replaces an existing copy.
    private static func moveAsideExclusively(_ file: URL, directory: URL, sessionId: String?) throws -> URL {
        let preferred = asideURL(directory: directory, sessionId: sessionId)
        let unique = { directory.appendingPathComponent("session-\(sessionId ?? "unreadable").\(UUID().uuidString).json") }
        switch renameExclusively(file, to: preferred) {
        case 0:
            return preferred
        case EEXIST:
            let other = unique()
            let code = renameExclusively(file, to: other)
            guard code == 0 else { throw posixError(code) }
            return other
        case ENOTSUP, EINVAL:
            // exFAT and SMB volumes have no RENAME_EXCL, and `recording_directory` may be one (round 3
            // item 1). Check-then-rename instead: `ioLock` (held by the caller) serializes every write
            // in this process, and only this process writes session files.
            let target = FileManager.default.fileExists(atPath: preferred.path) ? unique() : preferred
            try rename(file, to: target)
            return target
        case let code:
            throw posixError(code)
        }
    }

    /// `renamex_np(RENAME_EXCL)`; 0 or the errno.
    private static func renameExclusively(_ from: URL, to: URL) -> Int32 {
        if exclusiveRenameUnsupportedForTesting { return ENOTSUP }
        return renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// Temp files an interrupted durable write left for this session: `session.json.<uuid>.tmp`,
    /// `<id>.json.<uuid>.tmp` (the transcript) and `.<id>.finalized.<uuid>.tmp` (round 4 item 5).
    /// Under the lock; called at finalize and at recovery.
    public static func sweepTemporaries(directory: URL, sessionId: String) {
        ioLock.lock(); defer { ioLock.unlock() }
        let finals = [fileName, "\(sessionId).json", ".\(sessionId).finalized"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".tmp") {
            for final in finals where name.hasPrefix(final + ".") {
                let middle = name.dropFirst(final.count + 1).dropLast(".tmp".count)
                guard UUID(uuidString: String(middle)) != nil else { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// `session.json.<uuid>.tmp` left by a write that died. Only this process writes session.json and
    /// every write holds `ioLock`, so any temp file seen here is stale.
    private static func sweepStaleTemporaryFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("\(fileName).") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func posixError(_ code: Int32) -> Error { DurableFile.posixError(code) }

    /// POSIX `rename(2)`: atomic on one volume, replaces `to` if it exists.
    private static func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw posixError(errno) }
    }

    /// Read whatever session.json holds, whichever session it is. Internal (R2a M10): outside this
    /// module a session is only ever read by its id.
    static func read(directory: URL) -> SessionState? {
        read(url: fileURL(directory: directory))
    }

    private static func read(url: URL) -> SessionState? {
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

    /// Read session state only if it belongs to `sessionId` (P12): `session.json` when it is this
    /// session's — the live file, always its newest state — else the most complete of this session's
    /// moved-aside copies (C-I3). A file of a different recording is never merged into this one: nil
    /// when nothing matches.
    public static func read(directory: URL, sessionId: String) -> SessionState? {
        let current = read(directory: directory)
        if let current, current.sessionId == sessionId { return current }
        let asides = asideURLs(directory: directory, sessionId: sessionId).compactMap { url -> (SessionState, Date)? in
            guard let state = read(url: url), state.sessionId == sessionId else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (state, modified)
        }
        if let best = asides.max(by: { ($0.0.chunks.count, $0.1) < ($1.0.chunks.count, $1.1) }) {
            Logger.state.info("SessionState \(sessionId, privacy: .sensitive) found moved aside — using it")
            return best.0
        }
        if let current {
            Logger.state.warning(
                "SessionState belongs to \(current.sessionId, privacy: .sensitive), not \(sessionId, privacy: .sensitive) — ignoring it"
            )
        }
        return nil
    }

    /// Delete `sessionId`'s session state: `session.json` only when it is this session's (another
    /// recording may own it now), and every moved-aside copy of it. No-op when none exists.
    public static func delete(directory: URL, sessionId: String) {
        ioLock.lock(); defer { ioLock.unlock() }
        for url in [fileURL(directory: directory)] + asideURLs(directory: directory, sessionId: sessionId) {
            guard let stored = storedSessionId(at: url) else { continue }
            guard stored == sessionId else {
                if url.lastPathComponent == fileName {
                    Logger.state.info("session.json belongs to another session — not deleting it")
                }
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                Logger.state.debug("SessionState deleted: \(url.lastPathComponent, privacy: .sensitive)")
            } catch {
                Logger.state.warning("SessionState delete failed: \(error, privacy: .private)")
            }
        }
    }

    // MARK: - Finalized marker (R2a item 12)

    /// Record, durably, that `sessionId` was finalized into `transcript`. The caller writes the
    /// transcript durably first: the marker must never vouch for a transcript still in a cache.
    public static func markFinalized(directory: URL, sessionId: String, transcript: String) throws {
        let marker: [String: String] = ["session_id": sessionId, "transcript": transcript,
                                        "finalized_at": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        ioLock.lock(); defer { ioLock.unlock() }
        try DurableFile.replace(finalizedMarkerURL(directory: directory, sessionId: sessionId), with: data)
    }

    /// Whether `sessionId` was marked finalized.
    public static func isMarkedFinalized(directory: URL, sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: finalizedMarkerURL(directory: directory, sessionId: sessionId).path)
    }
}
