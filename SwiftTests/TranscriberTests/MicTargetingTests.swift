import Testing
@testable import TranscriberCore

/// The pure mic device-targeting rule (auto-follow / fallback / re-pin), exercised without hardware.
@Suite("MicTargeting")
struct MicTargetingTests {

    // MARK: - Auto-follow (no pin / "System Default")

    @Test("auto-follow: default unchanged → no switch")
    func autoFollowStable() {
        let d = MicTargeting.decide(
            pinned: nil, current: "builtin", available: ["builtin"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == false)
        #expect(d.target == "builtin")
        #expect(d.forceDefault == true)
    }

    @Test("auto-follow: AirPods connect and become default → follow to AirPods (old device still present)")
    func autoFollowToAirpods() {
        let d = MicTargeting.decide(
            pinned: nil, current: "builtin", available: ["builtin", "airpods"], systemDefault: "airpods"
        )
        #expect(d.needsSwitch == true)
        #expect(d.target == "airpods")
        #expect(d.forceDefault == true)
        #expect(d.leavingDeviceGone == false)  // built-in still exists — an intentional follow, not a loss
    }

    @Test("auto-follow: AirPods removed → fall back to built-in (leaving device gone → anomaly)")
    func autoFollowAirpodsRemoved() {
        let d = MicTargeting.decide(
            pinned: nil, current: "airpods", available: ["builtin"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == true)
        #expect(d.target == "builtin")
        #expect(d.forceDefault == true)
        #expect(d.leavingDeviceGone == true)
    }

    @Test("auto-follow: an unrelated device appears → no switch")
    func autoFollowUnrelatedDevice() {
        let d = MicTargeting.decide(
            pinned: nil, current: "builtin", available: ["builtin", "usb-cam"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == false)
    }

    // MARK: - Explicit pin (the override)

    @Test("pinned: device present and in use → no switch")
    func pinnedStable() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "airpods", available: ["builtin", "airpods"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == false)
        #expect(d.target == "airpods")
        #expect(d.forceDefault == false)
    }

    @Test("pinned: pinned device removed → fall back to default (leaving device gone → anomaly)")
    func pinnedRemovedFallsBack() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "airpods", available: ["builtin"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == true)
        #expect(d.target == "builtin")
        #expect(d.forceDefault == true)
        #expect(d.leavingDeviceGone == true)
    }

    @Test("pinned: pinned device reconnects while on fallback → re-pin (not a loss)")
    func pinnedReconnectRepins() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "builtin", available: ["builtin", "airpods"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == true)
        #expect(d.target == "airpods")
        #expect(d.forceDefault == false)   // re-pin, not a default-follow
        #expect(d.leavingDeviceGone == false)
    }

    @Test("pinned: device never available, already on default → no switch")
    func pinnedAbsentAlreadyOnDefault() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "builtin", available: ["builtin"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == false)
        #expect(d.forceDefault == true)
    }

    // MARK: - Edges

    @Test("startup: no current device yet → switch, treated as leaving-gone")
    func startupNoCurrent() {
        let d = MicTargeting.decide(
            pinned: nil, current: nil, available: ["builtin"], systemDefault: "builtin"
        )
        #expect(d.needsSwitch == true)
        #expect(d.target == "builtin")
        #expect(d.leavingDeviceGone == true)
    }

    @Test("no input devices at all → target nil (no mic), switch away from current, leaving gone")
    func noDevices() {
        let d = MicTargeting.decide(
            pinned: nil, current: "builtin", available: [], systemDefault: nil
        )
        #expect(d.target == nil)
        #expect(d.forceDefault == true)
        #expect(d.needsSwitch == true)
        #expect(d.leavingDeviceGone == true)
    }

    // MARK: - recoveryTarget (recomputed each recovery iteration)

    @Test("recoveryTarget: pinned device available → target the pin")
    func recoveryPinnedAvailable() {
        #expect(MicTargeting.recoveryTarget(pinned: "airpods", available: ["builtin", "airpods"]) == "airpods")
    }

    @Test("recoveryTarget: pinned device gone → nil (system default)")
    func recoveryPinnedGone() {
        #expect(MicTargeting.recoveryTarget(pinned: "airpods", available: ["builtin"]) == nil)
    }

    @Test("recoveryTarget: no pin (auto-follow) → nil (system default)")
    func recoveryNoPin() {
        #expect(MicTargeting.recoveryTarget(pinned: nil, available: ["builtin", "airpods"]) == nil)
    }

    @Test("recoveryTarget: pin set mid-recovery and now present → honored on the next pass (clobber fix)")
    func recoveryPinAppliedMidRecovery() {
        // Auto-follow recovery was in flight (pinned was nil); the user pins a present device mid-loop.
        // The next iteration reads the fresh pin and targets it — never frozen to the system default.
        #expect(MicTargeting.recoveryTarget(pinned: "usb-mic", available: ["builtin", "usb-mic"]) == "usb-mic")
    }

    @Test("recoveryTarget: no devices at all → nil")
    func recoveryNoDevices() {
        #expect(MicTargeting.recoveryTarget(pinned: "airpods", available: []) == nil)
    }

    // MARK: - Lid closed: the follow never lands on the built-in mic when another choice exists (#315)

    @Test("lid closed: pin gone, default is the built-in, a mic the user chose before is present → that mic, no alarm")
    func lidClosedFollowsToTheUsersEarlierChoice() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "airpods", available: ["builtin", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["airpods", "usb-cam"]
        )
        #expect(d.target == "usb-cam")
        #expect(d.needsSwitch == true)
        #expect(d.forceDefault == false, "not the system default")
        #expect(d.leavingDeviceGone == true)
        #expect(d.raiseSilenceAlarmNow == false)
    }

    @Test("lid closed: pin gone, nothing else the user chose is present → the default anyway, alarm at once")
    func lidClosedNoOtherChoiceAlarmsNow() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "airpods", available: ["builtin", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["airpods"]
        )
        #expect(d.target == "builtin")
        #expect(d.forceDefault == true)
        #expect(d.needsSwitch == true)
        #expect(d.raiseSilenceAlarmNow == true)
    }

    @Test("lid closed, auto-follow (no pin): AirPods removed → the user's earlier choice, never an unchosen input")
    func lidClosedAutoFollowUsesOnlyChosenInputs() {
        let d = MicTargeting.decide(
            pinned: nil, current: "airpods", available: ["builtin", "usb-cam", "phone-mic"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]
        )
        #expect(d.target == "usb-cam")
        #expect(d.raiseSilenceAlarmNow == false)
        let none = MicTargeting.decide(
            pinned: nil, current: "airpods", available: ["builtin", "phone-mic"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]
        )
        #expect(none.target == "builtin", "phone-mic was never chosen by the user: not picked")
        #expect(none.raiseSilenceAlarmNow == true)
    }

    @Test("lid closed: an earlier choice that is itself unusable is skipped")
    func lidClosedSkipsUnusableChoices() {
        let d = MicTargeting.decide(
            pinned: nil, current: "airpods", available: ["builtin", "builtin-2", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin", "builtin-2"], userChoices: ["builtin-2", "usb-cam"]
        )
        #expect(d.target == "usb-cam")
    }

    @Test("lid closed: already on the dead default, nothing chosen appears → no switch (no rebuild loop)")
    func lidClosedAlreadyOnDefaultNoSwitch() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "builtin", available: ["builtin"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["airpods", "usb-cam"]
        )
        #expect(d.needsSwitch == false)
    }

    @Test("lid closed: on the dead default and an earlier choice is plugged in → move to it")
    func lidClosedChosenMicAppearsMovesOffDeadDefault() {
        let d = MicTargeting.decide(
            pinned: "airpods", current: "builtin", available: ["builtin", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]
        )
        #expect(d.target == "usb-cam")
        #expect(d.needsSwitch == true)
        #expect(d.leavingDeviceGone == false)
    }

    @Test("lid open: the earlier choices change nothing — today's result exactly")
    func lidOpenIsTodaysRule() {
        let inputs: [(String?, String?, Set<String>, String?)] = [
            ("airpods", "airpods", ["builtin", "usb-cam"], "builtin"),
            (nil, "airpods", ["builtin", "usb-cam"], "builtin"),
            ("airpods", "builtin", ["builtin", "airpods", "usb-cam"], "builtin"),
            (nil, "builtin", ["builtin", "airpods"], "airpods"),
            (nil, "builtin", [], nil),
        ]
        for (pinned, current, available, systemDefault) in inputs {
            let today = MicTargeting.decide(pinned: pinned, current: current, available: available, systemDefault: systemDefault)
            let withChoices = MicTargeting.decide(
                pinned: pinned, current: current, available: available, systemDefault: systemDefault,
                unusable: [], userChoices: ["usb-cam", "airpods"]
            )
            #expect(withChoices == today)
            #expect(withChoices.raiseSilenceAlarmNow == false)
        }
    }

    @Test("pinned present → the pin, whatever the lid")
    func pinnedPresentWinsRegardlessOfLid() {
        for unusable: Set<String> in [[], ["builtin"]] {
            let d = MicTargeting.decide(
                pinned: "usb-cam", current: "builtin", available: ["builtin", "usb-cam"], systemDefault: "builtin",
                unusable: unusable, userChoices: ["airpods"]
            )
            #expect(d.target == "usb-cam")
            #expect(d.forceDefault == false)
            #expect(d.raiseSilenceAlarmNow == false)
        }
    }

    @Test("recoveryTarget: lid closed, pin gone → the user's earlier choice; none → nil (default)")
    func recoveryTargetLidClosed() {
        #expect(MicTargeting.recoveryTarget(
            pinned: "airpods", available: ["builtin", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]) == "usb-cam")
        #expect(MicTargeting.recoveryTarget(
            pinned: "airpods", available: ["builtin"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]) == nil)
        #expect(MicTargeting.recoveryTarget(
            pinned: "airpods", available: ["builtin", "usb-cam"], systemDefault: "builtin",
            unusable: [], userChoices: ["usb-cam"]) == nil, "lid open: the default, as today")
        #expect(MicTargeting.recoveryTarget(
            pinned: "airpods", available: ["builtin", "airpods", "usb-cam"], systemDefault: "builtin",
            unusable: ["builtin"], userChoices: ["usb-cam"]) == "airpods", "the pin first")
    }

    @Test("unusableInputs: only built-in inputs, and only while the lid is closed")
    func unusableInputsRule() {
        var asked: [String] = []
        let open = MicTargeting.unusableInputs(lidClosed: false, candidates: ["builtin", "usb-cam"]) {
            asked.append($0); return $0 == "builtin"
        }
        #expect(open.isEmpty)
        #expect(asked.isEmpty, "lid open: no device lookups at all")
        let closed = MicTargeting.unusableInputs(lidClosed: true, candidates: ["builtin", "usb-cam"]) { $0 == "builtin" }
        #expect(closed == ["builtin"])
    }

    // MARK: - The inputs the user chose by hand (persisted app-side, passed to the helper)

    @Test("rememberingUserChoice: newest first, no duplicates, capped, nil (system default) changes nothing")
    func rememberingUserChoice() {
        #expect(MicTargeting.rememberingUserChoice("usb-cam", in: []) == ["usb-cam"])
        #expect(MicTargeting.rememberingUserChoice("airpods", in: ["usb-cam"]) == ["airpods", "usb-cam"])
        #expect(MicTargeting.rememberingUserChoice("usb-cam", in: ["airpods", "usb-cam"]) == ["usb-cam", "airpods"])
        #expect(MicTargeting.rememberingUserChoice(nil, in: ["airpods"]) == ["airpods"])
        let full = MicTargeting.rememberingUserChoice("d", in: ["a", "b", "c"])
        #expect(full == Array(["d", "a", "b", "c"].prefix(MicTargeting.userChoiceLimit)))
        #expect(full.count == MicTargeting.userChoiceLimit)
    }
}
