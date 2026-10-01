import Foundation
import Testing
@testable import TranscriberCore

/// L10 review 53: how the app answers a request to end it. Pure, so every kind of termination is tested.
@Suite struct TerminationPolicyTests {
    private func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    @Test func workInFlightIsBusy() {
        #expect(!TerminationPolicy.isBusy(recording: false, startInFlight: false, stopInFlight: false, transcribing: false, recoveryInFlight: false))
        #expect(TerminationPolicy.isBusy(recording: true, startInFlight: false, stopInFlight: false, transcribing: false, recoveryInFlight: false))
        #expect(TerminationPolicy.isBusy(recording: false, startInFlight: true, stopInFlight: false, transcribing: false, recoveryInFlight: false))
        #expect(TerminationPolicy.isBusy(recording: false, startInFlight: false, stopInFlight: true, transcribing: false, recoveryInFlight: false))
        #expect(TerminationPolicy.isBusy(recording: false, startInFlight: false, stopInFlight: false, transcribing: true, recoveryInFlight: false))
        #expect(TerminationPolicy.isBusy(recording: false, startInFlight: false, stopInFlight: false, transcribing: false, recoveryInFlight: true))
    }

    @Test func anIdleAppEndsAtOnceWhateverTheKind() {
        for kind in [TerminationKind.userQuit, .powerOff, .outsideQuit] {
            #expect(TerminationPolicy.reply(busy: false, kind: kind) == .terminateNow)
        }
    }

    /// Busy: logout/shutdown/restart and an outside quit wait — for a TIGHT bound (≤ 5 s): the helper is
    /// stopped, the finalize left to the next launch. The user's own Quit already confirmed and stopped the
    /// recording (bounded at ≤ 30 s) before it asked: it ends at once.
    @Test func aBusyAppWaitsOnlyForAPowerOffOrAnOutsideQuit() {
        #expect(TerminationPolicy.reply(busy: true, kind: .powerOff) == .terminateLater(bound: TerminationPolicy.terminationBound))
        #expect(TerminationPolicy.reply(busy: true, kind: .outsideQuit) == .terminateLater(bound: TerminationPolicy.terminationBound))
        #expect(TerminationPolicy.reply(busy: true, kind: .userQuit) == .terminateNow)
        #expect(TerminationPolicy.terminationBound <= .seconds(5))
        #expect(TerminationPolicy.userQuitBound <= .seconds(30))
    }

    /// The quit Apple event's reason names a logout, restart or shutdown; `willPowerOff` says so too; else
    /// Parley's own menu Quit; else someone outside Parley (Activity Monitor, `osascript`, Sparkle).
    @Test func theKindComesFromTheQuitReasonThePowerOffAndTheMenu() {
        let now = Date()
        for reason in ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"] {
            #expect(TerminationPolicy.kind(quitReason: code(reason), powerOffSeenAt: nil, now: now, userQuitRequested: false) == .powerOff, "\(reason)")
        }
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: now, now: now, userQuitRequested: false) == .powerOff)
        #expect(TerminationPolicy.kind(quitReason: code("logo"), powerOffSeenAt: nil, now: now, userQuitRequested: true) == .powerOff)
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: nil, now: now, userQuitRequested: true) == .userQuit)
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: nil, now: now, userQuitRequested: false) == .outsideQuit)
        #expect(TerminationPolicy.kind(quitReason: code("xxxx"), powerOffSeenAt: nil, now: now, userQuitRequested: false) == .outsideQuit)
    }

    /// L review 107: a `willPowerOff` is time-boxed — a CANCELLED logout never makes a later quit a power-off —
    /// and the user's own Quit is always the user's, whatever `willPowerOff` said before it. Only the quit event's
    /// own reason makes it a power-off then.
    @Test func aCancelledLogoutNeverRecolorsALaterQuit() {
        let now = Date()
        let recent = now.addingTimeInterval(-10), stale = now.addingTimeInterval(-TerminationPolicy.powerOffWindow - 1)
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: recent, now: now, userQuitRequested: true) == .userQuit,
                "the user's Quit after a cancelled logout")
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: stale, now: now, userQuitRequested: false) == .outsideQuit,
                "a logout cancelled a minute ago is over")
        #expect(TerminationPolicy.kind(quitReason: nil, powerOffSeenAt: recent, now: now, userQuitRequested: false) == .powerOff)
        #expect(TerminationPolicy.powerOffWindow <= 60)
    }
}
