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
    /// DIAGNOSTIC ONLY (#247): the WAV writers skip their periodic `fsync` (the header is still
    /// rewritten), for the A/B that tells whether that `fsync` is what stalls the IO callback.
    public var debugSkipWavSync: Bool

    public init(tapAutoStart: Bool = true, remoteExactZeroSoftAlarmSeconds: Int? = nil, debugDropTapFrames: Bool = false,
                debugSkipWavSync: Bool = false) {
        self.tapAutoStart = tapAutoStart
        self.remoteExactZeroSoftAlarmSeconds = remoteExactZeroSoftAlarmSeconds
        self.debugDropTapFrames = debugDropTapFrames
        self.debugSkipWavSync = debugSkipWavSync
    }

    public init(config: Config) {
        self.init(tapAutoStart: config.tapAutoStart ?? true,
                  remoteExactZeroSoftAlarmSeconds: config.remoteExactZeroSoftAlarmSeconds,
                  debugDropTapFrames: config.debugDropTapFrames ?? false,
                  debugSkipWavSync: config.debugSkipWavSync ?? false)
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// `nil` unless `data` is a complete `CaptureOptions`. The helper's `configureCapture` uses this
    /// so it can reply "not understood" instead of silently recording with defaults.
    public static func decodeStrict(_ data: Data) -> CaptureOptions? {
        try? JSONDecoder().decode(CaptureOptions.self, from: data)
    }

    public static func decode(_ data: Data?) -> CaptureOptions {
        data.flatMap(decodeStrict) ?? CaptureOptions()
    }
}
