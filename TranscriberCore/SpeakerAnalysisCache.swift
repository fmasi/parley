import Foundation
import os

/// The speaker analysis of the channel the open rename dialog last re-detected (#341): its
/// segmentation and speaker embeddings, so a Re-detect at another count clusters again instead of
/// decoding the audio and running the models over it again. On a long call that is the difference
/// between minutes and seconds, and #265's pass with room for one more voice reuses it too.
///
/// One per rename dialog, closed when the dialog closes (`close`). It holds ONE analysis: a channel
/// or a recording other than the one held releases the held analysis before the new one is decoded
/// (`lookup`), so a long call's audio and embeddings are never in memory twice — on the 16 GB M1 Air
/// an hour of channel audio is about 230 MB of samples (`PreparedSpeakerAnalysis`).
///
/// In memory only, never on disk: an analysis never outlives the process, so a FluidAudio update can
/// never be served one its predecessor made.
public actor SpeakerAnalysisCache {
    /// What an analysis was made from. Any difference is a different analysis.
    public struct Key: Hashable, Sendable {
        /// One audio file a channel is decoded from, as it was on disk.
        public struct File: Hashable, Sendable {
            public let path: String
            /// nil when the file could not be read: a key that never matches one made while it could.
            public let size: Int?
            public let modified: Date?

            public init(path: String, size: Int?, modified: Date?) {
                self.path = path
                self.size = size
                self.modified = modified
            }

            /// The file as it is on disk now: a stat, never a URL's cached resource values (a `URL`
            /// keeps those, so a file changed since the same URL last looked would read as unchanged).
            public static func current(_ url: URL) -> File {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return File(path: url.path, size: (attributes?[.size] as? NSNumber)?.intValue,
                            modified: attributes?[.modificationDate] as? Date)
            }
        }

        public let source: String
        /// `SpeakerAnalysisReusing.preparationIdentity`.
        public let provider: String
        public let files: [File]
        /// Whether the mic was echo-cancelled before the analysis (#342), and by what.
        public let echoCanceller: String?
        /// The transcript's timeline inputs the decode reads: chunk lengths, offsets and capture gaps.
        public let chunkDurations: [Double]
        public let chunkOffsets: [Double]?
        public let gapSeconds: [Double]
        public let hasCaptureGaps: Bool

        public init(source: String, provider: String, files: [File], echoCanceller: String?,
                    chunkDurations: [Double], chunkOffsets: [Double]?, gapSeconds: [Double], hasCaptureGaps: Bool) {
            self.source = source
            self.provider = provider
            self.files = files
            self.echoCanceller = echoCanceller
            self.chunkDurations = chunkDurations
            self.chunkOffsets = chunkOffsets
            self.gapSeconds = gapSeconds
            self.hasCaptureGaps = hasCaptureGaps
        }
    }

    private var held: (key: Key, analysis: PreparedSpeakerAnalysis)?
    private var closed = false

    public init() {}

    /// The analysis made from `key`, or nil. On a miss the analysis held for another key is released
    /// here, before the caller decodes and prepares the new one: never two at once.
    public func lookup(_ key: Key) -> PreparedSpeakerAnalysis? {
        if let held, held.key == key { return held.analysis }
        release()
        return nil
    }

    /// Keep `analysis` for `key`, in place of whatever was held. Refused once the dialog closed: a
    /// re-detect cancelled by the close can still finish its preparation, and must not leave it held.
    public func store(_ analysis: PreparedSpeakerAnalysis, for key: Key) {
        guard !closed else { return }
        held = (key, analysis)
        Logger.transcription.info(
            "Re-detect: speaker analysis kept for the dialog — \(analysis.sampleCount / 16_000, privacy: .public) s of audio, \(analysis.embeddingCount, privacy: .public) embeddings")
    }

    /// The dialog closed: release the analysis and keep none from now on.
    public func close() {
        closed = true
        release()
    }

    private func release() {
        guard held != nil else { return }
        held = nil
        Logger.transcription.info("Re-detect: speaker analysis released")
    }

    /// The key of the analysis held, if any (tests).
    var heldKey: Key? { held?.key }
}
