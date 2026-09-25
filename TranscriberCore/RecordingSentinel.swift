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
    /// When the recording app was last known alive: refreshed every 60 s and at every rotation (§8.3).
    /// A relaunch within `RelaunchDecision.resumeWindow` of it resumes the same session. nil = written
    /// before this field existed (no liveness: salvaged, never resumed).
    public var lastAliveAt: Date?
    /// `kern.bootsessionuuid` when the recording started (§8.9): a sentinel from another boot is stale.
    public var bootSessionUUID: String?
    /// Stop marked it before asking the helper (§8.8): a crash during the stop or its finalize is
    /// salvaged at relaunch, never resumed — the user stopped that recording.
    public var stopping: Bool
    /// A deliberate quit or logout came while the stopped recording's transcript was being finished (L
    /// follow-up 42): the next launch says so, never "Parley crashed".
    public var quitDuringFinalize: Bool
    /// `quitDuringFinalize` came from `willPowerOff` only — a logout that may still be cancelled — so it is withdrawn if
    /// the app outlives the power-off window (L review 174). A quit's own mark clears it.
    public var quitMarkedByPowerOff: Bool
    /// Why the recording stopped, as the launch — or the session — that first kept it pending saw it (L review 147).
    /// A session kept in one boot and salvaged in another is worded by this, never by the boot it is salvaged in. nil:
    /// not kept yet (the slot's own sentinel), or kept by an earlier build.
    public var stopCause: StopCause?

    /// Why a recording stopped (L review 147).
    public enum StopCause: String, Codable, Sendable, Equatable {
        /// The Mac restarted (or lost power) while it was recording.
        case restart
        /// Parley itself went — a crash, a force-quit — while it was recording.
        case appCrash
        /// Its capture failed and could not be restarted (a failed start or restart the helper would not let go of).
        case captureFailed
        /// The recording folder stopped answering.
        case folderNotAnswering
    }

    public init(
        startedAt: Date,
        sessionName: String,
        systemAudioPath: String,
        micAudioPath: String,
        micDeviceUID: String? = nil,
        segment: Int = 0,
        chunkIndex: Int = 0,
        lastAliveAt: Date? = nil,
        bootSessionUUID: String? = nil,
        stopping: Bool = false,
        quitDuringFinalize: Bool = false,
        stopCause: StopCause? = nil,
        quitMarkedByPowerOff: Bool = false
    ) {
        self.startedAt = startedAt
        self.sessionName = sessionName
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.micDeviceUID = micDeviceUID
        self.segment = segment
        self.chunkIndex = chunkIndex
        self.lastAliveAt = lastAliveAt
        self.bootSessionUUID = bootSessionUUID
        self.stopping = stopping
        self.quitDuringFinalize = quitDuringFinalize
        self.stopCause = stopCause
        self.quitMarkedByPowerOff = quitMarkedByPowerOff
    }

    // MARK: - Codable (backwards-compatible: chunkIndex defaults to 0, the L7 fields to nil/false)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        systemAudioPath = try container.decode(String.self, forKey: .systemAudioPath)
        micAudioPath = try container.decode(String.self, forKey: .micAudioPath)
        micDeviceUID = try container.decodeIfPresent(String.self, forKey: .micDeviceUID)
        segment = try container.decode(Int.self, forKey: .segment)
        chunkIndex = try container.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
        lastAliveAt = try container.decodeIfPresent(Date.self, forKey: .lastAliveAt)
        bootSessionUUID = try container.decodeIfPresent(String.self, forKey: .bootSessionUUID)
        stopping = try container.decodeIfPresent(Bool.self, forKey: .stopping) ?? false
        quitDuringFinalize = try container.decodeIfPresent(Bool.self, forKey: .quitDuringFinalize) ?? false
        // An unknown cause (a newer build's) reads as none: the salvage then words it by its boot, as before.
        stopCause = (try? container.decodeIfPresent(StopCause.self, forKey: .stopCause)) ?? nil
        quitMarkedByPowerOff = try container.decodeIfPresent(Bool.self, forKey: .quitMarkedByPowerOff) ?? false
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

        Logger.state.debug("RecordingSentinel written — session: \(sentinel.sessionName, privacy: .sensitive), segment: \(sentinel.segment)")
    }

    /// Read sentinel from disk. Returns nil if file is missing or corrupt.
    public static func read(directory: URL? = nil) -> RecordingSentinel? {
        let url = fileURL(directory: directory)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let sentinel = try? makeDecoder().decode(RecordingSentinel.self, from: data) else {
            Logger.state.warning("RecordingSentinel at \(url.path, privacy: .sensitive) is corrupt — ignoring")
            return nil
        }
        Logger.state.info("RecordingSentinel found — session: \(sentinel.sessionName, privacy: .sensitive), segment: \(sentinel.segment)")
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
            Logger.state.warning("RecordingSentinel delete failed: \(error, privacy: .private)")
        }
    }

    // MARK: - Sessions awaiting salvage (L follow-ups 24, 40)

    private static let pendingFileName = "pending-sessions.json"

    /// The recording session this sentinel names: its folder and its chunk session id.
    public var sessionKey: String {
        URL(fileURLWithPath: systemAudioPath).deletingLastPathComponent().appendingPathComponent(stripSegmentSuffix(systemAudioPath)).path
    }

    /// Sessions a relaunch could not finish yet — their folder unreachable (an unplugged drive), or the
    /// capture helper not letting go of them — kept as a LIST beside the sentinel, so a later recording's
    /// sentinel can never take their place. Missing → empty. Unreadable — undecodable (L review 89), or there but
    /// not readable at all, a permissions or I/O error (L review 130) → set aside first: moved to
    /// `pending-sessions.unreadable-<time>.json`, never read as empty and then overwritten, which dropped every
    /// session it named. `setAside` says where. When even the move fails, `keptUnreadable` says the file was LEFT
    /// in place — never overwritten: `writePending` then writes a NEW list, `pending-<uuid>.json`, which this reads
    /// too (L review 166) — so a session held since is always tracked.
    public static func loadPending(directory: URL? = nil) -> (sessions: [RecordingSentinel], setAside: URL?, keptUnreadable: URL?) {
        let dir = directory ?? AppPaths.dataDirectory
        let main = loadMainPending(dir)
        var sessions = main.sessions
        for (_, overflow) in readableOverflowLists(dir) {
            for session in overflow where !sessions.contains(where: { $0.sessionKey == session.sessionKey }) { sessions.append(session) }
        }
        return (sessions, main.setAside, main.keptUnreadable)
    }

    /// The pending lists written beside an unreadable one that could not be set aside (L review 166): `pending-<uuid>.json`.
    /// Only the readable ones — an unreadable one is left alone, never deleted.
    private static func readableOverflowLists(_ dir: URL) -> [(url: URL, sessions: [RecordingSentinel])] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().compactMap { name -> (URL, [RecordingSentinel])? in
            guard name.hasPrefix("pending-"), name.hasSuffix(".json"),
                  UUID(uuidString: String(name.dropFirst("pending-".count).dropLast(".json".count))) != nil else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let sessions = try? makeDecoder().decode([RecordingSentinel].self, from: data) else {
                Logger.state.error("A pending list \(name, privacy: .sensitive) is unreadable — left as it is")
                return nil
            }
            return (url, sessions)
        }
    }

    private static func loadMainPending(_ dir: URL) -> (sessions: [RecordingSentinel], setAside: URL?, keptUnreadable: URL?) {
        let url = dir.appendingPathComponent(pendingFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, nil) }
        if let data = try? Data(contentsOf: url), let sessions = try? makeDecoder().decode([RecordingSentinel].self, from: data) {
            return (sessions, nil, nil)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        var aside = dir.appendingPathComponent("pending-sessions.unreadable-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: aside.path) {
            n += 1
            aside = dir.appendingPathComponent("pending-sessions.unreadable-\(stamp)-\(n).json")
        }
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            Logger.state.error("Pending sessions at \(url.path, privacy: .sensitive) are unreadable — set aside as \(aside.lastPathComponent, privacy: .sensitive)")
            return ([], aside, nil)
        } catch {
            Logger.state.error("Pending sessions at \(url.path, privacy: .sensitive) are unreadable and could not be set aside: \(error, privacy: .private)")
            return ([], nil, url)
        }
    }

    public static func readPending(directory: URL? = nil) -> [RecordingSentinel] {
        loadPending(directory: directory).sessions
    }

    /// Atomically replace the list; an empty list removes the file. A list that is there but cannot be read (and
    /// could not be set aside) is never replaced or removed (L review 130): the sessions go to a NEW list,
    /// `pending-<uuid>.json`, instead (L review 166). Either way, the readable overflow lists it replaces go.
    public static func writePending(_ sessions: [RecordingSentinel], directory: URL? = nil) throws {
        let dir = directory ?? AppPaths.dataDirectory
        let url = dir.appendingPathComponent(pendingFileName)
        let overflows = readableOverflowLists(dir).map(\.url)
        let mainUnreadable = FileManager.default.fileExists(atPath: url.path)
            && (try? Data(contentsOf: url)).flatMap({ try? makeDecoder().decode([RecordingSentinel].self, from: $0) }) == nil
        var written: URL?
        if !sessions.isEmpty {
            let target = mainUnreadable ? dir.appendingPathComponent("pending-\(UUID().uuidString).json") : url
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try makeEncoder().encode(sessions).write(to: target, options: .atomic)
            written = target
            if mainUnreadable { Logger.state.error("The pending list is unreadable and left in place — kept the sessions in \(target.lastPathComponent, privacy: .sensitive)") }
        } else if !mainUnreadable {
            try? FileManager.default.removeItem(at: url)
        }
        for overflow in overflows where overflow != written { try? FileManager.default.removeItem(at: overflow) }
    }

    // MARK: - Instance helpers

    /// Returns a copy with segment incremented by 1 and updated audio paths. Everything else carries
    /// over, the liveness, boot session and stop mark included.
    public func incrementedSegment(systemAudioPath: String, micAudioPath: String) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: startedAt,
            sessionName: sessionName,
            systemAudioPath: systemAudioPath,
            micAudioPath: micAudioPath,
            micDeviceUID: micDeviceUID,
            segment: segment + 1,
            chunkIndex: chunkIndex,
            lastAliveAt: lastAliveAt,
            bootSessionUUID: bootSessionUUID,
            stopping: stopping,
            quitDuringFinalize: quitDuringFinalize,
            stopCause: stopCause,
            quitMarkedByPowerOff: quitMarkedByPowerOff
        )
    }
}
