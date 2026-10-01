import Foundation

/// Removes characters that are unsafe in file names (path separators, colons, null bytes).
public func sanitizeFilename(_ name: String) -> String {
    var sanitized = name
    for char in ["/", ":", "\0"] {
        sanitized = sanitized.replacingOccurrences(of: char, with: "")
    }
    return sanitized
}

/// The longest a session's id — its files' base name — may be, in UTF-8 bytes (L review 262): every file named from it fits
/// in the 255 BYTES the strictest file systems allow (a share or a Linux server count bytes; APFS counts characters). The
/// longest such name is a damaged summary kept aside under a unique name, `<id>-summary.damaged-<UUID>.md`: 56 bytes more.
public let maxSessionIdBytes = 255 - 56

/// `name`, fitted into `maxBytes` UTF-8 bytes (L review 262): unchanged when it fits. Otherwise its longest prefix of WHOLE
/// characters that leaves room for "-" and an 8-hex-digit hash of the whole name — cut on a character boundary, and two long
/// names that share their start never fit to the same one.
public func fittedFilename(_ name: String, maxBytes: Int) -> String {
    guard name.utf8.count > maxBytes else { return name }
    var hash: UInt32 = 0x811C_9DC5   // FNV-1a: the same on every run, unlike `hashValue`
    for byte in name.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    let suffix = "-" + String(format: "%08x", hash)
    var kept = "", bytes = 0
    for character in name {
        let size = character.utf8.count
        guard bytes + size + suffix.utf8.count <= maxBytes else { break }
        kept.append(character)
        bytes += size
    }
    return kept + suffix
}
