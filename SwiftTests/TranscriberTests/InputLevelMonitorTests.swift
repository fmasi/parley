import Testing
@testable import TranscriberCore

struct InputLevelMonitorTests {

    @Test func initialLevelIsZero() {
        let monitor = InputLevelMonitor()
        #expect(monitor.level == 0.0)
    }

    @Test func isNotMonitoringInitially() {
        let monitor = InputLevelMonitor()
        #expect(monitor.isMonitoring == false)
    }

    @Test func stopWhenNotMonitoringIsNoOp() {
        let monitor = InputLevelMonitor()
        monitor.stop()
        #expect(monitor.isMonitoring == false)
        #expect(monitor.level == 0.0)
    }

    @Test func stopResetsLevel() {
        let monitor = InputLevelMonitor()
        // Simulate that level was set (in real use, the audio tap sets it)
        monitor.level = 0.75
        monitor.stop()
        #expect(monitor.level == 0.0)
        #expect(monitor.isMonitoring == false)
    }
}
