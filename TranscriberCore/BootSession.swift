import Foundation

/// `kern.bootsessionuuid`: changes on every boot, immune to sleep and to wall-clock changes
/// (gotcha #76: `ProcessInfo.systemUptime` excludes sleep — 7.2 h short on this Mac).
public enum BootSession {
    public static func currentUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        // `String(cString:)` on a `[CChar]` is deprecated (fix round 1, item 10): decode the bytes
        // up to the NUL terminator directly instead.
        let nulIndex = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<nulIndex].map { UInt8(bitPattern: $0) }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
