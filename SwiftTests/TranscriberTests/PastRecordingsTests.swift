import Testing
import Foundation
@testable import TranscriberCore

/// Opening any past recording in the rename dialog (#29): which files of a recordings folder are recordings' transcripts,
/// in what order the picker lists them, and the scan behind it — bounded, off the main thread. Synthetic names and an
/// empty temp folder only, never a real recording.
@Suite struct PastRecordingsListingTests {

    private let root = URL(fileURLWithPath: "/r", isDirectory: true)

    private func ids(_ list: [PastRecording]) -> [String] {
        list.map { "\($0.day)/\($0.transcript.lastPathComponent)" }
    }

    @Test func onlyARecordingsTranscriptIsListed() {
        let names = [
            "093000-weekly.json",               // a named recording
            "101500.json",                      // an unnamed one
            "093000-weekly-summary.md",         // its summary
            "093000-weekly.txt", "093000-weekly.srt",
            "093000-weekly.json.bak",           // the re-detect backup
            "093000-weekly.diag.jsonl",         // the capture record
            "093000-weekly.diag.live.jsonl",
            "093000-weekly.diag.coverage.json", // the live coverage, a .json
            "093000-weekly.m4a", "093000-weekly-0.m4a", "093000-weekly-1.wav", "093000-weekly-1_mic.wav",
            ".093000-weekly.finalized",         // the hidden marker
            ".hidden.json", "._101500.json",    // hidden files, AppleDouble
            "session.json", "session-093000-weekly.json", // session state
            "notes.json", "meeting.json",       // not a recording's name
            "09300-x.json", "093000-.json", "ab3000-x.json", "093000x.json",
            "101500.json.tmp",                  // a write in progress
        ]
        let list = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: names)], limit: 50)
        #expect(ids(list) == ["2026-11-16/101500.json", "2026-11-16/093000-weekly.json"])
    }

    @Test func aDamagedCopyARebuildKeptIsNotListed() {
        // `ChunkedSessionRecovery.moveDamagedRecordAside`: `<id>.damaged.json`, or a unique name when that is taken —
        // with or without the rebuilt transcript beside it.
        let names = ["093000-a.json", "093000-a.damaged.json", "093000-a.damaged-6F1C2A4E-0000-4000-8000-000000000000.json",
                     "110000-b.damaged.json", "120000-c.diag.coverage.json"]
        let list = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: names)], limit: 50)
        #expect(ids(list) == ["2026-11-16/093000-a.json"])
    }

    @Test func aSummaryLookalikeBesideItsRecordingIsNotListed_aRecordingNamedSoIs() {
        // Parley writes no `-summary.json`; one beside `<id>.json` is read as that recording's (as `SessionRenamer` does).
        let beside = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: [
            "093000-a.json", "093000-a-summary.json"])], limit: 50)
        #expect(ids(beside) == ["2026-11-16/093000-a.json"])
        // Alone, it is a recording someone named "…-summary": hiding it would hide a real meeting.
        let alone = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: ["093000-board-summary.json"])], limit: 50)
        #expect(ids(alone) == ["2026-11-16/093000-board-summary.json"])
    }

    @Test func aNameWithDotsOrDashesIsStillARecording() {
        // `sanitizeFilename` keeps dots and dashes: "v1.2 review" and "Q3-plan" are names, not sidecars.
        let names = ["093000-v1.2 review.json", "100000-Q3-plan.json", "110000-2.json", "110000.json"]
        let list = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: names)], limit: 50)
        #expect(Set(ids(list)) == Set(names.map { "2026-11-16/\($0)" }))
    }

    @Test func newestFirst_acrossDays_thenByTime_thenByName() {
        let list = PastRecordings.list(root: root, days: [
            .init(day: "2026-11-14", names: ["235959-late.json", "000001-early.json"]),
            .init(day: "2026-11-16", names: ["080000-b.json", "080000-a.json", "170000.json"]),
            .init(day: "2026-10-31", names: ["120000-old.json"]),
        ], limit: 50)
        #expect(ids(list) == [
            "2026-11-16/170000.json", "2026-11-16/080000-a.json", "2026-11-16/080000-b.json",
            "2026-11-14/235959-late.json", "2026-11-14/000001-early.json",
            "2026-10-31/120000-old.json",
        ])
    }

    @Test func onlyDayFoldersAreRead() {
        for day in ["2026-11-16", "1999-01-01"] { #expect(PastRecordings.isDayFolder(day), "\(day)") }
        for other in ["2026-11-1", "2026-13-01", "2026-11-32", "2026_11_16", "2026-11-16 copy", "Archive", ".2026-11-16", ""] {
            #expect(!PastRecordings.isDayFolder(other), "\(other)")
        }
        let list = PastRecordings.list(root: root, days: [
            .init(day: "Archive", names: ["093000-a.json"]),
            .init(day: "2026-11-16", names: ["093000-b.json"]),
        ], limit: 50)
        #expect(ids(list) == ["2026-11-16/093000-b.json"])
    }

    @Test func theLimitKeepsTheNewest() {
        let names = (0..<24).map { String(format: "%02d0000-m.json", $0) }
        let list = PastRecordings.list(root: root, days: [
            .init(day: "2026-11-15", names: names),
            .init(day: "2026-11-16", names: ["090000-today.json"]),
        ], limit: 3)
        #expect(ids(list) == ["2026-11-16/090000-today.json", "2026-11-15/230000-m.json", "2026-11-15/220000-m.json"])
        #expect(PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: ["090000.json"])], limit: 0).isEmpty)
    }

    @Test func eachRowSaysWhenAndWhat() throws {
        let list = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: ["093005-weekly sync.json", "101500.json"])], limit: 50)
        let named = try #require(list.first { $0.time == "093005" })
        #expect(named.name == "weekly sync")
        #expect(named.transcript.path == "/r/2026-11-16/093005-weekly sync.json")
        let unnamed = try #require(list.first { $0.time == "101500" })
        #expect(unnamed.name == "")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let start = try #require(named.startDate(calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second] == [2026, 11, 16, 9, 30, 5])
        // A timestamp that is no time of day has no date (the row shows the raw stamp instead).
        let odd = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: ["996100.json"])], limit: 50)
        #expect(odd.first?.startDate(calendar: calendar) == nil)
    }

    @Test func theLatestRecordingIsListedEvenFromAnotherFolder() {
        // The recordings folder changed in Settings since: the menu's last transcript is still offered, in its place.
        let latest = URL(fileURLWithPath: "/old/2026-11-16/120000-moved.json")
        let list = PastRecordings.list(root: root, days: [
            .init(day: "2026-11-16", names: ["090000-a.json", "130000-b.json"]),
        ], limit: 50, latest: latest)
        #expect(list.map(\.transcript.path) == [
            "/r/2026-11-16/130000-b.json", "/old/2026-11-16/120000-moved.json", "/r/2026-11-16/090000-a.json",
        ])
        // Already listed: once.
        let listed = PastRecordings.list(root: root, days: [.init(day: "2026-11-16", names: ["090000-a.json"])], limit: 50,
                                         latest: URL(fileURLWithPath: "/r/2026-11-16/090000-a.json"))
        #expect(listed.count == 1)
        // Not a recording's transcript, or not in a day folder: not offered.
        for other in ["/r/2026-11-16/session.json", "/elsewhere/090000-a.json"] {
            let none = PastRecordings.list(root: root, days: [], limit: 50, latest: URL(fileURLWithPath: other))
            #expect(none.isEmpty, "\(other)")
        }
    }

    @Test func aRecordingStillInFlightIsRefused_anyOtherOpens() {
        #expect(PastRecordings.openDecision(isSessionInFlight: false) == .open)
        guard case .refuse(let title, let message) = PastRecordings.openDecision(isSessionInFlight: true) else {
            Issue.record("an in-flight recording must be refused")
            return
        }
        #expect(!title.isEmpty)
        #expect(message == SessionRenamer.RenameError.inProgress.errorDescription)
    }
}

@Suite struct PastRecordingsScanTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("past-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    @Test func theScanReadsTheDayFoldersNewestFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("2026-11-15/090000-a.json"))
        try touch(root.appendingPathComponent("2026-11-15/090000-a-summary.md"))
        try touch(root.appendingPathComponent("2026-11-16/100000-b.json"))
        try touch(root.appendingPathComponent("2026-11-16/session.json"))
        try touch(root.appendingPathComponent("Archive/080000-c.json"))
        try touch(root.appendingPathComponent("stray.json"))

        let scan = PastRecordings.scan(root: root, limit: 50)
        #expect(scan.folderReadable)
        #expect(scan.recordings.map(\.transcript.lastPathComponent) == ["100000-b.json", "090000-a.json"])
    }

    @Test func theScanStopsOnceTheLimitIsReached() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("2026-11-16/100000-b.json"))
        try touch(root.appendingPathComponent("2026-11-15/090000-a.json"))
        var listed: [String] = []
        let scan = PastRecordings.scan(root: root, limit: 1) { folder in
            listed.append(folder.lastPathComponent)
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        }
        #expect(scan.recordings.map(\.transcript.lastPathComponent) == ["100000-b.json"])
        // The root, then the newest day only: an older day is never listed once the limit is met.
        #expect(listed == [root.lastPathComponent, "2026-11-16"])
    }

    @Test func aMissingFolderSaysSo() {
        let scan = PastRecordings.scan(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), limit: 50)
        #expect(!scan.folderReadable)
        #expect(scan.recordings.isEmpty)
    }

    @Test func theLatestIsOfferedOnlyWhileItIsOnDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try makeRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        let latest = other.appendingPathComponent("2026-11-16/120000-moved.json")
        #expect(PastRecordings.scan(root: root, limit: 50, latest: latest).recordings.isEmpty)
        try touch(latest)
        #expect(PastRecordings.scan(root: root, limit: 50, latest: latest).recordings.map(\.transcript) == [latest])
    }

    /// The picker's read goes through the rename reader, bounded: a recordings folder that does not answer gives no list
    /// (the picker says so and offers Choose File…), never a wait without end.
    @Test func aFolderThatDoesNotAnswerGivesNoListInTime() async throws {
        let hung = HangingRead()
        defer { hung.release() }
        let reads = RenameReads(reads: FolderReads(label: "past-recordings-\(UUID().uuidString)", beforeEachRead: { label in
            if label == "rename: recordings list" { hung.hang() }
        }))
        let started = ContinuousClock.now
        let result = await reads.recentRecordings(root: URL(fileURLWithPath: "/r"), latest: nil, seconds: 0.3)
        #expect(result == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aFolderThatAnswersGivesItsList() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("2026-11-16/100000-b.json"))
        let reads = RenameReads(reads: FolderReads(label: "past-recordings-\(UUID().uuidString)"))
        let result = try #require(await reads.recentRecordings(root: root, latest: nil))
        #expect(result.recordings.map(\.transcript.lastPathComponent) == ["100000-b.json"])
    }
}

/// A read that blocks until released — on the read queue, never the test's thread.
private final class HangingRead: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func hang() { semaphore.wait() }
    func release() { semaphore.signal() }
}
