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
    /// The loudspeaker-to-mic delay (16 kHz samples) estimated over the whole chunk and used by the filter
    /// (#361); nil when no confident estimate was found (no echo path, e.g. headphones) or the record
    /// predates it.
    public let delaySamples: Int?
    /// How much quieter the cleaned mic is than the raw one while the far end talks (`EchoReduction`, #361);
    /// nil when there was too little of that to measure or the record predates it.
    public let erleDB: Double?
    /// How far the raw mic rises above its own quiet floor while the far end talks (`EchoReduction`, #361):
    /// whether there was an echo to remove. nil as for `erleDB`.
    public let farEndLiftDB: Double?

    public init(engine: String, modelSHA256: String, framesReverted: Int, seconds: Double,
                delaySamples: Int? = nil, erleDB: Double? = nil, farEndLiftDB: Double? = nil) {
        self.engine = engine
        self.modelSHA256 = modelSHA256
        self.framesReverted = framesReverted
        self.seconds = seconds
        self.delaySamples = delaySamples
        self.erleDB = erleDB
        self.farEndLiftDB = farEndLiftDB
    }

    /// The mic heard the far end but cancellation removed next to nothing (#361): its voice is still in the
    /// mic copy that ASR and diarization read. Recorded as `echo_cancel_ineffective`.
    public var isIneffective: Bool {
        guard let farEndLiftDB, let erleDB else { return false }
        return farEndLiftDB >= EchoReduction.audibleEchoLiftDB && erleDB < EchoReduction.ineffectiveBelowDB
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case modelSHA256 = "model_sha256"
        case framesReverted = "frames_reverted"
        case seconds
        case delaySamples = "delay_samples"
        case erleDB = "erle_db"
        case farEndLiftDB = "far_end_lift_db"
    }
}

/// Whether echo cancellation removed the echo, measured on the chunk itself (#361). A canceller that
/// removes nothing used to be recorded as a success: on 2026-11-10 a whole chunk came out with its echo
/// untouched and `chunks_failed: 0`.
///
/// Two measures over 100 ms frames, judged together:
/// - the reduction: where the far end talks (reference at or above -40 dBFS) and the mic hears something
///   (at or above -50 dBFS), the median of how much quieter the cleaned mic is than the raw one. On the
///   2026-11-10 call a working chunk measured 45 dB there and the failed one 0 dB. The user talking over the
///   far end counts toward 0 dB, so the median, not the mean, and a threshold far below a working run.
/// - the lift: whether there was an echo to remove at all. With headphones the mic hears nothing of the far
///   end and the reduction is 0 dB too, rightly. Where the far end talks, the median raw mic level above the
///   mic's own floor (its 10th percentile over the chunk): 26-31 dB on loudspeakers, 2 dB on a headphone call.
///   Steady room noise lifts nothing, since it is the floor. (The delay estimate cannot tell: GCC-PHAT
///   locks onto leakage far too faint to hear, and found a confident delay on that headphone call.)
public enum EchoReduction {
    static let referenceFloorDB = -40.0
    static let micFloorDB = -50.0
    /// Fewer frames than this (30 s of the far end talking) is too little to judge.
    static let minimumFrames = 300
    /// Below this, cancellation counts as ineffective.
    public static let ineffectiveBelowDB = 10.0
    /// At or above this lift, the mic heard the far end: there was an echo to remove.
    public static let audibleEchoLiftDB = 15.0

    /// The lift in dB, rounded to 0.1 dB; nil with fewer than `minimumFrames` frames of the far end talking.
    /// Frames padded past the clip's end (-200, `NearEndGuard.Frames.levels`) are not part of the floor.
    static func farEndLift(micDB: [Double], refDB: [Double]) -> Double? {
        let n = min(micDB.count, refDB.count)
        var heard = [Double](), all = [Double]()
        for f in 0..<n where micDB[f] > -200 {
            all.append(micDB[f])
            if refDB[f] >= referenceFloorDB { heard.append(micDB[f]) }
        }
        guard heard.count >= minimumFrames else { return nil }
        all.sort()
        let floor = all[all.count / 10]
        return ((median(&heard) - floor) * 10).rounded() / 10
    }

    private static func median(_ values: inout [Double]) -> Double {
        values.sort()
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    /// The median reduction in dB, rounded to 0.1 dB; nil with fewer than `minimumFrames` frames to measure.
    /// The three level lists are per frame (`NearEndGuard.Frames.levels`); frames past the shortest are ignored.
    static func measure(micDB: [Double], cleanDB: [Double], refDB: [Double]) -> Double? {
        let n = min(micDB.count, cleanDB.count, refDB.count)
        var reductions = [Double]()
        for f in 0..<n where refDB[f] >= referenceFloorDB && micDB[f] >= micFloorDB {
            reductions.append(micDB[f] - cleanDB[f])
        }
        guard reductions.count >= minimumFrames else { return nil }
        return (median(&reductions) * 10).rounded() / 10
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

/// The canceller's input, as both cancel paths take it: the reference cut to the mic, and silence past its own end.
private func referenceBlock(_ reference: UnsafeBufferPointer<Float>, from offset: Int, count n: Int) -> [Float] {
    let available = max(0, min(n, reference.count - offset))
    var block = available > 0 ? Array(reference[offset..<(offset + available)]) : []
    if available < n { block.append(contentsOf: repeatElement(0, count: n - available)) }
    return block
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
        /// The mic read ended before the file's stated length (16 kHz samples).
        case shortRead(read: Int, expected: Int)
    }

    /// Resampler rounding allowed between a file's stated length and what a complete read returns.
    static let lengthToleranceFrames = 160

    /// Throws when a read of a file with an exact length (PCM) ended short of it. AVAudioFile already
    /// caps a WAV's length at the data it holds, so this catches a read that stopped early (a resampler
    /// that drained short, a file shrinking under the reader), not a lying header.
    static func checkComplete(read: Int, expected: Int, lengthIsEstimate: Bool) throws {
        if !lengthIsEstimate, read < expected - lengthToleranceFrames {
            throw Failure.shortRead(read: read, expected: expected)
        }
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

    /// A block at a time, in three passes over the files, so a chunk's length never sets the memory (#342):
    /// pass 1 decodes both WAVs to 16 kHz scratch files and estimates the echo delay over the whole chunk
    /// (#361); pass 2 streams the scratch files through the canceller at that delay, writes the cleaned mic
    /// to a scratch file and keeps only each stream's RMS per 100 ms frame; the guard's decision needs the far
    /// end half a second ahead, which those levels give. Pass 3 reads the mic and the cleaned mic back and
    /// writes the guarded output. The result is the same as `cancelEcho(microphone:reference:)` on the decoded files.
    public func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL) throws -> MicEchoCancelRecord {
        let rate = LocalVQEEchoCanceller.sampleRate
        let block = Self.blockSeconds * rate
        let micReader = try Mono16kReader(url: micURL), refReader = try Mono16kReader(url: systemURL)
        let scratch = outputURL.deletingLastPathComponent()
        let mic16URL = scratch.appendingPathComponent("parley-aec-mic16-\(UUID().uuidString).wav")
        let ref16URL = scratch.appendingPathComponent("parley-aec-ref16-\(UUID().uuidString).wav")
        let cleanURL = scratch.appendingPathComponent("parley-aec-clean-\(UUID().uuidString).wav")
        defer {
            for url in [mic16URL, ref16URL, cleanURL] { try? FileManager.default.removeItem(at: url) }
        }
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        var micCount = 0
        do {
            let mic16 = try MonoWavWriter(url: mic16URL, sampleRate: rate)
            let ref16 = try MonoWavWriter(url: ref16URL, sampleRate: rate)
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
                try micBlock.withUnsafeBufferPointer { m in
                    try refBlock.withUnsafeBufferPointer { r in try estimate.push(microphone: m, reference: r) }
                }
                try mic16.write(micBlock)
                try ref16.write(refBlock)
            }
        }
        guard micCount > 0 else { throw Failure.emptyMicrophone }
        // The whole mic, or nothing: a read that ended early (a truncated file, a header that claims
        // more than the file holds) would hand ASR a shorter mic and lose the chunk's end without a
        // word. The caller then falls back to the raw mic and records `echo_cancel_failed`.
        try Self.checkComplete(read: micCount, expected: micReader.expectedFrames, lengthIsEstimate: micReader.lengthIsEstimate)

        let stream = try LocalVQEEchoCanceller.Stream(canceller, delay: estimate)
        let frame = NearEndGuard.frameLength(sampleRate: rate, parameters: guardParameters)
        var micLevels = NearEndGuard.Frames(frame: frame), refLevels = micLevels, cleanLevels = micLevels
        do {
            let micIn = try Mono16kReader(url: mic16URL), refIn = try Mono16kReader(url: ref16URL)
            let clean = try MonoWavWriter(url: cleanURL, sampleRate: rate)
            var position = 0
            while position < micCount {
                let micBlock = try micIn.read(maxFrames: block)
                if micBlock.isEmpty { break }
                let refBlock = try refIn.read(maxFrames: micBlock.count)
                guard refBlock.count == micBlock.count else {
                    throw LocalVQEEchoCanceller.Failure.lengthMismatch(microphone: micBlock.count, reference: refBlock.count)
                }
                let cleaned = try micBlock.withUnsafeBufferPointer { m in
                    try refBlock.withUnsafeBufferPointer { r in
                        micLevels.add(m); refLevels.add(r)
                        return try stream.push(microphone: m, reference: r)
                    }
                }
                try clean.write(cleaned)
                cleaned.withUnsafeBufferPointer { cleanLevels.add($0) }
                position += micBlock.count
            }
            guard position == micCount else { throw Failure.shortRead(read: position, expected: micCount) }
            let tail = try stream.finish()
            try clean.write(tail)
            tail.withUnsafeBufferPointer { cleanLevels.add($0) }
        }

        let frames = (micCount + frame - 1) / frame
        let micDB = micLevels.levels(frames: frames), cleanDB = cleanLevels.levels(frames: frames)
        let refDB = refLevels.levels(frames: frames)
        let erle = EchoReduction.measure(micDB: micDB, cleanDB: cleanDB, refDB: refDB)
        let lift = EchoReduction.farEndLift(micDB: micDB, refDB: refDB)
        let mask = NearEndGuard.revertMask(micDB: micDB, cleanDB: cleanDB, refDB: refDB, parameters: guardParameters)
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
        // The output too: the whole mic, or the chunk falls back to the raw one.
        guard position == micCount else { throw Failure.shortRead(read: position, expected: micCount) }
        return MicEchoCancelRecord(engine: Self.engine, modelSHA256: canceller.modelSHA256,
                                   framesReverted: blend.revertedFrames, seconds: Double(micCount) / Double(rate),
                                   delaySamples: stream.estimatedDelay, erleDB: erle, farEndLiftDB: lift)
    }

    /// On samples already in memory (re-detect): the delay is estimated over all of them first (#361), then
    /// the canceller streams over them a block at a time and the guard mixes in place, so only the input and
    /// the output are held.
    public func cancelEcho(microphone mic: [Float], reference: [Float]) throws -> (samples: [Float], framesReverted: Int) {
        let rate = LocalVQEEchoCanceller.sampleRate
        let canceller = try LocalVQEEchoCanceller(assetsDirectory: assetsDirectory)
        let block = Self.blockSeconds * rate
        let estimate = LocalVQEEchoCanceller.DelayEstimate(canceller)
        try mic.withUnsafeBufferPointer { m in
            try reference.withUnsafeBufferPointer { r in
                var offset = 0
                while offset < m.count {
                    let n = min(block, m.count - offset)
                    let refBlock = referenceBlock(r, from: offset, count: n)
                    try refBlock.withUnsafeBufferPointer { rb in
                        try estimate.push(microphone: UnsafeBufferPointer(rebasing: m[offset..<(offset + n)]), reference: rb)
                    }
                    offset += n
                }
            }
        }
        let stream = try LocalVQEEchoCanceller.Stream(canceller, delay: estimate)
        let frame = NearEndGuard.frameLength(sampleRate: rate, parameters: guardParameters)
        var micLevels = NearEndGuard.Frames(frame: frame), refLevels = micLevels
        var cleaned = [Float]()
        cleaned.reserveCapacity(mic.count)
        try mic.withUnsafeBufferPointer { m in
            try reference.withUnsafeBufferPointer { r in
                var offset = 0
                while offset < m.count {
                    let n = min(block, m.count - offset)
                    let micBlock = UnsafeBufferPointer(rebasing: m[offset..<(offset + n)])
                    let refBlock = referenceBlock(r, from: offset, count: n)
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
