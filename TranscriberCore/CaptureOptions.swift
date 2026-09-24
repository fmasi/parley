import Foundation

/// What the app tells the helper before `startCapture` (§5, §10). JSON over `configureCapture`.
/// Every field has a default so an older helper (or a failed configure) records exactly as today.
public struct CaptureOptions: Codable, Equatable, Sendable {
    /// `kAudioAggregateDeviceTapAutoStartKey`. `true` = the shipped behaviour (gotcha #78); the
    /// default flips to `false` only if measurement M-B passes.
    public var tapAutoStart: Bool
    /// Seconds of exact-zero remote audio after which the helper says "can't confirm". `nil` = off,
    /// and it stays off unless the exact-zero census (M-A) shows no call app renders zeros when muted.
    public var remoteExactZeroSoftAlarmSeconds: Int?
    /// DIAGNOSTIC ONLY (device item D-04): the helper drops every tap buffer BEFORE stamping the
    /// heartbeat, reproducing Incident B's "expected but never delivered" deterministically.
    public var debugDropTapFrames: Bool

    public init(tapAutoStart: Bool = true, remoteExactZeroSoftAlarmSeconds: Int? = nil, debugDropTapFrames: Bool = false) {
        self.tapAutoStart = tapAutoStart
        self.remoteExactZeroSoftAlarmSeconds = remoteExactZeroSoftAlarmSeconds
        self.debugDropTapFrames = debugDropTapFrames
    }

    public init(config: Config) {
        self.init(tapAutoStart: config.tapAutoStart ?? true,
                  remoteExactZeroSoftAlarmSeconds: config.remoteExactZeroSoftAlarmSeconds,
                  debugDropTapFrames: config.debugDropTapFrames ?? false)
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> CaptureOptions {
        guard let data, let o = try? JSONDecoder().decode(CaptureOptions.self, from: data) else { return CaptureOptions() }
        return o
    }
}
