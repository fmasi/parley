import Foundation

/// Decides which device may CLOCK the system-audio capture aggregate.
///
/// The tap is a global process tap — it captures system-wide content regardless of route. But the
/// aggregate is clocked by its main sub-device, and that device's cadence decides how many frames
/// per second actually reach the IOProc. Clock off a device that runs slower than the format we
/// declared and the writer pads silence to hold the wall clock: 2x-fast speech with gaps, correct
/// duration, corrupt content.
///
/// The subtle part, and the whole reason this is a separate type: a Bluetooth device's rate at build
/// time predicts nothing about its rate a second later. Recording a call means we open the mic, and
/// opening the mic on an AirPod is exactly what makes macOS flip it A2DP → HFP (48 kHz → 24 kHz).
/// That transition is not a device change, so no HAL listener fires and nothing rebuilds. Reading
/// the rate and trusting it — which is what shipped — loses that race whenever the headset connects
/// just before the mic opens.
///
/// So the rule is transport-based, not rate-based: never clock off Bluetooth. The user keeps
/// listening on their headset either way; we simply stop letting its profile dictate what we record.
public enum ClockAnchorPolicy {

    public enum Reason: String, Equatable, Sendable {
        /// The output is already running at a hands-free rate.
        case degradedRate
        /// The output is Bluetooth: healthy *now*, but free to drop to HFP with no notification.
        case bluetoothVolatileRate
        /// The watchdog measured a real frame shortfall — the device is not delivering what it claims.
        case driftRemediation
    }

    public enum Decision: Equatable, Sendable {
        /// The default output is a safe clock; use it (keeps the aggregate on the device the user hears).
        case keepOutput
        /// Clock off a full-rate device instead.
        case reanchor(Reason)
    }

    /// Rates that only ever appear because a Bluetooth link dropped to a hands-free profile
    /// (A2DP -> HFP). 44.1 kHz is a perfectly healthy rate and must NOT appear here: substituting
    /// the clock for a device that is fine is a risk with no upside.
    public static let handsFreeRates: Set<Int> = [8000, 16000, 24000, 32000]

    /// A rebuild resets the drift monitor, so a device that keeps drifting would rebuild forever,
    /// tearing a dead window in the recording each time. Two attempts, then live with it and let the
    /// anomaly stand in the diagnostics.
    public static let maxDriftRemediations = 2

    /// - Parameters:
    ///   - outputRate: nominal sample rate the default output device reports right now.
    ///   - isBluetooth: whether that device's transport is Bluetooth (classic or LE).
    ///   - forcedByDrift: the watchdog has measured a sustained frame shortfall this session.
    public static func decide(outputRate: Int, isBluetooth: Bool, forcedByDrift: Bool) -> Decision {
        // Measured beats claimed: if frames are genuinely short, nothing the device reports about
        // itself is worth consulting.
        if forcedByDrift { return .reanchor(.driftRemediation) }
        // Degraded-rate first — it is the more specific and more actionable diagnosis when both hold.
        if handsFreeRates.contains(outputRate) { return .reanchor(.degradedRate) }
        if isBluetooth { return .reanchor(.bluetoothVolatileRate) }
        return .keepOutput
    }

    public static func shouldRemediate(attemptsSoFar: Int) -> Bool {
        attemptsSoFar < maxDriftRemediations
    }
}
