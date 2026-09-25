import Foundation
import os

// The recording folder, as the relaunch and the start see it (L review 128): whether it can be written (a ghost
// mount, a dangling link, a read-only volume, a link cycle), and what a re-attach, a resume and a salvage read from
// it. Moved out of RecordingCoordinator.swift as is; every read here is blocking file-system work, run only through
// the coordinator's bounded folder reader (`FolderReads`, L review 123).
extension RecordingCoordinator {
    /// What a re-attach needs from the session's folder, read off the main actor (L review 75).
    struct ReattachScan {
        /// Already transcribed: never re-attached — its capture is stopped and the salvage cleans up (L review 157).
        var finalized = false
        let persisted: SessionState?
        /// The helper's live file: the newest chunk on disk (indices only grow), never below the sentinel's.
        let liveIndex: Int
        /// When the live chunk began: its file's creation — before this process existed.
        let liveStartedAt: Date?
        /// Chunks the crash cut short (sealed, never processed), the live file excluded, with their creation.
        let orphans: [(chunk: CrashRecoveryPlanner.OrphanChunk, created: Date?)]
    }

    nonisolated static func scanForReattach(sentinel: RecordingSentinel, outputDir: URL) -> ReattachScan {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        let persisted = SessionState.read(directory: outputDir, sessionId: sessionId)
        let onDisk = CrashRecoveryPlanner.orphanChunks(
            outputDirectory: outputDir, sessionId: sessionId, completedIndices: Set(persisted?.chunks.map(\.index) ?? []))
        let liveIndex = max(sentinel.chunkIndex, onDisk.map(\.index).max() ?? sentinel.chunkIndex)
        return ReattachScan(
            finalized: CrashRecoveryPlanner.isFinalized(outputDirectory: outputDir, sessionId: sessionId),
            persisted: persisted, liveIndex: liveIndex,
            liveStartedAt: creationDate(outputDir.appendingPathComponent("\(sessionId)-\(liveIndex).wav")),
            orphans: onDisk.filter { $0.index != liveIndex }.map { ($0, creationDate(outputDir.appendingPathComponent($0.baseName + ".wav"))) })
    }

    nonisolated static func creationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// What `folderStatus` asks the file system. Injectable, so a ghost mount point, a dangling link and a
    /// hung share are testable.
    struct FolderProbe: Sendable {
        var exists: @Sendable (URL) -> Bool
        var isWritable: @Sendable (URL) -> Bool
        var isVolumeRoot: @Sendable (URL) -> Bool
        /// The destination of the symbolic link at this path (without following it), nil when it is not one.
        var symlinkDestination: @Sendable (URL) -> String? = { _ in nil }
        /// Whether the item at this path belongs to root (L review 179): an automount point's.
        var ownerIsRoot: @Sendable (URL) -> Bool = { _ in false }

        static let live = FolderProbe(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isWritable: { FileManager.default.isWritableFile(atPath: $0.path) },
            isVolumeRoot: { (try? $0.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true },
            symlinkDestination: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path) },
            ownerIsRoot: { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.ownerAccountID] as? NSNumber)?.intValue == 0 }
        )
    }

    /// Whether a recording folder can be written (L review 79: "not there" and "there but read-only" are
    /// different problems, and said differently).
    enum FolderStatus: Equatable, Sendable {
        case reachable
        /// Not there: an unmounted volume, a ghost mount point, a dangling link, a link cycle.
        case unreachable
        /// There — or, not created yet, its nearest existing ancestor is — but it cannot be written: its
        /// permissions, a read-only volume (L review 126).
        case notWritable
    }

    /// The session's folder status: the folder itself or, when it was never created (a crash before the
    /// helper made the day folder), its nearest existing ancestor must be writable. Every symbolic link in
    /// the path is substituted first — a DANGLING one too (L review 71): `resolvingSymlinksInPath()` leaves
    /// it alone, and `~/Recordings → /Volumes/Ext/…` with the drive unplugged read as the writable home
    /// folder. A folder under `/Volumes/<name>` is reachable only while that volume is MOUNTED: after an
    /// unplug a leftover folder there is a ghost on the boot volume, not the drive (L follow-up 39).
    ///
    /// A symbolic-link cycle (40 links followed) is unreachable, never "reachable" (L review 125). Once any mount
    /// check has passed, an unwritable nearest ancestor is a permissions problem — a read-only volume is not a
    /// missing drive (L review 126) — except under an automount root (`/Network`, `/net`, `/mnt`): there a folder that
    /// is not there, below an ancestor that is root's and cannot be written, is a share that is not mounted —
    /// unreachable (L review 179).
    nonisolated static func folderStatus(_ dir: URL, probe: FolderProbe = .live) -> FolderStatus {
        let (resolved, cycle) = resolution(dir, probe: probe)
        guard !cycle else { return .unreachable }
        let parts = resolved.pathComponents
        if parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" {
            let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2])
            guard probe.exists(mount), probe.isVolumeRoot(mount) else { return .unreachable }
        }
        if probe.exists(resolved) { return probe.isWritable(resolved) ? .reachable : .notWritable }
        let ancestor = nearestExistingDirectory(resolved, probe: probe)
        if probe.isWritable(ancestor) { return .reachable }
        if parts.count >= 3, parts[0] == "/", automountRoots.contains(parts[1]), probe.ownerIsRoot(ancestor) { return .unreachable }
        return .notWritable
    }

    /// Where macOS mounts network shares on demand (autofs): `/Network/Servers`, `/net/<host>`, and the conventional `/mnt`.
    nonisolated static let automountRoots: Set<String> = ["Network", "net", "mnt"]

    nonisolated static func folderReachable(_ dir: URL, probe: FolderProbe = .live) -> Bool {
        folderStatus(dir, probe: probe) == .reachable
    }

    /// `dir` with every symbolic link in its path substituted, a dangling one included, component by
    /// component (a relative link against its own folder); `/private` normalized as `resolvingSymlinksInPath`
    /// does. A loop stops after 40 links.
    nonisolated static func resolvedFolder(_ dir: URL, probe: FolderProbe = .live) -> URL {
        resolution(dir, probe: probe).url
    }

    /// `resolvedFolder`, and whether the 40-link cap was hit — a cycle (L review 125).
    nonisolated static func resolution(_ dir: URL, probe: FolderProbe = .live) -> (url: URL, cycle: Bool) {
        // Lexical only: `standardizedFileURL` strips `/private`, which would turn `/var → private/var` into a loop.
        func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
        var remaining = components(dir.path)
        var resolved: [String] = []
        var links = 0
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { _ = resolved.popLast(); continue }
            let next = URL(fileURLWithPath: "/" + (resolved + [part]).joined(separator: "/"))
            guard let destination = probe.symlinkDestination(next) else {
                resolved.append(part)
                continue
            }
            guard links < 40 else { return (URL(fileURLWithPath: "/" + (resolved + [part] + remaining).joined(separator: "/")), true) }
            links += 1
            // An absolute link restarts from the root; a relative one resolves against its own folder.
            if destination.hasPrefix("/") { resolved = [] }
            remaining = components(destination) + remaining
        }
        return (URL(fileURLWithPath: "/" + resolved.joined(separator: "/")).resolvingSymlinksInPath().standardizedFileURL, false)
    }

    /// `dir`, or its nearest ancestor that exists (at worst `/`), every link substituted.
    nonisolated static func nearestExistingDirectory(_ dir: URL, probe: FolderProbe = .live) -> URL {
        var candidate = resolvedFolder(dir, probe: probe)
        while !probe.exists(candidate) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return candidate.resolvingSymlinksInPath().standardizedFileURL   // `/private` normalized, now that it exists
    }

    /// What a resume needs from the session's folder, read off the main actor (L review 75).
    struct ResumeScan {
        /// Already transcribed: never resumed (L review 93).
        var finalized = false
        let plan: (baseName: String, index: Int, newSentinel: RecordingSentinel)
        let persisted: SessionState?
        /// The chunks the crash cut short, the plan's own file excluded, with their creation.
        let orphans: [(chunk: CrashRecoveryPlanner.OrphanChunk, created: Date?)]
        let crashedAt: Date
    }

    nonisolated static func scanForResume(sentinel: RecordingSentinel, outputDir: URL, lastAlive: Date?) -> ResumeScan {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        let plan = resumePlan(sentinel: sentinel, outputDir: outputDir)
        let persisted = SessionState.read(directory: outputDir, sessionId: sessionId)
        let orphans = CrashRecoveryPlanner.orphanChunks(
            outputDirectory: outputDir, sessionId: sessionId, completedIndices: Set(persisted?.chunks.map(\.index) ?? [])
        ).filter { $0.baseName != plan.baseName }
        return ResumeScan(finalized: CrashRecoveryPlanner.isFinalized(outputDirectory: outputDir, sessionId: sessionId),
                          plan: plan, persisted: persisted,
                          orphans: orphans.map { ($0, creationDate(outputDir.appendingPathComponent($0.baseName + ".wav"))) },
                          crashedAt: crashTime(sentinel: sentinel, outputDir: outputDir, lastAlive: lastAlive))
    }

    /// The resume's capture name: `CrashRecoveryPlanner.planRestart`'s index (the shared collision guard,
    /// #170), moved past any index that still has a chunk artefact on disk — like the rotator's own
    /// rule, the archive included: a chunk archived just before the crash, not yet in session.json,
    /// would otherwise be overwritten when the resumed chunk is archived under its name.
    nonisolated static func resumePlan(sentinel: RecordingSentinel, outputDir: URL) -> (baseName: String, index: Int, newSentinel: RecordingSentinel) {
        let planned = CrashRecoveryPlanner.planRestart(sentinel: sentinel, outputDirectory: outputDir)
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        func onDisk(_ index: Int) -> Bool {
            let base = outputDir.appendingPathComponent("\(sessionId)-\(index)").path
            return [".wav", "_mic.wav", ".m4a"].contains { FileManager.default.fileExists(atPath: base + $0) }
        }
        var index = planned.newSentinel.chunkIndex
        guard onDisk(index) else { return (planned.baseName, index, planned.newSentinel) }
        while onDisk(index) { index += 1 }
        Logger.state.error("Resume index \(planned.newSentinel.chunkIndex, privacy: .public) has chunk files on disk — resuming at \(index, privacy: .public)")
        let baseName = "\(sessionId)-\(index)"
        var newSentinel = sentinel.incrementedSegment(
            systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
            micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
        )
        newSentinel.chunkIndex = index
        return (baseName, index, newSentinel)
    }

    /// When capture actually stopped: the newest orphan chunk WAV's modification date when one exists
    /// (the helper sealed it on XPC disconnect, and WavFileWriter syncs every 0.5 s) — preferred even over
    /// a newer `lastAliveAt`, which vouches for the app, not the capture (L follow-up 37) — else the
    /// sentinel's `lastAliveAt` — refreshed every 60 s, so it can be up to that much early (C7/C9) — else
    /// `startedAt`. Never later than now. Read BEFORE a salvage archives (deletes) the orphans.
    nonisolated static func crashTime(sentinel: RecordingSentinel, outputDir: URL, lastAlive: Date?) -> Date {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        let orphanEnds = CrashRecoveryPlanner.orphanChunks(
            outputDirectory: outputDir, sessionId: sessionId,
            completedIndices: Set(SessionState.read(directory: outputDir, sessionId: sessionId)?.chunks.map(\.index) ?? [])
        )
        .flatMap { [$0.baseName + ".wav", $0.baseName + "_mic.wav"] }
        .compactMap { (try? FileManager.default.attributesOfItem(atPath: outputDir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
        return min(orphanEnds.max() ?? lastAlive ?? sentinel.startedAt, Date())
    }

    /// Whether the session was already finalized (R2's durable marker, or its transcript).
    enum FinalizedState: Equatable, Sendable {
        case notFinalized
        /// Its transcript verifies: the leftovers were cleaned up (R2's `cleanupFinalized`). Nothing more to do.
        case cleanedUp
        /// Its transcript cannot be read back: rebuilt from its session.json when there is one (L review 93b).
        case damaged
    }

    /// What a salvage needs from the session's folder, read off the main actor (L review 75).
    struct SalvageScan {
        /// Checked FIRST (L review 93, 120): a finalized session is never transcribed again.
        var finalized: FinalizedState = .notFinalized
        let stoppedAt: Date
        let chunkCount: Int
        /// Of `chunkCount`, the chunks on disk not yet transcribed into the session — what the salvage needs the engine for
        /// (L review 178).
        var orphanCount = 0
        /// The sentinel's own file holds audio, yet it is not a chunk of the session: a pre-0.6 recording.
        let legacyAudio: Bool
        /// When that older-format recording was last written: the later of its two files (L review 86).
        let legacyLastWrite: Date?
        /// A finalized session's audio written after its transcript, which the transcript does not list (L review
        /// 137); nil: none.
        var lateAudio: LateAudio?
    }

    /// Audio of a finished session recorded after its transcript was written (L reviews 137, 176, 181).
    struct LateAudio: Equatable, Sendable {
        /// The chunk files, by name.
        let files: [String]
        /// Their length; nil when a file's length could not be read — never a guess.
        let seconds: Double?
        /// The transcript they are not in, by name.
        let transcript: String
    }

    /// The note's key for the reference time: the transcript's modification time as the FIRST look found it (L review 176).
    nonisolated static let lateAudioReferenceKey = "transcript_modified_at"

    /// Chunk audio of a FINALIZED session written after its transcript — later than the transcript as first written, and
    /// not among the files it lists — is noted in the record (`metadata.audio_after_transcript`), once (L review 137).
    /// Later is judged from a FIXED reference (L review 176): the transcript's time as the first look found it, kept in the
    /// note — never its modification time now, which the note's own write moves. So every pass finds the same files, and
    /// a pass cut short after the note (a Start, a timeout) never loses the row. A file with no audio in it (a header, or
    /// less) is not late audio. Returns nil when there is none. Blocking file work: only through the bounded folder reader.
    nonisolated static func noteAudioAfterTranscript(outputDir: URL, sessionId: String) -> LateAudio? {
        let fm = FileManager.default
        let transcriptURL = outputDir.appendingPathComponent("\(sessionId).json")
        guard let modified = (try? fm.attributesOfItem(atPath: transcriptURL.path))?[.modificationDate] as? Date,
              let data = try? Data(contentsOf: transcriptURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var metadata = json["metadata"] as? [String: Any] else { return nil }
        let note = metadata["audio_after_transcript"] as? [String: Any]
        let written = (note?[lateAudioReferenceKey] as? Double).map(Date.init(timeIntervalSince1970:)) ?? modified
        let listed = Set(metadata["audio_files"] as? [String] ?? [])
        let prefix = "\(sessionId)-"
        let names = ((try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? []).filter { name in
            name.hasPrefix(prefix) && !name.hasSuffix("_mic.wav") && (name.hasSuffix(".wav") || name.hasSuffix(".m4a"))
                && Int(name.dropFirst(prefix.count).dropLast(4)) != nil && !listed.contains(name)
        }
        let late = names.filter { name in
            let attributes = try? fm.attributesOfItem(atPath: outputDir.appendingPathComponent(name).path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return size > 44 && (attributes?[.modificationDate] as? Date ?? .distantPast) > written
        }.sorted()
        guard !late.isEmpty else { return nil }
        let durations = late.map { TranscriptAssembler.duration(of: outputDir.appendingPathComponent($0)) }
        // A file whose length cannot be read makes the total unknown: said so, never made up (L review 181).
        let seconds: Double? = durations.contains { $0 <= 0 } ? nil : durations.reduce(0, +)
        if note?["files"] as? [String] != late || note?[lateAudioReferenceKey] == nil {
            var noted: [String: Any] = [
                "files": late,
                lateAudioReferenceKey: written.timeIntervalSince1970,
                "note": "Audio recorded after this transcript was written is kept beside it, not transcribed.",
            ]
            if let seconds { noted["seconds"] = seconds }
            metadata["audio_after_transcript"] = noted
            json["metadata"] = metadata
            do {
                try TranscriptAssembler.write(json, to: transcriptURL)
            } catch {
                Logger.files.error("Could not note the audio recorded after the transcript: \(error, privacy: .private)")
            }
        }
        return LateAudio(files: late, seconds: seconds, transcript: transcriptURL.lastPathComponent)
    }

    nonisolated static func scanForSalvage(sentinel: RecordingSentinel, outputDir: URL) -> SalvageScan {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        var finalized = FinalizedState.notFinalized
        if CrashRecoveryPlanner.isFinalized(outputDirectory: outputDir, sessionId: sessionId) {
            // Verified: cleaned up here (no rename, no summary) and done. Unreadable: rebuilt by the salvage (93b).
            if CrashRecoveryPlanner.cleanupFinalized(outputDirectory: outputDir, sessionId: sessionId) {
                return SalvageScan(finalized: .cleanedUp, stoppedAt: Date(), chunkCount: 0, legacyAudio: false, legacyLastWrite: nil,
                                   lateAudio: noteAudioAfterTranscript(outputDir: outputDir, sessionId: sessionId))
            }
            finalized = .damaged
        }
        let counts = chunkCounts(outputDir: outputDir, sessionId: sessionId, finalized: finalized == .damaged)
        let files = [sentinel.systemAudioPath, sentinel.micAudioPath].compactMap { try? FileManager.default.attributesOfItem(atPath: $0) }
        let withAudio = files.filter { ($0[.size] as? Int ?? 0) > 44 }
        return SalvageScan(finalized: finalized, stoppedAt: crashTime(sentinel: sentinel, outputDir: outputDir, lastAlive: sentinel.lastAliveAt),
                           chunkCount: counts.completed + counts.onDisk, orphanCount: counts.onDisk, legacyAudio: !withAudio.isEmpty,
                           legacyLastWrite: withAudio.compactMap { $0[.modificationDate] as? Date }.max())
    }

    /// Chunks of `sessionId` on disk: completed in `session.json`, plus chunk files not yet in it — the one count the
    /// salvage and the unsalvaged outcome share (L review 135). `finalized`: a finalized session has no "orphans"
    /// (R2), its chunk files are its record's audio — counted all the same, as kept. Reads the folder: only through
    /// `readOffMain`.
    nonisolated static func chunksOnDisk(outputDir: URL, sessionId: String, finalized: Bool) -> Int {
        let counts = chunkCounts(outputDir: outputDir, sessionId: sessionId, finalized: finalized)
        return counts.completed + counts.onDisk
    }

    /// `chunksOnDisk`, split: the chunks completed in `session.json`, and those on disk not in it.
    nonisolated static func chunkCounts(outputDir: URL, sessionId: String, finalized: Bool) -> (completed: Int, onDisk: Int) {
        let completed = Set(SessionState.read(directory: outputDir, sessionId: sessionId)?.chunks.map(\.index) ?? [])
        let onDisk = finalized
            ? CrashRecoveryPlanner.unregisteredChunks(outputDirectory: outputDir, sessionId: sessionId, completedIndices: completed)
            : CrashRecoveryPlanner.orphanChunks(outputDirectory: outputDir, sessionId: sessionId, completedIndices: completed)
        return (completed.count, onDisk.count)
    }
}
