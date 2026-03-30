import Foundation

/// Removes characters that are unsafe in file names (path separators, colons, null bytes).
public func sanitizeFilename(_ name: String) -> String {
    var sanitized = name
    for char in ["/", ":", "\0"] {
        sanitized = sanitized.replacingOccurrences(of: char, with: "")
    }
    return sanitized
}
