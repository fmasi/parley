import Foundation

/// Pure microphone device-targeting decision, factored out of `MicCaptureSession` so the
/// auto-follow / fallback / re-pin rule is unit-testable without real audio hardware.
///
/// The rule is a single invariant: **be on the user's pinned device if it is available; otherwise follow
/// the system default input.** That one rule covers, uniformly:
/// - **auto-follow** (no pin / "System Default"): the default flips (AirPods in/out) → target the new default;
/// - **pinned fallback**: the pinned device vanishes → target the default;
/// - **pinned re-pin**: the pinned device reappears while on a fallback → target the pin again.
///
/// One exception (#315): an input in `unusable` — a built-in mic while the lid is closed, which macOS keeps
/// as the default input and which delivers exact zeros — is not followed to when the user has another input
/// to hand: the target is then the most recent input the user chose by hand (`userChoices`) that is present
/// and usable. Only inputs the user chose: picking among inputs they never selected is a product decision
/// (v0.10, NEW D). With none, the target is the default anyway and `raiseSilenceAlarmNow` is set, so the
/// user is told at once rather than 12 s later by the exact-zero detector. With `unusable` empty (lid open)
/// the rule is exactly the one above.
public enum MicTargeting {
    public struct Decision: Equatable {
        /// The device we should capture on. `nil` = the system default.
        public let target: String?
        /// True when `target` is the system default rather than the pinned device (maps to the recovery
        /// path's `forceDefault`).
        public let forceDefault: Bool
        /// True when `target` differs from the device we are currently on — i.e. a rebuild is needed.
        public let needsSwitch: Bool
        /// True when the device we are LEAVING is no longer available — a genuine input loss worth
        /// flagging as an anomaly, vs an intentional follow while the old device still exists.
        public let leavingDeviceGone: Bool
        /// True when `target` is itself unusable (the lid-closed built-in mic, nothing else to hand): the
        /// silence alarm should be raised as soon as the follow lands, not when the exact-zero run is seen.
        public let raiseSilenceAlarmNow: Bool

        public init(target: String?, forceDefault: Bool, needsSwitch: Bool, leavingDeviceGone: Bool,
                    raiseSilenceAlarmNow: Bool = false) {
            self.target = target
            self.forceDefault = forceDefault
            self.needsSwitch = needsSwitch
            self.leavingDeviceGone = leavingDeviceGone
            self.raiseSilenceAlarmNow = raiseSilenceAlarmNow
        }
    }

    /// How many hand-chosen inputs are remembered (newest first).
    public static let userChoiceLimit = 3

    /// `recent` with `choice` moved to the front, deduplicated and capped at `userChoiceLimit`. `nil` (the
    /// user chose "System Default") is not an input and changes nothing.
    public static func rememberingUserChoice(_ choice: String?, in recent: [String]) -> [String] {
        guard let choice else { return recent }
        return Array(([choice] + recent.filter { $0 != choice }).prefix(userChoiceLimit))
    }

    /// The inputs the follow must not land on while another is to hand: the built-in ones (among the
    /// available inputs and the system default) while the lid is closed. `isBuiltIn` is a HAL read: asked
    /// only when the lid is closed, and never on the audio queue.
    public static func unusableInputs(lidClosed: Bool, available: Set<String>, systemDefault: String?,
                                      isBuiltIn: (String) -> Bool) -> Set<String> {
        guard lidClosed else { return [] }
        return available.union(systemDefault.map { [$0] } ?? []).filter(isBuiltIn)
    }

    /// Whether landing on `device` should raise the silence alarm at once: it is unusable (the lid-closed
    /// built-in mic) and the user did not pin it — a pinned built-in mic is the user's explicit choice, and
    /// the start's pre-flight already warned about it.
    public static func raisesSilenceAlarm(landedOn device: String?, pinned: String?, unusable: Set<String>) -> Bool {
        guard let device else { return false }
        return unusable.contains(device) && device != pinned
    }

    /// The pin if present; else the system default, unless it is unusable and an input the user chose by
    /// hand is present and usable. `onDefault` = the target is the system default.
    private static func preferred(
        pinned: String?, available: Set<String>, systemDefault: String?,
        unusable: Set<String>, userChoices: [String]
    ) -> (target: String?, onPin: Bool, onDefault: Bool) {
        if let pinned, available.contains(pinned) { return (pinned, true, false) }
        if let systemDefault, unusable.contains(systemDefault),
           let choice = userChoices.first(where: { available.contains($0) && !unusable.contains($0) }) {
            return (choice, false, false)
        }
        return (systemDefault, false, true)
    }

    /// - Parameters:
    ///   - pinned: the user's chosen device id (`nil` = "System Default").
    ///   - current: the concrete device id we are currently capturing on (`nil` = none yet).
    ///   - available: the set of currently-available input device ids.
    ///   - systemDefault: the current system default input device id (`nil` = none available).
    ///   - unusable: inputs not to follow to while another is to hand (see `unusableInputs`).
    ///   - userChoices: the inputs the user chose by hand, newest first.
    public static func decide(
        pinned: String?, current: String?, available: Set<String>, systemDefault: String?,
        unusable: Set<String> = [], userChoices: [String] = []
    ) -> Decision {
        let p = preferred(pinned: pinned, available: available, systemDefault: systemDefault,
                          unusable: unusable, userChoices: userChoices)
        let leavingGone = current.map { !available.contains($0) } ?? true
        return Decision(
            target: p.target,
            forceDefault: p.onDefault,
            needsSwitch: p.target != current,
            leavingDeviceGone: leavingGone,
            raiseSilenceAlarmNow: raisesSilenceAlarm(landedOn: p.target, pinned: pinned, unusable: unusable)
        )
    }

    /// The device id to (re)build on during recovery: the pinned device when it is available, else `nil`
    /// — where `nil` means "the system default", preserving the `nil == default` provenance convention
    /// that `mic_device` relies on. Recomputed from FRESH state on every recovery iteration so a pin the
    /// user applies mid-recovery (or a device that comes/goes during the loop) is honored, never frozen
    /// into a stale decision (council MIC-FOLLOW-PIN-OVERRIDE / mic-switch-clobbered-by-autofollow).
    /// While the system default is unusable (#315), an input the user chose by hand is targeted instead,
    /// by id; if there is none, `nil` (the default) as before.
    public static func recoveryTarget(
        pinned: String?, available: Set<String>, systemDefault: String? = nil,
        unusable: Set<String> = [], userChoices: [String] = []
    ) -> String? {
        let p = preferred(pinned: pinned, available: available, systemDefault: systemDefault,
                          unusable: unusable, userChoices: userChoices)
        return p.onDefault ? nil : p.target
    }
}
