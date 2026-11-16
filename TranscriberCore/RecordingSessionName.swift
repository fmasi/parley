import Foundation
import os

/// A name chosen for the recording in progress (#358), to be applied once its transcript is written.
///
/// A recording's name is baked into its file names at the start (`RecordingCoordinator.startNaming`), and the capture
/// helper writes every chunk under it. Changing it mid-recording would touch the capture path, so the change waits: the
/// coordinator keeps it here and renames the finished session with `SessionRenamer` — the routine the post-call rename
/// dialog uses (#357) — right after the transcript is written and before the user is told of it.
///
/// In memory only, deliberately not in the recovery sentinel: the sentinel is rewritten on its own queue by a start,
/// every rotation, the liveness refresh, a restart's segment step and every exit mark, and read by every relaunch and
/// salvage path. Carrying a name through all of them — and renaming inside a salvage, under the recovery gate — is new
/// failure surface in crash recovery for a convenience. A crash loses only the chosen name: the recording keeps the name
/// it started with, and the rename dialog that follows its salvage can still change it. Never a half-applied rename:
/// `SessionRenamer` is all or nothing.
public struct PendingSessionName: Equatable, Sendable {
    public enum Origin: String, Sendable {
        /// Typed by the user, in the menu or from the island.
        case user
        /// A calendar title that arrived after a one-click start had named the recording "<App> call".
        case calendar
    }

    /// The recording it belongs to (`RecordingCoordinator.sessionKey`): its folder and session id.
    public let sessionKey: String
    public let name: String
    public let origin: Origin

    public init(sessionKey: String, name: String, origin: Origin) {
        self.sessionKey = sessionKey
        self.name = name
        self.origin = origin
    }

    /// A typed name as one trimmed line (the dialog's field can take a paste with line breaks).
    public static func normalized(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name part of a session key (`…/093000-weekly sync` → `weekly sync`; `…/093000` → empty): what the files carry.
    public static func name(ofSessionKey key: String) -> String {
        let id = URL(fileURLWithPath: key).lastPathComponent
        return String(id.dropFirst(SessionRenamer.timestampLength).dropFirst())
    }

    /// The pending name once a late calendar title arrives for recording `sessionKey`: the title — unless the user already
    /// named this recording, whose choice always wins (as `SessionNameSuggestionPolicy` in the naming panel). nil = keep.
    public static func adoptingCalendarTitle(_ title: String, sessionKey: String, current: PendingSessionName?) -> PendingSessionName? {
        if let current, current.sessionKey == sessionKey, current.origin == .user { return nil }
        let name = normalized(title)
        guard !name.isEmpty else { return nil }
        return PendingSessionName(sessionKey: sessionKey, name: name, origin: .calendar)
    }
}

extension RecordingCoordinator {
    /// The recording in progress's session key: nil when nothing is recording.
    public var recordingSessionKey: String? {
        guard appState.isRecording else { return nil }
        return currentSessionKey
    }

    /// The name the recording in progress will carry (#358): the one chosen while it records, else the one it started with
    /// as its files spell it. nil when nothing is recording.
    public var recordingSessionName: String? {
        guard let key = recordingSessionKey else { return nil }
        if let pending = pendingSessionName, pending.sessionKey == key { return pending.name }
        return PendingSessionName.name(ofSessionKey: key)
    }

    /// Whether `recordingSessionName` is still to be applied (the files carry another name until the recording finishes).
    public var recordingSessionNameIsPending: Bool {
        guard let key = recordingSessionKey, let pending = pendingSessionName else { return false }
        return pending.sessionKey == key && pending.name != PendingSessionName.name(ofSessionKey: key)
    }

    /// The user named the recording in progress (#358): applied once its transcript is written. False when nothing is
    /// recording — once Stop is pressed, the post-call rename dialog is where the name is changed.
    @discardableResult
    public func renameRecordingInProgress(to name: String) -> Bool {
        guard let key = recordingSessionKey else { return false }
        pendingSessionName = PendingSessionName(sessionKey: key, name: PendingSessionName.normalized(name), origin: .user)
        Logger.state.notice("Recording renamed while it records — applied when it finishes")
        return true
    }

    /// A calendar title that arrived after a one-click start named its recording "<App> call" (#358). Taken only while
    /// that recording is the one recording, and never over a name the user chose.
    @discardableResult
    public func adoptLateCalendarTitle(_ title: String, forSession key: String) -> Bool {
        guard recordingSessionKey == key,
              let adopted = PendingSessionName.adoptingCalendarTitle(title, sessionKey: key, current: pendingSessionName)
        else { return false }
        pendingSessionName = adopted
        Logger.state.notice("A calendar title arrived after the start — the recording takes it when it finishes")
        return true
    }

    /// A name the finish could not apply to `transcript` (#358), handed over once: the rename dialog starts from it.
    public func unappliedSessionName(forTranscript transcript: URL) -> String? {
        unappliedSessionNames.removeValue(forKey: transcript.standardizedFileURL.path)
    }

    /// The pending name of the session whose transcript is `transcript`, if any, taken off the coordinator (#358): it is
    /// this session's, and nothing else will apply it.
    private func takePendingName(for transcript: URL) -> PendingSessionName? {
        guard let pending = pendingSessionName, let id = SessionRenamer.sessionId(ofTranscript: transcript),
              Self.lexicallySameSession(Self.sessionKey(of: (transcript.deletingLastPathComponent(), id)), pending.sessionKey)
        else { return nil }
        pendingSessionName = nil
        return pending
    }

    /// Lexical, never a file-system call: this runs on the main actor (`standardizedFileURL` removes `.` and `..` only).
    nonisolated static func lexicallySameSession(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// A transcript of the recording with a pending name was written by something other than its Stop's finish — a salvage
    /// of a stop that failed, a recovery (#358): never renamed there (a salvage runs under the recovery gate), never dropped.
    /// The name goes to the rename dialog, whose Save applies it.
    func handPendingNameToDialog(transcript: URL) {
        guard let pending = takePendingName(for: transcript) else { return }
        unappliedSessionNames[transcript.standardizedFileURL.path] = pending.name
        Logger.state.notice("A recording with a name chosen while it recorded was finished by a salvage — the rename dialog offers the name")
    }

    /// Rename the just-written session to the name chosen while it recorded, if any (#358). Returns the result with the
    /// transcript's new path; as it was when there is nothing to apply, or when the rename did not happen — then the name
    /// goes to the rename dialog (`unappliedSessionName`), which starts from it.
    ///
    /// Runs at the end of the Stop: the transcript is written, the stopping recovery file is deleted (`recoveryFileGone`; a
    /// recovery file left behind would send the next launch after the old names), the session state is gone and the capture
    /// is over. Two queued steps of the finish still name the files by their old names: the storage quota's pass protects
    /// the session's archives by name, and the live diagnostic log's delete is queued by session id. Both are waited for
    /// first, bounded; one that has not finished leaves the files as they are.
    ///
    /// The rename is ABANDONABLE: on a folder that stops answering, one that has not started by its bound never runs —
    /// landing after the app showed the old path, it would break the notice, the dialog, the auto-summary and its stamp.
    /// One already under way runs on; the transcript is shown where it is then.
    func applyPendingSessionName(to result: TranscriptionResult, recoveryFileGone: Bool = true) async -> TranscriptionResult {
        guard pendingSessionName != nil else { return result }
        let transcript = result.jsonPath, folder = transcript.deletingLastPathComponent()
        guard let pending = takePendingName(for: transcript) else {
            pendingSessionName = nil
            Logger.state.error("A name chosen while recording belongs to another session — not applied")
            return result
        }
        guard let oldId = SessionRenamer.sessionId(ofTranscript: transcript),
              SessionRenamer.newSessionId(oldId: oldId, name: pending.name) != oldId else { return result }
        let name = pending.name
        func handOver(_ why: String, _ result: TranscriptionResult) -> TranscriptionResult {
            Logger.state.error("The name chosen while recording was not applied — \(why, privacy: .public); the rename dialog offers it")
            unappliedSessionNames[transcript.standardizedFileURL.path] = name
            return result
        }
        guard recoveryFileGone else { return handOver("the recovery file's delete did not answer", result) }
        let bound = Self.seconds(folderReadDeadline)
        if let pass = result.quotaPass, await pass.removedRecordings(within: bound) == nil {
            // Waited for once: the completion notice does not wait for it again.
            return handOver("the storage quota pass had not finished",
                            TranscriptionResult(jsonPath: transcript, removedRecordings: result.removedRecordings, quotaPass: nil))
        }
        let client = captureClient
        let flushed = (try? await withDeadline(seconds: bound, label: "evidence before a session rename") {
            await client.flushEvidence()
        }) != nil
        guard flushed else { return handOver("the live diagnostic log's delete had not run", result) }

        let claim = OnceFlag(), fileSystem = sessionRenameFileSystem
        let outcome = await folderReads.read("finish: session rename", folder: folder.path, seconds: Self.seconds(folderWriteDeadline)) {
            // Claimed before anything moves: a finish whose bound ran out first has claimed it, and this never runs.
            guard claim.claim() else { return Result<URL, Error>.failure(SessionRenamer.RenameError.failedAndRolledBack) }
            return Result { try SessionRenamer.rename(transcript: transcript, toName: name, fileSystem: fileSystem) }
        }
        switch outcome {
        case .success(let renamed)?:
            Logger.state.notice("The name chosen while recording was applied (\(pending.origin.rawValue, privacy: .public))")
            return TranscriptionResult(jsonPath: renamed, removedRecordings: result.removedRecordings, quotaPass: result.quotaPass)
        case .failure(let error)?:
            // Nothing was renamed (or all of it was put back).
            Logger.state.error("Session rename at the finish: \(error, privacy: .private)")
            return handOver("the rename was refused or failed", result)
        case nil:
            if claim.claim() {
                return handOver("the recording folder did not answer before the rename could start (it never will)", result)
            }
            // Under way when the bound ran out: it runs on. Show the transcript where it is now — looked at off the main
            // actor, bounded; unanswered, where it was.
            let newTranscript = folder.appendingPathComponent("\(SessionRenamer.newSessionId(oldId: oldId, name: name)).json")
            let moved = (try? await withDeadline(seconds: bound, label: "where the transcript is") {
                FileManager.default.fileExists(atPath: newTranscript.path)
            }) ?? false
            Logger.state.error("""
                The session rename did not finish within \(Self.seconds(self.folderWriteDeadline), privacy: .public) s — it runs on; \
                the transcript is shown \(moved ? "under the new name" : "where it was", privacy: .public)
                """)
            return moved
                ? TranscriptionResult(jsonPath: newTranscript, removedRecordings: result.removedRecordings, quotaPass: result.quotaPass)
                : result
        }
    }
}
