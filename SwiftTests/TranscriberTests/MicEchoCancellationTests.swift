import Foundation
import Testing
@testable import TranscriberCore

/// Mic echo cancellation (#342): the near-end guard (pure), the LocalVQE canceller's asset checks and
/// its behaviour on synthetic signals, through the real model in ThirdParty/LocalVQE-CoreML.

private let rate = 16_000

/// A deterministic speech-like signal: a 120-180 Hz harmonic series, syllable-rate amplitude
/// modulation, a little noise. `seed` changes the pitch track and the syllable phase.
private func voice(seconds: Double, seed: UInt64, level: Float = 0.1) -> [Float] {
    var rng = seed &* 6364136223846793005 &+ 1442695040888963407
    func noise() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: rng >> 11) % 2001) / 1000 - 1
    }
    let n = Int(seconds * Double(rate))
    let f0Base = 120 + Double(seed % 60)
    var phase = 0.0
    return (0..<n).map { i in
        let t = Double(i) / Double(rate)
        let f0 = f0Base * (1 + 0.08 * sin(2 * .pi * 0.7 * t + Double(seed)))
        phase += 2 * .pi * f0 / Double(rate)
        var s = 0.0
        for h in 1...12 { s += sin(Double(h) * phase) / Double(h) }
        let syllable = max(0, sin(2 * .pi * 3.5 * t + Double(seed)))
        return level * (Float(s * syllable) * 0.6 + 0.02 * noise())
    }
}

/// The far end as heard through speakers: delayed, attenuated, with a short decaying tail.
private func echo(of x: [Float], delaySeconds: Double, gain: Float) -> [Float] {
    let d = Int(delaySeconds * Double(rate))
    let taps: [(Int, Float)] = [(0, 1), (37, 0.45), (91, -0.3), (160, 0.18), (300, 0.08)]
    var y = [Float](repeating: 0, count: x.count)
    for (lag, w) in taps {
        for i in (d + lag)..<x.count { y[i] += gain * w * x[i - d - lag] }
    }
    return y
}

private func rmsDB(_ x: ArraySlice<Float>) -> Double {
    let s = x.reduce(0.0) { $0 + Double($1) * Double($1) }
    return 10 * log10(max(s / Double(max(1, x.count)), 1e-20))
}

private func seconds(_ a: Double, _ b: Double) -> Range<Int> { Int(a * Double(rate))..<Int(b * Double(rate)) }

private let assetsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ThirdParty/LocalVQE-CoreML")

@Suite struct NearEndGuardTests {
    private let silence = [Float](repeating: 0, count: rate * 3)

    @Test func leavesAnUncutSignalAlone() {
        let mic = voice(seconds: 3, seed: 1)
        let result = NearEndGuard.apply(microphone: mic, cleaned: mic, reference: silence, sampleRate: rate)
        #expect(result.revertedFrames == 0)
        #expect(result.samples == mic)
    }

    @Test func restoresNearEndSpeechCutWhileTheFarEndIsSilent() {
        let mic = voice(seconds: 3, seed: 2)
        var cleaned = mic
        for i in seconds(1, 2) { cleaned[i] *= 0.01 }  // a 40 dB cut of the user's own voice
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: silence, sampleRate: rate)
        #expect(result.revertedFrames > 0)
        // Every loud frame inside the cut is the raw mic again.
        for frame in 10..<20 {
            let r = (frame * 1600)..<((frame + 1) * 1600)
            if rmsDB(mic[r]) >= -45 { #expect(Array(result.samples[r]) == Array(mic[r])) }
        }
        #expect(Array(result.samples[seconds(0, 0.9)]) == Array(cleaned[seconds(0, 0.9)]))
    }

    @Test func keepsTheCutWhileTheFarEndIsTalking() {
        let mic = voice(seconds: 3, seed: 3)
        var cleaned = mic
        for i in seconds(1, 2) { cleaned[i] *= 0.01 }
        let far = voice(seconds: 3, seed: 4)  // echo can exist: removing it is the point
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: far, sampleRate: rate)
        #expect(result.revertedFrames == 0)
        #expect(result.samples == cleaned)
    }

    @Test func keepsTheCutWhenTheFarEndTalksWithinHalfASecond() {
        let mic = voice(seconds: 3, seed: 5)
        var cleaned = mic
        for i in seconds(1, 1.3) { cleaned[i] *= 0.01 }
        var far = silence
        let burst = voice(seconds: 0.2, seed: 6, level: 0.2)
        for (k, v) in burst.enumerated() { far[Int(1.4 * Double(rate)) + k] = v }  // 0.1 s after the cut ends
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: far, sampleRate: rate)
        #expect(result.revertedFrames == 0)
    }

    @Test func ignoresQuietMicFrames() {
        let mic = voice(seconds: 3, seed: 7, level: 0.001)  // about -66 dBFS: room tone, not speech
        let cleaned = mic.map { $0 * 0.01 }
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: silence, sampleRate: rate)
        #expect(result.revertedFrames == 0)
    }

    @Test func crossfadesOutsideTheRestoredFrames() {
        let mic = [Float](repeating: 0.1, count: rate * 3)  // -20 dBFS, constant
        var cleaned = mic
        for i in seconds(1, 2) { cleaned[i] = 0 }
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: silence, sampleRate: rate)
        #expect(result.revertedFrames == 10)
        // Inside the cut, the raw mic; at the cut's edge, the raw mic's full value; a fade beyond.
        #expect(result.samples[Int(1.5 * Double(rate))] == 0.1)
        #expect(result.samples[rate] == 0.1)
        // Before the cut nothing was cut, so the blend of two equal signals is that signal.
        #expect(abs(result.samples[rate - 400] - 0.1) < 1e-6)
    }

    @Test func handlesAnEmptyStream() {
        let result = NearEndGuard.apply(microphone: [], cleaned: [], reference: [], sampleRate: rate)
        #expect(result.revertedFrames == 0)
        #expect(result.samples.isEmpty)
    }

    @Test func treatsAShortReferenceAsSilentPastItsEnd() {
        let mic = voice(seconds: 3, seed: 8)
        var cleaned = mic
        for i in seconds(2, 3) { cleaned[i] *= 0.01 }
        let far = voice(seconds: 1, seed: 9)  // ends a second before the cut starts
        let result = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: far, sampleRate: rate)
        #expect(result.revertedFrames > 0)
    }
}

@Suite(.serialized) struct LocalVQEEchoCancellerTests {
    @Test func loadsTheBundledModelAndReportsItsWeights() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let manifest = try LocalVQEEchoCanceller.verifiedManifest(in: assetsDirectory)
        #expect(canceller.modelSHA256 == manifest["LocalVQEAECResidualMask.mlmodelc/weights/weight.bin"])
        #expect(canceller.modelSHA256.count == 64)
    }

    @Test func refusesAModelFileThatDoesNotMatchTheManifest() throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: assetsDirectory, to: copy)
        let controller = copy.appendingPathComponent("daf_controller.f32")
        var bytes = try Data(contentsOf: controller)
        bytes[100] ^= 0xFF
        try bytes.write(to: controller)
        #expect(throws: LocalVQEEchoCanceller.Failure.assetChecksumMismatch("daf_controller.f32")) {
            _ = try LocalVQEEchoCanceller(assetsDirectory: copy)
        }
    }

    @Test func refusesADirectoryWithoutAManifest() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        #expect(throws: LocalVQEEchoCanceller.Failure.assetMissing("MANIFEST.json")) {
            _ = try LocalVQEEchoCanceller(assetsDirectory: empty)
        }
    }

    @Test func refusesStreamsOfDifferentLengths() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        #expect(throws: LocalVQEEchoCanceller.Failure.lengthMismatch(microphone: 10, reference: 9)) {
            _ = try canceller.process(microphone: [Float](repeating: 0, count: 10), reference: [Float](repeating: 0, count: 9))
        }
        #expect(try canceller.process(microphone: [], reference: []).isEmpty)
    }

    @Test func passesTheUsersVoiceThroughWhenNothingIsPlaying() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let mic = voice(seconds: 6, seed: 11)
        let out = try canceller.process(microphone: mic, reference: [Float](repeating: 0, count: mic.count))
        #expect(out.count == mic.count)
        let window = seconds(1, 6)
        let level = rmsDB(out[window]) - rmsDB(mic[window])
        #expect(abs(level) < 1, "near-end level changed by \(level) dB")
        // Sample-aligned with the input: the STFT's hop of latency is removed.
        var residual = 0.0, energy = 0.0
        for i in window { residual += Double(out[i] - mic[i]) * Double(out[i] - mic[i]); energy += Double(mic[i]) * Double(mic[i]) }
        #expect(10 * log10(energy / residual) > 15, "output does not line up with the input")
    }

    @Test func removesTheFarEndComingBackThroughTheSpeakers() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let far = voice(seconds: 12, seed: 21, level: 0.2)
        let mic = echo(of: far, delaySeconds: 0.06, gain: 0.5)
        let out = try canceller.process(microphone: mic, reference: far)
        let late = seconds(6, 12)  // after the delay estimate and the filter have settled
        let removed = rmsDB(mic[late]) - rmsDB(out[late])
        #expect(removed > 20, "only \(removed) dB of echo removed")
    }

    @Test func keepsTheUsersVoiceWhileTheFarEndTalksOverIt() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let far = voice(seconds: 12, seed: 31, level: 0.2)
        var near = [Float](repeating: 0, count: far.count)
        let speech = voice(seconds: 3, seed: 32, level: 0.1)
        for (k, v) in speech.enumerated() { near[8 * rate + k] = v }  // double talk from 8 s to 11 s
        let echoed = echo(of: far, delaySeconds: 0.06, gain: 0.5)
        let mic = zip(echoed, near).map { $0 + $1 }
        let out = try canceller.process(microphone: mic, reference: far)
        let talk = seconds(8.5, 11)
        // What is left over the double talk is mostly the user's voice: closer to it than the raw mic is.
        func error(_ x: [Float]) -> Double {
            talk.reduce(0.0) { $0 + Double(x[$1] - near[$1]) * Double(x[$1] - near[$1]) }
        }
        #expect(error(out) < error(mic) / 4, "double talk: \(10 * log10(error(mic) / error(out))) dB closer to the user's voice")
        #expect(rmsDB(out[talk]) - rmsDB(near[talk]) > -6, "the user's voice lost more than 6 dB under double talk")
    }

    @Test func givesTheSameAnswerTwice() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let far = voice(seconds: 4, seed: 41, level: 0.2)
        let mic = echo(of: far, delaySeconds: 0.05, gain: 0.4)
        let first = try canceller.process(microphone: mic, reference: far)
        let second = try canceller.process(microphone: mic, reference: far)
        #expect(first == second)
    }
}

@Suite(.serialized) struct LocalVQEMicEchoCancellerTests {
    @Test func writesACleanedMicAsLongAsTheMicWithAShorterReference() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let far = voice(seconds: 3, seed: 51, level: 0.2)
        let mic = echo(of: far + [Float](repeating: 0, count: rate), delaySeconds: 0.06, gain: 0.5)
        let micURL = dir.appendingPathComponent("mic.wav"), sysURL = dir.appendingPathComponent("sys.wav")
        let outURL = dir.appendingPathComponent("mic-aec.wav")
        try LocalVQEMicEchoCanceller.writeWAV(mic, to: micURL, sampleRate: rate)
        try LocalVQEMicEchoCanceller.writeWAV(far, to: sysURL, sampleRate: rate)
        let report = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory)
            .cancelEcho(micURL: micURL, systemURL: sysURL, outputURL: outURL)
        let out = try AudioDecode.mono16kHzFloat(contentsOf: outURL)
        #expect(out.count == mic.count)
        #expect(report.engine == "localvqe-v1.4-aec-coreml")
        #expect(abs(report.seconds - 4) < 0.01)
    }
}
