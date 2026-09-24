import Foundation
import os

/// The two recorded tracks. Raw values are the wire strings used across XPC and in the snapshot.
public enum CaptureTrack: String, Codable, CaseIterable, Sendable {
    case mic, system
}

/// What a NEW helper must observe before a STALE alarm (inherited from the helper it replaced) is
/// proven gone (§6.2). Each kind is disproved only by evidence about the thing it claims.
public enum AlarmEvidence: Sendable {
    /// A first heartbeat on the track: the track delivers again.
    case firstFrames
    /// A non-zero sample on the track. First frames cannot disprove a content alarm: a denied tap
    /// or a muted mic delivers frames on time, all of them zero.
    case realAudio
    /// A successful write: the disk takes audio again.
    case writeSucceeded
}

/// Alarm STATE (§6): per track, owned by the helper or the app, sticky until its condition
/// clears. Replaces the one-shot `captureQualityAnomaly` events + the single overwritable
/// `interruptionWarning` slot for anything that means "a side is not being recorded".
public enum AlarmKind: String, Codable, CaseIterable, Sendable {
    case micNotDelivering, micDigitalSilence
    case remoteNotDelivering, remoteRecoveryFailed, remotePermissionDenied, remoteCantConfirm
    case diskWriteFailure
    case diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff
    case recordingResumedWithGap, recordingStopped, recordingFolderUnavailable

    public var isHelperOwned: Bool { disprovedBy != nil }

    public var track: CaptureTrack? {
        switch self {
        case .micNotDelivering, .micDigitalSilence: return .mic
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm: return .system
        default: return nil
        }
    }

    /// The evidence that clears this kind once it is stale. `nil` for app-owned kinds, which never
    /// come from a helper and so are never stale.
    public var disprovedBy: AlarmEvidence? {
        switch self {
        case .micNotDelivering, .remoteNotDelivering, .remoteRecoveryFailed: return .firstFrames
        case .micDigitalSilence, .remotePermissionDenied, .remoteCantConfirm: return .realAudio
        case .diskWriteFailure: return .writeSucceeded
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
    /// Since when the condition has been true. A replacing helper re-raising it keeps this.
    public let raisedAt: Date
    /// When this KIND last notified — carried across episodes and clears, so a flapping condition
    /// cannot notify faster than `AlarmRealarmPolicy.notifyInterval`. App-side state: a value in a
    /// helper snapshot is ignored.
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
    /// Per-kind notification floor. Survives clears: a new episode notifies at once only if its kind
    /// has not notified within `notifyInterval`; the row itself updates immediately regardless.
    private var lastNotified: [AlarmKind: Date] = [:]
    /// Helper-owned alarms inherited from a helper that has since been replaced (crash restart).
    /// Kept and shown until the new helper's evidence proves the condition gone (§6.2).
    public private(set) var staleKinds: Set<AlarmKind> = []
    public private(set) var helperSessionId: String?
    /// Helpers already replaced. A message still in flight from one of them says nothing about now.
    private var retiredHelperSessionIds: Set<String> = []

    public init() {}

    /// True when newly raised; a repeat keeps the original alarm untouched.
    @discardableResult
    public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool {
        guard alarms[kind] == nil else { return false }
        let episode = (episodes[kind] ?? 0) + 1
        episodes[kind] = episode
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: now, lastNotifiedAt: lastNotified[kind], message: message, episode: episode)
        return true
    }

    @discardableResult
    public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm? {
        staleKinds.remove(kind)
        return alarms.removeValue(forKey: kind)
    }

    public mutating func markNotified(_ kind: AlarmKind, now: Date) {
        guard alarms[kind] != nil else { return }
        alarms[kind]?.lastNotifiedAt = now
        lastNotified[kind] = now
    }

    /// App side. The snapshot's helper becomes the current one (a NEW helper turns the previous
    /// helper's alarms stale, §6.2; a replaced helper's late snapshot is ignored). The current
    /// helper's snapshot is then the truth for every helper-owned kind that is not stale. An alarm
    /// continuing in the same episode, or re-raised by the replacing helper, keeps its `raisedAt`.
    /// App-owned kinds inside a snapshot are ignored.
    public mutating func apply(_ snapshot: CaptureStatusSnapshot) {
        guard adoptHelper(snapshot.helperSessionId) else { return }
        for kind in AlarmKind.allCases where kind.isHelperOwned && !staleKinds.contains(kind) {
            if !snapshot.alarms.contains(where: { $0.kind == kind }) { alarms.removeValue(forKey: kind) }
        }
        for incoming in snapshot.alarms where incoming.kind.isHelperOwned {
            var raisedAt = incoming.raisedAt
            if let existing = alarms[incoming.kind],
               staleKinds.contains(incoming.kind) || existing.episode == incoming.episode {
                raisedAt = existing.raisedAt
            }
            alarms[incoming.kind] = ActiveAlarm(kind: incoming.kind, raisedAt: raisedAt,
                                                lastNotifiedAt: lastNotified[incoming.kind],
                                                message: incoming.message, episode: incoming.episode)
            staleKinds.remove(incoming.kind)
        }
    }

    /// First frames of `track` from helper `helperSessionId`: the stale DELIVERY alarms on that track
    /// are disproved. Carries the helper id because this channel is not ordered with the snapshots:
    /// frames from a new helper may arrive before its first snapshot, and must not be lost.
    public mutating func noteFirstFrames(track: CaptureTrack, helperSessionId: String) {
        clearStale(helperSessionId: helperSessionId) { $0.disprovedBy == .firstFrames && $0.track == track }
    }

    /// A non-zero sample on `track`: the stale CONTENT alarms on that track (digital silence,
    /// permission denied, can't confirm) are disproved.
    public mutating func noteRealAudio(track: CaptureTrack, helperSessionId: String) {
        clearStale(helperSessionId: helperSessionId) { $0.disprovedBy == .realAudio && $0.track == track }
    }

    /// A successful write: a stale `diskWriteFailure` is disproved.
    public mutating func noteWriteSucceeded(helperSessionId: String) {
        clearStale(helperSessionId: helperSessionId) { $0.disprovedBy == .writeSucceeded }
    }

    /// The recording ended: everything scoped to it goes; machine-level and unacknowledged past
    /// events stay.
    public mutating func recordingEnded() {
        for kind in Array(alarms.keys) where !kind.outlivesRecording { _ = clear(kind) }
    }

    public var isEmpty: Bool { alarms.isEmpty }
    /// By `raisedAt`, ties broken by kind so the order is stable.
    public var sorted: [ActiveAlarm] {
        alarms.values.sorted { ($0.raisedAt, $0.kind.rawValue) < ($1.raisedAt, $1.kind.rawValue) }
    }

    /// Moves to helper `id`. A NEW helper turns every helper-owned alarm of the previous one stale.
    /// Returns false for a helper that has already been replaced: its message is ignored.
    private mutating func adoptHelper(_ id: String) -> Bool {
        if id == helperSessionId { return true }
        if retiredHelperSessionIds.contains(id) { return false }
        if let previous = helperSessionId {
            retiredHelperSessionIds.insert(previous)
            for kind in alarms.keys where kind.isHelperOwned { staleKinds.insert(kind) }
        }
        helperSessionId = id
        return true
    }

    /// Evidence from `helperSessionId` clears the stale kinds it disproves. The helper's own current
    /// alarms are left alone: its snapshots own them.
    private mutating func clearStale(helperSessionId id: String, _ disproved: (AlarmKind) -> Bool) {
        guard adoptHelper(id) else { return }
        for kind in Array(staleKinds) where disproved(kind) {
            alarms.removeValue(forKey: kind)
            staleKinds.remove(kind)
        }
    }
}

public struct TrackHealthSnapshot: Codable, Equatable, Sendable {
    public let track: CaptureTrack
    public let expected: Bool
    /// `nil` when unknown. A non-finite age is stored as `nil`: JSON cannot carry it, and one bad
    /// value must never make the whole snapshot unencodable.
    public let heartbeatAgeSeconds: Double?
    public let generation: Int
    public init(track: CaptureTrack, expected: Bool, heartbeatAgeSeconds: Double?, generation: Int) {
        self.track = track; self.expected = expected; self.generation = generation
        self.heartbeatAgeSeconds = heartbeatAgeSeconds.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// What the app PULLS from the helper on connect, every 5 s while recording, and after any
/// restart — and what the helper PUSHES on every change. JSON over XPC.
public struct CaptureStatusSnapshot: Codable, Equatable, Sendable {
    public let helperSessionId: String
    public let isCapturing: Bool
    public let alarms: [ActiveAlarm]
    public let tracks: [TrackHealthSnapshot]
    /// Decode side only: alarm kinds this build does not know (a newer helper), skipped from `alarms`.
    /// Never encoded.
    public private(set) var unknownAlarmKinds: [String] = []

    public init(helperSessionId: String, isCapturing: Bool, alarms: [ActiveAlarm], tracks: [TrackHealthSnapshot]) {
        self.helperSessionId = helperSessionId; self.isCapturing = isCapturing; self.alarms = alarms; self.tracks = tracks
    }

    // `unknownAlarmKinds` is deliberately absent: it describes the decoding build, not the wire.
    private enum CodingKeys: String, CodingKey { case helperSessionId, isCapturing, alarms, tracks }

    /// Tolerant of exactly one thing: an alarm whose KIND this build does not know is skipped and
    /// recorded in `unknownAlarmKinds`. Any other defect fails the whole snapshot — a silently
    /// dropped alarm would read as an all-clear on the next `apply` and clear a live alarm.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperSessionId = try c.decode(String.self, forKey: .helperSessionId)
        isCapturing = try c.decode(Bool.self, forKey: .isCapturing)
        tracks = try c.decodeIfPresent([TrackHealthSnapshot].self, forKey: .tracks) ?? []
        var known: [ActiveAlarm] = []
        var unknown: [String] = []
        for element in try c.decode([WireAlarm].self, forKey: .alarms) {
            switch element {
            case .known(let alarm): known.append(alarm)
            case .unknownKind(let raw): unknown.append(raw)
            }
        }
        alarms = known
        unknownAlarmKinds = unknown
    }

    /// ISO-8601 with milliseconds: alarms raised within the same second must keep their order.
    private static let fractionalDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDates = Date.ISO8601FormatStyle()

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractionalDates.format(date))
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = (try? fractionalDates.parse(text)) ?? (try? wholeSecondDates.parse(text)) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO-8601 date")
        }
        return (e, d)
    }

    public func encoded() -> Data {
        do {
            return try Self.coder().0.encode(self)
        } catch {
            Logger.audio.error("Capture status snapshot could not be encoded: \(error, privacy: .public)")
            return Data()
        }
    }

    public static func decode(_ data: Data) -> CaptureStatusSnapshot? { try? coder().1.decode(CaptureStatusSnapshot.self, from: data) }
}

/// One alarm on the wire, with its kind probed first so an unknown kind can be told apart from a
/// malformed alarm.
private enum WireAlarm: Decodable {
    case known(ActiveAlarm)
    case unknownKind(String)

    private enum Keys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
        guard AlarmKind(rawValue: raw) != nil else { self = .unknownKind(raw); return }
        self = .known(try ActiveAlarm(from: decoder))
    }
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
