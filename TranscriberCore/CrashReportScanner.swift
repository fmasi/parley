import Foundation
import os

/// Whether an XPC interruption looks like a real process crash or a benign connection blip.
public enum CrashClassification: Equatable {
    case likelyCrash
    case transientBlip
}

/// Classifies an XPC interruption by checking for a *fresh* crash report (`.ips`) that names
/// the capture helper. An interruption with no matching recent report is treated as a benign
/// route-change blip rather than a "crash" (#86) — the app survives, no `.ips` is written.
public enum CrashReportScanner {

    /// Default DiagnosticReports locations (user + system domains).
    public static var defaultReportDirectories: [URL] {
        var dirs: [URL] = []
        if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            dirs.append(lib.appendingPathComponent("Logs/DiagnosticReports"))
        }
        dirs.append(URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"))
        return dirs
    }

    /// Lower-cased substrings that mark a report as belonging to our capture stack.
    public static let captureProcessTokens = ["audio-capture-helper", "parley", "jetsamevent"]

    /// Pure classifier: is there a report whose name contains a process token AND that was
    /// modified within `[now - window, now]`? Reports dated in the future are ignored.
    public static func classify(
        reports: [(name: String, modified: Date)],
        processTokens: [String],
        now: Date,
        window: TimeInterval
    ) -> CrashClassification {
        let tokens = processTokens.map { $0.lowercased() }
        for report in reports {
            let lower = report.name.lowercased()
            guard tokens.contains(where: { lower.contains($0) }) else { continue }
            let age = now.timeIntervalSince(report.modified)
            if age >= 0 && age <= window {
                return .likelyCrash
            }
        }
        return .transientBlip
    }

    /// Live wrapper: scans the DiagnosticReports directories. Fails soft to `.transientBlip` —
    /// a missing or unreadable directory must never escalate a benign blip into a "crash".
    public static func classifyLive(
        now: Date = Date(),
        window: TimeInterval = 90,
        directories: [URL]? = nil,
        processTokens: [String] = captureProcessTokens
    ) -> CrashClassification {
        let dirs = directories ?? defaultReportDirectories
        var reports: [(name: String, modified: Date)] = []
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                reports.append((name: url.lastPathComponent, modified: mod))
            }
        }
        return classify(reports: reports, processTokens: processTokens, now: now, window: window)
    }
}
