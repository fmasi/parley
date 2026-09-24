import Foundation

/// Alarm STATE (§6): per track, owned by the helper or the app, sticky until its condition
/// clears. Replaces the one-shot `captureQualityAnomaly` events + the single overwritable
/// `interruptionWarning` slot for anything that means "a side is not being recorded".
public enum AlarmKind: String, Codable, CaseIterable, Sendable {
    case micNotDelivering, micDigitalSilence
    case remoteNotDelivering, remoteRecoveryFailed, remotePermissionDenied, remoteCantConfirm
    case diskWriteFailure
    case diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff
    case recordingResumedWithGap, recordingStopped, recordingFolderUnavailable

    public var isHelperOwned: Bool {
        switch self {
        case .micNotDelivering, .micDigitalSilence, .remoteNotDelivering, .remoteRecoveryFailed,
             .remotePermissionDenied, .remoteCantConfirm, .diskWriteFailure: return true
        default: return false
        }
    }

    public var track: String? {
        switch self {
        case .micNotDelivering, .micDigitalSilence: return "mic"
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm: return "system"
        default: return nil
        }
    }

    /// Past events the user dismisses; everything else clears only when the condition clears.
    public var isAcknowledgeable: Bool { self == .recordingResumedWithGap || self == .recordingStopped }

    /// Survives the end of a recording: a machine-level condition, or a past event the user has
    /// not acknowledged yet ("the recording STOPPED at 16:02" must outlive the recording it is about).
    public var outlivesRecording: Bool { self == .crashProtectionOff || isAcknowledgeable }
}

public struct ActiveAlarm: Codable, Equatable, Sendable {
    public let kind: AlarmKind
    public let raisedAt: Date
    public var lastNotifiedAt: Date?
    public let message: String
    public let episode: Int

    public init(kind: AlarmKind, raisedAt: Date, lastNotifiedAt: Date?, message: String, episode: Int) {
        self.kind = kind; self.raisedAt = raisedAt; self.lastNotifiedAt = lastNotifiedAt
        self.message = message; self.episode = episode
    }
}

public struct CaptureAlarmRegistry: Equatable, Sendable {
    public private(set) var alarms: [AlarmKind: ActiveAlarm] = [:]
    private var episodes: [AlarmKind: Int] = [:]
    /// Helper-owned alarms inherited from a helper that has since been replaced (crash restart).
    /// Kept and shown until the new helper's first frames on that track prove the condition gone (§6.2).
    public private(set) var staleKinds: Set<AlarmKind> = []
    public private(set) var helperSessionId: String?

    public init() {}

    /// True when newly raised; a repeat keeps the original alarm untouched.
    @discardableResult
    public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool {
        guard alarms[kind] == nil else { return false }
        let episode = (episodes[kind] ?? 0) + 1
        episodes[kind] = episode
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: now, lastNotifiedAt: nil, message: message, episode: episode)
        return true
    }

    @discardableResult
    public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm? {
        staleKinds.remove(kind)
        return alarms.removeValue(forKey: kind)
    }

    public mutating func markNotified(_ kind: AlarmKind, now: Date) { alarms[kind]?.lastNotifiedAt = now }

    /// App side. SAME helper: its snapshot is the truth for helper-owned kinds; a kind still active
    /// in the same episode keeps its notify clock (scan C7). NEW helper (`helperSessionId` changed):
    /// the previous helper's alarms become stale but stay visible; the new helper's are adopted (§6.2).
    public mutating func apply(_ snapshot: CaptureStatusSnapshot) {
        let sameHelper = helperSessionId == nil || helperSessionId == snapshot.helperSessionId
        if sameHelper {
            for kind in AlarmKind.allCases where kind.isHelperOwned && !staleKinds.contains(kind) {
                if !snapshot.alarms.contains(where: { $0.kind == kind }) { alarms.removeValue(forKey: kind) }
            }
        } else {
            for kind in alarms.keys where kind.isHelperOwned { staleKinds.insert(kind) }
        }
        for incoming in snapshot.alarms where incoming.kind.isHelperOwned {
            var kept = incoming
            if let existing = alarms[incoming.kind], existing.episode == incoming.episode,
               !staleKinds.contains(incoming.kind) {
                kept.lastNotifiedAt = existing.lastNotifiedAt
            }
            alarms[incoming.kind] = kept
            staleKinds.remove(incoming.kind)
        }
        helperSessionId = snapshot.helperSessionId
    }

    /// First frames of `track` from the current helper: the previous helper's alarms on that track,
    /// and its track-less ones (`diskWriteFailure`), are proven stale. The new helper re-raises
    /// anything that is still true within seconds.
    public mutating func noteFirstFrames(track: String) {
        for kind in Array(staleKinds) where kind.track == track || kind.track == nil {
            alarms.removeValue(forKey: kind)
            staleKinds.remove(kind)
        }
    }

    /// The recording ended: everything scoped to it goes; machine-level and unacknowledged past
    /// events stay.
    public mutating func recordingEnded() {
        for kind in Array(alarms.keys) where !kind.outlivesRecording { _ = clear(kind) }
    }

    public var isEmpty: Bool { alarms.isEmpty }
    public var sorted: [ActiveAlarm] { alarms.values.sorted { $0.raisedAt < $1.raisedAt } }
}

public struct TrackHealthSnapshot: Codable, Equatable, Sendable {
    public let track: String
    public let expected: Bool
    public let heartbeatAgeSeconds: Double?
    public let generation: Int
    public init(track: String, expected: Bool, heartbeatAgeSeconds: Double?, generation: Int) {
        self.track = track; self.expected = expected; self.heartbeatAgeSeconds = heartbeatAgeSeconds; self.generation = generation
    }
}

/// What the app PULLS from the helper on connect, every 5 s while recording, and after any
/// restart — and what the helper PUSHES on every change. JSON over XPC.
public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
    public let helperSessionId: String
    public let isCapturing: Bool
    public let alarms: [ActiveAlarm]
    public let tracks: [TrackHealthSnapshot]

    public init(helperSessionId: String, isCapturing: Bool, alarms: [ActiveAlarm], tracks: [TrackHealthSnapshot]) {
        self.helperSessionId = helperSessionId; self.isCapturing = isCapturing; self.alarms = alarms; self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey { case helperSessionId, isCapturing, alarms, tracks }

    /// Tolerant: an alarm whose kind this build does not know is dropped, the rest survive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperSessionId = try c.decode(String.self, forKey: .helperSessionId)
        isCapturing = try c.decode(Bool.self, forKey: .isCapturing)
        tracks = try c.decodeIfPresent([TrackHealthSnapshot].self, forKey: .tracks) ?? []
        var raw = try c.nestedUnkeyedContainer(forKey: .alarms)
        var kept: [ActiveAlarm] = []
        while !raw.isAtEnd {
            if let a = try? raw.decode(ActiveAlarm.self) { kept.append(a) } else { _ = try? raw.decode(SkippedElement.self) }
        }
        alarms = kept
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }
    public func encoded() -> Data { (try? Self.coder().0.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> CaptureStatusSnapshot? { try? coder().1.decode(CaptureStatusSnapshot.self, from: data) }
}

/// Consumes one unknown array element while decoding (used by the tolerant snapshot decoder).
private struct SkippedElement: Decodable {
    private enum NoKeys: CodingKey {}
    init(from decoder: Decoder) throws { _ = try? decoder.container(keyedBy: NoKeys.self) }
}

public enum AlarmRealarmPolicy {
    public static let notifyInterval: TimeInterval = 120

    public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool {
        guard let last = alarm.lastNotifiedAt else { return true }
        return now.timeIntervalSince(last) >= notifyInterval
    }

    public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool {
        CaptureReadiness.shouldPresentRepair(lastDismissedAt: lastDismissedAt, now: now)
    }
}
