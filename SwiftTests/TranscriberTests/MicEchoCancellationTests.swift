import AVFoundation
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

    /// The guard runs on the engine's output: with a threshold every frame trips, every loud frame
    /// with the far end silent is the raw mic again, and the record counts them.
    @Test func runsTheNearEndGuardOnTheEnginesOutput() throws {
        var everything = NearEndGuard.Parameters()
        everything.maxCutDB = -200
        let mic = voice(seconds: 3, seed: 61)
        let out = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory, guardParameters: everything)
            .cancelEcho(microphone: mic, reference: [Float](repeating: 0, count: mic.count))
        #expect(out.framesReverted > 10)
        let loudFrame = (12 * 1600)..<(13 * 1600)
        if rmsDB(mic[loudFrame]) >= -45 { #expect(Array(out.samples[loudFrame]) == Array(mic[loudFrame])) }
        let untouched = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory)
            .cancelEcho(microphone: mic, reference: [Float](repeating: 0, count: mic.count))
        #expect(untouched.framesReverted == 0)
    }
}

/// Block-at-a-time processing (#342) gives the answer the whole-clip processing gives, so a chunk's
/// length never sets the memory it takes.
@Suite(.serialized) struct EchoCancelStreamingTests {
    @Test func feedingTheEngineInOddBlocksGivesTheWholeClipAnswer() throws {
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let far = voice(seconds: 5, seed: 71, level: 0.2)
        let mic = zip(echo(of: far, delaySeconds: 0.06, gain: 0.5), voice(seconds: 5, seed: 72)).map { $0 + $1 }
        let whole = try canceller.process(microphone: mic, reference: far)
        // The delay estimate and the filter, each fed in odd blocks.
        func inOddBlocks(_ body: (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) throws -> Void) throws {
            var offset = 0
            for size in [1, 255, 257, 1000, 37, 16_000, 3, 9999].cycled(toCover: mic.count) {
                let n = min(size, mic.count - offset)
                if n == 0 { break }
                try mic.withUnsafeBufferPointer { m in
                    try far.withUnsafeBufferPointer { r in
                        try body(UnsafeBufferPointer(rebasing: m[offset..<(offset + n)]), UnsafeBufferPointer(rebasing: r[offset..<(offset + n)]))
                    }
                }
                offset += n
            }
        }
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        try inOddBlocks { try estimate.push(microphone: $0, reference: $1) }
        let stream = try LocalVQEEchoCanceller.Stream(canceller, delay: estimate)
        var streamed = [Float]()
        try inOddBlocks { streamed += try stream.push(microphone: $0, reference: $1) }
        streamed += try stream.finish()
        #expect(streamed.count == mic.count)
        #expect(streamed == whole)
    }

    @Test func theFilePathMatchesTheSamplesPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let far = voice(seconds: 9, seed: 81, level: 0.2)
        var near = [Float](repeating: 0, count: far.count)
        for (k, v) in voice(seconds: 2, seed: 82, level: 0.1).enumerated() { near[5 * rate + k] = v }
        let mic = zip(echo(of: far, delaySeconds: 0.05, gain: 0.4), near).map { $0 + $1 }
        let shortFar = Array(far[0..<(7 * rate)])  // the reference ends early: silence past it
        let micURL = dir.appendingPathComponent("mic.wav"), sysURL = dir.appendingPathComponent("sys.wav")
        let outURL = dir.appendingPathComponent("out.wav")
        try LocalVQEMicEchoCanceller.writeWAV(mic, to: micURL, sampleRate: rate)
        try LocalVQEMicEchoCanceller.writeWAV(shortFar, to: sysURL, sampleRate: rate)
        var strict = NearEndGuard.Parameters()
        strict.maxCutDB = -200  // every loud frame with the far end silent reverts, so the blend is compared too
        let canceller = LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory, guardParameters: strict)
        let record = try canceller.cancelEcho(micURL: micURL, systemURL: sysURL, outputURL: outURL)
        let fromFile = try AudioDecode.mono16kHzFloat(contentsOf: outURL)
        let fromSamples = try canceller.cancelEcho(microphone: mic, reference: shortFar)
        #expect(fromFile == fromSamples.samples)
        #expect(record.framesReverted == fromSamples.framesReverted)
        #expect(record.framesReverted > 0)
        // No scratch file is left beside the output.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["mic.wav", "out.wav", "sys.wav"])
    }

    @Test func theBlockReaderReadsWhatTheWholeFileReaderReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("48k.wav")
        try LocalVQEMicEchoCanceller.writeWAV(voice(seconds: 3.3, seed: 91).flatMap { [$0, $0, $0] }, to: url, sampleRate: 48_000)
        let whole = try AudioDecode.mono16kHzFloat(contentsOf: url)
        let reader = try Mono16kReader(url: url)
        var blocks = [Float]()
        while true {
            let b = try reader.read(maxFrames: 7_777)
            if b.isEmpty { break }
            blocks += b
        }
        #expect(abs(blocks.count - whole.count) <= 1)
        let n = min(blocks.count, whole.count)
        let worst = (0..<n).map { abs(blocks[$0] - whole[$0]) }.max() ?? 0
        #expect(worst < 1e-3, "block reader differs by \(worst)")
    }
}

/// The echo delay is estimated over the whole clip before it is filtered (#361). Upstream's online estimate
/// locks for good at its first confident one 3.5 s in; on 2026-11-10 a call's opening locked it at 1 s instead
/// of 25 ms and a whole chunk came out with its echo untouched, recorded as a success.
@Suite(.serialized) struct EchoDelayEstimateTests {
    /// The far end talking. For the first 4 s the mic hears it 0.75 s late (a decoy: what the online estimate
    /// has to go on when it locks), then, as for the rest of a call, 60 ms late through the speakers.
    private func deceptiveOpening(seconds: Double = 30) -> (mic: [Float], far: [Float]) {
        let far = voice(seconds: seconds, seed: 101, level: 0.2)
        let decoy = echo(of: far, delaySeconds: 0.75, gain: 0.5), real = echo(of: far, delaySeconds: 0.06, gain: 0.5)
        let mic = far.indices.map { $0 < 4 * rate ? decoy[$0] : real[$0] }
        return (mic, far)
    }

    /// Echo removed in dB over 10-30 s, long after either estimate settled.
    private func removed(_ mic: [Float], _ out: [Float]) -> Double { rmsDB(mic[seconds(10, 30)]) - rmsDB(out[seconds(10, 30)]) }

    @Test func aDeceptiveOpeningNoLongerLeavesTheChunkUncancelled() throws {
        let (mic, far) = deceptiveOpening()
        let out = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory).cancelEcho(microphone: mic, reference: far)
        #expect(removed(mic, out.samples) > 20, "only \(removed(mic, out.samples)) dB of echo removed")
    }

    /// What the bug was: the same clip through upstream's online estimate locks on the decoy and removes nothing.
    @Test func theOnlineEstimateLocksOnTheOpening() throws {
        let (mic, far) = deceptiveOpening()
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let stream = try LocalVQEEchoCanceller.Stream(canceller)
        var out = try mic.withUnsafeBufferPointer { m in try far.withUnsafeBufferPointer { try stream.push(microphone: m, reference: $0) } }
        out += try stream.finish()
        #expect(canceller.delaySamples > LocalVQEEchoCanceller.maxDelaySamples)
        #expect(removed(mic, out) < 10)
        #expect(stream.estimatedDelay == nil)
    }

    @Test func theWholeClipEstimateFindsTheSpeakerDelay() throws {
        let (mic, far) = deceptiveOpening()
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        try mic.withUnsafeBufferPointer { m in try far.withUnsafeBufferPointer { try estimate.push(microphone: m, reference: $0) } }
        let stream = try LocalVQEEchoCanceller.Stream(canceller, delay: estimate)
        // 960 samples (60 ms), less upstream's one-block safety margin, to a whole block.
        let delay = try #require(stream.estimatedDelay)
        #expect((640...960).contains(delay), "estimated \(delay) samples")
        #expect(canceller.delaySamples == delay)
    }

    /// A shift past the real delay leaves the echo before the filter's window; past `maxDelaySamples` none
    /// is taken, and the filter runs at 0, whose window still reaches 1.024 s.
    @Test func aDelayPastTheBoundIsNotFrozen() throws {
        let far = voice(seconds: 12, seed: 111, level: 0.2)
        let mic = echo(of: far, delaySeconds: 0.7, gain: 0.5)
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        try mic.withUnsafeBufferPointer { m in try far.withUnsafeBufferPointer { try estimate.push(microphone: m, reference: $0) } }
        let stream = try LocalVQEEchoCanceller.Stream(canceller, delay: estimate)
        #expect(stream.estimatedDelay == nil)
        #expect(canceller.delaySamples == 0)
    }

    /// The streaming estimate on Accelerate's FFT finds what upstream's own `daf_prime_delay` finds.
    @Test(arguments: [0.02, 0.06, 0.3])
    func theEstimateIsUpstreams(delaySeconds: Double) throws {
        let far = voice(seconds: 20, seed: 131, level: 0.2)
        let mic = zip(echo(of: far, delaySeconds: delaySeconds, gain: 0.4), voice(seconds: 20, seed: 132, level: 0.05)).map { $0 + $1 }
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let upstream = try #require(canceller.upstreamDelayEstimate(microphone: mic, reference: far))
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        try mic.withUnsafeBufferPointer { m in try far.withUnsafeBufferPointer { try estimate.push(microphone: m, reference: $0) } }
        #expect(try LocalVQEEchoCanceller.Stream(canceller, delay: estimate).estimatedDelay == upstream)
    }

    /// Headphones: the mic never hears the far end, so nothing removed is right, never "ineffective" — even
    /// where the delay estimate finds something to lock onto.
    @Test func aMicThatNeverHearsTheFarEndIsNotIneffective() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let far = voice(seconds: 90, seed: 141, level: 0.2)
        var rng: UInt64 = 142
        var mic = (0..<(90 * rate)).map { _ -> Float in  // steady room tone, about -65 dBFS
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 11) % 2001) / 1000 * 0.001
        }
        for (k, v) in voice(seconds: 5, seed: 143, level: 0.1).enumerated() { mic[30 * rate + k] += v }  // a few words
        let micURL = dir.appendingPathComponent("mic.wav"), sysURL = dir.appendingPathComponent("sys.wav")
        try LocalVQEMicEchoCanceller.writeWAV(mic, to: micURL, sampleRate: rate)
        try LocalVQEMicEchoCanceller.writeWAV(far, to: sysURL, sampleRate: rate)
        let record = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory)
            .cancelEcho(micURL: micURL, systemURL: sysURL, outputURL: dir.appendingPathComponent("out.wav"))
        #expect(try #require(record.farEndLiftDB) < EchoReduction.audibleEchoLiftDB)
        #expect(!record.isIneffective)
    }

    @Test func theEstimateRefusesWhatTheFilterRefuses() throws {
        let estimate = LocalVQEEchoCanceller.DelayEstimate(try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory))
        let two: [Float] = [0, 0], one: [Float] = [0], bad: [Float] = [0, .nan]
        #expect(throws: LocalVQEEchoCanceller.Failure.lengthMismatch(microphone: 2, reference: 1)) {
            try two.withUnsafeBufferPointer { m in try one.withUnsafeBufferPointer { try estimate.push(microphone: m, reference: $0) } }
        }
        #expect(throws: LocalVQEEchoCanceller.Failure.nonFiniteInput) {
            try bad.withUnsafeBufferPointer { m in try two.withUnsafeBufferPointer { try estimate.push(microphone: m, reference: $0) } }
        }
    }

    /// The file path records the delay it used and how much echo it removed; the samples path (re-detect) gives
    /// the same audio.
    @Test func theRecordCarriesTheDelayAndTheReduction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mic, far) = deceptiveOpening(seconds: 90)  // enough of the far end talking to measure
        let micURL = dir.appendingPathComponent("mic.wav"), sysURL = dir.appendingPathComponent("sys.wav")
        let outURL = dir.appendingPathComponent("out.wav")
        try LocalVQEMicEchoCanceller.writeWAV(mic, to: micURL, sampleRate: rate)
        try LocalVQEMicEchoCanceller.writeWAV(far, to: sysURL, sampleRate: rate)
        let canceller = LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory)
        let record = try canceller.cancelEcho(micURL: micURL, systemURL: sysURL, outputURL: outURL)
        #expect((640...960).contains(record.delaySamples ?? -1))
        let erle = try #require(record.erleDB)
        #expect(erle > 20, "measured \(erle) dB")
        #expect(try #require(record.farEndLiftDB) >= EchoReduction.audibleEchoLiftDB)
        #expect(!record.isIneffective)
        #expect(try AudioDecode.mono16kHzFloat(contentsOf: outURL) == canceller.cancelEcho(microphone: mic, reference: far).samples)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["mic.wav", "out.wav", "sys.wav"])
    }
}

/// `EchoReduction` (#361): the median reduction over the frames where the far end talks and the mic hears it.
@Suite struct EchoReductionTests {
    @Test func takesTheMedianOverFramesWhereTheFarEndTalksAndTheMicHearsIt() {
        // 400 frames counted: 300 cut by 40 dB, 100 not cut at all (the user over the far end). 100 more
        // are left out: the far end silent, or the mic too quiet.
        let mic = [Double](repeating: -30, count: 450) + [Double](repeating: -60, count: 50)
        let clean = [Double](repeating: -70, count: 300) + [Double](repeating: -30, count: 100) + [Double](repeating: -90, count: 100)
        let ref = [Double](repeating: -20, count: 400) + [Double](repeating: -60, count: 50) + [Double](repeating: -20, count: 50)
        #expect(EchoReduction.measure(micDB: mic, cleanDB: clean, refDB: ref) == 40)
    }

    @Test func aCancellerThatRemovedNothingMeasuresZero() {
        let levels = [Double](repeating: -26, count: 600)
        #expect(EchoReduction.measure(micDB: levels, cleanDB: levels, refDB: levels) == 0)
    }

    @Test func tooLittleFarEndIsNotJudged() {
        let mic = [Double](repeating: -30, count: 299), clean = [Double](repeating: -30, count: 299)
        #expect(EchoReduction.measure(micDB: mic, cleanDB: clean, refDB: mic) == nil)
        #expect(EchoReduction.measure(micDB: [], cleanDB: [], refDB: []) == nil)
    }

    @Test func isIneffectiveOnlyWhenTheMicHeardTheFarEndAndLittleWasRemoved() {
        func record(lift: Double?, erle: Double?, delay: Int? = 384) -> MicEchoCancelRecord {
            MicEchoCancelRecord(engine: "e", modelSHA256: "", framesReverted: 0, seconds: 1800, delaySamples: delay,
                                erleDB: erle, farEndLiftDB: lift)
        }
        #expect(record(lift: 31, erle: 0.1).isIneffective)
        #expect(record(lift: 15, erle: 9.9).isIneffective)
        #expect(record(lift: 31, erle: 0, delay: nil).isIneffective)  // an echo heard and no delay found: still a failure
        #expect(!record(lift: 31, erle: 10).isIneffective)
        #expect(!record(lift: 31, erle: nil).isIneffective)
        // The mic did not hear the far end (headphones): nothing to remove, so nothing removed is right.
        #expect(!record(lift: 2.3, erle: 0).isIneffective)
        #expect(!record(lift: nil, erle: 0).isIneffective)
    }

    @Test func theLiftIsTheMicAboveItsFloorWhileTheFarEndTalks() {
        // 400 frames of the far end talking with the mic at -26 dBFS (echo), 600 with the far end silent and the
        // mic at its -57 floor.
        let mic = [Double](repeating: -26, count: 400) + [Double](repeating: -57, count: 600)
        let ref = [Double](repeating: -20, count: 400) + [Double](repeating: -80, count: 600)
        #expect(EchoReduction.farEndLift(micDB: mic, refDB: ref) == 31)
        // Steady room noise is the floor: it lifts nothing.
        #expect(EchoReduction.farEndLift(micDB: [Double](repeating: -45, count: 1000), refDB: ref) == 0)
        // Frames past the clip's end are not the floor.
        #expect(EchoReduction.farEndLift(micDB: mic + [Double](repeating: -200, count: 500), refDB: ref + [Double](repeating: -200, count: 500)) == 31)
        #expect(EchoReduction.farEndLift(micDB: Array(mic.prefix(299)), refDB: ref) == nil)
    }
}

/// The per-sample blend (the guard a block at a time) against the whole-array rule it replaced.
@Suite struct NearEndGuardBlendTests {
    /// The original two-pass rule: 1 in reverted frames, a linear ramp over `fade` samples beside them.
    private func referenceGain(mask: [Bool], frame: Int, count: Int, fade: Int) -> [Float] {
        var gain = [Float](repeating: 0, count: count)
        for f in mask.indices where mask[f] { for s in (f * frame)..<min(count, (f + 1) * frame) { gain[s] = 1 } }
        var d = Int.max / 2
        for s in 0..<count {
            d = gain[s] == 1 ? 0 : d + 1
            if d > 0 && d <= fade { gain[s] = max(gain[s], 1 - Float(d) / Float(fade + 1)) }
        }
        d = Int.max / 2
        for s in stride(from: count - 1, through: 0, by: -1) {
            d = gain[s] == 1 ? 0 : d + 1
            if d > 0 && d <= fade { gain[s] = max(gain[s], 1 - Float(d) / Float(fade + 1)) }
        }
        return gain
    }

    @Test(arguments: [0.05, 0.25])  // a fade shorter than a frame (the default) and one longer than two
    func matchesTheWholeArrayRule(crossfade: Double) {
        var p = NearEndGuard.Parameters()
        p.crossfadeSeconds = crossfade
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<20 {
            let count = 1600 * 30 + Int.random(in: 0..<1600, using: &rng)  // a partial last frame
            let frames = (count + 1599) / 1600
            let mask = (0..<frames).map { _ in Bool.random(using: &rng) && Bool.random(using: &rng) }
            let blend = NearEndGuard.Blend(mask: mask, frame: 1600, count: count, sampleRate: 16_000, parameters: p)
            let reference = referenceGain(mask: mask, frame: 1600, count: count, fade: blend.fade)
            let mismatch = (0..<count).first { blend.gain(at: $0) != reference[$0] }
            #expect(mismatch == nil, "trial \(trial): sample \(mismatch ?? -1)")
        }
    }
}

private extension Array {
    /// The sizes repeated until their sum covers `total`.
    func cycled(toCover total: Int) -> [Element] where Element == Int {
        var out = [Int](), sum = 0
        while sum < total { for x in self { out.append(x); sum += x; if sum >= total { break } } }
        return out
    }
}

/// A read error is the end of a file only where the stated length is an estimate (AAC); on a WAV it is
/// an error, and echo cancellation refuses a mic read that ends short (the chunk then uses the raw mic).
@Suite(.serialized) struct BlockReaderShortReadTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func onlyACompressedFilesLengthIsAnEstimate() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let wav = d.appendingPathComponent("a.wav"), m4a = d.appendingPathComponent("a.m4a")
        try LocalVQEMicEchoCanceller.writeWAV(voice(seconds: 1, seed: 101), to: wav, sampleRate: rate)
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        do {  // the writer closes at the end of this scope
            let file = try AVAudioFile(forWriting: m4a, settings: aac)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            try file.write(from: buffer)
        }
        #expect(try Mono16kReader(url: wav).lengthIsEstimate == false)
        #expect(try Mono16kReader(url: m4a).lengthIsEstimate == true)
    }

    @Test func aPCMReadThatEndsShortIsRefusedAndAnEstimatedOneIsNot() throws {
        #expect(throws: LocalVQEMicEchoCanceller.Failure.shortRead(read: 16_000, expected: 32_000)) {
            try LocalVQEMicEchoCanceller.checkComplete(read: 16_000, expected: 32_000, lengthIsEstimate: false)
        }
        try LocalVQEMicEchoCanceller.checkComplete(read: 31_900, expected: 32_000, lengthIsEstimate: false)  // rounding
        try LocalVQEMicEchoCanceller.checkComplete(read: 16_000, expected: 32_000, lengthIsEstimate: true)   // AAC estimate
    }

    /// The rate the capture helper writes: a resampled mic is read, cancelled and written whole.
    /// (`shortRead` itself needs a file shrinking under the reader; `checkComplete` is tested directly above.)
    @Test func a48kHzMicIsCancelledToItsFullLength() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let mic = d.appendingPathComponent("mic.wav"), sys = d.appendingPathComponent("sys.wav"), out = d.appendingPathComponent("out.wav")
        try LocalVQEMicEchoCanceller.writeWAV(voice(seconds: 3.3, seed: 111).flatMap { [$0, $0, $0] }, to: mic, sampleRate: 48_000)
        try LocalVQEMicEchoCanceller.writeWAV(voice(seconds: 3.3, seed: 112).flatMap { [$0, $0, $0] }, to: sys, sampleRate: 48_000)
        let record = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory).cancelEcho(micURL: mic, systemURL: sys, outputURL: out)
        #expect(abs(record.seconds - 3.3) < 0.01)
        #expect(abs(try AudioDecode.mono16kHzFloat(contentsOf: out).count - Int(3.3 * 16_000)) <= 1)
    }

    @Test func aWAVWhoseHeaderOverReportsIsReadToItsRealEnd() throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let mic = d.appendingPathComponent("mic.wav"), sys = d.appendingPathComponent("sys.wav")
        try RecoveryFixtures.writeFakeWav(at: mic, seconds: 1, sampleRate: 16_000)
        try RecoveryFixtures.writeFakeWav(at: sys, seconds: 1, sampleRate: 16_000)
        var data = try Data(contentsOf: mic)  // the header claims two seconds; the file holds one
        withUnsafeBytes(of: UInt32(36 + 64_000).littleEndian) { data.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: UInt32(64_000).littleEndian) { data.replaceSubrange(40..<44, with: $0) }
        try data.write(to: mic)
        // AVAudioFile caps the length at the data held, so this is a complete read of one second.
        let record = try LocalVQEMicEchoCanceller(assetsDirectory: assetsDirectory)
            .cancelEcho(micURL: mic, systemURL: sys, outputURL: d.appendingPathComponent("out.wav"))
        #expect(abs(record.seconds - 1) < 0.01)
    }
}
