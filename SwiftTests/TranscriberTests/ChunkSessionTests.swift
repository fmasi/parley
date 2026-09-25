import Testing
import Foundation
@testable import TranscriberCore

@Suite("ChunkSession")
struct ChunkSessionTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeSegment() -> ProcessedChunk.Segment {
        ProcessedChunk.Segment(
            start: 0.0,
            end: 5.5,
            text: "Hello world",
            speaker: "SPEAKER_00",
            source: "microphone",
            qualityScore: 0.95
        )
    }

    private func makeChunk(index: Int = 0) -> ProcessedChunk {
        ProcessedChunk(
            index: index,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: "/tmp/chunk-\(index).wav",
            segments: [makeSegment()],
            speakerDatabase: ["SPEAKER_00": [0.1, 0.2, 0.3]]
        )
    }

    private func makeSession(chunks: [ProcessedChunk] = []) -> SessionState {
        SessionState(
            sessionId: "session-abc",
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000),
            engine: "fluidAudio",
            chunkDurationMinutes: 5,
            chunks: chunks
        )
    }

    // MARK: - Tests

    @Test("processedChunkEncodesAndDecodes")
    func processedChunkEncodesAndDecodes() throws {
        let chunk = makeChunk()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chunk)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProcessedChunk.self, from: data)

        #expect(decoded.index == chunk.index)
        #expect(decoded.audioPath == chunk.audioPath)
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments[0].text == "Hello world")
        #expect(decoded.segments[0].speaker == "SPEAKER_00")
        #expect(decoded.segments[0].qualityScore == 0.95)
        #expect(decoded.speakerDatabase["SPEAKER_00"] == [0.1, 0.2, 0.3])
    }

    @Test("sessionStateAtomicWriteAndRead")
    func sessionStateAtomicWriteAndRead() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession(chunks: [makeChunk()])
        try SessionState.write(session, directory: dir)

        let read = SessionState.read(directory: dir)
        #expect(read != nil)
        #expect(read?.sessionId == "session-abc")
        #expect(read?.engine == "fluidAudio")
        #expect(read?.chunkDurationMinutes == 5)
        #expect(read?.chunks.count == 1)
        #expect(read?.chunks[0].audioPath == "/tmp/chunk-0.wav")
    }

    @Test("sessionStateAccumulatesChunks")
    func sessionStateAccumulatesChunks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write with zero chunks
        var session = makeSession(chunks: [])
        try SessionState.write(session, directory: dir)

        // Add a chunk and write again
        session = SessionState(
            sessionId: session.sessionId,
            meetingStart: session.meetingStart,
            engine: session.engine,
            chunkDurationMinutes: session.chunkDurationMinutes,
            chunks: [makeChunk(index: 0), makeChunk(index: 1)]
        )
        try SessionState.write(session, directory: dir)

        let read = SessionState.read(directory: dir)
        #expect(read?.chunks.count == 2)
        #expect(read?.chunks[0].index == 0)
        #expect(read?.chunks[1].index == 1)
    }

    @Test("sessionStateMissingFileReturnsNil")
    func sessionStateMissingFileReturnsNil() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkSessionTests-nonexistent-\(UUID().uuidString)")
        let result = SessionState.read(directory: dir)
        #expect(result == nil)
    }

    @Test("sessionStateDeleteRemovesFile")
    func sessionStateDeleteRemovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession()
        try SessionState.write(session, directory: dir)

        // Verify it exists
        #expect(SessionState.read(directory: dir) != nil)

        // Delete and verify gone
        SessionState.delete(directory: dir, sessionId: session.sessionId)
        #expect(SessionState.read(directory: dir) == nil)
    }

    @Test("sessionStateGapsDefaultToEmptyAndRoundTrip")
    func sessionStateGapsDefaultToEmptyAndRoundTrip() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var state = makeSession(chunks: [])
        try SessionState.write(state, directory: dir)
        #expect(SessionState.read(directory: dir)?.gaps == [])
        let gap = CaptureGap(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 220), reason: "sleep")
        state.gaps.append(gap)
        try SessionState.write(state, directory: dir)
        let back = try #require(SessionState.read(directory: dir))
        #expect(back.gaps.count == 1 && back.gaps[0].reason == "sleep" && back.gaps[0].seconds == 120)
    }

    @Test("processedChunkIssuesDefaultToEmptyAndDecode")
    func processedChunkIssuesDefaultToEmptyAndDecode() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bare = Data(#"{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","segments":[],"speakerDatabase":{}}"#.utf8)
        #expect(try decoder.decode(ProcessedChunk.self, from: bare).issues == [])
        let withIssue = Data(#"{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","segments":[],"speakerDatabase":{},"issues":[{"code":"asr_failed","track":"remote"}]}"#.utf8)
        #expect(try decoder.decode(ProcessedChunk.self, from: withIssue).issues == [ChunkIssue(code: .asrFailed, track: "remote", count: nil)])
    }

    @Test("readWithMismatchedSessionIdReturnsNil")
    func readWithMismatchedSessionIdReturnsNil() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(makeSession(chunks: []), directory: dir)   // makeSession's sessionId is the fixture's
        let id = try #require(SessionState.read(directory: dir)?.sessionId)
        #expect(SessionState.read(directory: dir, sessionId: id) != nil)
        #expect(SessionState.read(directory: dir, sessionId: id + "-other") == nil)
    }

    /// Review round 1 item 11: a code written by a newer build must not make an older build drop
    /// the whole session.json (a downgrade mid-recording).
    @Test("unknownIssueCodesDecodeWithoutFailingTheSession")
    func unknownIssueCodesDecodeWithoutFailingTheSession() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let chunk = Data(#"{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","segments":[],"speakerDatabase":{},"issues":[{"code":"from_the_future","track":"remote"},{"code":"asr_failed"}]}"#.utf8)
        let decoded = try decoder.decode(ProcessedChunk.self, from: chunk)
        #expect(decoded.issues.map(\.code.rawValue) == ["from_the_future", "asr_failed"])
        #expect(decoded.issues[0].affectsContent == false)
        let session = Data(#"{"sessionId":"s","meetingStart":"2026-09-24T16:00:00Z","engine":"fluid_audio","chunkDurationMinutes":5,"chunks":[],"issues":[{"issue":{"code":"from_the_future"}}]}"#.utf8)
        #expect(try decoder.decode(SessionState.self, from: session).issues.map(\.issue.code.rawValue) == ["from_the_future"])
    }

    @Test("issueCodesThatAffectContent")
    func issueCodesThatAffectContent() {
        #expect(ChunkIssue.Code.vadFailed.affectsContent && ChunkIssue.Code.streamMissing.affectsContent)
        #expect(ChunkIssue.Code.seedMismatch.affectsContent)
        #expect(!ChunkIssue.Code.vadUnavailable.affectsContent && !ChunkIssue.Code.streamEmpty.affectsContent)
    }

    /// Review round 1 item 9: session.json's coder keeps whole seconds; the gap length must not drift.
    @Test("captureGapSecondsSurviveWholeSecondDates")
    func captureGapSecondsSurviveWholeSecondDates() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var state = makeSession(chunks: [])
        state.gaps = [CaptureGap(start: Date(timeIntervalSince1970: 100.4), end: Date(timeIntervalSince1970: 220.9), reason: "sleep")]
        try SessionState.write(state, directory: dir)
        #expect(SessionState.read(directory: dir)?.gaps.first?.seconds == 120.5)
    }

    @Test("negativeCaptureGapIsClampedToZero")
    func negativeCaptureGapIsClampedToZero() {
        #expect(CaptureGap(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 5), reason: "app relaunch").seconds == 0)
    }

    /// R5: a session.json left by ANOTHER recording in the same folder is never merged into this one.
    @Test("foreignSessionJsonIsIgnoredByRecovery")
    @MainActor
    func foreignSessionJsonIsIgnoredByRecovery() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "other", meetingStart: Date(timeIntervalSince1970: 0), chunkIndices: [0, 1, 2])
        #expect(!CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "m"))
        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "m") == 0)
        let result = try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "m", config: .default,
                                                              transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: TranscriptionRunner())
        #expect(result == nil)
    }

    /// R7: a session.json written before P10/P11 (segments with no flags) still decodes — a
    /// recovery across an upgrade must not lose the session.
    @Test("preFlagSessionSegmentsDecode")
    func preFlagSessionSegmentsDecode() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = Data(#"{"sessionId":"s","meetingStart":"2026-09-24T16:00:00Z","engine":"fluid_audio","chunkDurationMinutes":5,"chunks":[{"index":0,"startTime":"2026-09-24T16:00:00Z","audioPath":"a.m4a","speakerDatabase":{},"segments":[{"start":0,"end":1,"text":"hi","speaker":"S","source":"remote","qualityScore":0.9}]}]}"#.utf8)
        let seg = try #require(try decoder.decode(SessionState.self, from: data).chunks.first?.segments.first)
        #expect(seg.text == "hi" && !seg.filtered && !seg.echo && !seg.duplicate)
    }

    // MARK: - R2 council (C-I3, B-M11): one session.json per day folder

    private func session(_ id: String, chunks: [Int]) -> SessionState {
        SessionState(sessionId: id, meetingStart: Date(timeIntervalSince1970: 1_700_000_000), engine: "fluidAudio",
                     chunkDurationMinutes: 5, chunks: chunks.map { makeChunk(index: $0) })
    }

    /// C-I3: the next recording that day used to overwrite an unfinalized session's recognised text.
    /// Its file is moved aside, never overwritten, and the write says so.
    @Test("writingAnotherSessionMovesTheExistingFileAside")
    func writingAnotherSessionMovesTheExistingFileAside() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try SessionState.write(session("morning", chunks: [0, 1, 2]), directory: dir) == nil)
        let displaced = try SessionState.write(session("afternoon", chunks: [0]), directory: dir)
        #expect(displaced?.sessionId == "morning")
        #expect(displaced?.movedTo.lastPathComponent == "session-morning.json")
        #expect(SessionState.read(directory: dir)?.sessionId == "afternoon")
        #expect(try SessionState.write(session("afternoon", chunks: [0, 1]), directory: dir) == nil, "its own file is simply replaced")
        let aside = try JSONDecoder.iso8601.decode(SessionState.self, from: Data(contentsOf: dir.appendingPathComponent("session-morning.json")))
        #expect(aside.sessionId == "morning" && aside.chunks.map(\.index) == [0, 1, 2], "every chunk of the displaced session survives")
    }

    /// The aside session is still found by id — by recovery, resume and the orphan planner alike.
    @Test("readBySessionIdFindsAMovedAsideSession")
    func readBySessionIdFindsAMovedAsideSession() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(session("morning", chunks: [0, 1, 2]), directory: dir)
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 3)
        #expect(SessionState.read(directory: dir, sessionId: "afternoon")?.chunks.count == 1)
        #expect(SessionState.read(directory: dir, sessionId: "evening") == nil)
        #expect(CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: dir, sessionId: "morning"))
        #expect(CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: dir, sessionId: "morning") == 3)
    }

    /// A file whose session id cannot be read is not known to be someone else's: moved aside too.
    @Test("anUnreadableSessionFileIsMovedAsideNotOverwritten")
    func anUnreadableSessionFileIsMovedAsideNotOverwritten() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = Data("{not json".utf8)
        try garbage.write(to: dir.appendingPathComponent("session.json"))
        let displaced = try #require(try SessionState.write(session("afternoon", chunks: [0]), directory: dir))
        #expect(displaced.sessionId == nil)
        #expect(try Data(contentsOf: displaced.movedTo) == garbage)
        #expect(SessionState.read(directory: dir)?.sessionId == "afternoon")
    }

    /// Deletes (finalize, recovery) remove only the session they belong to — and its aside copy.
    @Test("deleteRemovesOnlyTheMatchingSession")
    func deleteRemovesOnlyTheMatchingSession() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(session("morning", chunks: [0]), directory: dir)
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)   // morning → session-morning.json
        SessionState.delete(directory: dir, sessionId: "evening")
        SessionState.delete(directory: dir, sessionId: "morning")
        #expect(SessionState.read(directory: dir)?.sessionId == "afternoon", "another session's session.json is never deleted")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("session-morning.json").path))
        SessionState.delete(directory: dir, sessionId: "afternoon")
        #expect(SessionState.read(directory: dir) == nil)
    }

    /// B-M11: concurrent writers shared one `session.json.tmp`; the loser's rename threw a false
    /// `sessionWriteFailed`. A unique tmp per write, still renamed atomically, and none left behind.
    @Test("concurrentWritesNeverFailAndLeaveNoTmp", .timeLimit(.minutes(1)))
    func concurrentWritesNeverFailAndLeaveNoTmp() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = session("afternoon", chunks: [0, 1])
        let failures = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    do { try SessionState.write(state, directory: dir); return 0 } catch { return 1 }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(failures == 0)
        #expect(SessionState.read(directory: dir, sessionId: "afternoon")?.chunks.count == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "session.json" }
        #expect(leftovers.isEmpty, "no tmp file (or aside copy of itself) is left: \(leftovers)")
    }

    // MARK: - R2 round 2 (R2a M1, M6, M8, M9)

    /// R2a M9: two recordings' writers interleaved — each id's state survives, one in session.json
    /// and the other aside; no write fails.
    @Test("interleavedWritersOfTwoSessionsBothSurvive", .timeLimit(.minutes(1)))
    func interleavedWritersOfTwoSessionsBothSurvive() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = session("morning", chunks: [0, 1]), b = session("afternoon", chunks: [0])
        let failures = await withTaskGroup(of: Int.self) { group in
            for i in 0..<48 {
                let state = i.isMultiple(of: 2) ? a : b
                group.addTask {
                    do { try SessionState.write(state, directory: dir); return 0 } catch { return 1 }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(failures == 0)
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 2)
        #expect(SessionState.read(directory: dir, sessionId: "afternoon")?.chunks.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    /// R2a M1: moving a file aside replaced an existing aside copy on the strength of an invariant.
    /// It is exclusive now: an existing copy is never replaced; the new one gets a unique suffix, and
    /// reads and deletes see every copy.
    @Test("anExistingAsideCopyIsNeverReplaced")
    func anExistingAsideCopyIsNeverReplaced() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SessionState.write(session("morning", chunks: [0]), directory: dir)
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)          // morning(1) → session-morning.json
        let firstAside = try Data(contentsOf: dir.appendingPathComponent("session-morning.json"))
        try SessionState.write(session("morning", chunks: [0, 1, 2]), directory: dir)      // afternoon aside, morning back
        let displaced = try #require(try SessionState.write(session("afternoon", chunks: [0, 1]), directory: dir))
        #expect(displaced.movedTo.lastPathComponent != "session-morning.json", "the existing aside copy is not replaced")
        #expect(try Data(contentsOf: dir.appendingPathComponent("session-morning.json")) == firstAside)
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 3, "the newest state wins on read")
        SessionState.delete(directory: dir, sessionId: "morning")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("session-morning") }.isEmpty,
                "delete removes every copy")
        #expect(SessionState.read(directory: dir, sessionId: "afternoon")?.chunks.count == 2)
    }

    /// R2a M6: "delete the WAVs only after persist" must survive a power loss, so the tmp is flushed
    /// to the disk (F_FULLFSYNC), not just to the cache, before it is renamed.
    @Test("aWriteIsFullySyncedBeforeTheRename")
    func aWriteIsFullySyncedBeforeTheRename() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        DurableFile.recordsSyncsForTesting = true
        defer { DurableFile.recordsSyncsForTesting = false }
        let before = DurableFile.syncedForTesting.count
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)
        #expect(DurableFile.syncedForTesting.dropFirst(before).contains(dir.appendingPathComponent("session.json").path))
    }

    /// Round 4 item 4: the seam records paths (meeting names) only when a test asks it to.
    @Test("theSyncSeamRecordsNothingUnlessATestAsks")
    func theSyncSeamRecordsNothingUnlessATestAsks() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = DurableFile.syncedForTesting.count
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)
        #expect(DurableFile.syncedForTesting.count == before)

        // Round 4 item 1: a FINALIZED session's leftover session.json (its transcript verifies) is
        // deleted when the next recording writes, never moved aside and never recorded as displaced.
        let leftover = session("finished", chunks: [0])
        try SessionState.write(leftover, directory: dir)
        try TranscriptAssembler.write(["metadata": [:] as [String: Any], "segments": [] as [Any]], to: dir.appendingPathComponent("finished.json"))
        try SessionState.markFinalized(directory: dir, sessionId: "finished", transcript: "finished.json")
        #expect(try SessionState.write(session("afternoon", chunks: [0, 1]), directory: dir) == nil)
        #expect(SessionState.read(directory: dir, sessionId: "finished") == nil)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("session-finished") }))

        // …but one whose transcript does NOT verify is still moved aside (never deleted).
        try SessionState.write(session("damaged", chunks: [0]), directory: dir)
        try Data("{".utf8).write(to: dir.appendingPathComponent("damaged.json"))
        try SessionState.markFinalized(directory: dir, sessionId: "damaged", transcript: "damaged.json")
        #expect(try SessionState.write(session("afternoon", chunks: [0, 1, 2]), directory: dir)?.sessionId == "damaged")
    }

    /// Round 3 item 1 (IMPORTANT): `RENAME_EXCL` is not supported on exFAT or SMB (ENOTSUP), and
    /// `recording_directory` can be an external drive: every write that had to move another session
    /// aside threw. It falls back to check-then-rename under the lock — still never replacing a copy.
    @Test("anExclusiveRenameThatIsNotSupportedFallsBackAndNeverReplaces")
    func anExclusiveRenameThatIsNotSupportedFallsBackAndNeverReplaces() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        SessionState.exclusiveRenameUnsupportedForTesting = true
        defer { SessionState.exclusiveRenameUnsupportedForTesting = false }
        try SessionState.write(session("morning", chunks: [0]), directory: dir)
        let first = try #require(try SessionState.write(session("afternoon", chunks: [0]), directory: dir))
        #expect(first.movedTo.lastPathComponent == "session-morning.json")
        let firstAside = try Data(contentsOf: first.movedTo)
        try SessionState.write(session("morning", chunks: [0, 1]), directory: dir)
        let second = try #require(try SessionState.write(session("afternoon", chunks: [0, 1]), directory: dir))
        #expect(second.movedTo.lastPathComponent != "session-morning.json")
        #expect(try Data(contentsOf: first.movedTo) == firstAside, "the existing copy is not replaced")
        #expect(SessionState.read(directory: dir, sessionId: "morning")?.chunks.count == 2)
    }

    /// R2a M8: a tmp left by a write that died (crash, power loss) is swept at the next write.
    @Test("aStaleTmpIsSweptAtTheNextWrite")
    func aStaleTmpIsSweptAtTheNextWrite() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("session.json.\(UUID().uuidString).tmp")
        try Data("{".utf8).write(to: stale)
        try SessionState.write(session("afternoon", chunks: [0]), directory: dir)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}

extension JSONDecoder {
    /// session.json's own date strategy, for tests that read an aside file directly.
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
