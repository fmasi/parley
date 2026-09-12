import Testing
@testable import TranscriberCore

@Suite("MeetingApps classification")
struct MeetingAppsTests {
    @Test("native apps map to their family, exact and helper")
    func nativeFamilies() {
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos")?.displayName == "Zoom")
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos.helper")?.displayName == "Zoom")   // TASK 0: confirm helper id
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams2")?.displayName == "Teams")
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams2.helper")?.displayName == "Teams")   // TASK 0
        #expect(MeetingApps.classify(bundleID: "com.microsoft.teams")?.displayName == "Teams")
        #expect(MeetingApps.classify(bundleID: "us.zoom.xos")?.kind == .native)
    }

    @Test("browsers and their helpers are browser-kind")
    func browsers() {
        let chrome = MeetingApps.classify(bundleID: "com.google.Chrome.helper")
        #expect(chrome?.displayName == "Chrome")
        #expect(chrome?.kind == .browser)
        #expect(MeetingApps.classify(bundleID: "com.google.Chrome")?.id == chrome?.id)   // same family
        let safari = MeetingApps.classify(bundleID: "com.apple.WebKit.GPU")
        #expect(safari?.displayName == "Safari")
        #expect(safari?.kind == .browser)
        #expect(MeetingApps.classify(bundleID: "company.thebrowser.Browser")?.displayName == "Arc")
        #expect(MeetingApps.classify(bundleID: "com.microsoft.edgemac")?.displayName == "Edge")
        #expect(MeetingApps.classify(bundleID: "org.mozilla.firefox")?.displayName == "Firefox")
    }

    @Test("Parley's own processes are never classified")
    func parleyExcluded() {
        #expect(MeetingApps.classify(bundleID: "eu.fmasi.parley") == nil)
        #expect(MeetingApps.classify(bundleID: "eu.fmasi.parley.capture-helper") == nil)
    }

    @Test("unknown, empty and FaceTime bundle IDs are nil")
    func unknownIsNil() {
        #expect(MeetingApps.classify(bundleID: "") == nil)
        #expect(MeetingApps.classify(bundleID: "com.apple.FaceTime") == nil)
        #expect(MeetingApps.classify(bundleID: "com.example.dictation") == nil)
        // A prefix match needs the dot: "us.zoomfoo" is not Zoom.
        #expect(MeetingApps.classify(bundleID: "us.zoomfoo") == nil)
    }
}
