import Foundation

/// A finished recording the rename dialog can open (#29): its transcript, and what the picker shows of it.
public struct PastRecording: Equatable, Sendable, Identifiable {
    /// The recording's transcript, `<root>/<yyyy-MM-dd>/<HHMMSS>[-<name>].json`.
    public let transcript: URL
    /// Its day folder's name, `yyyy-MM-dd`.
    public let day: String
    /// When it started, `HHMMSS`.
    public let time: String
    /// The name part — `""` for a recording started without one.
    public let name: String

    public var id: String { transcript.path }

    /// When the recording started, read from its day folder and timestamp in `calendar`'s time zone (the recording's
    /// own, as `RecordingCoordinator.startNaming` wrote it). nil when they are no real date and time of day.
    public func startDate(calendar: Calendar = .current) -> Date? {
        let day = self.day.split(separator: "-").compactMap { Int($0) }
        let digits = Array(time)
        guard day.count == 3, digits.count == 6,
              let hour = Int(String(digits[0...1])), let minute = Int(String(digits[2...3])),
              let second = Int(String(digits[4...5])),
              (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        let components = DateComponents(year: day[0], month: day[1], day: day[2], hour: hour, minute: minute, second: second)
        // A day that does not exist (2026-02-30) rolls over in `date(from:)`: read back, it is another day.
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == day[0], back.month == day[1], back.day == day[2] else { return nil }
        return date
    }
}

/// The recordings the rename dialog offers to open (#29): the recordings folder's day folders, newest first. The listing
/// is pure (`list`, from directory entries); the scan behind it (`scan`) blocks on the folder — a network share can
/// hang it — so it runs only through `RenameReads.recentRecordings`, off the main thread and bounded.
public enum PastRecordings {
    /// How many recordings the picker lists; older ones are reached with Choose File….
    public static let defaultLimit = 50

    /// One day folder's entries: its name and the file names in it.
    public struct DayListing: Equatable, Sendable {
        public let day: String
        public let names: [String]

        public init(day: String, names: [String]) {
            self.day = day
            self.names = names
        }
    }

    /// What a scan found: the recordings, newest first, and whether the recordings folder could be listed at all.
    public struct Scan: Equatable, Sendable {
        public let recordings: [PastRecording]
        public let folderReadable: Bool
    }

    /// What opening a past recording does: open it, or refuse — the recording is still being recorded, finished or
    /// summarized (`RecordingCoordinator.isSessionInFlight`), and its transcript can still be rewritten under the dialog.
    public enum OpenDecision: Equatable, Sendable {
        case open
        case refuse(title: String, message: String)
    }

    public static func openDecision(isSessionInFlight: Bool) -> OpenDecision {
        guard isSessionInFlight else { return .open }
        return .refuse(title: "This recording can’t be opened yet",
                       message: SessionRenamer.RenameError.inProgress.errorDescription ?? "")
    }

    /// Whether `name` is a day folder, `yyyy-MM-dd` (`RecordingCoordinator`'s): a real month and day, nothing else.
    public static func isDayFolder(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    /// The transcripts among one folder's `names`: a recording's name (`SessionRenamer.sessionId` — `HHMMSS[-name].json`,
    /// so never `session.json`, a hidden file, a `.json.bak`, a summary `.md` or a `.diag.jsonl`), and none of the
    /// sidecars Parley writes as `.json`: the live coverage (`<id>.diag.coverage.json`), a damaged copy a rebuild kept
    /// (`<id>.damaged[-<UUID>].json`), nor a file the session-rename rule takes for another transcript's in the same
    /// folder (`<id>-summary.json` beside `<id>.json`, as `SessionRenamer.belongs` reads it). A recording named
    /// "…-summary" with no other beside it is still one.
    static func transcripts(in names: [String]) -> [(name: String, id: String)] {
        let candidates: [(name: String, id: String)] = names.compactMap { name in
            guard !name.hasPrefix("."),
                  let id = SessionRenamer.sessionId(ofTranscript: URL(fileURLWithPath: name)) else { return nil }
            // A sidecar's marker is a dot-separated part AFTER the first (the name itself may hold dots: "v1.2 review").
            let parts = id.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
            guard !parts.contains(where: { $0 == "diag" || $0 == "damaged" || $0.hasPrefix("damaged-") }) else { return nil }
            return (name, id)
        }
        return candidates.filter { candidate in
            !candidates.contains { other in
                other.name != candidate.name && SessionRenamer.belongs(candidate.name, to: other.id)
            }
        }
    }

    /// The recordings in `days` (a recordings folder's day folders, in any order), newest first — by day, then time, then
    /// name — at most `limit`. `latest`, the menu's last transcript, is offered too when it is not among them (the
    /// recordings folder changed since it was recorded), in its place by time; only a recording's transcript in a day
    /// folder, and only once.
    public static func list(root: URL, days: [DayListing], limit: Int, latest: URL? = nil) -> [PastRecording] {
        var recordings: [PastRecording] = []
        for listing in days where isDayFolder(listing.day) {
            let folder = root.appendingPathComponent(listing.day, isDirectory: true)
            for (name, id) in transcripts(in: listing.names) {
                recordings.append(recording(transcript: folder.appendingPathComponent(name), day: listing.day, id: id))
            }
        }
        if let latest, let latestRecording = recording(at: latest),
           !recordings.contains(where: { $0.transcript.standardizedFileURL.path == latest.standardizedFileURL.path }) {
            recordings.append(latestRecording)
        }
        return Array(recordings.sorted(by: newestFirst).prefix(max(0, limit)))
    }

    /// `transcript` as a past recording: a recording's transcript in a day folder, else nil.
    static func recording(at transcript: URL) -> PastRecording? {
        let day = transcript.deletingLastPathComponent().lastPathComponent
        guard isDayFolder(day), let id = SessionRenamer.sessionId(ofTranscript: transcript),
              !transcript.lastPathComponent.hasPrefix(".") else { return nil }
        return recording(transcript: transcript, day: day, id: id)
    }

    private static func recording(transcript: URL, day: String, id: String) -> PastRecording {
        PastRecording(transcript: transcript, day: day, time: String(id.prefix(SessionRenamer.timestampLength)),
                      name: SessionRenamer.sessionName(ofTranscript: transcript) ?? "")
    }

    private static func newestFirst(_ a: PastRecording, _ b: PastRecording) -> Bool {
        if a.day != b.day { return a.day > b.day }
        if a.time != b.time { return a.time > b.time }
        if a.name != b.name { return a.name < b.name }
        return a.transcript.path < b.transcript.path
    }

    /// The newest `limit` recordings under `root`: its day folders, newest first, each listed only while the limit is not
    /// yet met (an old day is never read once it is). `latest` is offered while it is on disk (`list`). Blocks on the
    /// folder: only through `RenameReads.recentRecordings`. `listDirectory` is the one file-system call (tests observe it).
    static func scan(root: URL, limit: Int, latest: URL? = nil,
                     listDirectory: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) }) -> Scan {
        let latestOnDisk = latest.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let entries = try? listDirectory(root) else {
            return Scan(recordings: list(root: root, days: [], limit: limit, latest: latestOnDisk), folderReadable: false)
        }
        var days: [DayListing] = []
        var found = 0
        for day in entries.filter(isDayFolder).sorted(by: >) {
            guard found < limit else { break }
            // A day folder that cannot be listed (a permission, a vanished folder) is skipped: the others still are.
            guard let names = try? listDirectory(root.appendingPathComponent(day, isDirectory: true)) else { continue }
            days.append(DayListing(day: day, names: names))
            found += transcripts(in: names).count
        }
        return Scan(recordings: list(root: root, days: days, limit: limit, latest: latestOnDisk), folderReadable: true)
    }
}

extension RenameReads {
    /// How long the picker's scan of the recordings folder may take before it says the folder did not answer.
    public static let listDeadlineSeconds: Double = 10

    /// The newest recordings under `root` (`PastRecordings.scan`), on this reader's queue for the folder's volume and
    /// bounded by `seconds` of awake time; nil when the folder did not answer in time.
    public func recentRecordings(root: URL, latest: URL?, limit: Int = PastRecordings.defaultLimit,
                                 seconds: Double = listDeadlineSeconds) async -> PastRecordings.Scan? {
        await reads.read("rename: recordings list", folder: root.path, key: "rename: recordings list \(root.path)",
                         seconds: seconds) { PastRecordings.scan(root: root, limit: limit, latest: latest) }
    }
}
