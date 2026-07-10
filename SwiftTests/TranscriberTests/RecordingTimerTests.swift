import Testing
import Foundation
@testable import TranscriberCore

@Suite("RecordingTimer")
struct RecordingTimerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func elapsed(_ seconds: TimeInterval) -> String {
        recordingTimerString(from: start, to: start.addingTimeInterval(seconds))
    }

    @Test func zeroElapsed() {
        #expect(elapsed(0) == "00:00")
    }

    @Test func secondsPadToTwoDigits() {
        #expect(elapsed(5) == "00:05")
    }

    @Test func lastSecondBeforeMinuteRollover() {
        #expect(elapsed(59) == "00:59")
    }

    @Test func minuteRollover() {
        #expect(elapsed(60) == "01:00")
    }

    @Test func lastSecondBeforeHourRollover() {
        #expect(elapsed(3599) == "59:59")
    }

    /// The format widens at exactly one hour — the boundary the menu bar
    /// timer actually crosses during a long meeting.
    @Test func hourRolloverWidensFormat() {
        #expect(elapsed(3600) == "1:00:00")
    }

    @Test func hoursMinutesSecondsCompose() {
        #expect(elapsed(3600 + 2 * 60 + 3) == "1:02:03")
    }

    @Test func hoursDoNotPadButMinutesAndSecondsDo() {
        #expect(elapsed(10 * 3600 + 9 * 60 + 8) == "10:09:08")
    }

    /// A clock adjustment mid-recording must not render a negative timer.
    @Test func negativeElapsedClampsToZero() {
        #expect(elapsed(-42) == "00:00")
    }

    @Test func fractionalSecondsTruncate() {
        #expect(elapsed(9.99) == "00:09")
    }
}
