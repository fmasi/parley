import Foundation

/// Decision core that keeps the Core Audio tap honest about its System Audio Recording permission
/// (#220). Pure and single-threaded: the helper confines it to its audio queue and feeds it events;
/// it answers with actions for the helper to carry out.
///
/// Why this is a state machine, not a one-shot check (code council, 2026-09-23): a tap started
/// WITHOUT the grant keeps delivering exact zeros even after the grant arrives. Only a rebuild
/// picks it up. So "the permission is fine now" is not the end of it. The tap has to be rebuilt,
/// and the alarm must keep telling the user while the problem lasts, not fire once and go quiet
/// the way the #217 liveness warning did.
///
/// What it guarantees:
/// - A tap built while the permission was not granted is rebuilt as soon as a check sees it granted.
/// - While a problem is suspected or reported (and ONLY then) the permission is re-checked every
///   `recheckInterval`; a still-denied permission is re-reported every `reReportInterval`.
/// - "Restored" is reported only when real (non-zero) audio arrives: the TCC answer can be stale,
///   the audio cannot.
/// - Evidence of silence with the permission granted gets at most ONE insurance rebuild per episode,
///   and an unverifiable permission (private SPI gone) is reported but never triggers a rebuild, so
///   neither can loop.
public struct TapPermissionGuard {

    /// Why a check was asked for.
    public enum Evidence: Equatable, Sendable {
        /// Routine: after a build, or a periodic re-check while a problem is outstanding.
        case none
        /// The tap has delivered only exact zeros for `ExactZeroRunMonitor`'s threshold.
        case exactZeroRun
        /// The tap stopped delivering buffers while output was playing (liveness gap).
        case deliveryGap
    }

    public enum Action: Equatable, Sendable {
        /// Ask TCC for the current status and feed it back via `permissionChecked`.
        case checkPermission(Evidence)
        /// Rebuild the tap's aggregate in place (same recording).
        case rebuildTap
        /// Tell the user the tap is not being allowed to capture. `nil` = can't verify.
        case reportDenied(PermissionStatus?)
        /// Real audio is arriving again after a reported problem.
        case reportRestored
    }

    public static let recheckInterval: Double = 5
    public static let reReportInterval: Double = 60
    /// Building the tap raises the system prompt when the permission was never asked; don't alarm
    /// over a question the user is answering right now.
    public static let promptGrace: Double = 20
    /// After a grant rebuild, a tap that delivers no buffers at all for this long while output is
    /// playing is evidence too (no samples means the exact-zero detector can't see it).
    public static let noBuffersAfterRebuild: Double = 15

    /// A denial has been reported and not yet cleared by a grant.
    public private(set) var problemReported = false
    /// The current tap was built while the permission was not granted: it needs a rebuild once it is.
    public private(set) var builtWithoutGrant = false
    /// Granted and rebuilt after a problem; still owed proof (real audio) that the rebuild worked.
    private var awaitingAudio = false
    /// An alarm was raised this episode, so the first real audio must say "restored" (and only then:
    /// a fast Allow that never alarmed must not announce a recovery nobody saw a problem for).
    private var alarmRaised = false
    /// The outstanding report came from an unverifiable check: polling can't improve on it.
    private var problemUnverifiable = false
    private var lastSampleAt: Double = -.infinity
    private var insuranceRebuildUsed = false
    private var checkInFlight = false
    private var builtAt: Double = 0
    private var lastCheckAt: Double = -.infinity
    private var lastReportAt: Double = -.infinity
    private var zeroMonitor: ExactZeroRunMonitor
    private let zeroThresholdSeconds: Double

    /// Measured, permission-independent facts for provenance: how much of what the tap delivered was
    /// exact digital zero.
    public private(set) var deliveredFrames: Int64 = 0
    public private(set) var exactZeroFrames: Int64 = 0

    public init(zeroThresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds) {
        self.zeroThresholdSeconds = zeroThresholdSeconds
        self.zeroMonitor = ExactZeroRunMonitor(thresholdSeconds: zeroThresholdSeconds)
    }

    /// A tap aggregate was built or rebuilt. `status` is the permission at build time (`nil` = unverifiable).
    public mutating func tapBuilt(status: PermissionStatus?, now: Double) -> [Action] {
        // `awaitingAudio` and `insuranceRebuildUsed` deliberately survive a rebuild: proof that the
        // fix worked is still owed after an unrelated output-device rebuild, and only REAL audio
        // (in `samples`) clears them. The trade-off: a tap that has delivered no real audio since an
        // earlier insurance rebuild can be reported as "can't confirm" after another rebuild. That
        // is intended. A false alarm beats "neither audio nor an alarm".
        builtAt = now
        zeroMonitor = ExactZeroRunMonitor(thresholdSeconds: zeroThresholdSeconds)
        // Unverifiable is not "without grant": polling a check that can't answer helps nobody.
        builtWithoutGrant = status == .denied || status == .notDetermined
        // No immediate report: the first `tick` checks within a second, by which time the recording
        // is up and the app is listening.
        return []
    }

    /// A batch of real (not padded) tap samples.
    public mutating func samples(_ samples: [Int16], rate: Double, now: Double) -> [Action] {
        guard !samples.isEmpty else { return [] }
        lastSampleAt = now
        deliveredFrames += Int64(samples.count)
        let allZero = samples.allSatisfy { $0 == 0 }
        var actions: [Action] = []
        if allZero {
            exactZeroFrames += Int64(samples.count)
        } else {
            // Real audio: whatever the TCC cache says, the tap is being fed.
            builtWithoutGrant = false
            insuranceRebuildUsed = false
            problemReported = false
            problemUnverifiable = false
            awaitingAudio = false
            if alarmRaised {
                alarmRaised = false
                actions.append(.reportRestored)
            }
        }
        if case .silentRun = zeroMonitor.record(samples: samples, rate: rate) {
            actions += requestCheck(.exactZeroRun, now: now)
        }
        return actions
    }

    /// The liveness watchdog saw the tap stop delivering while output was playing.
    public mutating func deliveryGap(now: Double) -> [Action] {
        requestCheck(.deliveryGap, now: now)
    }

    /// Called about once a second while the tap is capturing. Only does anything while a problem
    /// is suspected or reported. `outputRunning` (is anything playing?) is only consulted while a grant
    /// rebuild still owes proof, and callers may pass nil otherwise.
    public mutating func tick(now: Double, outputRunning: Bool? = nil) -> [Action] {
        if awaitingAudio, outputRunning == true,
           now - max(lastSampleAt, builtAt) >= Self.noBuffersAfterRebuild,
           now - lastCheckAt >= Self.noBuffersAfterRebuild {
            return requestCheck(.deliveryGap, now: now)
        }
        guard builtWithoutGrant || (problemReported && !problemUnverifiable) else { return [] }
        guard now - lastCheckAt >= Self.recheckInterval else { return [] }
        return requestCheck(.none, now: now)
    }

    /// Whether `tick` wants to know if output is playing (a HAL read the caller can skip otherwise).
    public var wantsOutputState: Bool { awaitingAudio }

    private mutating func requestCheck(_ evidence: Evidence, now: Double) -> [Action] {
        guard !checkInFlight else { return [] }
        checkInFlight = true
        lastCheckAt = now
        return [.checkPermission(evidence)]
    }

    /// The result of a `.checkPermission` (or of an out-of-band check, e.g. the app asking the helper
    /// to restart after the user fixed the permission).
    public mutating func permissionChecked(_ status: PermissionStatus?, evidence: Evidence, now: Double) -> [Action] {
        checkInFlight = false
        switch status {
        case .authorized?:
            if builtWithoutGrant || (problemReported && !problemUnverifiable) {
                // The grant only reaches a tap built after it.
                builtWithoutGrant = false
                problemReported = false
                awaitingAudio = true
                return [.rebuildTap]
            }
            guard evidence != .none else { return [] }
            if !insuranceRebuildUsed {
                // Granted, yet silent: most likely a genuinely silent call, but TCC's answer can be
                // stale, and a rebuild during silence costs nothing. Once per episode, so it can't loop.
                insuranceRebuildUsed = true
                return [.rebuildTap]
            }
            if awaitingAudio {
                // A grant rebuild and an insurance rebuild later, still nothing real. It may be a
                // silent call, but "audio or an alarm, never neither": say we can't confirm it.
                return report(nil, now: now)
            }
            return []
        case .denied?:
            return report(.denied, now: now)
        case .notDetermined?:
            if !problemReported, evidence == .none, now - builtAt < Self.promptGrace { return [] }
            return report(.notDetermined, now: now)
        case nil:
            // Can't verify: only evidence justifies speaking up, and never a rebuild.
            guard evidence != .none else { return [] }
            return report(nil, now: now)
        }
    }

    private mutating func report(_ status: PermissionStatus?, now: Double) -> [Action] {
        guard !problemReported || now - lastReportAt >= Self.reReportInterval else { return [] }
        problemReported = true
        problemUnverifiable = status == nil
        alarmRaised = true
        lastReportAt = now
        return [.reportDenied(status)]
    }
}
