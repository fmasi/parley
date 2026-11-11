import Foundation
import os

/// Renames a finished recording (#357): the name typed at the start is baked into every file of the session
/// (`<HHMMSS>-<name>.json`, `.m4a` / `-0.m4a`…, `.srt` / `.txt`, `-summary.md`, `.diag.jsonl`, `.json.bak`, the hidden
/// `.<id>.finalized` marker) and into the references between them. Fixing a wrong or missing name by hand meant
/// renaming all of them and editing the transcript's `audio_files` / `audio_paths`, the summary's `Source transcript`
/// line and the marker's `session_id` / `transcript`. This does it as one step:
///
/// - the `HHMMSS` prefix is kept; the name is sanitized and fitted as `RecordingCoordinator.startNaming` does;
/// - only a finished session: never one with session state in its folder (`session.json` / `session-*.json` of either
///   id) — the caller also asks the coordinator whether the session is still being recorded, finished or summarized;
/// - refused, with nothing touched, when any target name is taken, or a file of the new id is already in the folder;
/// - all or nothing: a failure part-way restores what was rewritten and moves every renamed file back;
/// - under `TranscriptWrites`' lock for the transcript, so a speaker rename, a re-detect or a storage mark of the same
///   file never interleaves with it.
///
/// The `.diag.jsonl` and `.json.bak` are renamed, their contents left as written: the first is the capture's event
/// record, the second the transcript as it was before its first re-detect. Neither is read back by Parley.
public enum SessionRenamer {

    // MARK: - Names

    /// `HHMMSS`: the part of a session id a rename never changes.
    static let timestampLength = 6

    /// The session id a transcript names — its file name without `.json` — when it is a recording's:
    /// `HHMMSS` or `HHMMSS-<name>`. nil for anything else (a CLI transcript next to its input, `session.json`).
    public static func sessionId(ofTranscript transcript: URL) -> String? {
        let file = transcript.lastPathComponent
        guard file.hasSuffix(".json") else { return nil }
        let id = String(file.dropLast(".json".count))
        let stamp = id.prefix(timestampLength)
        guard stamp.count == timestampLength, stamp.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let rest = id.dropFirst(timestampLength)
        guard rest.isEmpty || (rest.hasPrefix("-") && rest.count > 1) else { return nil }
        return id
    }

    /// The name part of a recording's transcript — what the dialog's field shows: `"weekly"` for `093000-weekly.json`,
    /// `""` for an unnamed `093000.json`. nil when the transcript is not a recording's (nothing to rename).
    public static func sessionName(ofTranscript transcript: URL) -> String? {
        guard let id = sessionId(ofTranscript: transcript) else { return nil }
        return String(id.dropFirst(timestampLength).dropFirst())
    }

    /// The id a session `oldId` gets under `name`: its timestamp, then the name sanitized and fitted exactly as a new
    /// recording's is (`RecordingCoordinator.startNaming`). Line breaks become spaces and the ends are trimmed; an empty
    /// name gives the bare timestamp, as a recording started without one.
    public static func newSessionId(oldId: String, name: String) -> String {
        let stamp = String(oldId.prefix(timestampLength))
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = fittedFilename(sanitizeFilename(oneLine), maxBytes: maxSessionIdBytes - stamp.utf8.count - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? stamp : "\(stamp)-\(sanitized)"
    }

    /// Whether a file in the session's folder is one of session `id`'s:
    /// - `.<id>.finalized`, the marker;
    /// - `<id>.<anything>`: the transcript and its formats, the merged archive, the backup, the capture records
    ///   (`.diag.jsonl`, `.relaunch.diag.jsonl`, the live log and coverage), damaged copies a rebuild set aside;
    /// - `<id>-<n>` followed by `.`, `_` or `-`: a chunk's archive, WAV, `_mic.wav`, or a copy rescued from it;
    /// - `<id>-summary.`: the summary and a damaged one kept aside.
    /// Never a temporary (`.tmp`): it belongs to a write in progress, not to the record.
    static func belongs(_ name: String, to id: String) -> Bool {
        guard !name.hasSuffix(".tmp") else { return false }
        if name == ".\(id).finalized" { return true }
        guard name.hasPrefix(id) else { return false }
        let rest = name.dropFirst(id.count)
        if rest.hasPrefix(".") { return rest.count > 1 }
        guard rest.hasPrefix("-") else { return false }
        let tail = rest.dropFirst()
        if tail.hasPrefix("summary.") { return true }
        let digits = tail.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return false }
        guard let next = tail.dropFirst(digits.count).first else { return false }
        return next == "." || next == "_" || next == "-"
    }

    /// `name`, one of `oldId`'s files, under `newId`.
    static func renamed(_ name: String, from oldId: String, to newId: String) -> String {
        if name == ".\(oldId).finalized" { return ".\(newId).finalized" }
        return newId + name.dropFirst(oldId.count)
    }

    // MARK: - The plan

    /// One file to rename, by name, in the session's folder.
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
    }

    /// What a rename does: every file of the session, from its name to its new one.
    public struct Plan: Equatable, Sendable {
        public let folder: URL
        public let oldId: String
        public let newId: String
        public let moves: [Move]
        public var newTranscript: URL { folder.appendingPathComponent("\(newId).json") }
    }

    /// Why a rename did not happen. Each message names no path: the dialog can be on a shared screen.
    public enum RenameError: Error, Equatable, LocalizedError {
        /// The transcript is not a recording's (`HHMMSS[-name].json`).
        case notARecording
        /// The session is still being recorded, finished or summarized, or its folder holds its session state.
        case inProgress
        /// The folder did not list, or a session state in it has no readable id: nothing can be ruled out.
        case cannotTell
        /// Another recording's transcript in the folder has a name this session's files could be confused with.
        case ambiguous
        /// A file the rename would create, or a file of the new name, is already in the folder.
        case nameTaken(String)
        /// The transcript could not be read as one.
        case transcriptUnreadable
        /// A step failed; everything was put back as it was.
        case failedAndRolledBack
        /// A step failed and putting it back failed too: some files carry the new name. Logged file by file.
        case failedPartway

        public var errorDescription: String? {
            switch self {
            case .notARecording: return "This transcript is not a Parley recording, so it has no session name to change."
            case .inProgress: return "This recording is still being finished. Try again once it is done."
            case .cannotTell: return "Parley could not check the recording's folder, so nothing was renamed."
            case .ambiguous: return "Another recording in the same folder has a similar name, so nothing was renamed."
            case .nameTaken(let id): return "A recording named “\(id)” is already in this folder. Choose another name."
            case .transcriptUnreadable: return "The transcript could not be read, so nothing was renamed."
            case .failedAndRolledBack: return "The recording could not be renamed. Nothing was changed."
            case .failedPartway: return "The recording could not be renamed, and some of its files could not be put back. See Console for details."
            }
        }
    }

    /// The plan for renaming session `oldId` to `newId`, from the folder's file names. Pure: the collision checks
    /// that need the disk (a differently cased name on a case-insensitive volume) are `rename`'s.
    ///
    /// Throws `.ambiguous` when another transcript in the folder looks like one of `oldId`'s files, and `.nameTaken`
    /// when a file of `newId` that the plan does not create from one of `oldId`'s is already there.
    public static func plan(folder: URL, oldId: String, newId: String, names: [String]) throws -> Plan {
        let sources = names.filter { belongs($0, to: oldId) }.sorted()
        // Another recording's transcript among them — `<id>-summary.json` is session "<id>-summary"'s, `<id>-2.json`
        // session "<id>-2"'s: the name rule would take its files for this session's. (`<id>.<…>.json` is this one's:
        // its coverage, a damaged copy.) Two sessions share a timestamp only when moved into one folder by hand.
        if sources.contains(where: { $0.hasPrefix("\(oldId)-") && $0.hasSuffix(".json") }) {
            throw RenameError.ambiguous
        }
        let sourceSet = Set(sources)
        // A file of the new id already there, that the plan does not make from one of this session's: after the rename
        // it would be taken for this session's (an orphan chunk, a stray summary).
        if names.contains(where: { belongs($0, to: newId) && !sourceSet.contains($0) }) {
            throw RenameError.nameTaken(newId)
        }
        let moves = sources.map { Move(from: $0, to: renamed($0, from: oldId, to: newId)) }
        // A target that is another file of the plan (`a` → `a-2`, where `a-2.m4a` is chunk 2 and `a.m4a` the merge):
        // moving one over the other would lose it.
        if moves.contains(where: { $0.to != $0.from && sourceSet.contains($0.to) }) {
            throw RenameError.nameTaken(newId)
        }
        return Plan(folder: folder, oldId: oldId, newId: newId, moves: moves)
    }

    // MARK: - Contents

    /// The transcript with every reference to a renamed file following it: `audio_files`, `audio_paths` (when the path
    /// is in the session's folder) and the storage limit's `audio_removed.files` (#224), whose names are `audio_files`'.
    static func updatedTranscript(_ json: [String: Any], plan: Plan) -> [String: Any] {
        guard var metadata = json["metadata"] as? [String: Any] else { return json }
        func name(_ file: String) -> String {
            belongs(file, to: plan.oldId) ? renamed(file, from: plan.oldId, to: plan.newId) : file
        }
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let folder = canonical(plan.folder)
        if let files = metadata["audio_files"] as? [String] { metadata["audio_files"] = files.map(name) }
        if let paths = metadata["audio_paths"] as? [String] {
            metadata["audio_paths"] = paths.map { path in
                let url = URL(fileURLWithPath: path), file = url.lastPathComponent
                guard canonical(url.deletingLastPathComponent()) == folder, path.hasSuffix(file) else { return path }
                // Only the file name changes; the folder stays spelled as the transcript recorded it.
                return String(path.dropLast(file.count)) + name(file)
            }
        }
        if var removed = metadata["audio_removed"] as? [String: Any], let files = removed["files"] as? [String] {
            removed["files"] = files.map(name)
            metadata["audio_removed"] = removed
        }
        var json = json
        json["metadata"] = metadata
        return json
    }

    /// The summary's footer, `*Source transcript: `<id>.json`*` (`MeetingSummarizer`), naming the new transcript. nil
    /// when the summary has no such line: its text is the model's, and nothing else in it is touched.
    static func updatedSummary(_ text: String, plan: Plan) -> String? {
        let old = "*Source transcript: `\(plan.oldId).json`*"
        guard text.contains(old) else { return nil }
        return text.replacingOccurrences(of: old, with: "*Source transcript: `\(plan.newId).json`*")
    }

    /// The finalized marker (`SessionState.markFinalized`) naming the new id and transcript; `finalized_at` kept.
    static func updatedMarker(_ json: [String: Any], plan: Plan) -> [String: Any] {
        var json = json
        if json["session_id"] as? String == plan.oldId { json["session_id"] = plan.newId }
        if json["transcript"] as? String == "\(plan.oldId).json" { json["transcript"] = "\(plan.newId).json" }
        return json
    }

    // MARK: - Doing it

    /// Rename the recording whose transcript is `transcript` to `name`, every file and every reference with it. Returns
    /// the transcript's new location — `transcript` itself when the name gives the same id. Blocking file work: call it
    /// off the main actor. The caller has already asked whether the session is still in flight
    /// (`RecordingCoordinator.isSessionInFlight`); session state in the folder is checked here, under the lock.
    @discardableResult
    public static func rename(transcript: URL, toName name: String,
                              fileSystem: SessionRenameFileSystem = LiveSessionRenameFileSystem()) throws -> URL {
        guard let oldId = sessionId(ofTranscript: transcript) else { throw RenameError.notARecording }
        let newId = newSessionId(oldId: oldId, name: name)
        guard newId != oldId else { return transcript }
        return try TranscriptWrites.exclusive(transcript) {
            try renameUnlocked(transcript: transcript, oldId: oldId, newId: newId, fileSystem: fileSystem)
        }
    }

    private static func renameUnlocked(transcript: URL, oldId: String, newId: String,
                                       fileSystem fs: SessionRenameFileSystem) throws -> URL {
        let folder = transcript.deletingLastPathComponent()
        // A session with state in the folder is unfinished — being recorded, processed or awaiting salvage — and a
        // session state of the NEW id would take this one's renamed files (its marker above all) for its own.
        guard let withState = fs.sessionIdsWithState(in: folder) else { throw RenameError.cannotTell }
        if withState.contains(oldId) { throw RenameError.inProgress }
        if withState.contains(newId) { throw RenameError.nameTaken(newId) }
        guard let names = fs.list(folder) else { throw RenameError.cannotTell }
        guard names.contains(transcript.lastPathComponent) else { throw RenameError.transcriptUnreadable }
        let plan = try plan(folder: folder, oldId: oldId, newId: newId, names: names)
        for move in plan.moves {
            let target = folder.appendingPathComponent(move.to)
            // A target already there that is not its own source: on a case-insensitive volume `a` and `A` are one file,
            // so a change of case only is not a collision.
            if fs.exists(target) && !fs.sameFile(folder.appendingPathComponent(move.from), target) {
                throw RenameError.nameTaken(newId)
            }
        }

        // Everything rewritten is read and prepared before anything moves: a transcript that does not parse stops it here.
        guard let data = fs.read(transcript),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["metadata"] is [String: Any]
        else { throw RenameError.transcriptUnreadable }
        var rewrites: [(name: String, original: Data, updated: Data)] = []
        guard let updatedJSON = try? JSONSerialization.data(withJSONObject: updatedTranscript(json, plan: plan),
                                                            options: [.prettyPrinted, .sortedKeys])
        else { throw RenameError.transcriptUnreadable }
        rewrites.append(("\(newId).json", data, updatedJSON))
        let summary = "\(oldId)-summary.md"
        if names.contains(summary), let original = fs.read(folder.appendingPathComponent(summary)),
           let text = String(data: original, encoding: .utf8), let updated = updatedSummary(text, plan: plan) {
            rewrites.append(("\(newId)-summary.md", original, Data(updated.utf8)))
        }
        let marker = ".\(oldId).finalized"
        if names.contains(marker), let original = fs.read(folder.appendingPathComponent(marker)) {
            // An unreadable marker still moves: its existence is what recovery reads.
            if let parsed = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
               let updated = try? JSONSerialization.data(withJSONObject: updatedMarker(parsed, plan: plan), options: [.sortedKeys]) {
                rewrites.append((".\(newId).finalized", original, updated))
            } else {
                Logger.files.error("Session rename: the finalized marker is not readable — moved as it is")
            }
        }

        var moved: [Move] = []
        var rewritten: [(name: String, original: Data)] = []
        do {
            for move in plan.moves {
                let from = folder.appendingPathComponent(move.from), to = folder.appendingPathComponent(move.to)
                try fs.move(from, to: to, sameFile: fs.sameFile(from, to))
                moved.append(move)
            }
            for rewrite in rewrites {
                try fs.replace(folder.appendingPathComponent(rewrite.name), with: rewrite.updated)
                rewritten.append((rewrite.name, rewrite.original))
            }
        } catch {
            Logger.files.error("Session rename failed after \(moved.count, privacy: .public) of \(plan.moves.count, privacy: .public) file(s): \(error, privacy: .private) — putting them back")
            var restored = true
            for rewrite in rewritten.reversed() {
                do { try fs.replace(folder.appendingPathComponent(rewrite.name), with: rewrite.original) } catch {
                    restored = false
                    Logger.files.error("Session rename: could not restore \(rewrite.name, privacy: .sensitive): \(error, privacy: .private)")
                }
            }
            for move in moved.reversed() {
                let from = folder.appendingPathComponent(move.to), to = folder.appendingPathComponent(move.from)
                do { try fs.move(from, to: to, sameFile: fs.sameFile(from, to)) } catch {
                    restored = false
                    Logger.files.error("Session rename: could not move \(move.to, privacy: .sensitive) back to \(move.from, privacy: .sensitive): \(error, privacy: .private)")
                }
            }
            throw restored ? RenameError.failedAndRolledBack : RenameError.failedPartway
        }
        Logger.files.info("Session renamed: \(plan.moves.count, privacy: .public) file(s), \(rewrites.count, privacy: .public) rewritten — \(oldId, privacy: .sensitive) → \(newId, privacy: .sensitive)")
        return plan.newTranscript
    }
}

/// The file operations a session rename makes, behind a seam so a test can fail any one of them.
public protocol SessionRenameFileSystem: Sendable {
    /// The folder's file names; nil when it does not list.
    func list(_ folder: URL) -> [String]?
    /// `SessionState.sessionIdsWithState(in:)`: nil when it cannot tell.
    func sessionIdsWithState(in folder: URL) -> Set<String>?
    func exists(_ url: URL) -> Bool
    /// Whether two paths are one file (a change of case on a case-insensitive volume).
    func sameFile(_ a: URL, _ b: URL) -> Bool
    func read(_ url: URL) -> Data?
    /// Move `from` to `to`, never over another file. `sameFile`: `to` is `from` under another case.
    func move(_ from: URL, to: URL, sameFile: Bool) throws
    /// Replace `url`'s contents durably (`DurableFile.replace`).
    func replace(_ url: URL, with data: Data) throws
}

/// The disk.
public struct LiveSessionRenameFileSystem: SessionRenameFileSystem {
    public init() {}

    public func list(_ folder: URL) -> [String]? { try? FileManager.default.contentsOfDirectory(atPath: folder.path) }
    public func sessionIdsWithState(in folder: URL) -> Set<String>? { SessionState.sessionIdsWithState(in: folder) }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    public func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? FileManager.default.attributesOfItem(atPath: a.path),
              let y = try? FileManager.default.attributesOfItem(atPath: b.path),
              let xFile = x[.systemFileNumber] as? Int, let yFile = y[.systemFileNumber] as? Int,
              let xDevice = x[.systemNumber] as? Int, let yDevice = y[.systemNumber] as? Int
        else { return false }
        return xFile == yFile && xDevice == yDevice
    }

    public func move(_ from: URL, to: URL, sameFile: Bool) throws {
        if sameFile {
            // A change of case: the "existing" target is this file, so an exclusive rename would refuse it.
            guard Darwin.rename(from.path, to.path) == 0 else { throw DurableFile.posixError(errno) }
            return
        }
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        // exFAT and SMB have no RENAME_EXCL (`recording_directory` may be one): check, then rename. This process holds
        // the transcript's lock, and the plan already refused a name that was taken.
        guard code == ENOTSUP || code == EINVAL else { throw DurableFile.posixError(code) }
        guard !FileManager.default.fileExists(atPath: to.path) else { throw DurableFile.posixError(EEXIST) }
        guard Darwin.rename(from.path, to.path) == 0 else { throw DurableFile.posixError(errno) }
    }

    public func replace(_ url: URL, with data: Data) throws { try DurableFile.replace(url, with: data) }
}

/// Transcripts a step outside the coordinator is still working on — today the auto-summary, which reads the transcript,
/// writes `<id>-summary.md` beside it and stamps the transcript's disclosure (#138) — so a session rename waits for it
/// (#357): renamed under it, the summary would land under the old name and its disclosure stamp would fail.
public final class TranscriptsInUse: @unchecked Sendable {
    /// The app's one.
    public static let shared = TranscriptsInUse()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    public func begin(_ transcript: URL) {
        lock.withLock { counts[Self.key(transcript), default: 0] += 1 }
    }

    public func end(_ transcript: URL) {
        lock.withLock {
            let key = Self.key(transcript)
            if let n = counts[key], n > 1 { counts[key] = n - 1 } else { counts[key] = nil }
        }
    }

    public func contains(_ transcript: URL) -> Bool {
        lock.withLock { counts[Self.key(transcript)] != nil }
    }
}

extension RecordingCoordinator {
    /// Whether the recording whose transcript is `transcript` may still be written to by something other than the rename
    /// dialog (#357), so its session must not be renamed now:
    /// - the app is finishing a recording or a recovery (`.transcribing`): the session just presented — or salvaged — is
    ///   still being settled, and which one it is is not always known;
    /// - this session is the one being recorded (its key, or no key known);
    /// - its chunks are still being processed behind a Stop that stopped waiting (#226);
    /// - its auto-summary is running (`TranscriptsInUse`).
    /// Session state in its folder is checked by `SessionRenamer.rename` itself, under the transcript's lock.
    public func isSessionInFlight(transcript: URL, inUse: TranscriptsInUse = .shared) -> Bool {
        let id = transcript.deletingPathExtension().lastPathComponent
        let key = URL(fileURLWithPath: Self.sessionKey(of: (transcript.deletingLastPathComponent(), id))).standardizedFileURL.path
        func same(_ other: String?) -> Bool { other.map { URL(fileURLWithPath: $0).standardizedFileURL.path == key } ?? false }
        switch appState.phase {
        case .idle: break
        case .transcribing: return true
        case .recording: if currentSessionKey == nil || same(currentSessionKey) { return true }
        }
        if chunksStillProcessing.contains(where: same) { return true }
        return inUse.contains(transcript)
    }

    /// A session was renamed (#357): the menu's "last transcript" follows it, so Rename Speakers… opens the new file.
    public func transcriptRenamed(from old: URL, to new: URL) {
        if appState.lastJsonPath == old.path { appState.lastJsonPath = new.path }
        if appState.lastTranscriptPath == old.path { appState.lastTranscriptPath = new.path }
    }
}
