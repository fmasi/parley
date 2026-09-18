import Testing
@testable import TranscriberCore

/// #193's pre-flight check. Only `shouldWarn` (pure boolean logic) is unit-testable — `isLidClosed()`
/// and `isBuiltInMicSelected(deviceId:)` call IOKit/CoreAudio and require real hardware; they are
/// exercised only by a device test (see the worktree's final report).
@Suite struct ClamshellMicGuardTests {

    @Test func warnsOnlyWhenBothLidClosedAndBuiltInMicSelected() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: true, isBuiltInMic: true) == true)
    }

    @Test func lidOpenNeverWarnsEvenOnBuiltInMic() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: false, isBuiltInMic: true) == false)
    }

    @Test func closedLidOnAnExternalMicNeverWarns() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: true, isBuiltInMic: false) == false)
    }

    @Test func openLidAndExternalMicNeverWarns() {
        #expect(ClamshellMicGuard.shouldWarn(lidClosed: false, isBuiltInMic: false) == false)
    }

    /// The banner text is shared by the one call site so the wording can't silently drift between
    /// the guard and `RecordingCoordinator`.
    @Test func warningMessageIsNonEmpty() {
        #expect(!ClamshellMicGuard.warningMessage.isEmpty)
    }
}
