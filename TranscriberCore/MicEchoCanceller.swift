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

    /// Seconds of audio read, cancelled and written per step: what bounds the memory a chunk takes.
    static let blockSeconds = 4

    /// A block at a time, in two passes over the files, so a chunk's length never sets the memory (#342):
    /// pass 1 streams both WAVs through the canceller, writes the 16 kHz mic and the cleaned mic to scratch
    /// files and keeps only each stream's RMS per 100 ms frame; the guard's decision needs the far end
    /// half a second ahead, which those levels give. Pass 2 reads the two scratch files back and writes
    /// the guarded output. The result is the same as `cancelEcho(microphone:reference:)` on the decoded files.
    public func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        let rate = LocalVQEEchoCanceller.sampleRate
        let block = Self.blockSeconds * rate
        let micReader = try Mono16kReader(url: micURL), refReader = try Mono16kReader(url: systemURL)
        let scratch = outputURL.deletingLastPathComponent()
        let mic16URL = scratch.appendingPathComponent("parley-aec-mic16-\(UUID().uuidString).wav")
        let cleanURL = scratch.appendingPathComponent("parley-aec-clean-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: mic16URL)
            try? FileManager.default.removeItem(at: cleanURL)
        }
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let stream = try LocalVQEEchoCanceller.Stream(canceller)
        let frame = NearEndGuard.frameLength(sampleRate: rate, parameters: guardParameters)
        var micLevels = NearEndGuard.Frames(frame: frame), refLevels = micLevels, cleanLevels = micLevels
        var micCount = 0
        do {
            let mic16 = try MonoWavWriter(url: mic16URL, sampleRate: rate)
            let clean = try MonoWavWriter(url: cleanURL, sampleRate: rate)
            while true {
                let micBlock = try micReader.read(maxFrames: block)
                if micBlock.isEmpty { break }
                // The reference is cut to the mic, and silence past its own end.
                var refBlock = try refReader.read(maxFrames: micBlock.count)
                while refBlock.count < micBlock.count {
                    let more = try refReader.read(maxFrames: micBlock.count - refBlock.count)
                    if more.isEmpty { break }
                    refBlock.append(contentsOf: more)
                }
                if refBlock.count < micBlock.count { refBlock.append(contentsOf: repeatElement(0, count: micBlock.count - refBlock.count)) }
                micCount += micBlock.count
                let cleaned = try micBlock.withUnsafeBufferPointer { m in
                    try refBlock.withUnsafeBufferPointer { r in
                        micLevels.add(m); refLevels.add(r)
                        return try stream.push(microphone: m, reference: r)
                    }
                }
                try mic16.write(micBlock)
                try clean.write(cleaned)
                cleaned.withUnsafeBufferPointer { cleanLevels.add($0) }
            }
            let tail = try stream.finish()
            try clean.write(tail)
            tail.withUnsafeBufferPointer { cleanLevels.add($0) }
        }
        guard micCount > 0 else { throw Failure.emptyMicrophone }

        let frames = (micCount + frame - 1) / frame
        let mask = NearEndGuard.revertMask(micDB: micLevels.levels(frames: frames), cleanDB: cleanLevels.levels(frames: frames),
                                           refDB: refLevels.levels(frames: frames), parameters: guardParameters)
        let blend = NearEndGuard.Blend(mask: mask, frame: frame, count: micCount, sampleRate: rate, parameters: guardParameters)
        let micBack = try Mono16kReader(url: mic16URL), cleanBack = try Mono16kReader(url: cleanURL)
        let out = try MonoWavWriter(url: outputURL, sampleRate: rate)
        var position = 0
        while position < micCount {
            var cleaned = try cleanBack.read(maxFrames: block)
            if cleaned.isEmpty { break }
            let raw = try micBack.read(maxFrames: cleaned.count)
            guard raw.count == cleaned.count else {
                throw LocalVQEEchoCanceller.Failure.lengthMismatch(microphone: raw.count, reference: cleaned.count)
            }
            if blend.revertedFrames > 0 { blend.apply(microphone: raw[...], to: &cleaned[...], from: position) }
            try out.write(cleaned)
            position += cleaned.count
        }
        return MicEchoCancelRecord(engine: Self.engine, modelSHA256: canceller.modelSHA256,
                                   framesReverted: blend.revertedFrames, seconds: Double(micCount) / Double(rate))
    }

    /// On samples already in memory (re-detect): the canceller streams over them a block at a time and the
    /// guard mixes in place, so only the input and the output are held.
    public func cancelEcho(microphone mic: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) {
        let rate = LocalVQEEchoCanceller.sampleRate
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let stream = try LocalVQEEchoCanceller.Stream(canceller)
        let frame = NearEndGuard.frameLength(sampleRate: rate, parameters: guardParameters)
        var micLevels = NearEndGuard.Frames(frame: frame), refLevels = micLevels
        let block = Self.blockSeconds * rate
        var cleaned = [Float]()
        cleaned.reserveCapacity(mic.count)
        let zeros = [Float](repeating: 0, count: block)
        try mic.withUnsafeBufferPointer { m in
            try reference.withUnsafeBufferPointer { r in
                var offset = 0
                while offset < m.count {
                    let n = min(block, m.count - offset)
                    let micBlock = UnsafeBufferPointer(rebasing: m[offset..<(offset + n)])
                    // The reference is cut to the mic, and silence past its own end.
                    let available = max(0, min(n, r.count - offset))
                    var refBlock = available > 0 ? Array(r[offset..<(offset + available)]) : []
                    if available < n { refBlock.append(contentsOf: zeros[0..<(n - available)]) }
                    try refBlock.withUnsafeBufferPointer { rb in
                        micLevels.add(micBlock); refLevels.add(rb)
                        cleaned.append(contentsOf: try stream.push(microphone: micBlock, reference: rb))
                    }
                    offset += n
                }
            }
        }
        cleaned.append(contentsOf: try stream.finish())
        let frames = (mic.count + frame - 1) / frame
        var cleanLevels = NearEndGuard.Frames(frame: frame)
        cleaned.withUnsafeBufferPointer { cleanLevels.add($0) }
        let mask = NearEndGuard.revertMask(micDB: micLevels.levels(frames: frames), cleanDB: cleanLevels.levels(frames: frames),
                                           refDB: refLevels.levels(frames: frames), parameters: guardParameters)
        let blend = NearEndGuard.Blend(mask: mask, frame: frame, count: mic.count, sampleRate: rate, parameters: guardParameters)
        if blend.revertedFrames > 0 { blend.apply(microphone: mic[...], to: &cleaned[...], from: 0) }
        return (cleaned, blend.revertedFrames)
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
