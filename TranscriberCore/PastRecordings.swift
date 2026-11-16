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

    /// What a scan found: the recordings, newest first; whether the recordings folder could be listed at all; and how many
    /// of the day folders it went to read could not be (a permission, a folder gone) — said, never taken for empty.
    public struct Scan: Equatable, Sendable {
        public let recordings: [PastRecording]
        public let folderReadable: Bool
        public let unreadableDays: Int

        public init(recordings: [PastRecording], folderReadable: Bool, unreadableDays: Int = 0) {
            self.recordings = recordings
            self.folderReadable = folderReadable
            self.unreadableDays = unreadableDays
        }

        /// The picker's line about the day folders that could not be read; nil when there were none.
        public var note: String? {
            switch unreadableDays {
            case 0: return nil
            case 1: return "Parley couldn’t read 1 day folder of the recordings folder, so its recordings aren’t listed."
            default: return "Parley couldn’t read \(unreadableDays) day folders of the recordings folder, so their recordings aren’t listed."
            }
        }
    }

    /// What opening a past recording does: open it, or refuse — Parley is recording or finishing a recording (every
    /// session then reads as in flight, and none must open under it), or this recording is still being finished or
    /// summarized (`RecordingCoordinator.isSessionInFlight`): its transcript can still be rewritten under the dialog.
    public enum OpenDecision: Equatable, Sendable {
        case open
        case refuse(title: String, message: String)
    }

    /// Decided right before the panel shows (`RenameWindowController`'s queue), not when the pick was made: a pick can
    /// wait behind another panel.
    public static func openDecision(isIdle: Bool, isSessionInFlight: Bool) -> OpenDecision {
        let title = "This recording can’t be opened yet"
        guard isIdle else {
            return .refuse(title: title, message: "Parley is recording or finishing a recording. Try again once it is done.")
        }
        guard isSessionInFlight else { return .open }
        return .refuse(title: title, message: SessionRenamer.RenameError.inProgress.errorDescription ?? "")
    }

    /// Where a pick goes while the rename panels are busy (#29 review).
    public enum Placement: Equatable, Sendable {
        /// Nothing else is up: it opens now.
        case openNow
        /// It is the transcript on screen: that panel comes forward, no second one is queued.
        case bringToFront
        /// Another panel is up or preparing: it opens once that one is closed, and the user is told.
        case opensNext
    }

    public static func placement(of picked: URL, onScreen: URL?, queueBusy: Bool) -> Placement {
        if let onScreen, lexicalPath(onScreen) == lexicalPath(picked) { return .bringToFront }
        return queueBusy ? .opensNext : .openNow
    }

    /// What the user is told when a pick waits for the panel on screen.
    public static let opensNextNotice = "It opens once the rename window that is open now is closed."

    /// Whether a Cancel rewrites the transcript's `.txt` / `.srt`: always for the newest recording's flow (they may not
    /// exist yet), and for a past recording only when a re-detect rewrote its transcript — never a rewrite for nothing.
    public static func rewritesFormatsOnCancel(pastPick: Bool, transcriptRewritten: Bool) -> Bool {
        !pastPick || transcriptRewritten
    }

    /// `url`'s path with `.` and `..` removed, never touching the file system (a URL made without `isDirectory` looks
    /// on disk whether the path is a directory: a hung share would hang the caller).
    static func lexicalPath(_ url: URL) -> String {
        URL(fileURLWithPath: url.path, isDirectory: false).standardized.path
    }

    /// The sidecar tails Parley writes as `.json`, after a session id: the live coverage and a rebuild's damaged copy
    /// (`<id>.damaged.json`, or `<id>.damaged-<UUID>.json` when that was taken). Exactly these: a name may hold any dot-part.
    static func isSidecar(_ id: String) -> Bool {
        if id.hasSuffix(".diag.coverage") || id.hasSuffix(".damaged") { return true }
        guard let range = id.range(of: ".damaged-", options: .backwards) else { return false }
        return UUID(uuidString: String(id[range.upperBound...])) != nil
    }

    /// The transcripts among one folder's `names`: a recording's name (`SessionRenamer.sessionId` — `HHMMSS[-name].json`,
    /// so never `session.json`, a hidden file, a `.json.bak`, a summary `.md` or a `.diag.jsonl`), and none of the
    /// sidecars Parley writes as `.json` (`isSidecar`), nor a file the session-rename rule takes for another transcript's
    /// in the same folder (`<id>-summary.json` beside `<id>.json`, as `SessionRenamer.belongs` reads it). A recording
    /// named "…-summary" with no other beside it is still one.
    static func transcripts(in names: [String]) -> [(name: String, id: String)] {
        let candidates: [(name: String, id: String)] = names.compactMap { name in
            guard !name.hasPrefix("."),
                  let id = SessionRenamer.sessionId(ofTranscript: URL(fileURLWithPath: name, isDirectory: false)),
                  !isSidecar(id) else { return nil }
            return (name, id)
        }
        return candidates.filter { candidate in
            !candidates.contains { other in
                other.name != candidate.name && SessionRenamer.belongs(candidate.name, to: other.id)
            }
        }
    }

    /// The recordings in `days` (a recordings folder's day folders, in any order), newest first — by day, then time, then
    /// name — at most `limit`. A day folder is the storage limit's (`StorageManager.isDayFolderName`): one rule. `latest`,
    /// the menu's last transcript, is offered too when it is not among them (the recordings folder changed since it was
    /// recorded), in its place by time; only a recording's transcript in a day folder, and only once.
    public static func list(root: URL, days: [DayListing], limit: Int, latest: URL? = nil) -> [PastRecording] {
        var recordings: [PastRecording] = []
        for listing in days where StorageManager.isDayFolderName(listing.day) {
            let folder = root.appendingPathComponent(listing.day, isDirectory: true)
            for (name, id) in transcripts(in: listing.names) {
                recordings.append(recording(transcript: folder.appendingPathComponent(name, isDirectory: false),
                                            day: listing.day, id: id))
            }
        }
        return adding(latest: latest, to: recordings, limit: limit)
    }

    /// `recordings` with `latest` among them when it is a recording's transcript in a day folder and not there yet, newest
    /// first, at most `limit`.
    static func adding(latest: URL?, to recordings: [PastRecording], limit: Int) -> [PastRecording] {
        var recordings = recordings
        if let latest, let latestRecording = recording(at: latest),
           !recordings.contains(where: { lexicalPath($0.transcript) == lexicalPath(latest) }) {
            recordings.append(latestRecording)
        }
        return Array(recordings.sorted(by: newestFirst).prefix(max(0, limit)))
    }

    /// `transcript` as a past recording: a recording's transcript in a day folder, else nil.
    static func recording(at transcript: URL) -> PastRecording? {
        let day = transcript.deletingLastPathComponent().lastPathComponent
        guard StorageManager.isDayFolderName(day), let id = SessionRenamer.sessionId(ofTranscript: transcript),
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
    /// yet met (an old day is never read once it is); a day folder that cannot be listed is counted. `latestOnDisk` is
    /// offered as `list` says — whether it IS on disk is a read of its own (`RenameReads.recentRecordings`). Blocks on the
    /// folder: only through `RenameReads`. `listDirectory` is the one file-system call (tests observe it).
    static func scan(root: URL, limit: Int, latestOnDisk: URL? = nil,
                     listDirectory: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) }) -> Scan {
        guard let entries = try? listDirectory(root) else {
            return Scan(recordings: list(root: root, days: [], limit: limit, latest: latestOnDisk), folderReadable: false)
        }
        var days: [DayListing] = []
        var found = 0, unreadable = 0
        for day in entries.filter(StorageManager.isDayFolderName).sorted(by: >) {
            guard found < limit else { break }
            // A day folder that cannot be listed (a permission, a vanished folder) is counted: the others are still read.
            guard let names = try? listDirectory(root.appendingPathComponent(day, isDirectory: true)) else {
                unreadable += 1
                continue
            }
            days.append(DayListing(day: day, names: names))
            found += transcripts(in: names).count
        }
        return Scan(recordings: list(root: root, days: days, limit: limit, latest: latestOnDisk), folderReadable: true,
                    unreadableDays: unreadable)
    }
}

extension RenameReads {
    /// How long the picker's scan of the recordings folder may take before it says the folder did not answer.
    public static let listDeadlineSeconds: Double = 10
    /// How long the check that the menu's latest transcript is still on disk may take; past it, the list goes without it.
    public static let latestDeadlineSeconds: Double = 3

    /// The newest recordings under `root` (`PastRecordings.scan`), on this reader's queue for the folder's volume and
    /// bounded by `seconds` of awake time; nil when the folder did not answer in time. `latest` is looked for afterwards,
    /// in a read of its own bounded by `latestSeconds` (it may be on another volume, one that hangs): unanswered, the list
    /// comes back without it.
    public func recentRecordings(root: URL, latest: URL?, limit: Int = PastRecordings.defaultLimit,
                                 seconds: Double = listDeadlineSeconds,
                                 latestSeconds: Double = latestDeadlineSeconds) async -> PastRecordings.Scan? {
        guard let scan = await reads.read("rename: recordings list", folder: root.path, key: "rename: recordings list \(root.path)",
                                          seconds: seconds, { PastRecordings.scan(root: root, limit: limit) }) else { return nil }
        guard let latest, PastRecordings.recording(at: latest) != nil else { return scan }
        let path = latest.path
        let onDisk = await reads.read("rename: latest transcript", folder: (path as NSString).deletingLastPathComponent,
                                      key: "rename: latest \(path)", seconds: latestSeconds) {
            FileManager.default.fileExists(atPath: path)
        }
        guard onDisk == true else { return scan }
        return PastRecordings.Scan(recordings: PastRecordings.adding(latest: latest, to: scan.recordings, limit: limit),
                                   folderReadable: scan.folderReadable, unreadableDays: scan.unreadableDays)
    }
}
