import Foundation

/// Renders a filesystem path for display, abbreviating the user's home
/// directory to `~`.
///
/// Lives in Core (not the app target) so the boundary cases below are
/// reachable from the test suite — it is shared by Setup and Settings.
///
/// The match is **prefix-anchored**: an earlier implementation used
/// `replacingOccurrences(of: NSHomeDirectory(), with: "~")`, which rewrote the
/// home path wherever it appeared, so `/Users/me/backup/Users/me` collapsed in
/// the middle as well as at the front. Home is also standardized before
/// comparison, so a symlinked home still matches a standardized input path.
public func abbreviatedDisplayPath(_ path: String) -> String {
    let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    let home = (NSHomeDirectory() as NSString).standardizingPath

    if standardized == home { return "~" }
    if standardized.hasPrefix(home + "/") {
        return "~" + standardized.dropFirst(home.count)
    }
    return standardized
}
