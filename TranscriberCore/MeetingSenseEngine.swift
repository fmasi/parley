import Foundation

/// How the app reacts when it senses a meeting starting (a meeting app grabs the microphone).
/// Airgap-safe: the trigger is a local Core Audio HAL property, never the network or a calendar.
///
/// There is deliberately NO auto-record mode: meeting sensing only ever *prompts*, so the app never
/// records without an explicit user action (consent / courtroom-grade, locked in #118).
public enum MeetingSenseMode: String, Codable, Equatable, Sendable {
    case off
    case prompt
}

/// `AppState.Phase` without payloads — all the engine needs.
public enum MeetingSensePhase: Equatable, Sendable {
    case idle, recording, transcribing
}

/// What the sensor saw: the raw bundle IDs of every process currently running input IO.
public struct CaptureSnapshot: Equatable, Sendable {
    public var capturingBundleIDs: Set<String>
    public init(capturingBundleIDs: Set<String>) { self.capturingBundleIDs = capturingBundleIDs }
}

public enum MeetingSenseInput: Equatable, Sendable {
    case snapshot(CaptureSnapshot)
    case phaseChanged(MeetingSensePhase)
    /// The user answered "Not now" to the pending start offer.
    case notNow
    /// The user answered "Keep recording" to the stop offer.
    case keepRecording
}

public enum MeetingSenseAction: Equatable, Sendable {
    /// Show the start offer. `expand` = the attention-grabbing state; false = arrive compact.
    case offerStart(MeetingApp, expand: Bool)
    case withdrawStart
    case offerStop(MeetingApp)
    case withdrawStop
    /// The raw bundle IDs the sensor should hold per-process `IsRunningInput` listeners on. Empty = none.
    case watch(bundleIDs: Set<String>)
    /// Run an ordinary scan after this many seconds (one-shot; replaces any pending request).
    case scheduleScan(after: TimeInterval)
}

public struct MeetingSenseState: Equatable, Sendable {
    public var phase: MeetingSensePhase = .idle
    /// Meeting apps capturing at the last snapshot, with the time each was first seen capturing.
    /// Starts empty on purpose: apps already capturing at the first snapshot count as transitions
    /// (launching Parley mid-call, or turning the setting on mid-call, prompts — goal 1).
    public var capturing: [MeetingApp: Date] = [:]
    /// The raw bundle IDs of the last snapshot (so the watch list can name helpers, not families).
    public var lastSnapshot: Set<String> = []
    /// At most one start offer at a time.
    public var pendingStart: MeetingApp? = nil
    /// "Not now" / "Keep recording": quiet for this app until it releases the mic. The single
    /// suppression mechanism.
    public var suppressed: Set<MeetingApp> = []
    /// When each app last got the expanded island — the expansion-only cooldown.
    public var lastExpanded: [MeetingApp: Date] = [:]
    /// While recording: meeting apps seen capturing during this recording, and their raw bundle IDs.
    public var watched: Set<MeetingApp> = []
    public var watchedBundleIDs: Set<String> = []
    /// While recording: when every watched app was last seen released; nil while any is capturing.
    public var releasedAt: Date? = nil
    /// The stop offer for the current release span was emitted (exactly once per span).
    public var stopOffered = false

    public init() {}
}

/// Pure decision logic. No Core Audio, no AppKit, no clock of its own — `step` is a function of
/// (state, input, mode, now), which is what makes every rule unit-testable.
public enum MeetingSenseEngine {
    /// Minimum gap between two *expanded* start offers for the same app. A call that drops and
    /// reconnects keeps its persistent surface (compact island, banner, icon) but must not re-interrupt.
    public static let expansionCooldown: TimeInterval = 300
    /// How long every watched app must stay released before we offer to stop. Mute/unmute and device
    /// switches re-acquire within this window and cancel it.
    public static let stopDebounce: TimeInterval = 30

    public static func step(
        _ state: MeetingSenseState,
        input: MeetingSenseInput,
        mode: MeetingSenseMode,
        now: Date
    ) -> (state: MeetingSenseState, actions: [MeetingSenseAction]) {
        var s = state
        var out: [MeetingSenseAction] = []

        switch input {
        case .phaseChanged(let phase):
            let was = s.phase
            s.phase = phase
            if phase == .recording, was != .recording {
                // Manual Record, prompt Record, or crash re-attach: the offer is moot, and every meeting
                // app capturing right now is part of this recording.
                withdrawStart(&s, &out)
                s.watched = Set(s.capturing.keys)
                s.watchedBundleIDs = rawIDs(in: s.lastSnapshot, of: s.watched)
                s.releasedAt = nil
                s.stopOffered = false
                out.append(.watch(bundleIDs: s.watchedBundleIDs))
            } else if was == .recording, phase != .recording {
                // "Keep recording" was an answer about THIS recording; it must not silence the start
                // offer for the next meeting. Scoped to `watched` so a `.notNow` suppression the user
                // gave about a start offer survives.
                s.suppressed.subtract(s.watched)
                s.watched = []
                s.watchedBundleIDs = []
                s.releasedAt = nil
                withdrawStop(&s, &out)
                out.append(.watch(bundleIDs: []))
            }
        case .notNow:
            if let app = s.pendingStart { s.suppressed.insert(app) }
            withdrawStart(&s, &out)
        case .keepRecording:
            if s.stopOffered { s.suppressed.formUnion(s.watched) }
            withdrawStop(&s, &out)
        case .snapshot(let snapshot):
            applySnapshot(snapshot, &s, &out, mode: mode, now: now)
        }

        if mode == .off {
            withdrawStart(&s, &out)
            withdrawStop(&s, &out)
        }
        return (s, out)
    }

    // MARK: - Snapshot rules

    private static func applySnapshot(
        _ snapshot: CaptureSnapshot,
        _ s: inout MeetingSenseState,
        _ out: inout [MeetingSenseAction],
        mode: MeetingSenseMode,
        now: Date
    ) {
        var nowCapturing: [MeetingApp: Date] = [:]
        for id in snapshot.capturingBundleIDs {
            guard let app = MeetingApps.classify(bundleID: id) else { continue }
            nowCapturing[app] = s.capturing[app] ?? now
        }
        let started = Set(nowCapturing.keys).subtracting(s.capturing.keys)
        let released = Set(s.capturing.keys).subtracting(nowCapturing.keys)
        s.capturing = nowCapturing
        s.lastSnapshot = snapshot.capturingBundleIDs
        // An episode ends when the app lets go of the mic; the next acquisition is a new episode.
        s.suppressed.subtract(released)
        guard mode == .prompt else { return }

        if s.phase == .recording {
            s.watched.formUnion(started)
            guard !s.watched.isEmpty else { return }
            let ids = rawIDs(in: snapshot.capturingBundleIDs, of: s.watched)
            if !ids.isSubset(of: s.watchedBundleIDs) {
                s.watchedBundleIDs.formUnion(ids)
                out.append(.watch(bundleIDs: s.watchedBundleIDs))
            }
            if !s.watched.isDisjoint(with: nowCapturing.keys) {
                s.releasedAt = nil
                withdrawStop(&s, &out)
            } else if let releasedAt = s.releasedAt {
                let elapsed = now.timeIntervalSince(releasedAt)
                if elapsed >= stopDebounce {
                    let candidates = s.watched.subtracting(s.suppressed)
                    if !s.stopOffered, let app = first(of: candidates) {
                        s.stopOffered = true
                        out.append(.offerStop(app))
                    }
                } else {
                    out.append(.scheduleScan(after: stopDebounce - elapsed))
                }
            } else {
                s.releasedAt = now
                out.append(.scheduleScan(after: stopDebounce))
            }
            return
        }

        // Idle or transcribing: start offers.
        var justWithdrew = false
        if let pending = s.pendingStart, nowCapturing[pending] == nil {
            withdrawStart(&s, &out)
            justWithdrew = true
        }
        guard s.pendingStart == nil else { return }
        // Normally only transitions offer; after a withdrawal, any other app still capturing takes over
        // (Zoom dropped while Chrome holds the mic must not leave the user with no surface).
        let candidates = (justWithdrew ? Set(nowCapturing.keys) : started).subtracting(s.suppressed)
        guard let app = first(of: candidates) else { return }
        let expand = s.lastExpanded[app].map { now.timeIntervalSince($0) >= expansionCooldown } ?? true
        if expand { s.lastExpanded[app] = now }
        s.pendingStart = app
        out.append(.offerStart(app, expand: expand))
    }

    // MARK: - Helpers

    private static func withdrawStart(_ s: inout MeetingSenseState, _ out: inout [MeetingSenseAction]) {
        guard s.pendingStart != nil else { return }
        s.pendingStart = nil
        out.append(.withdrawStart)
    }

    private static func withdrawStop(_ s: inout MeetingSenseState, _ out: inout [MeetingSenseAction]) {
        guard s.stopOffered else { return }
        s.stopOffered = false
        out.append(.withdrawStop)
    }

    /// The raw bundle IDs in `ids` that classify into one of `apps`.
    private static func rawIDs(in ids: Set<String>, of apps: Set<MeetingApp>) -> Set<String> {
        Set(ids.filter { id in MeetingApps.classify(bundleID: id).map(apps.contains) ?? false })
    }

    /// Deterministic pick when several apps qualify: alphabetical by display name.
    private static func first(of apps: Set<MeetingApp>) -> MeetingApp? {
        apps.min { $0.displayName < $1.displayName }
    }
}
