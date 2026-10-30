import AVFoundation
import Foundation

/// What one mic echo cancellation did, for the record (#342).
public struct MicEchoCancelReport: Equatable, Sendable {
    /// The engine and model that ran, e.g. "localvqe-v1.4-aec-coreml".
    public let engine: String
    public let modelSHA256: String
    /// Frames the near-end guard gave the raw mic back (`NearEndGuard`).
    public let framesReverted: Int
    public let seconds: Double
}

/// Writes an echo-cancelled copy of a chunk's mic WAV, using the chunk's system WAV as the far-end
/// reference. The copy is what ASR and diarization read; the raw mic stays the recording.
public protocol MicEchoCancelling: Sendable {
    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelReport
}

/// LocalVQE v1.4-AEC plus the near-end guard. Reads both WAVs at 16 kHz mono (the rate ASR uses),
/// writes a 16 kHz mono float WAV the length of the mic. A reference shorter than the mic counts as
/// silence past its end; a longer one is cut to the mic.
public struct LocalVQEMicEchoCanceller: MicEchoCancelling {
    public static let engine = "localvqe-v1.4-aec-coreml"

    public let assetsDirectory: URL
    public let guardParameters: NearEndGuard.Parameters

    public init(assetsDirectory: URL, guardParameters: NearEndGuard.Parameters = NearEndGuard.Parameters()) {
        self.assetsDirectory = assetsDirectory
        self.guardParameters = guardParameters
    }

    /// The model directory in the app bundle (`Contents/Resources/LocalVQE-CoreML`), or nil when this
    /// binary does not carry it (a bare `swift build` product).
    public static func bundledAssetsDirectory(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appendingPathComponent("LocalVQE-CoreML", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("MANIFEST.json").path) ? url : nil
    }

    public func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelReport {
        // AudioDecode: the 16 kHz mono reader the re-detect path uses (FluidAudio's own converter is
        // unreachable by name from this module; see AudioDecode).
        let mic = try AudioDecode.mono16kHzFloat(contentsOf: micURL)
        var reference = try AudioDecode.mono16kHzFloat(contentsOf: systemURL)
        if reference.count > mic.count {
            reference.removeLast(reference.count - mic.count)
        } else {
            reference.append(contentsOf: repeatElement(0, count: mic.count - reference.count))
        }
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let cleaned = try canceller.process(microphone: mic, reference: reference)
        let guarded = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: reference,
                                         sampleRate: LocalVQEEchoCanceller.sampleRate, parameters: guardParameters)
        try Self.writeWAV(guarded.samples, to: outputURL, sampleRate: LocalVQEEchoCanceller.sampleRate)
        return MicEchoCancelReport(engine: Self.engine, modelSHA256: canceller.modelSHA256,
                                   framesReverted: guarded.revertedFrames,
                                   seconds: Double(mic.count) / Double(LocalVQEEchoCanceller.sampleRate))
    }

    static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false)
        else { throw LocalVQEEchoCanceller.Failure.assetMissing("audio format") }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let block = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(block, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buffer)
            offset += n
        }
    }
}
