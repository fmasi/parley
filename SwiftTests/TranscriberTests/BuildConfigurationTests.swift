import Testing
import Foundation
import TranscriberCore

/// #271: the capture helper stamps which kind of build made a recording into `captureStart`.
struct BuildConfigurationTests {

    /// The names are read by people and by scripts in a `.diag.jsonl`: they do not change.
    @Test func theTwoNamesAreStable() {
        #expect(BuildConfiguration.name(isDebug: true) == "debug")
        #expect(BuildConfiguration.name(isDebug: false) == "release")
    }

    @Test func theStampedNameIsTheOneForThisBuild() {
        #expect(BuildConfiguration.name == BuildConfiguration.name(isDebug: BuildConfiguration.isDebug))
    }

    /// `TranscriberCore` and the target that links it are compiled in the same configuration, so
    /// `#if DEBUG` inside Core answers for the capture helper too. This test target stands in for
    /// the helper: its own `#if DEBUG` must agree with Core's, whichever configuration runs it.
    @Test func coreAgreesWithTheTargetThatLinksIt() {
        #if DEBUG
        let thisTargetIsDebug = true
        #else
        let thisTargetIsDebug = false
        #endif
        #expect(BuildConfiguration.isDebug == thisTargetIsDebug)
    }
}
