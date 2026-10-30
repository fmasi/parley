import AVFoundation
import Foundation

/// What mic echo cancellation did for one chunk, as the chunk's record keeps it (#342).
public struct MicEchoCancelRecord: Codable, Equatable, Sendable {
    /// The engine and model that ran, e.g. "localvqe-v1.4-aec-coreml".
    public let engine: String
    /// SHA-256 of the model's weights, verified at load.
    public let modelSHA256: String
    /// Frames the near-end guard gave the raw mic back (`NearEndGuard`).
    public let framesReverted: Int
    /// Seconds of mic audio processed.
    public let seconds: Double

    public init(engine: String, modelSHA256: String, framesReverted: Int, seconds: Double) {
        self.engine = engine
        self.modelSHA256 = modelSHA256
        self.framesReverted = framesReverted
        self.seconds = seconds
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case modelSHA256 = "model_sha256"
        case framesReverted = "frames_reverted"
        case seconds
    }
}

/// The `mic_echo_cancel` setting. An unknown value (a newer build's mode) reads as `.off`, so a
/// downgrade never fails the whole config.
public enum MicEchoCancelMode: String, Codable, Equatable, Sendable {
    case off
    case on

    public init(from decoder: Decoder) throws {
        self = MicEchoCancelMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
    }
}

/// What chunk processing does about mic echo: nothing, cancel it, or record that it could not.
public enum MicEchoCancelSetup: Sendable {
    case off
    case on(any MicEchoCancelling)
    /// The setting is on but this build cannot run it; each dual-stream chunk records `echo_cancel_failed`.
    case unavailable(reason: String)

    /// The setup the setting asks for, with the model bundled in `bundle`.
    public static func resolve(_ config: Config, bundle: Bundle = .main) -> MicEchoCancelSetup {
        guard config.micEchoCancel == .on else { return .off }
        guard let directory = LocalVQEMicEchoCanceller.bundledAssetsDirectory(bundle: bundle) else {
            return .unavailable(reason: "the echo canceller's model is not in this build")
        }
        return .on(LocalVQEMicEchoCanceller(assetsDirectory: directory))
    }
}

/// Writes an echo-cancelled copy of a chunk's mic WAV, using the chunk's system WAV as the far-end
/// reference. The copy is what ASR and diarization read; the raw mic stays the recording.
public protocol MicEchoCancelling: Sendable {
    func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord
}

/// The same cancellation on samples already decoded to 16 kHz mono: what re-detect uses on the
/// archive's two channels (#342). A reference shorter than the mic counts as silence past its end.
public protocol MicEchoSampleCancelling: Sendable {
    func cancelEcho(microphone: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int)
}

/// LocalVQE v1.4-AEC plus the near-end guard. Reads both WAVs at 16 kHz mono (the rate ASR uses),
/// writes a 16 kHz mono float WAV the length of the mic. A reference shorter than the mic counts as
/// silence past its end; a longer one is cut to the mic.
public struct LocalVQEMicEchoCanceller: MicEchoCancelling, MicEchoSampleCancelling {
    public static let engine = "localvqe-v1.4-aec-coreml"

    public enum Failure: Error, Equatable {
        /// The mic WAV decoded to no samples: nothing to cancel, and a 0-frame copy would read as a
        /// broken stream instead of an empty one.
        case emptyMicrophone
    }

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

    /// The canceller over the model bundled in this app, or nil when this binary does not carry it.
    public static func bundled(bundle: Bundle = .main) -> LocalVQEMicEchoCanceller? {
        bundledAssetsDirectory(bundle: bundle).map { LocalVQEMicEchoCanceller(assetsDirectory: $0) }
    }

    public func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        // AudioDecode: the 16 kHz mono reader the re-detect path uses (FluidAudio's own converter is
        // unreachable by name from this module; see AudioDecode).
        let mic = try AudioDecode.mono16kHzFloat(contentsOf: micURL)
        guard !mic.isEmpty else { throw Failure.emptyMicrophone }
        let reference = try AudioDecode.mono16kHzFloat(contentsOf: systemURL)
        let (cleaned, reverted, modelSHA256) = try run(microphone: mic, reference: reference)
        try Self.writeWAV(cleaned, to: outputURL, sampleRate: LocalVQEEchoCanceller.sampleRate)
        return MicEchoCancelRecord(engine: Self.engine, modelSHA256: modelSHA256, framesReverted: reverted,
                                   seconds: Double(mic.count) / Double(LocalVQEEchoCanceller.sampleRate))
    }

    public func cancelEcho(microphone: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) {
        let (cleaned, reverted, _) = try run(microphone: microphone, reference: reference)
        return (cleaned, reverted)
    }

    private func run(microphone mic: [Float], reference: [Float]) throws -> ([Float], Int, String) {
        var reference = reference
        if reference.count > mic.count {
            reference.removeLast(reference.count - mic.count)
        } else {
            reference.append(contentsOf: repeatElement(0, count: mic.count - reference.count))
        }
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let cleaned = try canceller.process(microphone: mic, reference: reference)
        let guarded = NearEndGuard.apply(microphone: mic, cleaned: cleaned, reference: reference,
                                         sampleRate: LocalVQEEchoCanceller.sampleRate, parameters: guardParameters)
        return (guarded.samples, guarded.revertedFrames, canceller.modelSHA256)
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
