import Accelerate
import CLocalVQE
import CoreML
import CryptoKit
import Foundation

/// LocalVQE v1.4-AEC echo cancellation over a whole 16 kHz mono clip (#342): the adaptive filter
/// (LocalVQE's own C++, `CLocalVQE`) removes the linear echo, then the residual mask (a Core ML model)
/// removes what is left. Echo only: the user's voice, room noise and reverb are kept.
///
/// The model files live in one directory (`ThirdParty/LocalVQE-CoreML`, copied into the app's
/// Resources); every file is checked against `MANIFEST.json` before anything is loaded. One instance
/// holds one stream's state, so it is not shared: create one per clip.
///
/// The host-side STFT follows soniqo's speech-swift port (Apache-2.0), which the residual mask was
/// exported for: 512-point frames every 256 samples, LocalVQE's analysis window, bins 1...256.
public final class LocalVQEEchoCanceller {
    public static let sampleRate = 16_000
    static let fftSize = 512
    static let hop = 256
    static let bins = 256

    public enum Failure: Error, Equatable {
        case assetMissing(String)
        case assetChecksumMismatch(String)
        case manifestUnreadable
        case controllerRejected
        case lengthMismatch(microphone: Int, reference: Int)
        case nonFiniteInput
        case modelOutputMissing
        case nonFiniteOutput
    }

    static let maskName = "LocalVQEAECResidualMask.mlmodelc"
    static let controllerName = "daf_controller.f32"
    static let windowName = "analysis_window.f32"

    /// SHA-256 of the mask's weights, as `MANIFEST.json` lists and this load verified: the record's
    /// model identity.
    public let modelSHA256: String

    private let daf: OpaquePointer
    private let model: MLModel
    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    public init(assetsDirectory: URL) throws {
        let manifest = try Self.verifiedManifest(in: assetsDirectory)
        guard let weightsSHA = manifest["\(Self.maskName)/weights/weight.bin"] else {
            throw Failure.assetMissing("\(Self.maskName)/weights/weight.bin")
        }
        modelSHA256 = weightsSHA

        window = try Self.floats(assetsDirectory.appendingPathComponent(Self.windowName))
        guard window.count == Self.fftSize else { throw Failure.assetMissing(Self.windowName) }
        let controller = try Self.floats(assetsDirectory.appendingPathComponent(Self.controllerName))
        guard controller.count == localvqe_daf_weight_count(),
              let daf = controller.withUnsafeBufferPointer({ localvqe_daf_create($0.baseAddress, $0.count) })
        else { throw Failure.controllerRejected }
        self.daf = daf

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly  // same speed as the Neural Engine here, and the same answer on every Mac
        do {
            model = try MLModel(contentsOf: assetsDirectory.appendingPathComponent(Self.maskName),
                                configuration: configuration)
        } catch {
            localvqe_daf_destroy(daf)
            throw error
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(Self.fftSize), .INVERSE)
        else { localvqe_daf_destroy(daf); throw Failure.assetMissing("vDSP DFT setup") }
        self.forward = forward
        self.inverse = inverse
    }

    deinit {
        localvqe_daf_destroy(daf)
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// The reference delay (samples) the filter's online estimate settled on in the last `process`.
    public var delaySamples: Int { Int(localvqe_daf_delay_samples(daf)) }

    /// Cancels the echo of `reference` in `microphone` (same length, 16 kHz mono) and returns the
    /// cleaned microphone, sample-aligned with the input: the STFT's one hop of latency is removed.
    /// A whole clip in memory; `Stream` is the same processing a block at a time.
    public func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        guard microphone.count == reference.count else {
            throw Failure.lengthMismatch(microphone: microphone.count, reference: reference.count)
        }
        if microphone.isEmpty { return [] }
        let stream = try Stream(self)
        var output = try microphone.withUnsafeBufferPointer { m in
            try reference.withUnsafeBufferPointer { r in try stream.push(microphone: m, reference: r) }
        }
        output.append(contentsOf: try stream.finish())
        return output
    }

    /// One clip's cancellation, fed in blocks of any length (#342): what lets a 30-minute chunk be
    /// cancelled without holding it in memory. `push` returns the cleaned samples completed so far,
    /// sample-aligned with the input; `finish` flushes the rest, so the output is exactly as long as
    /// the input. Starting a stream resets the canceller: one stream at a time per canceller.
    public final class Stream {
        private let canceller: LocalVQEEchoCanceller
        private let state: MLState
        private let micInput: MLMultiArray
        private let refInput: MLMultiArray
        private var residual: [Float], estimate: [Float]
        private var residualHistory: [Float], estimateHistory: [Float]
        private var overlap: [Float]
        private var spectrum: [Float]
        /// Input not yet a whole hop.
        private var pendingMic: [Float] = [], pendingRef: [Float] = []
        /// The first hop out of the overlap-add belongs to before the clip: it is dropped.
        private var dropped = false
        private var samplesIn = 0, samplesOut = 0

        public init(_ canceller: LocalVQEEchoCanceller) throws {
            self.canceller = canceller
            localvqe_daf_reset(canceller.daf)
            state = canceller.model.makeState()
            micInput = try MLMultiArray(shape: [1, 2, 1, NSNumber(value: LocalVQEEchoCanceller.bins)], dataType: .float16)
            refInput = try MLMultiArray(shape: [1, 2, 1, NSNumber(value: LocalVQEEchoCanceller.bins)], dataType: .float16)
            let hop = LocalVQEEchoCanceller.hop
            residual = [Float](repeating: 0, count: hop); estimate = residual
            residualHistory = residual; estimateHistory = residual
            overlap = [Float](repeating: 0, count: LocalVQEEchoCanceller.fftSize)
            spectrum = [Float](repeating: 0, count: 2 * LocalVQEEchoCanceller.bins)
        }

        /// Feeds `microphone` and `reference` (same length) and returns the cleaned samples now complete.
        public func push(microphone: UnsafeBufferPointer<Float>, reference: UnsafeBufferPointer<Float>) throws -> [Float] {
            guard microphone.count == reference.count else {
                throw Failure.lengthMismatch(microphone: microphone.count, reference: reference.count)
            }
            guard microphone.allSatisfy(\.isFinite), reference.allSatisfy(\.isFinite) else { throw Failure.nonFiniteInput }
            samplesIn += microphone.count
            let hop = LocalVQEEchoCanceller.hop
            var output = [Float]()
            output.reserveCapacity(microphone.count + hop)
            var offset = 0
            if !pendingMic.isEmpty {  // complete the partial hop first
                let take = min(hop - pendingMic.count, microphone.count)
                pendingMic.append(contentsOf: microphone[0..<take]); pendingRef.append(contentsOf: reference[0..<take])
                offset = take
                if pendingMic.count == hop {
                    let (m, r) = (pendingMic, pendingRef)
                    pendingMic.removeAll(keepingCapacity: true); pendingRef.removeAll(keepingCapacity: true)
                    try m.withUnsafeBufferPointer { mp in
                        try r.withUnsafeBufferPointer { rp in try hopThrough(mp.baseAddress!, rp.baseAddress!, into: &output) }
                    }
                }
            }
            while offset + hop <= microphone.count {
                try hopThrough(microphone.baseAddress! + offset, reference.baseAddress! + offset, into: &output)
                offset += hop
            }
            if offset < microphone.count {
                pendingMic.append(contentsOf: microphone[offset...]); pendingRef.append(contentsOf: reference[offset...])
            }
            return output
        }

        /// Flushes the partial hop and the overlap-add (one hop of zeros), and returns the rest of the
        /// output: in total, exactly as many samples as were pushed.
        public func finish() throws -> [Float] {
            let hop = LocalVQEEchoCanceller.hop
            var output = [Float]()
            let zeros = [Float](repeating: 0, count: hop)
            let owed = samplesIn - samplesOut  // what the output still lacks; the flush makes up to a hop more
            if !pendingMic.isEmpty {
                let fill = hop - pendingMic.count
                pendingMic.append(contentsOf: zeros[0..<fill]); pendingRef.append(contentsOf: zeros[0..<fill])
                let (m, r) = (pendingMic, pendingRef)
                pendingMic.removeAll(); pendingRef.removeAll()
                try m.withUnsafeBufferPointer { mp in
                    try r.withUnsafeBufferPointer { rp in try hopThrough(mp.baseAddress!, rp.baseAddress!, into: &output) }
                }
            }
            try zeros.withUnsafeBufferPointer { z in try hopThrough(z.baseAddress!, z.baseAddress!, into: &output) }
            if output.count > owed { output.removeLast(output.count - owed) }
            samplesOut = samplesIn
            return output
        }

        private func hopThrough(_ mic: UnsafePointer<Float>, _ ref: UnsafePointer<Float>, into output: inout [Float]) throws {
            let c = canceller
            guard localvqe_daf_process(c.daf, mic, ref, LocalVQEEchoCanceller.hop, &residual, &estimate) else {
                throw Failure.controllerRejected
            }
            c.analyze(frame: residual, history: &residualHistory, into: &spectrum)
            LocalVQEEchoCanceller.write(spectrum, to: micInput)
            c.analyze(frame: estimate, history: &estimateHistory, into: &spectrum)
            LocalVQEEchoCanceller.write(spectrum, to: refInput)
            try autoreleasepool {
                let inputs = try MLDictionaryFeatureProvider(dictionary: [
                    "mic_spectrum": MLFeatureValue(multiArray: micInput),
                    "reference_spectrum": MLFeatureValue(multiArray: refInput),
                ])
                let result = try c.model.prediction(from: inputs, using: state)
                guard let enhanced = result.featureValue(for: "enhanced_spectrum")?.multiArrayValue,
                      enhanced.count == 2 * LocalVQEEchoCanceller.bins
                else { throw Failure.modelOutputMissing }
                LocalVQEEchoCanceller.read(enhanced, into: &spectrum)
            }
            var completed = [Float]()
            completed.reserveCapacity(LocalVQEEchoCanceller.hop)
            c.synthesize(spectrum: spectrum, overlap: &overlap, appendingTo: &completed)
            guard completed.allSatisfy(\.isFinite) else { throw Failure.nonFiniteOutput }
            if !dropped { dropped = true; return }
            samplesOut += completed.count
            output.append(contentsOf: completed)
        }
    }

    // MARK: - STFT (512 / 256, bins 1...256; real bins then imaginary bins)

    fileprivate func analyze(frame: [Float], history: inout [Float], into spectrum: inout [Float]) {
        var real = [Float](repeating: 0, count: Self.fftSize), imaginary = [Float](repeating: 0, count: Self.fftSize)
        var windowed = history + frame
        vDSP.multiply(windowed, window, result: &windowed)
        history = frame
        let zeros = [Float](repeating: 0, count: Self.fftSize)
        vDSP_DFT_Execute(forward, windowed, zeros, &real, &imaginary)
        for bin in 0..<Self.bins {
            spectrum[bin] = real[bin + 1]
            spectrum[Self.bins + bin] = imaginary[bin + 1]
        }
    }

    fileprivate func synthesize(spectrum: [Float], overlap: inout [Float], appendingTo output: inout [Float]) {
        var real = [Float](repeating: 0, count: Self.fftSize), imaginary = [Float](repeating: 0, count: Self.fftSize)
        for bin in 0..<(Self.bins - 1) {
            real[bin + 1] = spectrum[bin]
            imaginary[bin + 1] = spectrum[Self.bins + bin]
        }
        // LocalVQE's packed spectrum carries half the real Nyquist coefficient.
        real[Self.bins] = 2 * spectrum[Self.bins - 1]
        for bin in 1..<Self.bins {
            real[Self.fftSize - bin] = real[bin]
            imaginary[Self.fftSize - bin] = -imaginary[bin]
        }
        var timeReal = [Float](repeating: 0, count: Self.fftSize), timeImaginary = timeReal
        vDSP_DFT_Execute(inverse, real, imaginary, &timeReal, &timeImaginary)
        let scale = 1 / Float(Self.fftSize)  // vDSP's inverse is unnormalised
        for i in 0..<Self.fftSize { overlap[i] += timeReal[i] * scale * window[i] }
        output.append(contentsOf: overlap[0..<Self.hop])
        overlap.replaceSubrange(0..<Self.hop, with: overlap[Self.hop..<Self.fftSize])
        for i in Self.hop..<Self.fftSize { overlap[i] = 0 }
    }

    fileprivate static func write(_ values: [Float], to array: MLMultiArray) {
        let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: values.count)
        for i in values.indices { pointer[i] = Float16(values[i]) }
    }

    fileprivate static func read(_ array: MLMultiArray, into values: inout [Float]) {
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: values.count)
            for i in values.indices { values[i] = Float(pointer[i]) }
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
            for i in values.indices { values[i] = pointer[i] }
        default:
            for i in values.indices { values[i] = array[i].floatValue }
        }
    }

    // MARK: - Assets

    /// Reads `MANIFEST.json` and checks every file it lists; returns path -> SHA-256.
    static func verifiedManifest(in directory: URL) throws -> [String: String] {
        let manifestURL = directory.appendingPathComponent("MANIFEST.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.assetMissing("MANIFEST.json") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: String], !files.isEmpty
        else { throw Failure.manifestUnreadable }
        for required in ["\(maskName)/model.mil", "\(maskName)/weights/weight.bin", controllerName, windowName]
            where files[required] == nil {
            throw Failure.assetMissing(required)
        }
        for (path, expected) in files {
            let url = directory.appendingPathComponent(path)
            guard let contents = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw Failure.assetMissing(path)
            }
            let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw Failure.assetChecksumMismatch(path) }
        }
        return files
    }

    static func floats(_ url: URL) throws -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count % 4 == 0 else {
            throw Failure.assetMissing(url.lastPathComponent)
        }
        return data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}
