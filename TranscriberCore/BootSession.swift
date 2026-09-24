import Foundation

/// `kern.bootsessionuuid`: changes on every boot, immune to sleep and to wall-clock changes
/// (gotcha #76: `ProcessInfo.systemUptime` excludes sleep — 7.2 h short on this Mac).
public enum BootSession {
    public static func currentUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
