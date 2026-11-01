import Foundation

/// What Settings says after a model update check, and whether it offers a re-download (#349).
/// Every message names an action the app actually has: a re-download where one would change the
/// files Parley loads, a Parley update where only new files were published.
public enum ModelUpdateNotice {
    public static func message(for status: ManifestUpdateStatus) -> String {
        switch status {
        case .upToDate(let sha):
            return "Up to date (\(short(sha)))."
        case .loadedFilesUnchanged(let local, let remote, let added):
            guard !added.isEmpty else {
                return "Up to date (\(short(local))). Hugging Face has a newer commit (\(short(remote))), "
                    + "but none of the files Parley uses changed."
            }
            let verb = added.count == 1 ? "it" : "them"
            return "Up to date (\(short(local))). Hugging Face has since added \(list(added)), which this "
                + "version of Parley doesn't use — a Parley update would bring \(verb) in."
        case .updateAvailable(let local, let remote, let when, let changed):
            let date = when.map { ", \($0.prefix(10))" } ?? ""
            return "Update available: \(list(changed)) changed on Hugging Face (\(short(local)) → \(short(remote))\(date)). "
                + "Re-download the model to apply it."
        case .noBaseline:
            return "No record yet of which model version is on this Mac. Re-download the model to record one."
        case .checkFailed(let reason):
            return "Check failed: \(reason)"
        }
    }

    /// Whether a re-download would do something: apply changed files, or record the missing baseline.
    public static func offersRedownload(for status: ManifestUpdateStatus) -> Bool {
        switch status {
        case .updateAvailable, .noBaseline: return true
        case .upToDate, .loadedFilesUnchanged, .checkFailed: return false
        }
    }

    private static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "files"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
