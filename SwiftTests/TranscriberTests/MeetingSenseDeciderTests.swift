import Foundation
import Testing
@testable import TranscriberCore

@Suite("MeetingSenseDecider")
struct MeetingSenseDeciderTests {

    /// A full "meeting is happening" signal: mic in use, a meeting app running, not already recording.
    private let meeting = MeetingSignal(micActive: true, meetingAppRunning: true, isRecording: false)

    @Test("off mode never acts, even on a full signal")
    func offModeIgnores() {
        #expect(MeetingSenseDecider.decide(signal: meeting, mode: .off, secondsSinceLastAction: nil) == .ignore)
    }

    @Test("prompt mode prompts on a full signal")
    func promptOnFullSignal() {
        #expect(MeetingSenseDecider.decide(signal: meeting, mode: .prompt, secondsSinceLastAction: nil) == .prompt)
    }

    @Test("never prompts while already recording")
    func ignoresWhileRecording() {
        let s = MeetingSignal(micActive: true, meetingAppRunning: true, isRecording: true)
        #expect(MeetingSenseDecider.decide(signal: s, mode: .prompt, secondsSinceLastAction: nil) == .ignore)
    }

    @Test("mic in use but no meeting app → ignore (filters dictation/FaceTime/Voice Memos)")
    func micWithoutMeetingAppIgnores() {
        let s = MeetingSignal(micActive: true, meetingAppRunning: false, isRecording: false)
        #expect(MeetingSenseDecider.decide(signal: s, mode: .prompt, secondsSinceLastAction: nil) == .ignore)
    }

    @Test("meeting app running but mic idle → ignore (app open, no call)")
    func meetingAppWithoutMicIgnores() {
        let s = MeetingSignal(micActive: false, meetingAppRunning: true, isRecording: false)
        #expect(MeetingSenseDecider.decide(signal: s, mode: .prompt, secondsSinceLastAction: nil) == .ignore)
    }

    @Test("cooldown suppresses a second action within the window")
    func cooldownSuppresses() {
        let within = MeetingSenseDecider.defaultCooldown - 1
        #expect(MeetingSenseDecider.decide(signal: meeting, mode: .prompt, secondsSinceLastAction: within) == .ignore)
    }

    @Test("action resumes once the cooldown window has passed")
    func actsAfterCooldown() {
        let past = MeetingSenseDecider.defaultCooldown + 1
        #expect(MeetingSenseDecider.decide(signal: meeting, mode: .prompt, secondsSinceLastAction: past) == .prompt)
    }

    @Test("cooldown boundary: exactly at the window it acts (since < cooldown is exclusive)")
    func actsExactlyAtCooldownBoundary() {
        // Pins the < vs <= fence-post: at secondsSinceLastAction == cooldown the guard must NOT suppress.
        let atBoundary = MeetingSenseDecider.defaultCooldown
        #expect(MeetingSenseDecider.decide(signal: meeting, mode: .prompt, secondsSinceLastAction: atBoundary) == .prompt)
    }

    @Test("known conferencing apps are in the match set; ambiguous browsers are not")
    func meetingAppsSetIsConferencingOnly() {
        #expect(MeetingApps.bundleIDs.contains("us.zoom.xos"))
        #expect(MeetingApps.bundleIDs.contains("com.microsoft.teams2"))
        #expect(!MeetingApps.bundleIDs.contains("com.google.Chrome"))
        #expect(!MeetingApps.bundleIDs.contains("com.apple.Safari"))
    }
}
