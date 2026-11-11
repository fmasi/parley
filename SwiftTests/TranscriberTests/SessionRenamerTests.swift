import Testing
import Foundation
@testable import TranscriberCore

/// Renaming a finished recording (#357): the names, the plan, and the rename on disk — every file and every reference
/// moved together, refused with nothing touched, rolled back on a failure part-way. Synthetic files in a temp folder only.
@Suite struct SessionRenamerNameTests {

    @Test func aRecordingsTranscriptNamesItsSessionAndName() {
        let named = URL(fileURLWithPath: "/r/093000-weekly sync.json")
        #expect(SessionRenamer.sessionId(ofTranscript: named) == "093000-weekly sync")
        #expect(SessionRenamer.sessionName(ofTranscript: named) == "weekly sync")
        let unnamed = URL(fileURLWithPath: "/r/093000.json")
        #expect(SessionRenamer.sessionId(ofTranscript: unnamed) == "093000")
        #expect(SessionRenamer.sessionName(ofTranscript: unnamed) == "")
    }

    @Test func anythingElseIsNotARecording() {
        for file in ["meeting.json", "session.json", "09300-x.json", "093000-.json", "093000x.json", "093000-x.srt",
                     "093000-x.json.bak", "ab3000-x.json"] {
            #expect(SessionRenamer.sessionId(ofTranscript: URL(fileURLWithPath: "/r/\(file)")) == nil, "\(file)")
        }
    }

    @Test func theNewIdKeepsTheTimestampAndIsSanitizedAsAtTheStart() {
        #expect(SessionRenamer.newSessionId(oldId: "093000", name: "planning") == "093000-planning")
        #expect(SessionRenamer.newSessionId(oldId: "093000-old", name: "  new name \n") == "093000-new name")
        #expect(SessionRenamer.newSessionId(oldId: "093000-old", name: "a\nb") == "093000-a b")
        #expect(SessionRenamer.newSessionId(oldId: "093000-old", name: "a/b:c") == "093000-abc")
        // No name: the bare timestamp, as a recording started without one.
        #expect(SessionRenamer.newSessionId(oldId: "093000-old", name: "   ") == "093000")
        #expect(SessionRenamer.newSessionId(oldId: "093000-old", name: "/:") == "093000")
        // The same fitting as a new recording: a long name fits the byte limit, and gives the id a start would.
        let long = String(repeating: "é", count: 400)
        let id = SessionRenamer.newSessionId(oldId: "093000", name: long)
        #expect(id.utf8.count <= maxSessionIdBytes)
        let started = RecordingCoordinator.startNaming(sessionName: long, now: Date()).chunkBaseName
        #expect(id.dropFirst(6) == started.dropFirst(6))
    }

    @Test func aSessionsFilesAreFoundByName() {
        let id = "093000-standup"
        for name in [".093000-standup.finalized", "093000-standup.json", "093000-standup.json.bak", "093000-standup.srt",
                     "093000-standup.txt", "093000-standup.m4a", "093000-standup-0.m4a", "093000-standup-12.m4a",
                     "093000-standup-0.wav", "093000-standup-0_mic.wav", "093000-standup-0-RESCUED-remote.wav",
                     "093000-standup-summary.md", "093000-standup-summary.damaged.md", "093000-standup.diag.jsonl",
                     "093000-standup.relaunch-2.diag.jsonl", "093000-standup.diag.live.jsonl",
                     "093000-standup.damaged.json"] {
            #expect(SessionRenamer.belongs(name, to: id), "\(name)")
        }
        for name in ["093000-standup", "093000-standup.", "093000-standup-review.json", "093000-standup-2 notes.json",
                     "093000-standup-summary", "093000-standupx.json", ".093000-standup.json.0B0E.tmp",
                     "093000-standup.json.8F7C0A8E-6B5A-4C1E-9A53-0D6A3E7F1A22.tmp", "session.json",
                     ".093000-standup.finalized.bak", "x093000-standup.json"] {
            #expect(!SessionRenamer.belongs(name, to: id), "\(name)")
        }
    }
}

@Suite struct SessionRenamerPlanTests {
    let folder = URL(fileURLWithPath: "/r/2026-01-02")

    @Test func anUnnamedSessionGetsEveryFileRenamed() throws {
        let names = [".160527.finalized", "160527.json", "160527-0.m4a", "160527-1.m4a", "160527.srt", "160527-summary.md",
                     "160527.diag.jsonl", "101500-other.json", "101500-other-0.m4a", "session-101500-other.json"]
        let plan = try SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-weekly", names: names)
        #expect(Set(plan.moves.map(\.from)) == Set(names.prefix(7)))
        #expect(Set(plan.moves.map(\.to)) == [".160527-weekly.finalized", "160527-weekly.json", "160527-weekly-0.m4a",
                                              "160527-weekly-1.m4a", "160527-weekly.srt", "160527-weekly-summary.md",
                                              "160527-weekly.diag.jsonl"])
        #expect(plan.newTranscript.lastPathComponent == "160527-weekly.json")
    }

    @Test func aFileOfTheNewNameAlreadyThereRefusesIt() {
        let names = ["160527.json", "160527-0.m4a", "160527-weekly-3.m4a"]
        #expect(throws: SessionRenamer.RenameError.nameTaken("160527-weekly")) {
            try SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-weekly", names: names)
        }
    }

    @Test func aTargetThatIsAnotherFileOfThePlanRefusesIt() {
        // `160527.m4a` (the merge) would land on `160527-2.m4a` (chunk 2).
        let names = ["160527.json", "160527.m4a", "160527-2.m4a"]
        #expect(throws: SessionRenamer.RenameError.nameTaken("160527-2")) {
            try SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-2", names: names)
        }
        // Without the merge it is consistent: every chunk follows.
        let plan = try? SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-2",
                                            names: ["160527.json", "160527-0.m4a", "160527-2.m4a"])
        #expect(plan.map { Set($0.moves.map(\.to)) } == ["160527-2.json", "160527-2-0.m4a", "160527-2-2.m4a"])
    }

    @Test func anotherRecordingsTranscriptThatLooksLikeOneOfItsFilesRefusesIt() {
        // Session "160527-2" shares the timestamp (moved in by hand): its transcript reads as chunk 2 of "160527".
        #expect(throws: SessionRenamer.RenameError.ambiguous) {
            try SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-weekly",
                                    names: ["160527.json", "160527-2.json"])
        }
    }
}

@Suite struct SessionRenamerTranscriptContentTests {
    @Test func theReferencesFollowTheRename() throws {
        let folder = URL(fileURLWithPath: "/r/day")
        let plan = try SessionRenamer.plan(folder: folder, oldId: "160527", newId: "160527-weekly",
                                           names: ["160527.json", "160527-0.m4a", "160527-1.m4a"])
        let json: [String: Any] = ["segments": [], "metadata": [
            "audio_files": ["160527-0.m4a", "160527-1.m4a"],
            "audio_paths": ["/r/day/160527-0.m4a", "/r/day/./160527-1.m4a", "/elsewhere/160527-0.m4a"],
            "audio_removed": ["files": ["160527-0.m4a"], "reason": "storage_limit"],
            "speaker_names": ["Local Speaker 1": "160527-0.m4a"],
        ]]
        let metadata = try #require(SessionRenamer.updatedTranscript(json, plan: plan)["metadata"] as? [String: Any])
        #expect(metadata["audio_files"] as? [String] == ["160527-weekly-0.m4a", "160527-weekly-1.m4a"])
        // A path outside the session's folder names another file: left as it is.
        #expect(metadata["audio_paths"] as? [String] == ["/r/day/160527-weekly-0.m4a", "/r/day/./160527-weekly-1.m4a",
                                                         "/elsewhere/160527-0.m4a"])
        #expect((metadata["audio_removed"] as? [String: Any])?["files"] as? [String] == ["160527-weekly-0.m4a"])
        // Nothing else is touched.
        #expect(metadata["speaker_names"] as? [String: String] == ["Local Speaker 1": "160527-0.m4a"])
    }

    @Test func theSummaryFooterAndTheMarkerNameTheNewSession() throws {
        let plan = try SessionRenamer.plan(folder: URL(fileURLWithPath: "/r"), oldId: "160527", newId: "160527-weekly",
                                           names: ["160527.json"])
        let summary = "# Notes\n\nSee 160527.json.\n\n---\n*Source transcript: `160527.json`*\n"
        #expect(SessionRenamer.updatedSummary(summary, plan: plan)
                == "# Notes\n\nSee 160527.json.\n\n---\n*Source transcript: `160527-weekly.json`*\n")
        #expect(SessionRenamer.updatedSummary("# Notes, no footer\n", plan: plan) == nil)
        let marker = SessionRenamer.updatedMarker(
            ["session_id": "160527", "transcript": "160527.json", "finalized_at": "2026-01-02T10:00:00Z"], plan: plan)
        #expect(marker as? [String: String] == ["session_id": "160527-weekly", "transcript": "160527-weekly.json",
                                                "finalized_at": "2026-01-02T10:00:00Z"])
    }
}

/// On disk, in a temp folder.
@Suite struct SessionRenamerDiskTests {

    /// A finished chunked session `id` in a fresh folder, and an unrelated one beside it.
    struct Folder {
        let url: URL
        let id: String
        var transcript: URL { url.appendingPathComponent("\(id).json") }

        init(id: String = "160527") throws {
            self.id = id
            url = FileManager.default.temporaryDirectory.appendingPathComponent("session-renamer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let json: [String: Any] = [
                "segments": [["start": 0.0, "end": 1.0, "speaker": "Local Speaker 1", "text": "hello", "source": "local"]],
                "metadata": ["audio_files": ["\(id)-0.m4a", "\(id)-1.m4a"],
                             "audio_paths": [url.appendingPathComponent("\(id)-0.m4a").path,
                                             url.appendingPathComponent("\(id)-1.m4a").path]],
            ]
            try write("\(id).json", JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
            try write("\(id)-0.m4a", Data("chunk0".utf8))
            try write("\(id)-1.m4a", Data("chunk1".utf8))
            try write("\(id)-0.wav", Data("wav0".utf8))
            try write("\(id)-0_mic.wav", Data("mic0".utf8))
            try write("\(id).srt", Data("1\n00:00:00,000 --> 00:00:01,000\nhello\n".utf8))
            try write("\(id)-summary.md", Data("# Notes\n\n---\n*Source transcript: `\(id).json`*\n".utf8))
            try write("\(id).diag.jsonl", Data("{\"kind\":\"captureStart\",\"detail\":{\"chunk\":\"\(id)-0\"}}\n".utf8))
            try write("\(id).json.bak", Data("{\"metadata\":{\"audio_files\":[\"\(id)-0.m4a\"]}}".utf8))
            try write(".\(id).finalized", JSONSerialization.data(
                withJSONObject: ["session_id": id, "transcript": "\(id).json", "finalized_at": "2026-01-02T10:00:00Z"],
                options: [.sortedKeys]))
            try write("101500-other.json", Data("{\"metadata\":{},\"segments\":[]}".utf8))
            try write("101500-other-0.m4a", Data("other".utf8))
        }

        func write(_ name: String, _ data: Data) throws { try data.write(to: url.appendingPathComponent(name)) }
        func read(_ name: String) -> Data? { try? Data(contentsOf: url.appendingPathComponent(name)) }
        func text(_ name: String) -> String? { read(name).flatMap { String(data: $0, encoding: .utf8) } }
        func names() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []) }
        /// Every file and its bytes: what "nothing was touched" compares.
        func snapshot() -> [String: Data] {
            Dictionary(uniqueKeysWithValues: names().map { ($0, read($0) ?? Data()) })
        }
        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    @Test func everyFileAndEveryReferenceFollowsTheNewName() throws {
        let f = try Folder(); defer { f.remove() }
        let before = f.snapshot()
        let renamed = try SessionRenamer.rename(transcript: f.transcript, toName: "weekly sync")
        let new = "160527-weekly sync"
        #expect(renamed == f.url.appendingPathComponent("\(new).json"))
        #expect(f.names() == [".\(new).finalized", "\(new).json", "\(new)-0.m4a", "\(new)-1.m4a", "\(new)-0.wav",
                              "\(new)-0_mic.wav", "\(new).srt", "\(new)-summary.md", "\(new).diag.jsonl", "\(new).json.bak",
                              "101500-other.json", "101500-other-0.m4a"])
        // The audio itself is unchanged, only its name.
        #expect(f.read("\(new)-0.m4a") == before["160527-0.m4a"] && f.read("\(new)-0_mic.wav") == before["160527-0_mic.wav"])
        let data = try #require(f.read("\(new).json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["audio_files"] as? [String] == ["\(new)-0.m4a", "\(new)-1.m4a"])
        #expect(metadata["audio_paths"] as? [String] == [f.url.appendingPathComponent("\(new)-0.m4a").path,
                                                         f.url.appendingPathComponent("\(new)-1.m4a").path])
        #expect((json["segments"] as? [[String: Any]])?.first?["text"] as? String == "hello")
        #expect(f.text("\(new)-summary.md") == "# Notes\n\n---\n*Source transcript: `\(new).json`*\n")
        let markerData = try #require(f.read(".\(new).finalized"))
        let marker = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: String])
        #expect(marker == ["session_id": new, "transcript": "\(new).json", "finalized_at": "2026-01-02T10:00:00Z"])
        // The event record and the backup are renamed, their contents as written.
        #expect(f.read("\(new).diag.jsonl") == before["160527.diag.jsonl"])
        #expect(f.read("\(new).json.bak") == before["160527.json.bak"])
        // The new session reads as finalized; the old id has nothing left.
        #expect(CrashRecoveryPlanner.isFinalized(outputDirectory: f.url, sessionId: new))
        #expect(!CrashRecoveryPlanner.isFinalized(outputDirectory: f.url, sessionId: "160527"))
        // The other recording is untouched.
        #expect(f.read("101500-other.json") == before["101500-other.json"])
    }

    @Test func theSameNameChangesNothing() throws {
        let f = try Folder(id: "160527-standup"); defer { f.remove() }
        let before = f.snapshot()
        #expect(try SessionRenamer.rename(transcript: f.transcript, toName: "  standup ") == f.transcript)
        #expect(f.snapshot() == before)
    }

    @Test func aNameAlreadyTakenRefusesWithNothingTouched() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("160527-weekly.json", Data("{}".utf8))
        let before = f.snapshot()
        #expect(throws: SessionRenamer.RenameError.nameTaken("160527-weekly")) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
        #expect(f.snapshot() == before)
    }

    @Test func aSessionWithStateInItsFolderIsNotRenamed() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("session.json", Data("{\"sessionId\":\"160527\"}".utf8))
        let before = f.snapshot()
        #expect(throws: SessionRenamer.RenameError.inProgress) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
        #expect(f.snapshot() == before)
    }

    @Test func aMovedAsideStateOfTheSessionAlsoRefusesIt() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("session-160527.json", Data("{\"sessionId\":\"160527\"}".utf8))
        #expect(throws: SessionRenamer.RenameError.inProgress) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
    }

    /// An unfinished session of the NEW id would take the renamed marker for its own and never be finished.
    @Test func anUnfinishedSessionOfTheNewNameRefusesIt() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("session.json", Data("{\"sessionId\":\"160527-weekly\"}".utf8))
        let before = f.snapshot()
        #expect(throws: SessionRenamer.RenameError.nameTaken("160527-weekly")) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
        #expect(f.snapshot() == before)
    }

    @Test func stateWhoseSessionCannotBeReadRefusesIt() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("session.json", Data("not json".utf8))
        #expect(throws: SessionRenamer.RenameError.cannotTell) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
    }

    @Test func anUnreadableTranscriptRefusesWithNothingTouched() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("160527.json", Data("not json".utf8))
        let before = f.snapshot()
        #expect(throws: SessionRenamer.RenameError.transcriptUnreadable) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly")
        }
        #expect(f.snapshot() == before)
    }

    @Test func aTranscriptThatIsNotARecordingsIsRefused() throws {
        let f = try Folder(); defer { f.remove() }
        try f.write("meeting.json", Data("{\"metadata\":{},\"segments\":[]}".utf8))
        #expect(throws: SessionRenamer.RenameError.notARecording) {
            try SessionRenamer.rename(transcript: f.url.appendingPathComponent("meeting.json"), toName: "weekly")
        }
    }

    /// A change of case only: on a case-insensitive volume the "existing" target is the file itself.
    @Test func aChangeOfCaseOnlyIsARename() throws {
        let f = try Folder(id: "160527-standup"); defer { f.remove() }
        let upper = "Standup"
        let renamed = try SessionRenamer.rename(transcript: f.transcript, toName: upper)
        #expect(renamed.lastPathComponent == "160527-\(upper).json")
        #expect(f.names().contains("160527-\(upper).json") && f.names().contains("160527-\(upper)-0.m4a"))
        #expect(!f.names().contains("160527-standup.json"))
        let data = try #require(f.read("160527-\(upper).json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["metadata"] as? [String: Any])?["audio_files"] as? [String] == ["160527-\(upper)-0.m4a", "160527-\(upper)-1.m4a"])
    }

    // MARK: - All or nothing

    /// The disk, with one chosen operation failing.
    final class FailingFileSystem: SessionRenameFileSystem, @unchecked Sendable {
        let live = LiveSessionRenameFileSystem()
        /// Fail the n-th move (1-based), counting moves back too.
        var failMove: Set<Int> = []
        /// Fail every replace of a file with this name.
        var failReplace: String?
        private(set) var moves = 0

        func list(_ folder: URL) -> [String]? { live.list(folder) }
        func sessionIdsWithState(in folder: URL) -> Set<String>? { live.sessionIdsWithState(in: folder) }
        func exists(_ url: URL) -> Bool { live.exists(url) }
        func sameFile(_ a: URL, _ b: URL) -> Bool { live.sameFile(a, b) }
        func read(_ url: URL) -> Data? { live.read(url) }
        func move(_ from: URL, to: URL, sameFile: Bool) throws {
            moves += 1
            if failMove.contains(moves) { throw CocoaError(.fileWriteUnknown) }
            try live.move(from, to: to, sameFile: sameFile)
        }
        func replace(_ url: URL, with data: Data) throws {
            if url.lastPathComponent == failReplace { throw CocoaError(.fileWriteUnknown) }
            try live.replace(url, with: data)
        }
    }

    @Test func aMoveThatFailsPutsEveryFileBack() throws {
        let f = try Folder(); defer { f.remove() }
        let before = f.snapshot()
        let fs = FailingFileSystem()
        fs.failMove = [5]
        #expect(throws: SessionRenamer.RenameError.failedAndRolledBack) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly", fileSystem: fs)
        }
        #expect(fs.moves == 9, "4 moved, the 5th failed, 4 moved back")
        #expect(f.snapshot() == before)
    }

    @Test func aRewriteThatFailsRestoresTheContentsAndMovesEverythingBack() throws {
        let f = try Folder(); defer { f.remove() }
        let before = f.snapshot()
        let fs = FailingFileSystem()
        // The transcript is rewritten first, then the summary: the summary's write fails.
        fs.failReplace = "160527-weekly-summary.md"
        #expect(throws: SessionRenamer.RenameError.failedAndRolledBack) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly", fileSystem: fs)
        }
        #expect(f.snapshot() == before)
    }

    @Test func aRollbackThatFailsSaysSo() throws {
        let f = try Folder(); defer { f.remove() }
        let fs = FailingFileSystem()
        fs.failMove = [3, 4]   // the 3rd move fails, then the first move back (of the 2nd file)
        #expect(throws: SessionRenamer.RenameError.failedPartway) {
            try SessionRenamer.rename(transcript: f.transcript, toName: "weekly", fileSystem: fs)
        }
    }

    @Test func everyRefusalSaysWhyWithoutAPath() {
        let errors: [SessionRenamer.RenameError] = [.notARecording, .inProgress, .cannotTell, .ambiguous,
                                                    .nameTaken("160527-weekly"), .transcriptUnreadable,
                                                    .failedAndRolledBack, .failedPartway]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty && !text.contains("/"), "\(error)")
        }
    }
}

/// What the app asks before a rename, and what follows it (#357).
@MainActor
@Suite struct SessionRenameCoordinatorTests {

    @Test func aSessionIsInFlightWhileItIsRecordedFinishedOrSummarized() throws {
        let h = try Harness()
        let folder = h.tmp.appendingPathComponent("rec/2026-01-02")
        let transcript = folder.appendingPathComponent("160527-weekly.json")
        let inUse = TranscriptsInUse()
        #expect(!h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))

        // Finishing a recording or a recovery: which session is not always known.
        h.appState.phase = .transcribing(progress: "Finishing…")
        #expect(h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))

        // Recording ANOTHER session: this one can be renamed.
        h.appState.phase = .recording(since: Date())
        h.coordinator.currentSessionKey = folder.appendingPathComponent("170000-next").path
        #expect(!h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))
        // Recording this one (a resume), or one whose session is not known.
        h.coordinator.currentSessionKey = folder.appendingPathComponent("160527-weekly").path
        #expect(h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))
        h.coordinator.currentSessionKey = nil
        #expect(h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))

        // Its summary running.
        h.appState.phase = .idle
        inUse.begin(transcript)
        #expect(h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))
        inUse.end(transcript)
        #expect(!h.coordinator.isSessionInFlight(transcript: transcript, inUse: inUse))
    }

    @Test func theLastTranscriptFollowsTheRename() throws {
        let h = try Harness()
        let old = URL(fileURLWithPath: "/r/160527.json"), new = URL(fileURLWithPath: "/r/160527-weekly.json")
        h.appState.lastJsonPath = old.path
        h.appState.lastTranscriptPath = old.path
        h.coordinator.transcriptRenamed(from: old, to: new)
        #expect(h.appState.lastJsonPath == new.path && h.appState.lastTranscriptPath == new.path)
        // Another recording's rename leaves it alone.
        h.coordinator.transcriptRenamed(from: URL(fileURLWithPath: "/r/090000.json"), to: URL(fileURLWithPath: "/r/090000-x.json"))
        #expect(h.appState.lastJsonPath == new.path)
    }

    @Test func aSummaryRunCountsNestedUses() {
        let inUse = TranscriptsInUse()
        let t = URL(fileURLWithPath: "/r/160527.json")
        inUse.begin(t); inUse.begin(URL(fileURLWithPath: "/r/./160527.json"))
        inUse.end(t)
        #expect(inUse.contains(t))
        inUse.end(t)
        #expect(!inUse.contains(t))
        inUse.end(t)   // an extra end is harmless
        #expect(!inUse.contains(t))
    }
}
