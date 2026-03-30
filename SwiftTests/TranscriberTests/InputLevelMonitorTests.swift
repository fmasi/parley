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

    // MARK: - RMS Float32

    @Test func rmsFloatSilenceIsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = [0.0, 0.0, 0.0, 0.0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(rms == 0.0)
    }

    @Test func rmsFloatFullScaleSine() {
        let monitor = InputLevelMonitor()
        // A full-scale sine wave has RMS = 1/√2 ≈ 0.707
        // Approximate with +1, -1 alternating
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(rms == 1.0)  // sqrt(mean of 1s) = 1.0
    }

    @Test func rmsFloatHalfAmplitude() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: $0.count) }
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test func rmsFloatEmptyReturnsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Float] = []
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSFloat($0.baseAddress!, count: 0) }
        #expect(rms == 0.0)
    }

    // MARK: - RMS Int16

    @Test func rmsInt16SilenceIsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [0, 0, 0, 0]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        #expect(rms == 0.0)
    }

    @Test func rmsInt16FullScale() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [32767, -32767, 32767, -32767]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        // 32767/32768 ≈ 0.99997
        #expect(abs(rms - 1.0) < 0.001)
    }

    @Test func rmsInt16HalfAmplitude() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = [16384, -16384, 16384, -16384]
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: $0.count) }
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test func rmsInt16EmptyReturnsZero() {
        let monitor = InputLevelMonitor()
        let samples: [Int16] = []
        let rms = samples.withUnsafeBufferPointer { monitor.computeRMSInt16($0.baseAddress!, count: 0) }
        #expect(rms == 0.0)
    }

    // MARK: - dB normalization

    @Test func dBNormalizeZeroReturnsZero() {
        let monitor = InputLevelMonitor()
        #expect(monitor.dBNormalize(0.0) == 0.0)
    }

    @Test func dBNormalizeFullScaleReturnsOne() {
        let monitor = InputLevelMonitor()
        // RMS of 1.0 = 0 dB, normalized to 1.0
        #expect(monitor.dBNormalize(1.0) == 1.0)
    }

    @Test func dBNormalizeVeryQuietClampsToZero() {
        let monitor = InputLevelMonitor()
        // RMS of 0.00001 ≈ -100 dB, well below -50 dB floor
        #expect(monitor.dBNormalize(0.00001) == 0.0)
    }

    @Test func dBNormalizeMidRange() {
        let monitor = InputLevelMonitor()
        // RMS of ~0.00316 = -50 dB, should map to 0.0 (the floor)
        let atFloor = monitor.dBNormalize(0.00316)
        #expect(abs(atFloor) < 0.02)
    }

    @Test func dBNormalizeMonotonicallyIncreasing() {
        let monitor = InputLevelMonitor()
        let low = monitor.dBNormalize(0.01)
        let mid = monitor.dBNormalize(0.1)
        let high = monitor.dBNormalize(0.5)
        #expect(low < mid)
        #expect(mid < high)
    }
}
