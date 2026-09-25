import Foundation
import os

/// The two recorded tracks. Raw values are the wire strings used across XPC and in the snapshot.
public enum CaptureTrack: String, Codable, CaseIterable, Sendable {
    case mic, system
}

/// Names one helper alarm-registry instance, ORDERED: `"<process start ms>-<registry resets>"`, e.g.
/// `"1790000000123-4"`. A later process is newer whatever its counter; within one process every
/// registry reset is newer. The app adopts an id only when it is strictly newer than the current one,
/// so a late message from a replaced helper can never displace its replacement.
public struct HelperSessionId: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let processStartMillis: UInt64
    public let registryResets: UInt64

    public init(processStartMillis: UInt64, registryResets: UInt64) {
        self.processStartMillis = processStartMillis
        self.registryResets = registryResets
    }

    /// Strict: exactly two runs of ASCII digits joined by one `-`.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let start = UInt64(parts[0]), let resets = UInt64(parts[1]) else { return nil }
        self.init(processStartMillis: start, registryResets: resets)
    }

    public var description: String { "\(processStartMillis)-\(registryResets)" }

    public static func < (lhs: HelperSessionId, rhs: HelperSessionId) -> Bool {
        (lhs.processStartMillis, lhs.registryResets) < (rhs.processStartMillis, rhs.registryResets)
    }
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
    /// Helper-owned, ACKNOWLEDGEABLE, per recording (H2 round 2 item 12): switching to a new microphone
    /// failed, but the previous one is still recording. Cleared by a later successful follow, the end
    /// of the recording, or the user's acknowledgement.
    case micFollowFailed
    case remoteNotDelivering, remoteRecoveryFailed, remotePermissionDenied, remoteCantConfirm
    case diskWriteFailure
    case diskLow, rotationFailed, sessionWriteFailed, helperUnresponsive, crashProtectionOff
    case recordingResumedWithGap, recordingStopped, recordingFolderUnavailable
    /// App-owned, ACKNOWLEDGEABLE (L review 219): audio of a finished recording, recorded after its transcript was written,
    /// is kept beside it untranscribed. A past event — nothing just stopped — so never under "Recording STOPPED".
    case audioAfterTranscript
    /// App-owned, ACKNOWLEDGEABLE (L review 268): chunks the helper MAY have recorded after a Stop's transcript, which the
    /// Stop could not check — the folder was not answering. Only what is certain is said: possibly audio, kept if it is there.
    case possibleAudioAfterTranscript
    /// App-owned, ACKNOWLEDGEABLE (L review 249): a list of unfinished recordings Parley could not read — set aside, or left
    /// in place — and those recordings may need finishing by hand. A note about the list, not about one recording: never
    /// under "Recording STOPPED", where it would take the place of a session's own row.
    case pendingListUnreadable
    /// App-owned: the helper reported alarm kinds this build does not know (a newer helper). One
    /// generic alarm, so they are never silently dropped; cleared when a snapshot no longer has any.
    case unknownHelperAlarm

    public var isHelperOwned: Bool { disprovedBy != nil }

    public var track: CaptureTrack? {
        switch self {
        case .micNotDelivering, .micDigitalSilence, .micFollowFailed: return .mic
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm: return .system
        default: return nil
        }
    }

    /// The evidence that clears this kind once it is stale. `nil` for app-owned kinds, which never
    /// come from a helper and so are never stale.
    public var disprovedBy: AlarmEvidence? {
        switch self {
        // A replacing helper reopens the mic: its first frames disprove an inherited follow failure too.
        case .micNotDelivering, .remoteNotDelivering, .remoteRecoveryFailed, .micFollowFailed: return .firstFrames
        case .micDigitalSilence, .remotePermissionDenied, .remoteCantConfirm: return .realAudio
        case .diskWriteFailure: return .writeSucceeded
        default: return nil
        }
    }

    /// A past event about ONE recording (L review 261): another recording's, raised while the row is still up, is added to
    /// it — never dropped because the kind is already up.
    public var addsPerSession: Bool { self == .recordingStopped || self == .audioAfterTranscript || self == .possibleAudioAfterTranscript }

    /// Past events the user dismisses; everything else clears only when the condition clears.
    public var isAcknowledgeable: Bool {
        self == .recordingResumedWithGap || self == .recordingStopped || self == .micFollowFailed || self == .audioAfterTranscript
            || self == .possibleAudioAfterTranscript || self == .pendingListUnreadable
    }

    /// The row's headline, shared by the menu's sticky rows and the alarm window (in Core, so it is tested — L review 219).
    public var headline: String {
        switch self {
        case .crashProtectionOff: return "Crash protection is off"
        case .micNotDelivering, .micDigitalSilence: return "Your microphone isn’t being recorded"
        case .micFollowFailed: return "Couldn’t switch microphones"
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm:
            return "The other side may not be recorded"
        case .diskLow, .diskWriteFailure, .rotationFailed, .sessionWriteFailed: return "Recording to disk is in trouble"
        case .helperUnresponsive: return "The capture helper stopped answering"
        case .recordingResumedWithGap: return "Recording resumed after a crash"
        case .recordingStopped: return "Recording STOPPED"
        case .recordingFolderUnavailable: return "Recording folder unavailable"
        case .audioAfterTranscript: return "Audio kept after a transcript"
        case .possibleAudioAfterTranscript: return "Possible audio after a transcript"
        case .pendingListUnreadable: return "A list of unfinished recordings couldn’t be read"
        case .unknownHelperAlarm: return "Parley needs an update to show a capture problem"
        }
    }

    /// Survives the end of a recording: a machine-level condition, or a past event the user has
    /// not acknowledged yet ("the recording STOPPED at 16:02" must outlive the recording it is about).
    /// `micFollowFailed` is acknowledgeable but about the recording's own mic: it goes with it.
    public var outlivesRecording: Bool {
        self == .crashProtectionOff || self == .recordingFolderUnavailable || (isAcknowledgeable && self != .micFollowFailed)
    }

    /// The permission kinds keep their own repair window (§6.3): while it is open, the alarm window
    /// leaves their rows — and their notifications — to it.
    public var hasOwnRepairWindow: Bool { self == .remotePermissionDenied || self == .remoteCantConfirm }

    /// One stable notification identifier per kind: a re-notify replaces that kind's banner, never
    /// stacks another, and never replaces a different alarm's (L round 6).
    public var notificationIdentifier: String { "parley-capture-alarm.\(rawValue)" }
}

public struct ActiveAlarm: Codable, Equatable, Sendable {
    public let kind: AlarmKind
    /// Since when the condition has been true. A replacing helper re-raising it keeps this.
    public let raisedAt: Date
    /// When this KIND last notified — carried across episodes and clears, so a flapping condition
    /// cannot notify faster than `AlarmRealarmPolicy.notifyInterval`. Acknowledgeable kinds are
    /// exempt: each is a one-off past event and notifies at once. App-side state: a value in a
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
    /// The newest helper registry heard from. Anything older is a late message and is ignored.
    public private(set) var helperSessionId: HelperSessionId?
    /// Sequence of the last snapshot applied from the current helper; a same-helper snapshot that is
    /// not newer (a pull reply overtaken by a push) is ignored. Reset when a newer helper is adopted.
    private var lastAppliedSequence: UInt64?
    /// Helper-owned acknowledgeable alarms the user acknowledged, by episode of the current helper: its
    /// later snapshots of that episode must not bring the row back (H2 round 2 item 12). Episodes count
    /// per helper registry, so a newer helper forgets them.
    private var acknowledgedEpisodes: [AlarmKind: Int] = [:]

    public init() {}

    /// True when newly raised — or, for a kind that `addsPerSession`, when another recording's message was added to its row
    /// still up (L review 261). A repeat keeps the alarm untouched.
    @discardableResult
    public mutating func raise(_ kind: AlarmKind, message: String, now: Date) -> Bool {
        if let existing = alarms[kind] {
            guard kind.addsPerSession, !existing.message.contains(message) else { return false }
            alarms[kind] = ActiveAlarm(kind: kind, raisedAt: existing.raisedAt, lastNotifiedAt: existing.lastNotifiedAt,
                                       message: existing.message + " " + message, episode: existing.episode)
            return true
        }
        let episode = (episodes[kind] ?? 0) + 1
        episodes[kind] = episode
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: now, lastNotifiedAt: kind.isAcknowledgeable ? nil : lastNotified[kind],
                                   message: message, episode: episode)
        return true
    }

    /// A per-session row's message REVISED (L review 255): `old`, one recording's, is replaced by `new` where the row still
    /// says it — never left beside it; otherwise `new` is raised (or added). True when the row changed.
    @discardableResult
    public mutating func revise(_ kind: AlarmKind, replacing old: String, with new: String, now: Date) -> Bool {
        guard let existing = alarms[kind], existing.message.contains(old) else { return raise(kind, message: new, now: now) }
        guard old != new else { return false }
        alarms[kind] = ActiveAlarm(kind: kind, raisedAt: existing.raisedAt, lastNotifiedAt: existing.lastNotifiedAt,
                                   message: existing.message.replacingOccurrences(of: old, with: new), episode: existing.episode)
        return true
    }

    @discardableResult
    public mutating func clear(_ kind: AlarmKind) -> ActiveAlarm? {
        staleKinds.remove(kind)
        return alarms.removeValue(forKey: kind)
    }

    /// The user acknowledged a past event. A no-op for a live condition, which clears only when it clears.
    public mutating func acknowledge(_ kind: AlarmKind) {
        guard kind.isAcknowledgeable, let alarm = clear(kind) else { return }
        if kind.isHelperOwned { acknowledgedEpisodes[kind] = alarm.episode }
    }

    public mutating func markNotified(_ kind: AlarmKind, now: Date) {
        guard alarms[kind] != nil else { return }
        alarms[kind]?.lastNotifiedAt = now
        lastNotified[kind] = now
    }

    /// App side. A snapshot from a NEWER helper makes it the current one and turns the previous
    /// helper's alarms stale (§6.2); one from an older helper, or an older/duplicate `sequence` from
    /// the current helper, is ignored. The current helper's snapshot is then the truth for every
    /// helper-owned kind that is not stale. An alarm continuing in the same episode, or re-raised by
    /// the replacing helper, keeps its `raisedAt`. App-owned kinds inside a snapshot are ignored.
    /// Returns whether the snapshot was adopted, so nothing downstream acts on a rejected one.
    @discardableResult
    public mutating func apply(_ snapshot: CaptureStatusSnapshot) -> Bool {
        guard adoptHelper(snapshot.helperSessionId) else { return false }
        if let last = lastAppliedSequence, snapshot.sequence <= last { return false }
        lastAppliedSequence = snapshot.sequence
        for kind in AlarmKind.allCases where kind.isHelperOwned && !staleKinds.contains(kind) {
            if !snapshot.alarms.contains(where: { $0.kind == kind }) { alarms.removeValue(forKey: kind) }
        }
        for incoming in snapshot.alarms where incoming.kind.isHelperOwned {
            if acknowledgedEpisodes[incoming.kind] == incoming.episode { continue }
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
        return true
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

    /// Hears a message from helper `raw`. The current helper: true. A strictly NEWER one becomes
    /// current and turns every helper-owned alarm of the previous one stale: true. An older helper
    /// (a late message) or an unparsable id: false, the message is ignored.
    private mutating func adoptHelper(_ raw: String) -> Bool {
        guard let id = HelperSessionId(raw) else {
            Logger.audio.warning("Capture status from an unparsable helper id — ignored")
            return false
        }
        guard let current = helperSessionId else {
            helperSessionId = id
            return true
        }
        if id == current { return true }
        guard id > current else { return false }
        for kind in alarms.keys where kind.isHelperOwned { staleKinds.insert(kind) }
        helperSessionId = id
        lastAppliedSequence = nil
        acknowledgedEpisodes = [:]
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
    /// A `HelperSessionId` string.
    public let helperSessionId: String
    /// Increments on every snapshot the helper builds (pull reply or push), so the app can drop one
    /// that arrives after a newer one from the same helper.
    public let sequence: UInt64
    public let isCapturing: Bool
    public let alarms: [ActiveAlarm]
    public let tracks: [TrackHealthSnapshot]
    /// A status PULL's cumulative per-track coverage for this helper session (`remote_*` / `local_*` and
    /// `helper_session` detail keys, as in `captureStop`): the app keeps the latest, so a helper crash
    /// cannot erase it (L11, council A-I4). nil in a push, when not capturing, or from an older helper.
    public let coverage: [String: String]?
    /// Decode side only: alarm kinds this build does not know (a newer helper), skipped from `alarms`.
    /// Never encoded.
    public private(set) var unknownAlarmKinds: [String] = []

    public init(helperSessionId: String, sequence: UInt64, isCapturing: Bool, alarms: [ActiveAlarm], tracks: [TrackHealthSnapshot],
                coverage: [String: String]? = nil) {
        self.helperSessionId = helperSessionId; self.sequence = sequence
        self.isCapturing = isCapturing; self.alarms = alarms; self.tracks = tracks
        self.coverage = coverage
    }

    // `unknownAlarmKinds` is deliberately absent: it describes the decoding build, not the wire.
    private enum CodingKeys: String, CodingKey { case helperSessionId, sequence, isCapturing, alarms, tracks, coverage }

    /// Tolerant of exactly one thing: an alarm whose KIND this build does not know is skipped and
    /// recorded in `unknownAlarmKinds`. Any other defect fails the whole snapshot — a silently
    /// dropped alarm would read as an all-clear on the next `apply` and clear a live alarm.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        helperSessionId = try c.decode(String.self, forKey: .helperSessionId)
        sequence = try c.decode(UInt64.self, forKey: .sequence)
        isCapturing = try c.decode(Bool.self, forKey: .isCapturing)
        tracks = try c.decodeIfPresent([TrackHealthSnapshot].self, forKey: .tracks) ?? []
        coverage = try c.decodeIfPresent([String: String].self, forKey: .coverage)
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

/// What the open permission repair window lists, for the source it verified (L round 7).
public struct RepairWindowListing: Equatable, Sendable {
    public let listed: [CapturePermission]
    public let source: SystemAudioSource
    public init(listed: [CapturePermission], source: SystemAudioSource) { self.listed = listed; self.source = source }

    /// Whether it covers the remote-permission alarms (`hasOwnRepairWindow` kinds).
    public var coversRemoteAlarms: Bool { CaptureReadiness.repairWindowCovers(listed: listed, source: source) }
}

public enum AlarmRealarmPolicy {
    public static let notifyInterval: TimeInterval = 120

    /// A past event (acknowledgeable) is presented ONCE: its sticky row stays until acknowledged, but it
    /// never re-notifies (L round 4). A live condition re-notifies every `notifyInterval`.
    public static func shouldRenotify(_ alarm: ActiveAlarm, now: Date) -> Bool {
        guard let last = alarm.lastNotifiedAt else { return true }
        if alarm.kind.isAcknowledgeable { return false }
        return now.timeIntervalSince(last) >= notifyInterval
    }

    public static func shouldReopenWindow(lastDismissedAt: Date?, now: Date) -> Bool {
        CaptureReadiness.shouldPresentRepair(lastDismissedAt: lastDismissedAt, now: now)
    }

    /// The repair window's own notification is a duplicate when the alarm's notification for the same
    /// permission problem went out in the last 30 s — e.g. the 3 s fallback, then the window opening
    /// once a macOS prompt is answered (L round 6): one notification per alarm.
    public static let repairNotificationDedupWindow: TimeInterval = 30

    public static func repairNotificationDuplicates(lastAlarmNotificationAt: Date?, now: Date) -> Bool {
        guard let lastAlarmNotificationAt else { return false }
        return now.timeIntervalSince(lastAlarmNotificationAt) < repairNotificationDedupWindow
    }

    /// While NOT recording (owner ruling, L2/L4 fix round 2): the gap before the next re-notify of an
    /// idle alarm after `n` notifications — 2 min, then 10 min, then at most hourly. Mid-call alarms keep
    /// the 2-minute `notifyInterval`; an idle "crash protection off" every 2 min all day is noise.
    public static func idleRenotifyInterval(afterNotifications n: Int) -> TimeInterval {
        switch n {
        case ...1: return notifyInterval
        case 2: return 600
        default: return 3600
        }
    }

    /// `notificationsWhileIdle`: how often this kind has been presented since the app went idle. A past
    /// event (acknowledgeable) is presented once; the sticky row stays until it is acknowledged.
    public static func shouldRenotifyWhileIdle(_ alarm: ActiveAlarm, notificationsWhileIdle n: Int, now: Date) -> Bool {
        guard let last = alarm.lastNotifiedAt else { return true }
        if alarm.kind.isAcknowledgeable { return false }
        return now.timeIntervalSince(last) >= idleRenotifyInterval(afterNotifications: n)
    }

    /// What one presentation does (§6.3). `notify`: the due alarm the notification names (a newly
    /// raised one first), nil = post nothing. `openWindow`: at once for a new row, else only once the
    /// "Later" snooze has passed.
    public struct Presentation: Equatable, Sendable {
        public let notify: ActiveAlarm?
        public let openWindow: Bool
        public init(notify: ActiveAlarm?, openWindow: Bool) { self.notify = notify; self.openWindow = openWindow }
    }

    /// `due`: the alarms whose notify floor allows a presentation now. Rows the open repair window
    /// COVERS are left to it — including the notification, which it posts itself. A NEW permission kind
    /// reaches here only when the repair window declined to open (the coordinator hands it over first,
    /// L round 4): it is then presented like any other. `repairWindow`: what it lists, nil when closed.
    public static func presentation(due: [ActiveAlarm], newlyRaised: [AlarmKind], repairWindow: RepairWindowListing?,
                                    lastDismissedAt: Date?, now: Date) -> Presentation {
        let rows = windowRows(due, repairWindow: repairWindow)
        guard !rows.isEmpty else { return Presentation(notify: nil, openWindow: false) }
        let newRow = rows.first { newlyRaised.contains($0.kind) }
        return Presentation(notify: newRow ?? rows[0],
                            openWindow: newRow != nil || shouldReopenWindow(lastDismissedAt: lastDismissedAt, now: now))
    }

    /// The rows the alarm window lists: every alarm, minus the permission ones the repair window COVERS
    /// — only when it lists the remote permission they are about. A repair window open for another
    /// permission (the microphone) says nothing about the other side, so it filters nothing (L round 7).
    public static func windowRows(_ alarms: [ActiveAlarm], repairWindow: RepairWindowListing?) -> [ActiveAlarm] {
        guard let repairWindow, repairWindow.coversRemoteAlarms else { return alarms }
        return alarms.filter { !$0.kind.hasOwnRepairWindow }
    }
}
