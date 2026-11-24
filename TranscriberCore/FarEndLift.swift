import Foundation

/// The far-end lift of one chunk (#374): how far the raw mic rose above its own floor while the far end
/// talked (`EchoReduction.farEndLift`), the measure echo dedup's headphone guard reads (#365 (a),
/// `EchoDeduplicator.AcousticCoupling`). Persisted on `ProcessedChunk.farEndLift` and, placed on the
/// transcript's timeline, in `metadata.acoustic_coupling.per_chunk`.
public struct FarEndLiftRecord: Codable, Equatable, Sendable {
    /// One window of the chunk (`FarEndLift.windowSeconds`, every `hopSeconds`), on the chunk's timeline.
    public struct Window: Codable, Equatable, Sendable {
        public let start: Double
        public let seconds: Double
        /// nil: too little far-end speech (or of its silence) in the window to judge — unknown.
        public let farEndLiftDB: Double?

        public init(start: Double, seconds: Double, farEndLiftDB: Double?) {
            self.start = start
            self.seconds = seconds
            self.farEndLiftDB = farEndLiftDB
        }

        enum CodingKeys: String, CodingKey {
            case start, seconds
            case farEndLiftDB = "far_end_lift_db"
        }
    }

    /// Seconds of mic audio measured: where the measure applies on the chunk's timeline.
    public let seconds: Double
    /// The whole chunk's lift: evidence, comparable with the canceller's. nil: too little far-end speech (or
    /// of its silence) to judge.
    public let farEndLiftDB: Double?
    /// The lift per window: what echo dedup's headphone guard judges by, so a chunk that changes output
    /// halfway (laptop speakers, then headphones) is judged in each part by its own (#374 review). nil for a
    /// record taken from echo cancellation's whole-chunk measure (a chunk written before the windows).
    public let windows: [Window]?

    public init(seconds: Double, farEndLiftDB: Double?, windows: [Window]? = nil) {
        self.seconds = seconds
        self.farEndLiftDB = farEndLiftDB
        self.windows = windows
    }

    /// The measure echo cancellation took over the whole chunk: one span, no windows.
    public init(_ record: MicEchoCancelRecord) {
        self.init(seconds: record.seconds, farEndLiftDB: record.farEndLiftDB)
    }

    enum CodingKeys: String, CodingKey {
        case seconds, windows
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
/// The lift is judged per window of `windowSeconds`, one every `hopSeconds`, not over the chunk: one median for
/// 30 minutes read a chunk that began on laptop speakers and went on in headphones as "no coupling", and held
/// back the bleed lines of its first minutes under the user's name (review of #374). A window needs 30 s of
/// the far end talking and 30 s of it silent (`EchoReduction.minimumFrames`), else it is unknown. Each line is
/// judged by every window over it (`EchoDeduplicator.AcousticCoupling.isUncoupled`): held back when at least one
/// is measured and every measured one is below the line; an unmeasured window is no evidence either way. With windows 4x their hop, any moment before or after a single change of
/// output sits in a window at least three quarters on its own side of it.
///
/// The threshold the guard applies (`EchoDeduplicator.AcousticCoupling.uncoupledBelowLiftDB`, 15 dB) was
/// measured on headphones (about 0-3 dB) and loudspeakers (27-32 dB) only. The 7-15 dB band — a quiet
/// loudspeaker in a noisy room — is unmeasured: a lift there reads as "no coupling" and holds a line back.
public enum FarEndLift {
    /// Seconds read per step: what bounds the memory a chunk takes.
    static let blockSeconds = 4
    /// A window's length: room for the 30 s of far-end speech and 30 s of its silence a measure needs.
    public static let windowSeconds = 120.0
    /// How far apart windows start.
    public static let hopSeconds = 30.0

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
        let micDB = micLevels.levels(frames: frames), refDB = referenceLevels.levels(frames: frames)
        let frameSeconds = Double(frame) / Double(rate)
        return FarEndLiftRecord(seconds: Double(micCount) / Double(rate),
                                farEndLiftDB: EchoReduction.farEndLift(micDB: micDB, refDB: refDB),
                                windows: windows(micDB: micDB, refDB: refDB, frameSeconds: frameSeconds))
    }

    /// The lift per window over per-frame levels: windows of `windowSeconds` every `hopSeconds`, the last one
    /// ending at the chunk's end; one window over the whole chunk when it is shorter than a window.
    static func windows(micDB: [Double], refDB: [Double], frameSeconds: Double) -> [FarEndLiftRecord.Window] {
        let frames = min(micDB.count, refDB.count)
        guard frames > 0, frameSeconds > 0 else { return [] }
        let length = max(1, Int((windowSeconds / frameSeconds).rounded()))
        let hop = max(1, Int((hopSeconds / frameSeconds).rounded()))
        var starts = Array(stride(from: 0, through: max(0, frames - length), by: hop))
        if let last = starts.last, last + length < frames { starts.append(frames - length) }
        return starts.map { first in
            let end = min(frames, first + length)
            let lift = EchoReduction.farEndLift(micDB: Array(micDB[first..<end]), refDB: Array(refDB[first..<end]))
            return FarEndLiftRecord.Window(start: (Double(first) * frameSeconds * 1000).rounded() / 1000,
                                           seconds: (Double(end - first) * frameSeconds * 1000).rounded() / 1000,
                                           farEndLiftDB: lift)
        }
    }
}
