import Foundation

/// The far-end lift of one chunk (#374): how far the raw mic rose above its own floor while the far end
/// talked (`EchoReduction.farEndLift`), the measure echo dedup's headphone guard reads (#365 (a),
/// `EchoDeduplicator.AcousticCoupling`). Persisted on `ProcessedChunk.farEndLift` and, placed on the
/// transcript's timeline, in `metadata.acoustic_coupling.per_chunk`.
public struct FarEndLiftRecord: Codable, Equatable, Sendable {
    /// Seconds of mic audio measured: where the measure applies on the chunk's timeline.
    public let seconds: Double
    /// nil: measured, but too little far-end speech (or of its silence) to judge — unknown, as before #374.
    public let farEndLiftDB: Double?

    public init(seconds: Double, farEndLiftDB: Double?) {
        self.seconds = seconds
        self.farEndLiftDB = farEndLiftDB
    }

    /// The measure echo cancellation took on the same audio: the same frames, the same rule, so it is not
    /// measured twice.
    public init(_ record: MicEchoCancelRecord) {
        self.init(seconds: record.seconds, farEndLiftDB: record.farEndLiftDB)
    }

    enum CodingKeys: String, CodingKey {
        case seconds
        case farEndLiftDB = "far_end_lift_db"
    }
}

/// Measures the far-end lift from levels alone, without the canceller (#374): what echo cancellation records
/// when it runs (#361), for every dual-stream chunk whether or not it ran.
///
/// Both WAVs are read at 16 kHz mono a block at a time (`Mono16kReader`), as the canceller reads them, and only
/// each stream's RMS per 100 ms frame is kept (`NearEndGuard.Frames`): two lists of 18,000 values for a
/// 30-minute chunk, never the audio. The reference is cut to the mic and counts as silence past its own end,
/// as for the canceller, so the result is the canceller's own `farEndLiftDB` for the same files.
///
/// The threshold the guard applies (`EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB`, 15 dB) was
/// measured on headphones (about 0-3 dB) and loudspeakers (27-32 dB) only. The 7-15 dB band — a quiet
/// loudspeaker in a noisy room — is unmeasured: a lift there reads as "no coupling" and holds a line back.
public enum FarEndLift {
    /// Seconds read per step: what bounds the memory a chunk takes.
    static let blockSeconds = 4

    public static func measure(micURL: URL, systemURL: URL) throws -> FarEndLiftRecord {
        let rate = Int(Mono16kReader.sampleRate)
        let block = blockSeconds * rate
        let mic = try Mono16kReader(url: micURL), reference = try Mono16kReader(url: systemURL)
        let frame = NearEndGuard.frameLength(sampleRate: rate, parameters: NearEndGuard.Parameters())
        var micLevels = NearEndGuard.Frames(frame: frame), referenceLevels = micLevels
        var micCount = 0
        while true {
            let micBlock = try mic.read(maxFrames: block)
            if micBlock.isEmpty { break }
            var referenceBlock = try reference.read(maxFrames: micBlock.count)
            while referenceBlock.count < micBlock.count {
                let more = try reference.read(maxFrames: micBlock.count - referenceBlock.count)
                if more.isEmpty { break }
                referenceBlock.append(contentsOf: more)
            }
            // Silence past the reference's end, as the canceller pads it: a frame half past it is measured alike.
            if referenceBlock.count < micBlock.count {
                referenceBlock.append(contentsOf: repeatElement(0, count: micBlock.count - referenceBlock.count))
            }
            micBlock.withUnsafeBufferPointer { micLevels.add($0) }
            referenceBlock.withUnsafeBufferPointer { referenceLevels.add($0) }
            micCount += micBlock.count
        }
        let frames = (micCount + frame - 1) / frame
        let lift = EchoReduction.farEndLift(micDB: micLevels.levels(frames: frames), refDB: referenceLevels.levels(frames: frames))
        return FarEndLiftRecord(seconds: Double(micCount) / Double(rate), farEndLiftDB: lift)
    }
}
