import Foundation

/// Pure microphone device-targeting decision, factored out of `MicCaptureSession` so the
/// auto-follow / fallback / re-pin rule is unit-testable without real audio hardware.
///
/// The rule is a single invariant: **be on the user's pinned device if it is available; otherwise follow
/// the system default input.** That one rule covers, uniformly:
/// - **auto-follow** (no pin / "System Default"): the default flips (AirPods in/out) → target the new default;
/// - **pinned fallback**: the pinned device vanishes → target the default;
/// - **pinned re-pin**: the pinned device reappears while on a fallback → target the pin again.
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

        public init(target: String?, forceDefault: Bool, needsSwitch: Bool, leavingDeviceGone: Bool) {
            self.target = target
            self.forceDefault = forceDefault
            self.needsSwitch = needsSwitch
            self.leavingDeviceGone = leavingDeviceGone
        }
    }

    /// - Parameters:
    ///   - pinned: the user's chosen device id (`nil` = "System Default").
    ///   - current: the concrete device id we are currently capturing on (`nil` = none yet).
    ///   - available: the set of currently-available input device ids.
    ///   - systemDefault: the current system default input device id (`nil` = none available).
    public static func decide(
        pinned: String?, current: String?, available: Set<String>, systemDefault: String?
    ) -> Decision {
        let onPin = pinned.map { available.contains($0) } ?? false
        let target = onPin ? pinned : systemDefault
        let leavingGone = current.map { !available.contains($0) } ?? true
        return Decision(
            target: target,
            forceDefault: !onPin,
            needsSwitch: target != current,
            leavingDeviceGone: leavingGone
        )
    }

    /// The device id to (re)build on during recovery: the pinned device when it is available, else `nil`
    /// — where `nil` means "the system default", preserving the `nil == default` provenance convention
    /// that `mic_device` relies on. Recomputed from FRESH state on every recovery iteration so a pin the
    /// user applies mid-recovery (or a device that comes/goes during the loop) is honored, never frozen
    /// into a stale decision (council MIC-FOLLOW-PIN-OVERRIDE / mic-switch-clobbered-by-autofollow).
    public static func recoveryTarget(pinned: String?, available: Set<String>) -> String? {
        let onPin = pinned.map { available.contains($0) } ?? false
        return onPin ? pinned : nil
    }
}
