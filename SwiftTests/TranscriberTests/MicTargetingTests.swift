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
}
