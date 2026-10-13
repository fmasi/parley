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
///
/// Judging silence by evidence (#333). coreaudiod decides a tap's access when its IO context
/// starts (gotcha #70): a tap started without the grant delivers exact zeros until it is rebuilt.
/// So a tap that has delivered non-zero audio WAS granted access, and later zeros on it are silence.
/// A call app renders exact zeros whenever the other side is quiet: 571 s of a 66-minute call on
/// 2026-10-13, of which nothing was lost. While the grant is proven (`grantProven`):
/// - a zero run still gets its permission check, the only mid-call revocation detector, but no
///   insurance rebuild. A rebuild recreates the process tap, which can drop Bluetooth output for a
///   second or two (2026-10-09), and it ran every time the remote went quiet for 12 s;
/// - the soft "can't confirm" alarm stays quiet;
/// - its zeros are not counted as `unprovenZeroFrames`, so the record can tell a quiet remote from
///   zeros nobody can vouch for (a run during which the proof is withdrawn goes with it, whole).
/// Zeros from the first frame (#220's shape) keep every path they had. So does a session whose
/// remote has not spoken yet: by content it is the same thing.
public struct TapPermissionGuard {

    /// Why a check was asked for.
    public enum Evidence: Equatable, Sendable {
        /// Routine: after a build, or a periodic re-check while a problem is outstanding.
        case none
        /// The tap has delivered only exact zeros for `ExactZeroRunMonitor`'s threshold.
        case exactZeroRun
    }

    /// Why the guard wants the tap rebuilt; the helper's healing ladder runs it as a
    /// `.permissionGrant` or `.permissionInsurance` trigger (§5).
    public enum RebuildReason: Equatable, Sendable {
        /// The permission is granted now and the tap was built (or reported) without it.
        case grant
        /// Granted, yet silent: the once-per-episode rebuild in case TCC's answer was stale.
        case insurance
    }

    public enum Action: Equatable, Sendable {
        /// Ask TCC for the current status and feed it back via `permissionChecked`.
        case checkPermission(Evidence)
        /// Rebuild the tap's aggregate in place (same recording).
        case rebuildTap(reason: RebuildReason)
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
    private var insuranceRebuildUsed = false
    private var checkInFlight = false
    private var builtAt: Double = 0
    private var lastCheckAt: Double = -.infinity
    private var lastReportAt: Double = -.infinity
    private var zeroMonitor: ExactZeroRunMonitor
    private let zeroThresholdSeconds: Double
    /// Seconds of exact zeros (with nothing real in between) after which the guard says "can't
    /// confirm" on its own. `nil` = off, the shipped default until the M-A census (§9).
    private let softAlarmSeconds: Double?
    /// When the current run of exact zeros began; `nil` = the last batch was real audio (or none yet).
    /// Survives rebuilds: the window is "since real audio", however many aggregates that spans.
    private var zeroRunStartedAt: Double?

    /// The current tap has delivered non-zero audio, so it was granted access (#333): zeros
    /// on it are silence. Withdrawn by any permission answer but `authorized`, and by a (re)build
    /// whose status is not `authorized`. That includes `nil`: a new tap nobody could verify is not
    /// vouched for by the audio of the one it replaced. A rebuild with a fresh `authorized` answer
    /// keeps it. Accepted risk: that answer being stale while coreaudiod refuses the new tap, after
    /// real audio earlier, would read as proven silence; never observed, and before this the guard
    /// also went quiet there, after one insurance rebuild.
    ///
    /// Known ordering race, harmless as it stands: `tapBuilt` reaches the audio queue after a TCC
    /// read, so the new tap's first samples can get there before it. A late non-authorized
    /// `tapBuilt` then clears a proof the new tap has just earned. It heals on the next non-zero
    /// batch, and `builtWithoutGrant` is stale in the same way. Changing the order of the two is a
    /// change to both.
    public private(set) var grantProven = false

    /// Measured, permission-independent facts for provenance: how much of what the tap delivered was
    /// exact digital zero.
    public private(set) var deliveredFrames: Int64 = 0
    public private(set) var exactZeroFrames: Int64 = 0
    /// The part of `exactZeroFrames` nobody can vouch for: the zeros before the session's first real
    /// audio, and every zero run during which the proof was withdrawn (a denial, an unconfirmed
    /// rebuild), from the run's first frame until real audio returns. The rest is silence that
    /// began and ended, or is still going on, with the grant proven.
    public private(set) var unprovenZeroFrames: Int64 = 0
    /// Zeros of the CURRENT run counted as proven so far. The proof is withdrawn only when the answer
    /// arrives, 12 s or more into the run that made the guard ask: those zeros are what the answer
    /// is about, so `withdrawProof` moves them to `unprovenZeroFrames`. Real audio ends the run and
    /// settles them as silence. Like `zeroRunStartedAt`, it runs on across a confirmed rebuild.
    private var provenRunZeroFrames: Int64 = 0

    public init(zeroThresholdSeconds: Double = ExactZeroRunMonitor.defaultThresholdSeconds, softAlarmSeconds: Double? = nil) {
        self.zeroThresholdSeconds = zeroThresholdSeconds
        self.zeroMonitor = ExactZeroRunMonitor(thresholdSeconds: zeroThresholdSeconds)
        self.softAlarmSeconds = softAlarmSeconds
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
        // It is not a proven grant either: only a confirmed one carries the proof to the new tap.
        if status != .authorized { withdrawProof() }
        // No immediate report: the first `tick` checks within a second, by which time the recording
        // is up and the app is listening.
        return []
    }

    /// A batch of real (not padded) tap samples.
    public mutating func samples(_ samples: [Int16], rate: Double, now: Double) -> [Action] {
        guard !samples.isEmpty else { return [] }
        deliveredFrames += Int64(samples.count)
        let allZero = samples.allSatisfy { $0 == 0 }
        var actions: [Action] = []
        if allZero {
            exactZeroFrames += Int64(samples.count)
            if grantProven { provenRunZeroFrames += Int64(samples.count) } else { unprovenZeroFrames += Int64(samples.count) }
            if zeroRunStartedAt == nil { zeroRunStartedAt = now }
        } else {
            // Real audio: whatever the TCC cache says, the tap is being fed.
            grantProven = true
            provenRunZeroFrames = 0
            zeroRunStartedAt = nil
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

    /// Called about once a second while the tap is capturing. Only does anything while a problem
    /// is suspected or reported, or (when enabled) once the soft "can't confirm" window has elapsed
    /// on a tap whose grant is not proven: a long silence after real audio is a quiet remote.
    /// Delivery gaps are not the guard's business: the liveness monitor and the healing ladder own them.
    public mutating func tick(now: Double) -> [Action] {
        if let soft = softAlarmSeconds, let since = zeroRunStartedAt, now - since >= soft, !problemReported, !grantProven {
            return report(nil, now: now)
        }
        guard builtWithoutGrant || (problemReported && !problemUnverifiable) else { return [] }
        guard now - lastCheckAt >= Self.recheckInterval else { return [] }
        return requestCheck(.none, now: now)
    }

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
        // Before anything else: after any answer but `authorized`, zeros are unproven again.
        if status != .authorized { withdrawProof() }
        switch status {
        case .authorized?:
            if builtWithoutGrant || (problemReported && !problemUnverifiable) {
                // The grant only reaches a tap built after it.
                builtWithoutGrant = false
                problemReported = false
                awaitingAudio = true
                return [.rebuildTap(reason: .grant)]
            }
            guard evidence != .none else { return [] }
            // This tap has delivered real audio and the permission is still granted: a silent
            // stretch, nothing to repair (#333). `awaitingAudio` is never set here, since
            // the real audio that proved the grant cleared it.
            if grantProven { return [] }
            if !insuranceRebuildUsed {
                // Granted, yet silent, and nothing real from this tap to prove the grant: most likely a
                // remote that has not spoken yet, but TCC's answer can be stale (#220), and by content
                // the two are the same. Once per episode, so it can't loop.
                insuranceRebuildUsed = true
                return [.rebuildTap(reason: .insurance)]
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

    /// The grant is no longer proven, and neither was the silence this tap is in the middle of.
    private mutating func withdrawProof() {
        grantProven = false
        unprovenZeroFrames += provenRunZeroFrames
        provenRunZeroFrames = 0
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
